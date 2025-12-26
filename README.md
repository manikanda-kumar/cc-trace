# cc-trace

Claude Code tracing hooks for LangSmith. Automatically sends conversation traces to LangSmith and surfaces learnings from past tool failures at session start. Based on article [Tracing Claude code with Langsmith](https://docs.langchain.com/langsmith/trace-claude-code)

## Features

- **Trace Export**: Sends Claude Code conversations to LangSmith as structured traces (turns, LLM calls, tool calls)
- **Project Metadata**: Tags traces with GitHub repo name and folder for filtering
- **Session Learnings**: Queries LangSmith for recent tool failures and injects actionable reminders at session start
- **Incremental Processing**: Only processes new messages since last hook run

## Installation

1. Clone this repository
2. Run the installer:

```bash
./install-claude-hooks.sh
```

3. Edit `~/.claude/hooks/env` and add your LangSmith API key:

```bash
CC_LANGSMITH_API_KEY=your-api-key-here
```

4. Copy `settings.json` to your project's `.claude/` directory (or merge with existing settings):

```bash
mkdir -p .claude
cp settings.json .claude/settings.json
```

## Configuration

Environment variables in `~/.claude/hooks/env`:

| Variable | Default | Description |
|----------|---------|-------------|
| `TRACE_TO_LANGSMITH` | `true` | Enable/disable tracing |
| `CC_LANGSMITH_API_KEY` | - | LangSmith API key (required) |
| `CC_LANGSMITH_PROJECT` | `claude-code` | LangSmith project name |
| `CC_LANGSMITH_DEBUG` | `false` | Enable debug logging |
| `CC_LANGSMITH_MAX_GROUPS` | `6` | Max failure groups to show |
| `CC_LANGSMITH_MAX_RUNS` | `200` | Max runs to query |

## How It Works

### Stop Hook (Trace Export)

After each Claude Code response:

1. Parses the conversation transcript (JSONL)
2. Groups messages into turns (user message → assistant responses → tool results)
3. Creates hierarchical traces in LangSmith:
   - **Turn run** (chain): Top-level container
   - **LLM runs**: Each Claude response
   - **Tool runs**: Each tool call with inputs/outputs
4. Tags traces with repo name and folder for filtering

### Start Hook (Session Learnings)

At session start:

1. Queries LangSmith for recent tool failures matching the current repo/folder
2. Deduplicates and ranks failures by recency and frequency
3. Generates actionable hints (e.g., "Check file permissions", "Verify binaries on PATH")
4. Injects learnings into Claude's context

## Requirements

- `jq` - JSON processing
- `curl` - API calls
- `python3` - For start hook LangSmith queries (with `langsmith` package)
- `uuidgen` - UUID generation

## Logs

Hook logs are written to `~/.claude/state/hook.log`

## Project Structure

```
├── start_hook.sh           # SessionStart hook - loads learnings
├── stop_hook.sh            # Stop hook - exports traces
├── install-claude-hooks.sh # Installer script
└── settings.json           # Claude Code hook configuration
```
