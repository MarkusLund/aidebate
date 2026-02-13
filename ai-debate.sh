#!/usr/bin/env bash
set -euo pipefail

# Detect available tools
HAS_CLAUDE=false; HAS_CODEX=false; HAS_GEMINI=false
command -v claude >/dev/null 2>&1 && HAS_CLAUDE=true
command -v codex >/dev/null 2>&1 && HAS_CODEX=true
command -v gemini >/dev/null 2>&1 && HAS_GEMINI=true
command -v jq >/dev/null 2>&1 || { echo "Error: 'jq' not found in PATH"; exit 1; }
if ! $HAS_CLAUDE && ! $HAS_CODEX && ! $HAS_GEMINI; then
  echo "Error: No AI tools found ('claude', 'codex', or 'gemini')"; exit 1
fi

# Determine agent assignments
if $HAS_CLAUDE && $HAS_CODEX; then
  AGENT_A_CMD=claude; AGENT_B_CMD=codex
  AGENT_A_NAME="Claude"; AGENT_B_NAME="Codex"
  AGENT_A_COLOR='\033[1;34m'; AGENT_B_COLOR='\033[1;32m'
elif $HAS_CLAUDE && $HAS_GEMINI; then
  AGENT_A_CMD=claude; AGENT_B_CMD=gemini
  AGENT_A_NAME="Claude"; AGENT_B_NAME="Gemini"
  AGENT_A_COLOR='\033[1;34m'; AGENT_B_COLOR='\033[1;35m'
elif $HAS_CODEX && $HAS_GEMINI; then
  AGENT_A_CMD=codex; AGENT_B_CMD=gemini
  AGENT_A_NAME="Codex"; AGENT_B_NAME="Gemini"
  AGENT_A_COLOR='\033[1;32m'; AGENT_B_COLOR='\033[1;35m'
elif $HAS_CLAUDE; then
  echo "Warning: Only 'claude' found. Using claude for both agents."
  AGENT_A_CMD=claude; AGENT_B_CMD=claude
  AGENT_A_NAME="Claude (1)"; AGENT_B_NAME="Claude (2)"
  AGENT_A_COLOR='\033[1;34m'; AGENT_B_COLOR='\033[1;36m'
elif $HAS_CODEX; then
  echo "Warning: Only 'codex' found. Using codex for both agents."
  AGENT_A_CMD=codex; AGENT_B_CMD=codex
  AGENT_A_NAME="Codex (1)"; AGENT_B_NAME="Codex (2)"
  AGENT_A_COLOR='\033[1;32m'; AGENT_B_COLOR='\033[1;36m'
else
  echo "Warning: Only 'gemini' found. Using gemini for both agents."
  AGENT_A_CMD=gemini; AGENT_B_CMD=gemini
  AGENT_A_NAME="Gemini (1)"; AGENT_B_NAME="Gemini (2)"
  AGENT_A_COLOR='\033[1;35m'; AGENT_B_COLOR='\033[1;36m'
fi

# macOS doesn't have timeout by default (coreutils provides gtimeout)
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD=gtimeout
else
  # Fallback: no timeout enforcement
  TIMEOUT_CMD=""
fi

run_with_timeout() {
  if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" "${API_TIMEOUT}s" "$@"
  else
    "$@"
  fi
}

# AI Debate: Agent A vs Agent B

CLAUDE_MODELS=("haiku" "sonnet" "opus")
CODEX_MODELS=("gpt-5.1-codex-mini" "gpt-5.2-codex")
GEMINI_MODELS=("gemini-2.5-flash" "gemini-3-flash-preview")
CLAUDE_MODEL=""
CODEX_MODEL=""
GEMINI_MODEL=""

MAX_MESSAGES=10
API_TIMEOUT=60
MAX_RETRIES=3
RETRY_BASE_DELAY=5
DEBUG=false
SYSTEM_PROMPT_FILE=""
OUTPUT_FILE=""
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# Utility functions for user feedback

# Read user input with timeout (prevents indefinite hangs)
# Usage: read_with_timeout timeout_seconds prompt default_value
# Sets REPLY variable with the result
read_with_timeout() {
  local timeout="$1" prompt="$2" default="$3"
  printf "%s" "$prompt"
  if ! read -t "$timeout" -r REPLY; then
    REPLY="$default"
    echo ""
    echo -e "${GRAY}Timeout after ${timeout}s, using default: $default${NC}"
  fi
  [[ -z "$REPLY" ]] && REPLY="$default"
  return 0
}

# Validate numeric choice is within valid range
# Usage: validated=$(validate_choice "$input" min max default) || continue
validate_choice() {
  local input="$1" min="$2" max="$3" default="$4"
  if [[ -z "$input" ]]; then
    echo "$default"
    return 0
  fi
  if ! [[ "$input" =~ ^[0-9]+$ ]] || [[ "$input" -lt "$min" || "$input" -gt "$max" ]]; then
    echo -e "${YELLOW}Invalid choice: must be $min-$max${NC}" >&2
    return 1
  fi
  echo "$input"
}

# Spinner for visual feedback during long operations
SPINNER_PID=""
start_spinner() {
  local msg="$1"
  # Non-TTY: just print static message
  if [[ ! -t 1 ]]; then
    echo -e "${GRAY}${msg}${NC}"
    return
  fi
  ( while true; do
      for c in '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'; do
        printf "\r${GRAY}%s %s${NC}" "$c" "$msg"
        sleep 0.1
      done
    done ) &
  SPINNER_PID=$!
}

stop_spinner() {
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    printf "\r\033[K"
    SPINNER_PID=""
  fi
}

# Display a countdown during backoff waits
# Usage: countdown_wait seconds label
countdown_wait() {
  local secs="$1" label="$2"
  if [[ -t 1 ]]; then
    for (( i=secs; i>0; i-- )); do
      printf "\r${YELLOW}${label}: retrying in ${i}s...${NC}\033[K"
      sleep 1
    done
    printf "\r\033[K"
  else
    echo -e "${YELLOW}${label}: retrying in ${secs}s...${NC}"
    sleep "$secs"
  fi
}

# Check if a file contains rate limit indicators
# Usage: _is_rate_limited file
_is_rate_limited() {
  local file="$1"
  [[ -f "$file" ]] && grep -qiE "rate.?limit|too.?many.?requests|429|quota.?exceeded" "$file"
}

# Dual spinner for Round 0 parallel execution
DUAL_SPINNER_PID=""
DUAL_SPINNER_AGENT_A=""
DUAL_SPINNER_AGENT_B=""
DUAL_SPINNER_COLOR_A=""
DUAL_SPINNER_COLOR_B=""

# Start dual spinner showing status for both agents
# Usage: start_dual_spinner agent_a_name agent_b_name agent_a_color agent_b_color
start_dual_spinner() {
  DUAL_SPINNER_AGENT_A="$1"
  DUAL_SPINNER_AGENT_B="$2"
  DUAL_SPINNER_COLOR_A="$3"
  DUAL_SPINNER_COLOR_B="$4"

  # Non-TTY: just print static messages
  if [[ ! -t 1 ]]; then
    echo -e "${GRAY}Round 0: Both agents thinking in parallel...${NC}"
    echo -e "${GRAY}  ${DUAL_SPINNER_AGENT_A}: working...${NC}"
    echo -e "${GRAY}  ${DUAL_SPINNER_AGENT_B}: working...${NC}"
    return
  fi

  # Print header and two status lines
  echo -e "${GRAY}Round 0: Both agents thinking in parallel...${NC}"
  echo ""
  echo ""

  # Spawn background process to animate spinners
  (
    local spinners=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local idx=0
    local done_a=false done_b=false

    while true; do
      local char="${spinners[$idx]}"
      idx=$(( (idx + 1) % 10 ))

      # Check completion status
      [[ -f "$tmpdir/agent_a_r0_exit" ]] && done_a=true
      [[ -f "$tmpdir/agent_b_r0_exit" ]] && done_b=true

      # Build status for agent A
      local status_a
      if $done_a; then
        status_a="${DUAL_SPINNER_COLOR_A}  ✓ ${DUAL_SPINNER_AGENT_A}${NC}"
      else
        status_a="${GRAY}  ${char} ${DUAL_SPINNER_AGENT_A}${NC}"
      fi

      # Build status for agent B
      local status_b
      if $done_b; then
        status_b="${DUAL_SPINNER_COLOR_B}  ✓ ${DUAL_SPINNER_AGENT_B}${NC}"
      else
        status_b="${GRAY}  ${char} ${DUAL_SPINNER_AGENT_B}${NC}"
      fi

      # Move cursor up 2 lines, print status, clear to end of line
      printf "\033[2A"
      printf "\r\033[K"
      echo -e "$status_a"
      printf "\r\033[K"
      echo -e "$status_b"

      sleep 0.1
    done
  ) &
  DUAL_SPINNER_PID=$!
}

# Stop dual spinner and show final state
stop_dual_spinner() {
  if [[ -n "$DUAL_SPINNER_PID" ]]; then
    kill "$DUAL_SPINNER_PID" 2>/dev/null || true
    wait "$DUAL_SPINNER_PID" 2>/dev/null || true
    DUAL_SPINNER_PID=""

    # Non-TTY: just print completion
    if [[ ! -t 1 ]]; then
      echo -e "${GRAY}Round 0 complete${NC}"
      return
    fi

    # Print final state with checkmarks
    printf "\033[2A"
    printf "\r\033[K"
    echo -e "${DUAL_SPINNER_COLOR_A}  ✓ ${DUAL_SPINNER_AGENT_A}${NC}"
    printf "\r\033[K"
    echo -e "${DUAL_SPINNER_COLOR_B}  ✓ ${DUAL_SPINNER_AGENT_B}${NC}"
  fi
}

# Warn on empty API responses
validate_response() {
  local response="$1" agent="$2"
  if [[ -z "$response" || "$response" =~ ^[[:space:]]*$ ]]; then
    echo -e "${YELLOW}Warning: ${agent} returned empty response${NC}" >&2
    [[ "$DEBUG" != true ]] && echo -e "${GRAY}Hint: Re-run with --debug to inspect raw output${NC}" >&2
    return 1
  fi
  return 0
}

# Validate JSON before parsing API responses
validate_json() {
  local raw="$1" label="$2"
  if [[ -z "$raw" ]]; then
    echo "ERROR: $label returned empty response." >&2
    return 1
  fi
  if ! echo "$raw" | jq -e . >/dev/null 2>&1; then
    # Check for rate limit patterns before generic error
    if echo "$raw" | grep -qiE "rate.?limit|too.?many.?requests|429|quota.?exceeded"; then
      echo "ERROR: $label hit rate limit." >&2
      return 2
    else
      echo "ERROR: $label returned invalid JSON. Use --debug to inspect." >&2
    fi
    return 1
  fi
  return 0
}

# Parse CLI flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-rounds)
      MAX_MESSAGES="$2"; shift 2 ;;
    --timeout)
      API_TIMEOUT="$2"; shift 2 ;;
    --max-retries)
      MAX_RETRIES="$2"; shift 2 ;;
    --system-prompt-file)
      SYSTEM_PROMPT_FILE="$2"; shift 2 ;;
    --claude-model)
      CLAUDE_MODEL="$2"; shift 2 ;;
    --codex-model)
      CODEX_MODEL="$2"; shift 2 ;;
    --gemini-model)
      GEMINI_MODEL="$2"; shift 2 ;;
    --debug)
      DEBUG=true; shift ;;
    --output|-o)
      OUTPUT_FILE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: bash ai-debate.sh [OPTIONS] \"<problem>\""
      echo ""
      echo "Options:"
      echo "  --max-rounds N          Max number of messages (default: 10)"
      echo "  --timeout N             API timeout in seconds (default: 60)"
      echo "  --max-retries N         Max retries on rate limit (default: 3)"
      echo "  --claude-model MODEL    Claude model (haiku, sonnet, opus)"
      echo "  --codex-model MODEL     Codex model (gpt-5.1-codex-mini, gpt-5.2-codex)"
      echo "  --gemini-model MODEL    Gemini model (gemini-2.5-flash, gemini-3-flash-preview)"
      echo "  --system-prompt-file F  Read system prompt from file"
      echo "  --output, -o FILE       Save debate transcript to JSON file"
      echo "  --debug                 Keep raw API responses and show tmpdir"
      echo "  --help, -h              Show this help"
      exit 0
      ;;
    -*)
      echo "Unknown flag: $1"; exit 1 ;;
    *)
      break ;;
  esac
done

if [[ $# -eq 0 ]]; then
  # No problem provided — open an editor for multiline input
  EDITORS=()
  EDITOR_NAMES=()
  # Detect available editors
  command -v nano &>/dev/null && EDITORS+=("nano") && EDITOR_NAMES+=("nano")
  command -v vim &>/dev/null && EDITORS+=("vim") && EDITOR_NAMES+=("vim")
  command -v vi &>/dev/null && [[ ! " ${EDITORS[*]} " =~ " vim " ]] && EDITORS+=("vi") && EDITOR_NAMES+=("vi")
  command -v code &>/dev/null && EDITORS+=("code --wait") && EDITOR_NAMES+=("VS Code")
  command -v cursor &>/dev/null && EDITORS+=("cursor --wait") && EDITOR_NAMES+=("Cursor")

  if [[ ${#EDITORS[@]} -eq 0 ]]; then
    echo "Error: No text editor found. Please provide your problem as an argument."
    echo "Usage: bash ai-debate.sh [OPTIONS] \"<problem>\""
    exit 1
  fi

  echo "No problem provided. Select an editor to write your problem:"
  for i in "${!EDITOR_NAMES[@]}"; do
    echo "  $((i+1))) ${EDITOR_NAMES[$i]}"
  done
  printf "Choice [1]: "
  read -r choice
  choice=${choice:-1}
  SELECTED_EDITOR="${EDITORS[$((choice-1))]}"

  TMPFILE=$(mktemp /tmp/aidebate-problem.XXXXXX) || exit 1
  $SELECTED_EDITOR "$TMPFILE"

  PROBLEM=$(cat "$TMPFILE")
  rm -f "$TMPFILE"

  if [[ -z "$PROBLEM" ]]; then
    echo "Error: No problem provided. Aborting."
    exit 1
  fi
else
  PROBLEM="$*"
fi

# Interactive model selection (only for agents in use)
# 30 second timeout for model selection prompts
MODEL_SELECT_TIMEOUT=30

# Generic model selection function
# Usage: select_model VAR_NAME "Display Name" model1 model2 ...
select_model() {
  local var_name="$1" display_name="$2"
  shift 2
  local models
  models=("$@")
  local current_val="${!var_name}"

  # Skip if already set via CLI
  [[ -n "$current_val" ]] && return

  echo "Select $display_name model:"
  for i in "${!models[@]}"; do
    echo "  $((i+1))) ${models[$i]}"
  done
  while true; do
    read_with_timeout "$MODEL_SELECT_TIMEOUT" "Choice [1]: " "1"
    if validated=$(validate_choice "$REPLY" 1 "${#models[@]}" 1); then
      printf -v "$var_name" '%s' "${models[$((validated-1))]}"
      echo -e "${GRAY}Selected $display_name model: ${!var_name}${NC}"
      break
    fi
  done
}

# Select models for agents in use
[[ "$AGENT_A_CMD" == "claude" || "$AGENT_B_CMD" == "claude" ]] && select_model CLAUDE_MODEL "Claude" "${CLAUDE_MODELS[@]}"
[[ "$AGENT_A_CMD" == "codex" || "$AGENT_B_CMD" == "codex" ]] && select_model CODEX_MODEL "Codex" "${CODEX_MODELS[@]}"
[[ "$AGENT_A_CMD" == "gemini" || "$AGENT_B_CMD" == "gemini" ]] && select_model GEMINI_MODEL "Gemini" "${GEMINI_MODELS[@]}"

SYSTEM_PROMPT="You are participating in a critical debate with another AI agent to solve a problem.

IMPORTANT GUIDELINES:
1. Be THOROUGH and CRITICAL - do not agree too quickly. Challenge assumptions, identify gaps, and push back on incomplete analyses.
2. Provide DETAILED EVIDENCE for your claims - cite specific code, line numbers, documentation, or reasoning.
3. If the other agent proposes a hypothesis, stress-test it. Look for edge cases, alternative explanations, or overlooked factors.
4. Only agree when you are CONVINCED the analysis is complete and correct. If something is missing, say so.
5. Each response should ADD NEW INFORMATION or INSIGHTS - don't just restate what's already been said.

This first message is your chance to think deeply through the problem. Explore multiple angles, consider alternative hypotheses, and formulate a well-reasoned position. Be thorough, not brief.

After this you will receive the other agent's perspective, and you will exchange responses back and forth. Challenge each other constructively to arrive at the best possible conclusion.

Max $MAX_MESSAGES messages total.
When you are fully satisfied that a complete and correct conclusion has been reached, write it on its own line starting with \"AGREED:\" followed by the conclusion. Do NOT agree prematurely."

if [[ -n "$SYSTEM_PROMPT_FILE" ]]; then
  if [[ ! -f "$SYSTEM_PROMPT_FILE" ]]; then
    echo "Error: System prompt file '$SYSTEM_PROMPT_FILE' does not exist."
    exit 1
  fi
  SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")
fi

agent_a_session=""
agent_b_session=""
msg_count=0
debug_counter=0

# Extension feature state
EXTENSION_CONTEXT=""
EXTENSION_CONTEXT_SENT_A=false
EXTENSION_CONTEXT_SENT_B=false
DEBATE_AGREED=false
DEBATE_CONCLUSION=""

# Transcript recording for --output
TRANSCRIPT_MESSAGES="[]"

# Add a message to the transcript
# Usage: transcript_add "agent_id" "content"
transcript_add() {
  local agent="$1" content="$2"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  TRANSCRIPT_MESSAGES=$(echo "$TRANSCRIPT_MESSAGES" | jq --arg agent "$agent" --arg content "$content" --arg ts "$timestamp" \
    '. + [{"agent": $agent, "content": $content, "timestamp": $ts}]')
}

# Write transcript to output file
write_transcript() {
  [[ -z "$OUTPUT_FILE" ]] && return
  local conclusion="${DEBATE_CONCLUSION:-No agreement reached}"
  jq -n \
    --arg problem "$PROBLEM" \
    --arg agent_a_name "$AGENT_A_NAME" \
    --arg agent_a_model "$(_agent_model "$AGENT_A_CMD")" \
    --arg agent_b_name "$AGENT_B_NAME" \
    --arg agent_b_model "$(_agent_model "$AGENT_B_CMD")" \
    --arg conclusion "$conclusion" \
    --argjson messages "$TRANSCRIPT_MESSAGES" \
    '{
      "problem": $problem,
      "agents": {
        "a": {"name": $agent_a_name, "model": $agent_a_model},
        "b": {"name": $agent_b_name, "model": $agent_b_model}
      },
      "messages": $messages,
      "conclusion": $conclusion
    }' > "$OUTPUT_FILE"
  echo -e "${GRAY}Transcript saved to: $OUTPUT_FILE${NC}"
}

# Temp dir for round 0 communication and debug output
tmpdir=$(mktemp -d)
if [[ "$DEBUG" == true ]]; then
  echo -e "${GRAY}Debug: tmpdir=$tmpdir${NC}"
fi

# Unified cleanup function
cleanup() {
  stop_spinner 2>/dev/null
  stop_dual_spinner 2>/dev/null
  [[ "$DEBUG" != true ]] && rm -rf "$tmpdir"
}
trap cleanup EXIT

debug_save() {
  if [[ "$DEBUG" == true ]]; then
    debug_counter=$((debug_counter + 1))
    local label="$1"
    local content="$2"
    echo "$content" > "$tmpdir/${debug_counter}_${label}.raw"
  fi
}

parse_claude_output() {
  local raw="$1" sid_file="$2"
  local sid
  sid=$(echo "$raw" | jq -r '.session_id // empty' 2>/dev/null) || true
  if [[ -n "$sid" ]]; then
    echo "$sid" > "$sid_file"
  fi
  echo "$raw" | jq -r '.result // empty' 2>/dev/null
}

parse_gemini_output() {
  local raw="$1" sid_file="$2"
  local sid
  sid=$(echo "$raw" | jq -r '.session_id // empty' 2>/dev/null) || true
  if [[ -n "$sid" ]]; then
    echo "$sid" > "$sid_file"
  fi
  echo "$raw" | jq -r '.response // empty' 2>/dev/null
}

parse_codex_output() {
  local raw="$1" sid_file="$2"
  local sid
  sid=$(echo "$raw" | jq -r 'select(.type=="thread.started") | .thread_id // empty' 2>/dev/null | head -1) || true
  if [[ -n "$sid" ]]; then
    echo "$sid" > "$sid_file"
  fi
  local text
  text=$(echo "$raw" | jq -r 'select(.type=="item.completed" and .item.type=="agent_message") | .item.text // empty' 2>/dev/null | tail -1) || true
  if [[ -z "$text" ]]; then
    echo "ERROR: Failed to parse Codex output (no agent_message found in response)" >&2
    return 1
  fi
  echo "$text"
}

# Generic call function: call_agent <cmd> <session_var_name> <agent_label> <msg>
_call_agent() {
  local cmd="$1" session_var="$2" label="$3" msg="$4"
  local session="${!session_var}"
  local raw err_file="$tmpdir/${label}_err"
  local attempt=0 rate_limited=false

  while true; do
    rate_limited=false

    if [[ "$cmd" == "claude" ]]; then
      local args=(claude -p "$msg" --model "$CLAUDE_MODEL" --output-format json)
      if [[ -n "$session" ]]; then
        args+=(--resume "$session")
      fi
      if ! raw=$(run_with_timeout "${args[@]}" 2>"$err_file"); then
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
          echo "ERROR: $label API call timed out after ${API_TIMEOUT}s" >&2
          return 1
        elif _is_rate_limited "$err_file"; then
          rate_limited=true
        else
          echo "ERROR: $label API call failed (exit $exit_code): $(cat "$err_file")" >&2
          return 1
        fi
      fi
      if [[ "$rate_limited" != true ]]; then
        debug_save "$label" "$raw"
        local vj_exit=0
        if validate_json "$raw" "$label"; then
          vj_exit=0
        else
          vj_exit=$?
        fi
        if [[ $vj_exit -eq 2 ]]; then
          rate_limited=true
        elif [[ $vj_exit -ne 0 ]]; then
          return 1
        fi
      fi
      if [[ "$rate_limited" != true ]]; then
        if [[ -z "$session" ]]; then
          local new_sid
          new_sid=$(echo "$raw" | jq -r '.session_id // empty' 2>/dev/null) || true
          printf -v "$session_var" '%s' "$new_sid"
        fi
        echo "$raw" | jq -r '.result // empty' 2>/dev/null
        return 0
      fi
    elif [[ "$cmd" == "gemini" ]]; then
      local args=(gemini -p "$msg" -o json -m "$GEMINI_MODEL")
      if [[ -n "$session" ]]; then
        args+=(--resume "$session")
      fi
      if ! raw=$(run_with_timeout "${args[@]}" 2>"$err_file"); then
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
          echo "ERROR: $label API call timed out after ${API_TIMEOUT}s" >&2
          return 1
        elif _is_rate_limited "$err_file"; then
          rate_limited=true
        else
          echo "ERROR: $label API call failed (exit $exit_code): $(cat "$err_file")" >&2
          return 1
        fi
      fi
      if [[ "$rate_limited" != true ]]; then
        debug_save "$label" "$raw"
        local vj_exit=0
        if validate_json "$raw" "$label"; then
          vj_exit=0
        else
          vj_exit=$?
        fi
        if [[ $vj_exit -eq 2 ]]; then
          rate_limited=true
        elif [[ $vj_exit -ne 0 ]]; then
          return 1
        fi
      fi
      if [[ "$rate_limited" != true ]]; then
        if [[ -z "$session" ]]; then
          local new_sid
          new_sid=$(echo "$raw" | jq -r '.session_id // empty' 2>/dev/null) || true
          printf -v "$session_var" '%s' "$new_sid"
        fi
        echo "$raw" | jq -r '.response // empty' 2>/dev/null
        return 0
      fi
    else
      # codex
      if [[ -z "$session" ]]; then
        if ! raw=$(run_with_timeout codex exec -m "$CODEX_MODEL" -c 'model_reasoning_effort="medium"' "$msg" --json 2>"$err_file"); then
          local exit_code=$?
          if [[ $exit_code -eq 124 ]]; then
            echo "ERROR: $label API call timed out after ${API_TIMEOUT}s" >&2
            return 1
          elif _is_rate_limited "$err_file"; then
            rate_limited=true
          else
            echo "ERROR: $label API call failed (exit $exit_code): $(cat "$err_file")" >&2
            return 1
          fi
        fi
      else
        if ! raw=$(run_with_timeout codex exec resume "$session" -m "$CODEX_MODEL" -c 'model_reasoning_effort="medium"' "$msg" --json 2>"$err_file"); then
          local exit_code=$?
          if [[ $exit_code -eq 124 ]]; then
            echo "ERROR: $label API call timed out after ${API_TIMEOUT}s" >&2
            return 1
          elif _is_rate_limited "$err_file"; then
            rate_limited=true
          else
            echo "ERROR: $label API call failed (exit $exit_code): $(cat "$err_file")" >&2
            return 1
          fi
        fi
      fi
      if [[ "$rate_limited" != true ]]; then
        debug_save "$label" "$raw"
        if [[ -z "$raw" ]]; then
          echo "ERROR: $label returned empty response." >&2
          return 1
        fi
        if echo "$raw" | grep -qiE "rate.?limit|too.?many.?requests|429|quota.?exceeded"; then
          rate_limited=true
        fi
      fi
      if [[ "$rate_limited" != true ]]; then
        if [[ -z "$session" ]]; then
          local new_sid
          new_sid=$(echo "$raw" | jq -r 'select(.type=="thread.started") | .thread_id // empty' 2>/dev/null | head -1) || true
          printf -v "$session_var" '%s' "$new_sid"
        fi
        local codex_text
        codex_text=$(echo "$raw" | jq -r 'select(.type=="item.completed" and .item.type=="agent_message") | .item.text // empty' 2>/dev/null | tail -1) || true
        if [[ -z "$codex_text" ]]; then
          echo "ERROR: $label returned no parsable response. Re-run with --debug to inspect raw output." >&2
          return 1
        fi
        echo "$codex_text"
        return 0
      fi
    fi

    # Rate limited — retry with exponential backoff
    if [[ $attempt -ge $MAX_RETRIES ]]; then
      echo "ERROR: $label rate limited, gave up after $MAX_RETRIES retries." >&2
      return 1
    fi
    attempt=$((attempt + 1))
    local delay=$(( RETRY_BASE_DELAY * (1 << (attempt - 1)) ))
    stop_spinner >&2
    countdown_wait "$delay" "$label" >&2
    start_spinner "Retrying $label..." >&2
  done
}

call_agent_a() {
  _call_agent "$AGENT_A_CMD" agent_a_session "agent_a" "$1"
}

call_agent_b() {
  _call_agent "$AGENT_B_CMD" agent_b_session "agent_b" "$1"
}

print_msg() {
  local color="$1" agent="$2" num="$3" remaining="$4" text="$5"
  echo ""
  echo -e "${color}━━━ ${agent} [message ${num}/${MAX_MESSAGES}, ${remaining} remaining] ━━━${NC}"
  echo -e "${color}${text}${NC}"
}

# Resolve model name for each agent
_agent_model() {
  case "$1" in
    claude) echo "$CLAUDE_MODEL" ;;
    codex)  echo "$CODEX_MODEL" ;;
    gemini) echo "$GEMINI_MODEL" ;;
  esac
}
BANNER_TITLE="AI DEBATE: ${AGENT_A_NAME} ($(_agent_model "$AGENT_A_CMD")) vs ${AGENT_B_NAME} ($(_agent_model "$AGENT_B_CMD"))"
BANNER_LEN=${#BANNER_TITLE}
BANNER_WIDTH=$(( BANNER_LEN + 4 ))
(( BANNER_WIDTH < 40 )) && BANNER_WIDTH=40
BANNER_INNER=$(( BANNER_WIDTH - 2 ))
BANNER_PAD=$(( (BANNER_INNER - BANNER_LEN) / 2 ))
BANNER_PAD_STR=$(printf '%*s' "$BANNER_PAD" '')
BANNER_LINE=$(printf '%*s' "$BANNER_INNER" '' | tr ' ' '═')
echo -e "${BOLD}╔${BANNER_LINE}╗${NC}"
printf "${BOLD}║%s%s%*s║${NC}\n" "$BANNER_PAD_STR" "$BANNER_TITLE" $((BANNER_INNER - BANNER_PAD - BANNER_LEN)) ""
echo -e "${BOLD}╚${BANNER_LINE}╝${NC}"
echo ""
echo -e "${YELLOW}Problem:${NC} $PROBLEM"
echo -e "${GRAY}Max $MAX_MESSAGES messages total${NC}"
echo ""
echo -e "${GRAY}Configuration complete. Starting debate...${NC}"

# Round 0: Both get the same starting message in parallel
start_msg="$SYSTEM_PROMPT

The problem to solve:
$PROBLEM

Remaining messages: $MAX_MESSAGES"

echo ""

# Helper to build round 0 command for an agent (with retry for rate limits)
_r0_cmd() {
  local cmd="$1" outfile="$2" errfile="$3" exitfile="$4"
  (
    local attempt=0
    while true; do
      local rc=0
      if [[ "$cmd" == "claude" ]]; then
        if run_with_timeout claude -p "$start_msg" --model "$CLAUDE_MODEL" --output-format json 2>"$errfile" > "$outfile"; then
          rc=0
        else
          rc=$?
        fi
      elif [[ "$cmd" == "gemini" ]]; then
        if run_with_timeout gemini -p "$start_msg" -o json -m "$GEMINI_MODEL" 2>"$errfile" > "$outfile"; then
          rc=0
        else
          rc=$?
        fi
      else
        if run_with_timeout codex exec -m "$CODEX_MODEL" -c 'model_reasoning_effort="medium"' "$start_msg" --json 2>"$errfile" > "$outfile"; then
          rc=0
        else
          rc=$?
        fi
      fi
      echo "$rc" > "$exitfile"

      # Don't retry timeouts or success
      [[ "$rc" == "0" ]] && break
      [[ "$rc" == "124" ]] && break

      # Check for rate limit in stderr or stdout
      local is_rl=false
      grep -qiE "rate.?limit|too.?many.?requests|429|quota.?exceeded" "$errfile" 2>/dev/null && is_rl=true
      [[ "$is_rl" != true ]] && grep -qiE "rate.?limit|too.?many.?requests|429|quota.?exceeded" "$outfile" 2>/dev/null && is_rl=true
      [[ "$is_rl" != true ]] && break

      if [[ $attempt -ge $MAX_RETRIES ]]; then
        echo "rate_limit_exhausted" > "$exitfile"
        break
      fi
      attempt=$((attempt + 1))
      local delay=$(( RETRY_BASE_DELAY * (1 << (attempt - 1)) ))
      sleep "$delay"
    done
  ) &
  echo $!
}

_r0_parse() {
  local cmd="$1" rawfile="$2" sidfile="$3"
  local raw
  raw=$(cat "$rawfile")
  if [[ "$cmd" == "claude" ]]; then
    parse_claude_output "$raw" "$sidfile"
  elif [[ "$cmd" == "gemini" ]]; then
    parse_gemini_output "$raw" "$sidfile"
  else
    parse_codex_output "$raw" "$sidfile"
  fi
}

# Start dual spinner before launching background processes
start_dual_spinner "$AGENT_A_NAME" "$AGENT_B_NAME" "$AGENT_A_COLOR" "$AGENT_B_COLOR"

# Run both in background, writing raw output to files
pid_a=$(_r0_cmd "$AGENT_A_CMD" "$tmpdir/agent_a_raw" "$tmpdir/agent_a_r0_err" "$tmpdir/agent_a_r0_exit")
pid_b=$(_r0_cmd "$AGENT_B_CMD" "$tmpdir/agent_b_raw" "$tmpdir/agent_b_r0_err" "$tmpdir/agent_b_r0_exit")

wait $pid_a 2>/dev/null || true
wait $pid_b 2>/dev/null || true
stop_dual_spinner

agent_a_exit=$(cat "$tmpdir/agent_a_r0_exit" 2>/dev/null || echo "1")
agent_b_exit=$(cat "$tmpdir/agent_b_r0_exit" 2>/dev/null || echo "1")

if [[ "$agent_a_exit" != "0" ]]; then
  if [[ "$agent_a_exit" == "rate_limit_exhausted" ]]; then
    echo "ERROR: $AGENT_A_NAME round 0 rate limited after $MAX_RETRIES retries" >&2
  elif [[ "$agent_a_exit" == "124" ]]; then
    echo "ERROR: $AGENT_A_NAME round 0 timed out after ${API_TIMEOUT}s" >&2
  else
    echo "ERROR: $AGENT_A_NAME round 0 failed (exit $agent_a_exit): $(cat "$tmpdir/agent_a_r0_err" 2>/dev/null)" >&2
  fi
  exit 1
fi
if [[ "$agent_b_exit" != "0" ]]; then
  if [[ "$agent_b_exit" == "rate_limit_exhausted" ]]; then
    echo "ERROR: $AGENT_B_NAME round 0 rate limited after $MAX_RETRIES retries" >&2
  elif [[ "$agent_b_exit" == "124" ]]; then
    echo "ERROR: $AGENT_B_NAME round 0 timed out after ${API_TIMEOUT}s" >&2
  else
    echo "ERROR: $AGENT_B_NAME round 0 failed (exit $agent_b_exit): $(cat "$tmpdir/agent_b_r0_err" 2>/dev/null)" >&2
  fi
  exit 1
fi

# Save debug output for round 0
debug_save "agent_a_r0" "$(cat "$tmpdir/agent_a_raw")"
debug_save "agent_b_r0" "$(cat "$tmpdir/agent_b_raw")"

# Parse results
agent_a_response=$(_r0_parse "$AGENT_A_CMD" "$tmpdir/agent_a_raw" "$tmpdir/agent_a_sid")
agent_b_response=$(_r0_parse "$AGENT_B_CMD" "$tmpdir/agent_b_raw" "$tmpdir/agent_b_sid")
agent_a_session=$(cat "$tmpdir/agent_a_sid" 2>/dev/null || true)
agent_b_session=$(cat "$tmpdir/agent_b_sid" 2>/dev/null || true)
msg_count=2

# Validate responses
if ! validate_response "$agent_a_response" "$AGENT_A_NAME"; then
  exit 1
fi
if ! validate_response "$agent_b_response" "$AGENT_B_NAME"; then
  exit 1
fi

print_msg "$AGENT_A_COLOR" "$AGENT_A_NAME" 1 $((MAX_MESSAGES - msg_count)) "$agent_a_response"
transcript_add "a" "$agent_a_response"
print_msg "$AGENT_B_COLOR" "$AGENT_B_NAME" 2 $((MAX_MESSAGES - msg_count)) "$agent_b_response"
transcript_add "b" "$agent_b_response"

# Extract AGREED conclusion from a response
extract_agreed() {
  echo "$1" | grep -oiE "^[[:space:]]*\*{0,2}AGREED:.*" | head -1 | sed 's/^[[:space:]]*\*\{0,2\}[Aa][Gg][Rr][Ee][Ee][Dd]:[[:space:]]*//' || true
}

# Check if response contains AGREED
has_agreed() {
  echo "$1" | grep -qiE "^[[:space:]]*\*{0,2}AGREED:"
}

# When one agent says AGREED, ask the other to confirm
# Args: proposer_name proposal confirmer_name confirmer_call_fn confirmer_color confirmer_response_var confirmer_id
confirm_agreement() {
  local proposer="$1" proposal="$2" confirmer="$3" call_fn="$4" confirm_color="$5" response_var="$6" confirmer_id="$7"
  local conclusion
  conclusion=$(extract_agreed "$proposal")

  echo ""
  echo -e "${GRAY}${proposer} proposes agreement. Asking ${confirmer} to confirm...${NC}"

  local confirm_msg="${proposer} proposes that you have reached agreement and concludes with:
AGREED: ${conclusion}

CRITICAL REVIEW REQUIRED: Before agreeing, carefully evaluate:
1. Is this conclusion COMPLETE? Are there any gaps in the analysis?
2. Is it CORRECT? Have all alternative explanations been considered and ruled out?
3. Is there sufficient EVIDENCE to support this conclusion?
4. Are there any edge cases, caveats, or nuances that should be included?

If the analysis is incomplete or you have additional insights to add, explain what's missing and continue the debate.
Only respond with \"AGREED: <conclusion>\" if you are fully satisfied this is a thorough and correct answer."

  local confirm_response
  start_spinner "Waiting for ${confirmer} to respond..."
  confirm_response=$($call_fn "$confirm_msg")
  stop_spinner
  msg_count=$((msg_count + 1))

  print_msg "$confirm_color" "$confirmer" "$msg_count" $((MAX_MESSAGES - msg_count)) "$confirm_response"
  transcript_add "$confirmer_id" "$confirm_response"

  if has_agreed "$confirm_response"; then
    local final
    final=$(extract_agreed "$confirm_response")
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║          AGREEMENT REACHED            ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
    echo -e "${BOLD}Conclusion:${NC} ${final}"
    echo -e "${GRAY}Messages used: ${msg_count}/${MAX_MESSAGES}${NC}"
    if [[ "$DEBUG" == true ]]; then
      echo -e "${GRAY}Debug files: $tmpdir/${NC}"
    fi
    DEBATE_AGREED=true
    DEBATE_CONCLUSION="$final"
    return 0
  fi

  # Not confirmed — update the appropriate response variable for the loop
  printf -v "$response_var" '%s' "$confirm_response"
}

# Print resume commands for continuing conversation with each agent
print_resume_commands() {
  echo ""
  echo -e "${GRAY}To continue the conversation with an agent, run:${NC}"
  if [[ -n "$agent_a_session" ]]; then
    case "$AGENT_A_CMD" in
      claude) echo -e "  ${AGENT_A_COLOR}${AGENT_A_NAME}:${NC} claude --resume $agent_a_session" ;;
      codex)  echo -e "  ${AGENT_A_COLOR}${AGENT_A_NAME}:${NC} codex resume $agent_a_session" ;;
      gemini) echo -e "  ${AGENT_A_COLOR}${AGENT_A_NAME}:${NC} gemini --resume $agent_a_session" ;;
    esac
  fi
  if [[ -n "$agent_b_session" ]]; then
    case "$AGENT_B_CMD" in
      claude) echo -e "  ${AGENT_B_COLOR}${AGENT_B_NAME}:${NC} claude --resume $agent_b_session" ;;
      codex)  echo -e "  ${AGENT_B_COLOR}${AGENT_B_NAME}:${NC} codex resume $agent_b_session" ;;
      gemini) echo -e "  ${AGENT_B_COLOR}${AGENT_B_NAME}:${NC} gemini --resume $agent_b_session" ;;
    esac
  fi
}

# Prompt user to extend the debate with more messages
# Returns 0 if extending, 1 if not
# 60 second timeout for extension prompts
EXTENSION_PROMPT_TIMEOUT=60

prompt_extend_debate() {
  echo ""
  echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║          DEBATE LIMIT REACHED          ║${NC}"
  echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
  echo -e "No agreement after ${MAX_MESSAGES} messages."
  echo -e "${BOLD}Final positions:${NC}"
  echo -e "  ${AGENT_A_COLOR}${AGENT_A_NAME}:${NC} $(echo "$agent_a_response" | head -3)"
  echo -e "  ${AGENT_B_COLOR}${AGENT_B_NAME}:${NC} $(echo "$agent_b_response" | head -3)"
  if [[ "$DEBUG" == true ]]; then
    echo -e "${GRAY}Debug files: $tmpdir/${NC}"
  fi

  echo ""
  read_with_timeout "$EXTENSION_PROMPT_TIMEOUT" "Continue for 5 more messages? (y/n) " "n"
  if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
    return 1
  fi

  local additional_msgs=5

  # Clear any previous extension context before prompting for new
  EXTENSION_CONTEXT=""

  # Option to inject context
  read_with_timeout "$EXTENSION_PROMPT_TIMEOUT" "Would you like to inject additional context/guidance for both agents? (y/n) " "n"
  if [[ "$REPLY" == "y" || "$REPLY" == "Y" ]]; then
    echo "Enter additional context (or 'edit' to open an editor):"
    printf "> "
    read -r context_input
    if [[ "$context_input" == "edit" ]]; then
      # Open editor for multiline context
      local context_file
      context_file=$(mktemp /tmp/aidebate-context.XXXXXX) || return 1
      ${EDITOR:-nano} "$context_file"
      EXTENSION_CONTEXT=$(cat "$context_file")
      rm -f "$context_file"
    else
      EXTENSION_CONTEXT="$context_input"
    fi
    if [[ -n "$EXTENSION_CONTEXT" ]]; then
      echo -e "${GRAY}Context will be injected into the next exchange.${NC}"
      EXTENSION_CONTEXT_SENT_A=false
      EXTENSION_CONTEXT_SENT_B=false
    fi
  fi

  # Update max messages
  local old_max=$MAX_MESSAGES
  MAX_MESSAGES=$((MAX_MESSAGES + additional_msgs))
  echo ""
  echo -e "${GRAY}Debate extended by ${additional_msgs} messages. New limit: ${MAX_MESSAGES}${NC}"
  echo -e "${GRAY}Continuing debate...${NC}"

  return 0
}

# Build message for an agent, injecting extension context if applicable
# Args: other_name other_response remaining is_agent_a
build_agent_message() {
  local other_name="$1" other_response="$2" remaining="$3" is_agent_a="$4"
  local msg=""

  # Check if we need to inject extension context
  if [[ -n "$EXTENSION_CONTEXT" ]]; then
    if [[ "$is_agent_a" == "true" && "$EXTENSION_CONTEXT_SENT_A" == "false" ]]; then
      msg="[ADDITIONAL CONTEXT FROM USER]: ${EXTENSION_CONTEXT}

"
      EXTENSION_CONTEXT_SENT_A=true
    elif [[ "$is_agent_a" == "false" && "$EXTENSION_CONTEXT_SENT_B" == "false" ]]; then
      msg="[ADDITIONAL CONTEXT FROM USER]: ${EXTENSION_CONTEXT}

"
      EXTENSION_CONTEXT_SENT_B=true
    fi
  fi

  msg+="${other_name}'s message:
${other_response}

Remaining messages: ${remaining}"

  echo "$msg"
}

# Prompt user to export a report of the conversation
prompt_export_report() {
  echo ""
  read_with_timeout 60 "Would you like to export a report of the conversation? (y/n) " "n"
  if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
    return
  fi

  if [[ -z "$OUTPUT_FILE" ]]; then
    local default_name="debate-report-$(date +%Y-%m-%d-%H%M%S).json"
    read_with_timeout 60 "Filename [$default_name]: " "$default_name"
    OUTPUT_FILE="$REPLY"
  fi

  write_transcript
}

# Post-debate interactive menu
post_debate_menu() {
  while true; do
    echo ""
    echo "What would you like to do?"
    echo "  1) Chat with an agent"
    echo "  2) Export report"
    echo "  3) Exit"
    read_with_timeout 60 "Choice [3]: " "3"

    case "$REPLY" in
      1)
        # Agent selection
        echo ""
        echo "Select an agent to chat with:"
        echo "  1) $AGENT_A_NAME"
        echo "  2) $AGENT_B_NAME"
        printf "Choice [1]: "
        read -r agent_choice
        agent_choice=${agent_choice:-1}

        local chat_agent_name chat_agent_color chat_agent_id call_fn
        if [[ "$agent_choice" == "2" ]]; then
          chat_agent_name="$AGENT_B_NAME"
          chat_agent_color="$AGENT_B_COLOR"
          chat_agent_id="b"
          call_fn=call_agent_b
        else
          chat_agent_name="$AGENT_A_NAME"
          chat_agent_color="$AGENT_A_COLOR"
          chat_agent_id="a"
          call_fn=call_agent_a
        fi

        echo ""
        echo -e "${GRAY}Chatting with ${chat_agent_name}. Type 'exit' or 'quit' to end.${NC}"

        while true; do
          echo ""
          printf "${BOLD}You:${NC} "
          read -r user_input

          [[ -z "$user_input" || "$user_input" == "exit" || "$user_input" == "quit" ]] && break

          transcript_add "user" "$user_input"

          start_spinner "${chat_agent_name} is thinking..."
          local response
          response=$($call_fn "$user_input")
          stop_spinner

          transcript_add "$chat_agent_id" "$response"

          echo ""
          echo -e "${chat_agent_color}━━━ ${chat_agent_name} ━━━${NC}"
          echo -e "${chat_agent_color}${response}${NC}"
        done

        echo -e "${GRAY}Chat ended.${NC}"
        ;;
      2)
        prompt_export_report
        ;;
      *)
        # Save transcript with all chat turns before exiting
        if [[ -n "$OUTPUT_FILE" ]]; then
          write_transcript
        fi
        break
        ;;
    esac
  done
}

# Check round 0 for early agreement
if has_agreed "$agent_a_response" && has_agreed "$agent_b_response"; then
  DEBATE_CONCLUSION=$(extract_agreed "$agent_a_response")
  echo ""
  echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║          AGREEMENT REACHED            ║${NC}"
  echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
  echo -e "${BOLD}Conclusion:${NC} $DEBATE_CONCLUSION"
  echo -e "${GRAY}Messages used: ${msg_count}/${MAX_MESSAGES}${NC}"
  if [[ "$DEBUG" == true ]]; then
    echo -e "${GRAY}Debug files: $tmpdir/${NC}"
  fi
  DEBATE_AGREED=true
elif has_agreed "$agent_a_response"; then
  confirm_agreement "$AGENT_A_NAME" "$agent_a_response" "$AGENT_B_NAME" call_agent_b "$AGENT_B_COLOR" agent_b_response "b"
elif has_agreed "$agent_b_response"; then
  confirm_agreement "$AGENT_B_NAME" "$agent_b_response" "$AGENT_A_NAME" call_agent_a "$AGENT_A_COLOR" agent_a_response "a"
fi

# Skip to final cleanup if agreement was reached in round 0
if [[ "$DEBATE_AGREED" == "true" ]]; then
  post_debate_menu
  print_resume_commands
  exit 0
fi

# Rounds 1+: Ping-pong with extension support
# Outer loop allows extending the debate when limit is reached
while true; do
  # Inner loop: debate rounds
  while [[ $msg_count -lt $MAX_MESSAGES ]]; do
    remaining=$((MAX_MESSAGES - msg_count))

    # Agent A gets Agent B's last response
    agent_a_msg=$(build_agent_message "$AGENT_B_NAME" "$agent_b_response" "$((remaining - 1))" "true")

    start_spinner "${AGENT_A_NAME} is thinking..."
    agent_a_response=$(call_agent_a "$agent_a_msg")
    stop_spinner
    msg_count=$((msg_count + 1))
    print_msg "$AGENT_A_COLOR" "$AGENT_A_NAME" "$msg_count" $((MAX_MESSAGES - msg_count)) "$agent_a_response"
    transcript_add "a" "$agent_a_response"

    if has_agreed "$agent_a_response"; then
      confirm_agreement "$AGENT_A_NAME" "$agent_a_response" "$AGENT_B_NAME" call_agent_b "$AGENT_B_COLOR" agent_b_response "b"
      if [[ "$DEBATE_AGREED" == "true" ]]; then
        break 2
      fi
    fi

    if [[ $msg_count -ge $MAX_MESSAGES ]]; then break; fi

    # Agent B gets Agent A's last response
    agent_b_msg=$(build_agent_message "$AGENT_A_NAME" "$agent_a_response" "$((MAX_MESSAGES - msg_count - 1))" "false")

    start_spinner "${AGENT_B_NAME} is thinking..."
    agent_b_response=$(call_agent_b "$agent_b_msg")
    stop_spinner
    msg_count=$((msg_count + 1))
    print_msg "$AGENT_B_COLOR" "$AGENT_B_NAME" "$msg_count" $((MAX_MESSAGES - msg_count)) "$agent_b_response"
    transcript_add "b" "$agent_b_response"

    if has_agreed "$agent_b_response"; then
      confirm_agreement "$AGENT_B_NAME" "$agent_b_response" "$AGENT_A_NAME" call_agent_a "$AGENT_A_COLOR" agent_a_response "a"
      if [[ "$DEBATE_AGREED" == "true" ]]; then
        break 2
      fi
    fi
  done

  # Check if we exited due to agreement
  if [[ "$DEBATE_AGREED" == "true" ]]; then
    break
  fi

  # Offer extension
  if ! prompt_extend_debate; then
    # User declined extension - show final "DEBATE IS OVER" banner
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║          DEBATE IS OVER               ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
    break
  fi
  # User chose to extend - continue outer loop
done

# Final cleanup: post-debate menu and resume commands
post_debate_menu
print_resume_commands
