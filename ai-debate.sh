#!/usr/bin/env bash
set -euo pipefail

# Verify required tools
for cmd in claude codex jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Feil: '$cmd' ikke funnet i PATH"; exit 1; }
done

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

# AI Debate: Claude (haiku) vs Codex (gpt-5.1-codex-mini)

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
    --debug)
      DEBUG=true; shift ;;
    --help|-h)
      echo "Usage: bash ai-debate.sh [OPTIONS] \"<problem>\""
      echo ""
      echo "Options:"
      echo "  --max-rounds N          Maks antall meldinger (default: 10)"
      echo "  --timeout N             API timeout i sekunder (default: 60)"
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

claude_session=""
codex_session=""
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

parse_claude() {
  local raw
  raw=$(cat)
  local sid
  sid=$(echo "$raw" | jq -r '.session_id // empty' 2>/dev/null) || true
  if [[ -n "$sid" ]]; then
    echo "$sid" > "$tmpdir/claude_sid"
  fi
  echo "$raw" | jq -r '.result // empty' 2>/dev/null
}

parse_codex() {
  local raw
  raw=$(cat)
  local sid
  sid=$(echo "$raw" | grep '"type":"thread.started"' | jq -r '.thread_id // empty' 2>/dev/null) || true
  if [[ -n "$sid" ]]; then
    echo "$sid" > "$tmpdir/codex_sid"
  fi
  echo "$raw" | grep '"type":"item.completed"' | grep '"agent_message"' | tail -1 | jq -r '.item.text // empty' 2>/dev/null
}

call_claude() {
  local msg="$1"
  local args=(claude -p "$msg" --model haiku --output-format json)
  if [[ -n "$claude_session" ]]; then
    args+=(--resume "$claude_session")
  fi
  local raw err_file="$tmpdir/claude_err"
  if ! raw=$(run_with_timeout "${args[@]}" 2>"$err_file"); then
    local exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
      echo "FEIL: Claude API-kall tidsavbrutt etter ${API_TIMEOUT}s" >&2
    else
      echo "FEIL: Claude API-kall feilet (exit $exit_code): $(cat "$err_file")" >&2
    fi
    return 1
  fi
  debug_save "claude" "$raw"
  if [[ -z "$claude_session" ]]; then
    claude_session=$(echo "$raw" | jq -r '.session_id // empty' 2>/dev/null) || true
  fi
  echo "$raw" | jq -r '.result // empty' 2>/dev/null
}

call_codex() {
  local msg="$1"
  local raw err_file="$tmpdir/codex_err"
  if [[ -z "$codex_session" ]]; then
    if ! raw=$(run_with_timeout codex exec -m gpt-5.1-codex-mini "$msg" --json 2>"$err_file"); then
      local exit_code=$?
      if [[ $exit_code -eq 124 ]]; then
        echo "FEIL: Codex API-kall tidsavbrutt etter ${API_TIMEOUT}s" >&2
      else
        echo "FEIL: Codex API-kall feilet (exit $exit_code): $(cat "$err_file")" >&2
      fi
      return 1
    fi
  else
    if ! raw=$(run_with_timeout codex exec resume "$codex_session" -m gpt-5.1-codex-mini "$msg" --json 2>"$err_file"); then
      local exit_code=$?
      if [[ $exit_code -eq 124 ]]; then
        echo "FEIL: Codex API-kall tidsavbrutt etter ${API_TIMEOUT}s" >&2
      else
        echo "FEIL: Codex API-kall feilet (exit $exit_code): $(cat "$err_file")" >&2
      fi
      return 1
    fi
  fi
  debug_save "codex" "$raw"
  if [[ -z "$codex_session" ]]; then
    codex_session=$(echo "$raw" | grep '"type":"thread.started"' | jq -r '.thread_id // empty' 2>/dev/null) || true
  fi
  echo "$raw" | grep '"type":"item.completed"' | grep '"agent_message"' | tail -1 | jq -r '.item.text // empty' 2>/dev/null
}

print_msg() {
  local color="$1" agent="$2" num="$3" remaining="$4" text="$5"
  echo ""
  echo -e "${color}━━━ ${agent} [melding ${num}/${MAX_MESSAGES}, ${remaining} gjenstår] ━━━${NC}"
  echo -e "${color}${text}${NC}"
}

echo -e "${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║        AI DEBATT: Claude vs Codex      ║${NC}"
echo -e "${BOLD}╚════════════════════════════════════════╝${NC}"
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

# Run both in background, writing raw output to files
(run_with_timeout claude -p "$start_msg" --model haiku --output-format json 2>"$tmpdir/claude_r0_err" > "$tmpdir/claude_raw"; echo $? > "$tmpdir/claude_r0_exit") &
pid_claude=$!
(run_with_timeout codex exec -m gpt-5.1-codex-mini "$start_msg" --json 2>"$tmpdir/codex_r0_err" > "$tmpdir/codex_raw"; echo $? > "$tmpdir/codex_r0_exit") &
pid_codex=$!

wait $pid_claude 2>/dev/null || true
wait $pid_codex 2>/dev/null || true

claude_exit=$(cat "$tmpdir/claude_r0_exit" 2>/dev/null || echo "1")
codex_exit=$(cat "$tmpdir/codex_r0_exit" 2>/dev/null || echo "1")

if [[ "$claude_exit" != "0" ]]; then
  if [[ "$claude_exit" == "124" ]]; then
    echo "FEIL: Claude runde 0 tidsavbrutt etter ${API_TIMEOUT}s" >&2
  else
    echo "FEIL: Claude runde 0 feilet (exit $claude_exit): $(cat "$tmpdir/claude_r0_err" 2>/dev/null)" >&2
  fi
  exit 1
fi
if [[ "$codex_exit" != "0" ]]; then
  if [[ "$codex_exit" == "124" ]]; then
    echo "FEIL: Codex runde 0 tidsavbrutt etter ${API_TIMEOUT}s" >&2
  else
    echo "FEIL: Codex runde 0 feilet (exit $codex_exit): $(cat "$tmpdir/codex_r0_err" 2>/dev/null)" >&2
  fi
  exit 1
fi

# Save debug output for round 0
debug_save "claude_r0" "$(cat "$tmpdir/claude_raw")"
debug_save "codex_r0" "$(cat "$tmpdir/codex_raw")"

# Parse results
claude_response=$(cat "$tmpdir/claude_raw" | parse_claude)
codex_response=$(cat "$tmpdir/codex_raw" | parse_codex)
claude_session=$(cat "$tmpdir/claude_sid" 2>/dev/null || true)
codex_session=$(cat "$tmpdir/codex_sid" 2>/dev/null || true)
msg_count=2

print_msg "$BLUE" "Claude" 1 $((MAX_MESSAGES - msg_count)) "$claude_response"
print_msg "$GREEN" "Codex" 2 $((MAX_MESSAGES - msg_count)) "$codex_response"

# Extract ENIG conclusion from a response
extract_enig() {
  echo "$1" | grep -oiE "^[[:space:]]*\*{0,2}ENIG:.*" | head -1 | sed 's/^[[:space:]]*\*\{0,2\}[Ee][Nn][Ii][Gg]:[[:space:]]*//' || true
}

# Check if response contains ENIG
has_enig() {
  echo "$1" | grep -qiE "^[[:space:]]*\*{0,2}ENIG:"
}

# When one agent says ENIG, ask the other to confirm
confirm_agreement() {
  local proposer="$1" proposal="$2" confirmer="$3" call_fn="$4"
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

  local confirm_color
  if [[ "$confirmer" == "Claude" ]]; then confirm_color="$BLUE"; else confirm_color="$GREEN"; fi
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
  if [[ "$confirmer" == "Claude" ]]; then
    claude_response="$confirm_response"
  else
    codex_response="$confirm_response"
  fi
}

# Check round 0 for early agreement
if has_enig "$claude_response" && has_enig "$codex_response"; then
  echo ""
  echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║           ENIGHET OPPNÅDD             ║${NC}"
  echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
  echo -e "${BOLD}Konklusjon:${NC} $(extract_enig "$claude_response")"
  echo -e "${GRAY}Meldinger brukt: ${msg_count}/${MAX_MESSAGES}${NC}"
  if [[ "$DEBUG" == true ]]; then
    echo -e "${GRAY}Debug-filer: $tmpdir/${NC}"
  fi
  exit 0
elif has_enig "$claude_response"; then
  confirm_agreement "Claude" "$claude_response" "Codex" call_codex
elif has_enig "$codex_response"; then
  confirm_agreement "Codex" "$codex_response" "Claude" call_claude
fi

# Rounds 1+: Ping-pong (sequential, so session vars work)
while [[ $msg_count -lt $MAX_MESSAGES ]]; do
  remaining=$((MAX_MESSAGES - msg_count))

  # Claude gets Codex's last response
  claude_msg="Codex sin melding:
$codex_response

Gjenværende meldinger: $((remaining - 1))"

  claude_response=$(call_claude "$claude_msg")
  msg_count=$((msg_count + 1))
  print_msg "$BLUE" "Claude" "$msg_count" $((MAX_MESSAGES - msg_count)) "$claude_response"

  if has_enig "$claude_response"; then
    confirm_agreement "Claude" "$claude_response" "Codex" call_codex
  fi

  if [[ $msg_count -ge $MAX_MESSAGES ]]; then break; fi

  # Codex gets Claude's last response
  codex_msg="Claude sin melding:
$claude_response

Gjenværende meldinger: $((MAX_MESSAGES - msg_count - 1))"

  codex_response=$(call_codex "$codex_msg")
  msg_count=$((msg_count + 1))
  print_msg "$GREEN" "Codex" "$msg_count" $((MAX_MESSAGES - msg_count)) "$codex_response"

  if has_enig "$codex_response"; then
    confirm_agreement "Codex" "$codex_response" "Claude" call_claude
  fi
done

echo ""
echo -e "${YELLOW}╔════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║         DEBATTEN ER OVER              ║${NC}"
echo -e "${YELLOW}╚════════════════════════════════════════╝${NC}"
echo -e "Ingen enighet etter ${MAX_MESSAGES} meldinger."
echo -e "${BOLD}Siste standpunkter:${NC}"
echo -e "  ${BLUE}Claude:${NC} $(echo "$claude_response" | head -3)"
echo -e "  ${GREEN}Codex:${NC} $(echo "$codex_response" | head -3)"
if [[ "$DEBUG" == true ]]; then
  echo -e "${GRAY}Debug-filer: $tmpdir/${NC}"
fi
