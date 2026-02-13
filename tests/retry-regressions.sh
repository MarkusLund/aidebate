#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT_PATH="$ROOT_DIR/ai-debate.sh"
JQ_BIN=$(command -v jq)

CASE_DIR=""
CASE_OUT=""
CASE_ERR=""
CASE_COUNTER=""
CASE_RC=0
CASE_CALLS=0

setup_case() {
  CASE_DIR=$(mktemp -d)
  local bin_dir="$CASE_DIR/bin"
  mkdir -p "$bin_dir"
  CASE_OUT="$CASE_DIR/stdout.log"
  CASE_ERR="$CASE_DIR/stderr.log"
  CASE_COUNTER="$CASE_DIR/counter.txt"
  echo 0 > "$CASE_COUNTER"

  ln -sf "$JQ_BIN" "$bin_dir/jq"

  cat > "$bin_dir/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$bin_dir/sleep"

  cat > "$bin_dir/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

counter_file="${AIDEBATE_COUNTER_FILE:?}"
scenario="${AIDEBATE_TEST_SCENARIO:?}"
lock_dir="${counter_file}.lock"

while ! mkdir "$lock_dir" 2>/dev/null; do
  /bin/sleep 0.01
done

count=$(cat "$counter_file" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$counter_file"
rmdir "$lock_dir"

emit_ok() {
  local n="$1"
  printf '{"session_id":"sid-%s","result":"response-%s"}\n' "$n" "$n"
}

case "$scenario" in
  validate_json_retry)
    if [[ $count -le 2 ]]; then
      emit_ok "$count"
      exit 0
    fi
    if [[ $count -eq 3 ]]; then
      echo "rate limit 429 quota exceeded"
      exit 0
    fi
    emit_ok "$count"
    ;;
  r0_retry)
    worker_counter_file="${counter_file}.worker.${PPID}"
    worker_count=$(cat "$worker_counter_file" 2>/dev/null || echo 0)
    worker_count=$((worker_count + 1))
    echo "$worker_count" > "$worker_counter_file"
    if [[ $worker_count -eq 1 ]]; then
      echo "HTTP 429 rate limit exceeded" >&2
      exit 1
    fi
    emit_ok "$count"
    ;;
  max_retries_exact)
    if [[ $count -le 2 ]]; then
      emit_ok "$count"
      exit 0
    fi
    echo "rate limit 429 quota exceeded"
    exit 0
    ;;
  timeout_no_retry)
    if [[ $count -le 2 ]]; then
      emit_ok "$count"
      exit 0
    fi
    echo "simulated timeout" >&2
    exit 124
    ;;
  *)
    echo "Unknown scenario: $scenario" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$bin_dir/claude"
}

teardown_case() {
  if [[ -n "$CASE_DIR" && -d "$CASE_DIR" ]]; then
    rm -rf "$CASE_DIR"
  fi
}

fail_case() {
  local msg="$1"
  echo "FAIL: $msg" >&2
  echo "--- stdout ---" >&2
  cat "$CASE_OUT" >&2 || true
  echo "--- stderr ---" >&2
  cat "$CASE_ERR" >&2 || true
  exit 1
}

run_case() {
  local scenario="$1" max_rounds="$2" max_retries="$3"
  setup_case
  set +e
  PATH="$CASE_DIR/bin:/usr/bin:/bin" \
    AIDEBATE_TEST_SCENARIO="$scenario" \
    AIDEBATE_COUNTER_FILE="$CASE_COUNTER" \
    /bin/bash "$SCRIPT_PATH" --max-rounds "$max_rounds" --max-retries "$max_retries" "retry regression test" \
    </dev/null >"$CASE_OUT" 2>"$CASE_ERR"
  CASE_RC=$?
  set -e
  CASE_CALLS=$(cat "$CASE_COUNTER")
}

test_validate_json_retry() {
  run_case "validate_json_retry" 3 1
  [[ $CASE_RC -eq 0 ]] || fail_case "validate_json retry case should succeed"
  [[ $CASE_CALLS -eq 4 ]] || fail_case "expected 4 calls, got $CASE_CALLS"
  grep -q "agent_a: retrying in" "$CASE_ERR" || fail_case "missing retry indicator for agent_a on stderr"
  ! grep -q "agent_a: retrying in" "$CASE_OUT" || fail_case "retry indicator should not appear in stdout"
  teardown_case
  echo "PASS: validate_json status is handled without stdout contamination"
}

test_round0_retry_survives_failure() {
  run_case "r0_retry" 2 1
  [[ $CASE_RC -eq 0 ]] || fail_case "round-0 retry case should succeed"
  [[ $CASE_CALLS -ge 4 ]] || fail_case "expected at least 4 calls, got $CASE_CALLS"
  grep -q "round 0 failed" "$CASE_ERR" && fail_case "round-0 should not fail when retry succeeds"
  teardown_case
  echo "PASS: round-0 retries after first failure"
}

test_max_retries_exact() {
  run_case "max_retries_exact" 3 3
  [[ $CASE_RC -ne 0 ]] || fail_case "max-retries exhaustion case should fail"
  [[ $CASE_CALLS -eq 6 ]] || fail_case "expected 6 calls (2 round-0 + 4 attempt path), got $CASE_CALLS"
  grep -q "gave up after 3 retries" "$CASE_ERR" || fail_case "missing retries exhausted message"
  teardown_case
  echo "PASS: max-retries applies full configured retry count"
}

test_timeout_not_retried() {
  run_case "timeout_no_retry" 3 3
  [[ $CASE_RC -ne 0 ]] || fail_case "timeout case should fail"
  [[ $CASE_CALLS -eq 3 ]] || fail_case "expected 3 calls (2 round-0 + 1 timeout), got $CASE_CALLS"
  grep -Eq "timed out after|API call failed" "$CASE_ERR" || fail_case "missing timeout/failure error message"
  teardown_case
  echo "PASS: timeout path is non-retriable"
}

test_validate_json_retry
test_round0_retry_survives_failure
test_max_retries_exact
test_timeout_not_retried

echo "All retry regression tests passed."
