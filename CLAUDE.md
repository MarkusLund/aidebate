# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

aidebate is a bash-based AI debate simulator that orchestrates structured dialogues between AI CLI tools (Claude, Codex, Gemini) to collaboratively solve problems. Two agents receive the same problem, form independent hypotheses, then exchange responses until agreement or message limit.

## Running the Tool

```bash
# Direct execution
bash ai-debate.sh "Your problem here"

# Via npm (after npm install -g)
aidebate "Your problem here"

# With options
aidebate --max-rounds 4 --claude-model sonnet --codex-model gpt-5.2-codex "Your problem"

# Debug mode (keeps temp files, shows raw API responses)
aidebate --debug "Your problem"
```

## Architecture

The entire application is a single bash script (`ai-debate.sh`). Key sections:

1. **Tool Detection (lines 5-42)**: Auto-detects available CLI tools (`claude`, `codex`, `gemini`) and assigns agent pairs by priority: Claude+Codex > Claude+Gemini > Codex+Gemini > single-agent fallback.

2. **API Calls (lines 340-432)**: `_call_agent()` handles all three backends with session resumption. Each backend has different JSON output formats:
   - Claude: `{ session_id, result }`
   - Gemini: `{ session_id, response }`
   - Codex: NDJSON with `thread.started` and `item.completed` events

3. **Round 0 Parallel Execution (lines 476-553)**: Both agents receive the problem simultaneously and respond in parallel using background processes.

4. **Agreement Detection (lines 556-607)**: Monitors for `AGREED:` prefix in responses. When one agent proposes agreement, the other is asked to confirm.

5. **Session Management**: Each agent maintains a session ID for context continuity across the debate and optional post-debate chat.

## Dependencies

- Required: `jq` for JSON parsing
- At least one AI CLI: `claude`, `codex`, or `gemini`
- Optional: `timeout` or `gtimeout` (coreutils) for API timeout enforcement

## Maintenance

Keep this CLAUDE.md file updated when making significant changes to the codebase, such as adding new CLI options, changing the agent priority system, modifying API response parsing, or altering the debate flow logic.
