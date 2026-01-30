#!/usr/bin/env bash
set -euo pipefail

# Detect available tools
HAS_CLAUDE=false; HAS_CODEX=false; HAS_GEMINI=false
command -v claude >/dev/null 2>&1 && HAS_CLAUDE=true
command -v codex >/dev/null 2>&1 && HAS_CODEX=true
command -v gemini >/dev/null 2>&1 && HAS_GEMINI=true
command -v jq >/dev/null 2>&1 || { echo "Feil: 'jq' ikke funnet i PATH"; exit 1; }
if ! $HAS_CLAUDE && ! $HAS_CODEX && ! $HAS_GEMINI; then
  echo "Feil: Ingen AI-verktøy funnet ('claude', 'codex', eller 'gemini')"; exit 1
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
  echo "Advarsel: Bare 'claude' funnet. Bruker claude for begge agenter."
  AGENT_A_CMD=claude; AGENT_B_CMD=claude
  AGENT_A_NAME="Claude (1)"; AGENT_B_NAME="Claude (2)"
  AGENT_A_COLOR='\033[1;34m'; AGENT_B_COLOR='\033[1;36m'
elif $HAS_CODEX; then
  echo "Advarsel: Bare 'codex' funnet. Bruker codex for begge agenter."
  AGENT_A_CMD=codex; AGENT_B_CMD=codex
  AGENT_A_NAME="Codex (1)"; AGENT_B_NAME="Codex (2)"
  AGENT_A_COLOR='\033[1;32m'; AGENT_B_COLOR='\033[1;36m'
else
  echo "Advarsel: Bare 'gemini' funnet. Bruker gemini for begge agenter."
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
      echo "  --max-rounds N          Maks antall meldinger (default: 10)"
      echo "  --timeout N             API timeout i sekunder (default: 60)"
      echo "  --claude-model MODEL    Claude-modell (haiku, sonnet, opus)"
      echo "  --codex-model MODEL     Codex-modell (gpt-5.1-codex-mini, gpt-5.2-codex)"
      echo "  --gemini-model MODEL    Gemini-modell (gemini-2.5-flash, gemini-3-flash-preview)"
      echo "  --system-prompt-file F  Les systemprompt fra fil"
      echo "  --debug                 Bevar raw API-svar og vis tmpdir"
      echo "  --help, -h              Vis denne hjelpen"
      exit 0
      ;;
    -*)
      echo "Ukjent flagg: $1"; exit 1 ;;
    *)
      break ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "Usage: bash ai-debate.sh [OPTIONS] \"<problem>\""
  echo "Bruk --help for flere alternativer."
  exit 1
fi
PROBLEM="$*"

# Interactive model selection (only for agents in use)
if [[ "$AGENT_A_CMD" == "claude" || "$AGENT_B_CMD" == "claude" ]] && [[ -z "$CLAUDE_MODEL" ]]; then
  echo "Velg Claude-modell:"
  for i in "${!CLAUDE_MODELS[@]}"; do
    echo "  $((i+1))) ${CLAUDE_MODELS[$i]}"
  done
  printf "Valg [1]: "
  read -r choice
  choice=${choice:-1}
  CLAUDE_MODEL="${CLAUDE_MODELS[$((choice-1))]}"
fi

if [[ "$AGENT_A_CMD" == "codex" || "$AGENT_B_CMD" == "codex" ]] && [[ -z "$CODEX_MODEL" ]]; then
  echo "Velg Codex-modell:"
  for i in "${!CODEX_MODELS[@]}"; do
    echo "  $((i+1))) ${CODEX_MODELS[$i]}"
  done
  printf "Valg [1]: "
  read -r choice
  choice=${choice:-1}
  CODEX_MODEL="${CODEX_MODELS[$((choice-1))]}"
fi

if [[ "$AGENT_A_CMD" == "gemini" || "$AGENT_B_CMD" == "gemini" ]] && [[ -z "$GEMINI_MODEL" ]]; then
  echo "Velg Gemini-modell:"
  for i in "${!GEMINI_MODELS[@]}"; do
    echo "  $((i+1))) ${GEMINI_MODELS[$i]}"
  done
  printf "Valg [1]: "
  read -r choice
  choice=${choice:-1}
  GEMINI_MODEL="${GEMINI_MODELS[$((choice-1))]}"
fi

SYSTEM_PROMPT="Du deltar i et samarbeid med en annen AI-agent for å løse et problem.

Denne første meldingen er din sjanse til å tenke gjennom problemet på egenhånd og formulere din hypotese.
Etter dette vil du motta den andre agentens perspektiv, og dere vil sende svar frem og tilbake.

Maks $MAX_MESSAGES meldinger totalt. Vær konsis.
Når dere er enige, skriv konklusjonen på en egen linje som starter med \"ENIG:\" etterfulgt av konklusjonen."

if [[ -n "$SYSTEM_PROMPT_FILE" ]]; then
  if [[ ! -f "$SYSTEM_PROMPT_FILE" ]]; then
    echo "Feil: Systemprompt-fil '$SYSTEM_PROMPT_FILE' finnes ikke."
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
else
  trap 'rm -rf "$tmpdir"' EXIT
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
  sid=$(echo "$raw" | grep '"type":"thread.started"' | jq -r '.thread_id // empty' 2>/dev/null) || true
  if [[ -n "$sid" ]]; then
    echo "$sid" > "$sid_file"
  fi
  echo "$raw" | grep '"type":"item.completed"' | grep '"agent_message"' | tail -1 | jq -r '.item.text // empty' 2>/dev/null
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
        echo "FEIL: $label API-kall tidsavbrutt etter ${API_TIMEOUT}s" >&2
      else
        echo "FEIL: $label API-kall feilet (exit $exit_code): $(cat "$err_file")" >&2
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
        echo "FEIL: $label API-kall tidsavbrutt etter ${API_TIMEOUT}s" >&2
      else
        echo "FEIL: $label API-kall feilet (exit $exit_code): $(cat "$err_file")" >&2
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
          echo "FEIL: $label API-kall tidsavbrutt etter ${API_TIMEOUT}s" >&2
        else
          echo "FEIL: $label API-kall feilet (exit $exit_code): $(cat "$err_file")" >&2
        fi
        return 1
      fi
    else
      if ! raw=$(run_with_timeout codex exec resume "$session" -m "$CODEX_MODEL" "$msg" --json 2>"$err_file"); then
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
          echo "FEIL: $label API-kall tidsavbrutt etter ${API_TIMEOUT}s" >&2
        else
          echo "FEIL: $label API-kall feilet (exit $exit_code): $(cat "$err_file")" >&2
        fi
        return 1
      fi
    fi
    debug_save "$label" "$raw"
    if [[ -z "$session" ]]; then
      local new_sid
      new_sid=$(echo "$raw" | grep '"type":"thread.started"' | jq -r '.thread_id // empty' 2>/dev/null) || true
      printf -v "$session_var" '%s' "$new_sid"
    fi
    echo "$raw" | grep '"type":"item.completed"' | grep '"agent_message"' | tail -1 | jq -r '.item.text // empty' 2>/dev/null
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
  echo -e "${color}━━━ ${agent} [melding ${num}/${MAX_MESSAGES}, ${remaining} gjenstår] ━━━${NC}"
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
BANNER_TITLE="AI DEBATT: ${AGENT_A_NAME} ($(_agent_model "$AGENT_A_CMD")) vs ${AGENT_B_NAME} ($(_agent_model "$AGENT_B_CMD"))"
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
echo -e "${GRAY}Maks $MAX_MESSAGES meldinger totalt${NC}"

# Round 0: Both get the same starting message in parallel
start_msg="$SYSTEM_PROMPT

Problemet dere skal løse:
$PROBLEM

Gjenværende meldinger: $MAX_MESSAGES"

echo ""
echo -e "${GRAY}Runde 0: Begge agenter tenker parallelt...${NC}"

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

agent_a_exit=$(cat "$tmpdir/agent_a_r0_exit" 2>/dev/null || echo "1")
agent_b_exit=$(cat "$tmpdir/agent_b_r0_exit" 2>/dev/null || echo "1")

if [[ "$agent_a_exit" != "0" ]]; then
  if [[ "$agent_a_exit" == "124" ]]; then
    echo "FEIL: $AGENT_A_NAME runde 0 tidsavbrutt etter ${API_TIMEOUT}s" >&2
  else
    echo "FEIL: $AGENT_A_NAME runde 0 feilet (exit $agent_a_exit): $(cat "$tmpdir/agent_a_r0_err" 2>/dev/null)" >&2
  fi
  exit 1
fi
if [[ "$agent_b_exit" != "0" ]]; then
  if [[ "$agent_b_exit" == "124" ]]; then
    echo "FEIL: $AGENT_B_NAME runde 0 tidsavbrutt etter ${API_TIMEOUT}s" >&2
  else
    echo "FEIL: $AGENT_B_NAME runde 0 feilet (exit $agent_b_exit): $(cat "$tmpdir/agent_b_r0_err" 2>/dev/null)" >&2
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

print_msg "$AGENT_A_COLOR" "$AGENT_A_NAME" 1 $((MAX_MESSAGES - msg_count)) "$agent_a_response"
print_msg "$AGENT_B_COLOR" "$AGENT_B_NAME" 2 $((MAX_MESSAGES - msg_count)) "$agent_b_response"

# Extract ENIG conclusion from a response
extract_enig() {
  echo "$1" | grep -oiE "^[[:space:]]*\*{0,2}ENIG:.*" | head -1 | sed 's/^[[:space:]]*\*\{0,2\}[Ee][Nn][Ii][Gg]:[[:space:]]*//' || true
}

# Check if response contains ENIG
has_enig() {
  echo "$1" | grep -qiE "^[[:space:]]*\*{0,2}ENIG:"
}

# When one agent says ENIG, ask the other to confirm
# Args: proposer_name proposal confirmer_name confirmer_call_fn confirmer_color confirmer_response_var
confirm_agreement() {
  local proposer="$1" proposal="$2" confirmer="$3" call_fn="$4" confirm_color="$5" response_var="$6"
  local conclusion
  conclusion=$(extract_enig "$proposal")

  echo ""
  echo -e "${GRAY}${proposer} foreslår enighet. Ber ${confirmer} bekrefte...${NC}"

  local confirm_msg="${proposer} foreslår at dere er enige og konkluderer med:
ENIG: ${conclusion}

Er du enig? Hvis ja, svar med \"ENIG: <samme eller justert konklusjon>\". Hvis nei, forklar hvorfor."

  local confirm_response
  confirm_response=$($call_fn "$confirm_msg")
  msg_count=$((msg_count + 1))

  print_msg "$confirm_color" "$confirmer" "$msg_count" $((MAX_MESSAGES - msg_count)) "$confirm_response"

  if has_enig "$confirm_response"; then
    local final
    final=$(extract_enig "$confirm_response")
    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║           ENIGHET OPPNÅDD             ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
    echo -e "${BOLD}Konklusjon:${NC} ${final}"
    echo -e "${GRAY}Meldinger brukt: ${msg_count}/${MAX_MESSAGES}${NC}"
    if [[ "$DEBUG" == true ]]; then
      echo -e "${GRAY}Debug-filer: $tmpdir/${NC}"
    fi
    exit 0
  fi

  # Not confirmed — update the appropriate response variable for the loop
  printf -v "$response_var" '%s' "$confirm_response"
}

# Check round 0 for early agreement
if has_enig "$agent_a_response" && has_enig "$agent_b_response"; then
  echo ""
  echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║           ENIGHET OPPNÅDD             ║${NC}"
  echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
  echo -e "${BOLD}Konklusjon:${NC} $(extract_enig "$agent_a_response")"
  echo -e "${GRAY}Meldinger brukt: ${msg_count}/${MAX_MESSAGES}${NC}"
  if [[ "$DEBUG" == true ]]; then
    echo -e "${GRAY}Debug-filer: $tmpdir/${NC}"
  fi
  exit 0
elif has_enig "$agent_a_response"; then
  confirm_agreement "$AGENT_A_NAME" "$agent_a_response" "$AGENT_B_NAME" call_agent_b "$AGENT_B_COLOR" agent_b_response
elif has_enig "$agent_b_response"; then
  confirm_agreement "$AGENT_B_NAME" "$agent_b_response" "$AGENT_A_NAME" call_agent_a "$AGENT_A_COLOR" agent_a_response
fi

# Rounds 1+: Ping-pong (sequential, so session vars work)
while [[ $msg_count -lt $MAX_MESSAGES ]]; do
  remaining=$((MAX_MESSAGES - msg_count))

  # Agent A gets Agent B's last response
  agent_a_msg="$AGENT_B_NAME sin melding:
$agent_b_response

Gjenværende meldinger: $((remaining - 1))"

  agent_a_response=$(call_agent_a "$agent_a_msg")
  msg_count=$((msg_count + 1))
  print_msg "$AGENT_A_COLOR" "$AGENT_A_NAME" "$msg_count" $((MAX_MESSAGES - msg_count)) "$agent_a_response"

  if has_enig "$agent_a_response"; then
    confirm_agreement "$AGENT_A_NAME" "$agent_a_response" "$AGENT_B_NAME" call_agent_b "$AGENT_B_COLOR" agent_b_response
  fi

  if [[ $msg_count -ge $MAX_MESSAGES ]]; then break; fi

  # Agent B gets Agent A's last response
  agent_b_msg="$AGENT_A_NAME sin melding:
$agent_a_response

Gjenværende meldinger: $((MAX_MESSAGES - msg_count - 1))"

  agent_b_response=$(call_agent_b "$agent_b_msg")
  msg_count=$((msg_count + 1))
  print_msg "$AGENT_B_COLOR" "$AGENT_B_NAME" "$msg_count" $((MAX_MESSAGES - msg_count)) "$agent_b_response"

  if has_enig "$agent_b_response"; then
    confirm_agreement "$AGENT_B_NAME" "$agent_b_response" "$AGENT_A_NAME" call_agent_a "$AGENT_A_COLOR" agent_a_response
  fi
done

echo ""
echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║         DEBATTEN ER OVER              ║${NC}"
echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
echo -e "Ingen enighet etter ${MAX_MESSAGES} meldinger."
echo -e "${BOLD}Siste standpunkter:${NC}"
echo -e "  ${AGENT_A_COLOR}${AGENT_A_NAME}:${NC} $(echo "$agent_a_response" | head -3)"
echo -e "  ${AGENT_B_COLOR}${AGENT_B_NAME}:${NC} $(echo "$agent_b_response" | head -3)"
if [[ "$DEBUG" == true ]]; then
  echo -e "${GRAY}Debug-filer: $tmpdir/${NC}"
fi
