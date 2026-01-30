# aidebate

AI debate simulator that pits two AI agents against each other to collaboratively solve a problem through structured dialogue.

## How it works

Two AI agents receive the same problem and independently form their initial hypotheses (round 0, in parallel). They then take turns responding to each other's arguments until they reach agreement or hit the message limit. When one agent proposes a conclusion (prefixed with `ENIG:`), the other is asked to confirm or object.

## Supported agents

The script auto-detects which CLI tools are available and picks the best pair:

| Priority | Agent A | Agent B |
|----------|---------|---------|
| 1        | Claude  | Codex   |
| 2        | Claude  | Gemini  |
| 3        | Codex   | Gemini  |
| 4        | Single agent fallback (same tool for both sides) |

Requires at least one of: `claude`, `codex`, `gemini`. Also requires `jq`.

## Installation

```bash
npm install -g aidebate
```

Or run directly:

```bash
bash ai-debate.sh "Your problem here"
```

## Usage

```bash
aidebate [OPTIONS] "<problem>"
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--max-rounds N` | Max number of messages | 10 |
| `--timeout N` | API timeout in seconds | 60 |
| `--claude-model MODEL` | Claude model (`haiku`, `sonnet`, `opus`) | interactive |
| `--codex-model MODEL` | Codex model (`gpt-5.1-codex-mini`, `gpt-5.2-codex`) | interactive |
| `--gemini-model MODEL` | Gemini model (`gemini-2.5-flash`, `gemini-3-flash-preview`) | interactive |
| `--system-prompt-file F` | Custom system prompt from file | built-in |
| `--debug` | Keep raw API responses and show tmpdir | off |

### Examples

```bash
# Basic usage with interactive model selection
aidebate "Is P = NP?"

# Specify models directly
aidebate --claude-model sonnet --codex-model gpt-5.2-codex "Explain monads"

# Short debate with debug output
aidebate --max-rounds 4 --debug "Best sorting algorithm for nearly-sorted data"
```

## License

MIT
