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
DEBUG=false
SYSTEM_PROMPT_FILE=""
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# Utility functions for user feedback

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

# Parse CLI flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-rounds)
      MAX_MESSAGES="$2"; shift 2 ;;
    --timeout)
      API_TIMEOUT="$2"; shift 2 ;;
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
    --help|-h)
      echo "Usage: bash ai-debate.sh [OPTIONS] \"<problem>\""
      echo ""
      echo "Options:"
      echo "  --max-rounds N          Max number of messages (default: 10)"
      echo "  --timeout N             API timeout in seconds (default: 60)"
      echo "  --claude-model MODEL    Claude model (haiku, sonnet, opus)"
      echo "  --codex-model MODEL     Codex model (gpt-5.1-codex-mini, gpt-5.2-codex)"
      echo "  --gemini-model MODEL    Gemini model (gemini-2.5-flash, gemini-3-flash-preview)"
      echo "  --system-prompt-file F  Read system prompt from file"
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
if [[ "$AGENT_A_CMD" == "claude" || "$AGENT_B_CMD" == "claude" ]] && [[ -z "$CLAUDE_MODEL" ]]; then
  echo "Select Claude model:"
  for i in "${!CLAUDE_MODELS[@]}"; do
    echo "  $((i+1))) ${CLAUDE_MODELS[$i]}"
  done
  while true; do
    printf "Choice [1]: "
    read -r choice
    if validated=$(validate_choice "$choice" 1 "${#CLAUDE_MODELS[@]}" 1); then
      CLAUDE_MODEL="${CLAUDE_MODELS[$((validated-1))]}"
      echo -e "${GRAY}Selected Claude model: $CLAUDE_MODEL${NC}"
      break
    fi
  done
fi

if [[ "$AGENT_A_CMD" == "codex" || "$AGENT_B_CMD" == "codex" ]] && [[ -z "$CODEX_MODEL" ]]; then
  echo "Select Codex model:"
  for i in "${!CODEX_MODELS[@]}"; do
    echo "  $((i+1))) ${CODEX_MODELS[$i]}"
  done
  while true; do
    printf "Choice [1]: "
    read -r choice
    if validated=$(validate_choice "$choice" 1 "${#CODEX_MODELS[@]}" 1); then
      CODEX_MODEL="${CODEX_MODELS[$((validated-1))]}"
      echo -e "${GRAY}Selected Codex model: $CODEX_MODEL${NC}"
      break
    fi
  done
fi

if [[ "$AGENT_A_CMD" == "gemini" || "$AGENT_B_CMD" == "gemini" ]] && [[ -z "$GEMINI_MODEL" ]]; then
  echo "Select Gemini model:"
  for i in "${!GEMINI_MODELS[@]}"; do
    echo "  $((i+1))) ${GEMINI_MODELS[$i]}"
  done
  while true; do
    printf "Choice [1]: "
    read -r choice
    if validated=$(validate_choice "$choice" 1 "${#GEMINI_MODELS[@]}" 1); then
      GEMINI_MODEL="${GEMINI_MODELS[$((validated-1))]}"
      echo -e "${GRAY}Selected Gemini model: $GEMINI_MODEL${NC}"
      break
    fi
  done
fi

SYSTEM_PROMPT="You are participating in a collaboration with another AI agent to solve a problem.

This first message is your chance to think through the problem on your own and formulate your hypothesis.
After this you will receive the other agent's perspective, and you will exchange responses back and forth.

Max $MAX_MESSAGES messages total. Be concise.
When you agree, write the conclusion on its own line starting with \"AGREED:\" followed by the conclusion."

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

# Temp dir for round 0 communication and debug output
tmpdir=$(mktemp -d)
if [[ "$DEBUG" == true ]]; then
  echo -e "${GRAY}Debug: tmpdir=$tmpdir${NC}"
  trap 'stop_spinner 2>/dev/null' EXIT
else
  trap 'stop_spinner 2>/dev/null; rm -rf "$tmpdir"' EXIT
fi

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

  if [[ "$cmd" == "claude" ]]; then
    local args=(claude -p "$msg" --model "$CLAUDE_MODEL" --output-format json)
    if [[ -n "$session" ]]; then
      args+=(--resume "$session")
    fi
    if ! raw=$(run_with_timeout "${args[@]}" 2>"$err_file"); then
      local exit_code=$?
      if [[ $exit_code -eq 124 ]]; then
        echo "ERROR: $label API call timed out after ${API_TIMEOUT}s" >&2
      else
        echo "ERROR: $label API call failed (exit $exit_code): $(cat "$err_file")" >&2
      fi
      return 1
    fi
    debug_save "$label" "$raw"
    if [[ -z "$session" ]]; then
      local new_sid
      new_sid=$(echo "$raw" | jq -r '.session_id // empty' 2>/dev/null) || true
      printf -v "$session_var" '%s' "$new_sid"
    fi
    echo "$raw" | jq -r '.result // empty' 2>/dev/null
  elif [[ "$cmd" == "gemini" ]]; then
    local args=(gemini -p "$msg" -o json -m "$GEMINI_MODEL")
    if [[ -n "$session" ]]; then
      args+=(--resume "$session")
    fi
    if ! raw=$(run_with_timeout "${args[@]}" 2>"$err_file"); then
      local exit_code=$?
      if [[ $exit_code -eq 124 ]]; then
        echo "ERROR: $label API call timed out after ${API_TIMEOUT}s" >&2
      else
        echo "ERROR: $label API call failed (exit $exit_code): $(cat "$err_file")" >&2
      fi
      return 1
    fi
    debug_save "$label" "$raw"
    if [[ -z "$session" ]]; then
      local new_sid
      new_sid=$(echo "$raw" | jq -r '.session_id // empty' 2>/dev/null) || true
      printf -v "$session_var" '%s' "$new_sid"
    fi
    echo "$raw" | jq -r '.response // empty' 2>/dev/null
  else
    # codex
    if [[ -z "$session" ]]; then
      if ! raw=$(run_with_timeout codex exec -m "$CODEX_MODEL" "$msg" --json 2>"$err_file"); then
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
          echo "ERROR: $label API call timed out after ${API_TIMEOUT}s" >&2
        else
          echo "ERROR: $label API call failed (exit $exit_code): $(cat "$err_file")" >&2
        fi
        return 1
      fi
    else
      if ! raw=$(run_with_timeout codex exec resume "$session" -m "$CODEX_MODEL" "$msg" --json 2>"$err_file"); then
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
          echo "ERROR: $label API call timed out after ${API_TIMEOUT}s" >&2
        else
          echo "ERROR: $label API call failed (exit $exit_code): $(cat "$err_file")" >&2
        fi
        return 1
      fi
    fi
    debug_save "$label" "$raw"
    if [[ -z "$session" ]]; then
      local new_sid
      new_sid=$(echo "$raw" | jq -r 'select(.type=="thread.started") | .thread_id // empty' 2>/dev/null | head -1) || true
      printf -v "$session_var" '%s' "$new_sid"
    fi
    local codex_text
    codex_text=$(echo "$raw" | jq -r 'select(.type=="item.completed" and .item.type=="agent_message") | .item.text // empty' 2>/dev/null | tail -1) || true
    if [[ -z "$codex_text" ]]; then
      echo "ERROR: $label returned no parseable response. Re-run with --debug to inspect raw output." >&2
      return 1
    fi
    echo "$codex_text"
  fi
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
start_spinner "Round 0: Both agents thinking in parallel..."

# Helper to build round 0 command for an agent
_r0_cmd() {
  local cmd="$1" outfile="$2" errfile="$3" exitfile="$4"
  if [[ "$cmd" == "claude" ]]; then
    (run_with_timeout claude -p "$start_msg" --model "$CLAUDE_MODEL" --output-format json 2>"$errfile" > "$outfile"; echo $? > "$exitfile") &
  elif [[ "$cmd" == "gemini" ]]; then
    (run_with_timeout gemini -p "$start_msg" -o json -m "$GEMINI_MODEL" 2>"$errfile" > "$outfile"; echo $? > "$exitfile") &
  else
    (run_with_timeout codex exec -m "$CODEX_MODEL" "$start_msg" --json 2>"$errfile" > "$outfile"; echo $? > "$exitfile") &
  fi
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

# Run both in background, writing raw output to files
pid_a=$(_r0_cmd "$AGENT_A_CMD" "$tmpdir/agent_a_raw" "$tmpdir/agent_a_r0_err" "$tmpdir/agent_a_r0_exit")
pid_b=$(_r0_cmd "$AGENT_B_CMD" "$tmpdir/agent_b_raw" "$tmpdir/agent_b_r0_err" "$tmpdir/agent_b_r0_exit")

wait $pid_a 2>/dev/null || true
wait $pid_b 2>/dev/null || true
stop_spinner

agent_a_exit=$(cat "$tmpdir/agent_a_r0_exit" 2>/dev/null || echo "1")
agent_b_exit=$(cat "$tmpdir/agent_b_r0_exit" 2>/dev/null || echo "1")

if [[ "$agent_a_exit" != "0" ]]; then
  if [[ "$agent_a_exit" == "124" ]]; then
    echo "ERROR: $AGENT_A_NAME round 0 timed out after ${API_TIMEOUT}s" >&2
  else
    echo "ERROR: $AGENT_A_NAME round 0 failed (exit $agent_a_exit): $(cat "$tmpdir/agent_a_r0_err" 2>/dev/null)" >&2
  fi
  exit 1
fi
if [[ "$agent_b_exit" != "0" ]]; then
  if [[ "$agent_b_exit" == "124" ]]; then
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

echo -e "${GRAY}Round 0 complete${NC}"

print_msg "$AGENT_A_COLOR" "$AGENT_A_NAME" 1 $((MAX_MESSAGES - msg_count)) "$agent_a_response"
print_msg "$AGENT_B_COLOR" "$AGENT_B_NAME" 2 $((MAX_MESSAGES - msg_count)) "$agent_b_response"

# Extract AGREED conclusion from a response
extract_agreed() {
  echo "$1" | grep -oiE "^[[:space:]]*\*{0,2}AGREED:.*" | head -1 | sed 's/^[[:space:]]*\*\{0,2\}[Aa][Gg][Rr][Ee][Ee][Dd]:[[:space:]]*//' || true
}

# Check if response contains AGREED
has_agreed() {
  echo "$1" | grep -qiE "^[[:space:]]*\*{0,2}AGREED:"
}

# When one agent says AGREED, ask the other to confirm
# Args: proposer_name proposal confirmer_name confirmer_call_fn confirmer_color confirmer_response_var
confirm_agreement() {
  local proposer="$1" proposal="$2" confirmer="$3" call_fn="$4" confirm_color="$5" response_var="$6"
  local conclusion
  conclusion=$(extract_agreed "$proposal")

  echo ""
  echo -e "${GRAY}${proposer} proposes agreement. Asking ${confirmer} to confirm...${NC}"

  local confirm_msg="${proposer} proposes that you have reached agreement and concludes with:
AGREED: ${conclusion}

Do you agree? If yes, respond with \"AGREED: <same or adjusted conclusion>\". If no, explain why."

  local confirm_response
  start_spinner "Waiting for ${confirmer} to respond..."
  confirm_response=$($call_fn "$confirm_msg")
  stop_spinner
  msg_count=$((msg_count + 1))

  print_msg "$confirm_color" "$confirmer" "$msg_count" $((MAX_MESSAGES - msg_count)) "$confirm_response"

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
    post_debate_chat
    print_resume_commands
    exit 0
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

# Post-debate chat: continue conversation with one agent
post_debate_chat() {
  echo ""
  echo -e "${GRAY}Would you like to continue chatting with one of the agents? (y/n)${NC}"
  read -r continue_chat
  [[ "$continue_chat" != "y" && "$continue_chat" != "Y" ]] && return

  # Agent selection
  echo "Select an agent to chat with:"
  echo "  1) $AGENT_A_NAME"
  echo "  2) $AGENT_B_NAME"
  printf "Choice [1]: "
  read -r agent_choice
  agent_choice=${agent_choice:-1}

  local chat_agent_name chat_agent_color call_fn
  if [[ "$agent_choice" == "2" ]]; then
    chat_agent_name="$AGENT_B_NAME"
    chat_agent_color="$AGENT_B_COLOR"
    call_fn=call_agent_b
  else
    chat_agent_name="$AGENT_A_NAME"
    chat_agent_color="$AGENT_A_COLOR"
    call_fn=call_agent_a
  fi

  echo ""
  echo -e "${GRAY}Chatting with ${chat_agent_name}. Type 'exit' or 'quit' to end.${NC}"

  while true; do
    echo ""
    printf "${BOLD}You:${NC} "
    read -r user_input

    [[ -z "$user_input" || "$user_input" == "exit" || "$user_input" == "quit" ]] && break

    start_spinner "${chat_agent_name} is thinking..."
    local response
    response=$($call_fn "$user_input")
    stop_spinner

    echo ""
    echo -e "${chat_agent_color}━━━ ${chat_agent_name} ━━━${NC}"
    echo -e "${chat_agent_color}${response}${NC}"
  done

  echo -e "${GRAY}Chat ended.${NC}"
}

# Check round 0 for early agreement
if has_agreed "$agent_a_response" && has_agreed "$agent_b_response"; then
  echo ""
  echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║          AGREEMENT REACHED            ║${NC}"
  echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
  echo -e "${BOLD}Conclusion:${NC} $(extract_agreed "$agent_a_response")"
  echo -e "${GRAY}Messages used: ${msg_count}/${MAX_MESSAGES}${NC}"
  if [[ "$DEBUG" == true ]]; then
    echo -e "${GRAY}Debug files: $tmpdir/${NC}"
  fi
  post_debate_chat
  exit 0
elif has_agreed "$agent_a_response"; then
  confirm_agreement "$AGENT_A_NAME" "$agent_a_response" "$AGENT_B_NAME" call_agent_b "$AGENT_B_COLOR" agent_b_response
elif has_agreed "$agent_b_response"; then
  confirm_agreement "$AGENT_B_NAME" "$agent_b_response" "$AGENT_A_NAME" call_agent_a "$AGENT_A_COLOR" agent_a_response
fi

# Rounds 1+: Ping-pong (sequential, so session vars work)
while [[ $msg_count -lt $MAX_MESSAGES ]]; do
  remaining=$((MAX_MESSAGES - msg_count))

  # Agent A gets Agent B's last response
  agent_a_msg="${AGENT_B_NAME}'s message:
$agent_b_response

Remaining messages: $((remaining - 1))"

  start_spinner "${AGENT_A_NAME} is thinking..."
  agent_a_response=$(call_agent_a "$agent_a_msg")
  stop_spinner
  msg_count=$((msg_count + 1))
  print_msg "$AGENT_A_COLOR" "$AGENT_A_NAME" "$msg_count" $((MAX_MESSAGES - msg_count)) "$agent_a_response"

  if has_agreed "$agent_a_response"; then
    confirm_agreement "$AGENT_A_NAME" "$agent_a_response" "$AGENT_B_NAME" call_agent_b "$AGENT_B_COLOR" agent_b_response
  fi

  if [[ $msg_count -ge $MAX_MESSAGES ]]; then break; fi

  # Agent B gets Agent A's last response
  agent_b_msg="${AGENT_A_NAME}'s message:
$agent_a_response

Remaining messages: $((MAX_MESSAGES - msg_count - 1))"

  start_spinner "${AGENT_B_NAME} is thinking..."
  agent_b_response=$(call_agent_b "$agent_b_msg")
  stop_spinner
  msg_count=$((msg_count + 1))
  print_msg "$AGENT_B_COLOR" "$AGENT_B_NAME" "$msg_count" $((MAX_MESSAGES - msg_count)) "$agent_b_response"

  if has_agreed "$agent_b_response"; then
    confirm_agreement "$AGENT_B_NAME" "$agent_b_response" "$AGENT_A_NAME" call_agent_a "$AGENT_A_COLOR" agent_a_response
  fi
done

echo ""
echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║          DEBATE IS OVER               ║${NC}"
echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
echo -e "No agreement after ${MAX_MESSAGES} messages."
echo -e "${BOLD}Final positions:${NC}"
echo -e "  ${AGENT_A_COLOR}${AGENT_A_NAME}:${NC} $(echo "$agent_a_response" | head -3)"
echo -e "  ${AGENT_B_COLOR}${AGENT_B_NAME}:${NC} $(echo "$agent_b_response" | head -3)"
if [[ "$DEBUG" == true ]]; then
  echo -e "${GRAY}Debug files: $tmpdir/${NC}"
fi
post_debate_chat
print_resume_commands
