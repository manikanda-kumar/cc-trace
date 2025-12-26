#!/bin/bash
###
# Claude Code SessionStart Hook - Load "Learnings" from LangSmith tool failures
#
# For SessionStart hooks, stdout is injected into Claude's context.
# This script fetches recent tool-call failures for the current project
# (as tagged by stop_hook.sh), then prints a short, deduped, actionable block.
###

set -e

# Optional env file for local installs.
ENV_FILE="$HOME/.claude/hooks/env"
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

LOG_FILE="$HOME/.claude/state/hook.log"
DEBUG="$(echo "$CC_LANGSMITH_DEBUG" | tr '[:upper:]' '[:lower:]')"

log() {
    local level="$1"
    shift
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $*" >> "$LOG_FILE"
}

debug() {
    if [ "$DEBUG" = "true" ]; then
        log "DEBUG" "$@"
    fi
}

# Exit early if tracing disabled
if [ "$(echo "$TRACE_TO_LANGSMITH" | tr '[:upper:]' '[:lower:]')" != "true" ]; then
    log "INFO" "Tracing disabled, skipping LangSmith context load"
    exit 0
fi

# Required commands
for cmd in jq python3; do
    if ! command -v "$cmd" &> /dev/null; then
        log "WARN" "$cmd not found, skipping context load"
        exit 0
    fi
done

API_KEY="${CC_LANGSMITH_API_KEY:-$LANGSMITH_API_KEY}"
PROJECT="${CC_LANGSMITH_PROJECT:-claude-code}"

if [ -z "$API_KEY" ]; then
    log "WARN" "API key not set, skipping context load"
    exit 0
fi

# Read hook input (SessionStart includes cwd + source)
HOOK_INPUT="$(cat || true)"
SOURCE="$(echo "$HOOK_INPUT" | jq -r '.source // ""' 2>/dev/null || echo "")"
CWD_FROM_INPUT="$(echo "$HOOK_INPUT" | jq -r '.cwd // ""' 2>/dev/null || echo "")"

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${CWD_FROM_INPUT:-$PWD}}"  # repo root
CWD_DIR="${CWD_FROM_INPUT:-$PWD}"                           # session cwd

# Folder path relative to repo root (used for LangSmith metadata + filtering)
if [ -n "$PROJECT_DIR" ] && [[ "$CWD_DIR" == "$PROJECT_DIR"* ]]; then
    FOLDER_NAME="${CWD_DIR#"$PROJECT_DIR"}"
    FOLDER_NAME="${FOLDER_NAME#/}"
    if [ -z "$FOLDER_NAME" ]; then
        FOLDER_NAME="."
    fi
else
    FOLDER_NAME="$(basename "$CWD_DIR")"
fi
FOLDER_TAG="${FOLDER_NAME//\//_}"

get_git_project_root() {
    local dir="$1"
    git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo ""
}

get_github_project_name() {
    local dir="$1"
    local remote_url

    remote_url=$(git -C "$dir" remote get-url origin 2>/dev/null || echo "")
    if [ -z "$remote_url" ]; then
        echo "unknown"
        return
    fi
    echo "$remote_url" | sed -E 's|.*/([^/]+)(\.git)?$|\1|'
}

# Prefer deriving project root from git when possible.
GIT_PROJECT_ROOT="$(get_git_project_root "$PROJECT_DIR")"
if [ -n "$GIT_PROJECT_ROOT" ]; then
    PROJECT_DIR="$GIT_PROJECT_ROOT"
fi

GITHUB_PROJECT="$(get_github_project_name "$PROJECT_DIR")"

log "INFO" "SessionStart hook: source=$SOURCE project_root=$PROJECT_DIR cwd=$CWD_DIR repo=$GITHUB_PROJECT folder_rel=$FOLDER_NAME"

# If we cannot determine a stable repo identity, skip to avoid cross-project mismatches.
if [ "$GITHUB_PROJECT" = "unknown" ]; then
    log "WARN" "No git remote detected (repo=unknown); skipping LangSmith context load"
    exit 0
fi

# Query LangSmith for recent tool runs with errors for this project metadata.
# Output should be short, deduped, and actionable to serve as "learnings".
query_langsmith_tool_errors() {
    local python_script
    python_script=$(cat <<'PY'
import os
import re
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone


def _safe_str(v) -> str:
    try:
        return "" if v is None else str(v)
    except Exception:
        return ""


def _truncate(s: str, limit: int) -> str:
    s = (s or "").strip()
    if len(s) <= limit:
        return s
    return s[: limit - 1] + "…"


def _iso(ts):
    if not ts:
        return None
    try:
        return ts.isoformat()
    except Exception:
        return _safe_str(ts)


def _normalize_error(err: str) -> str:
    # Strip volatile details so we can dedupe.
    err = (err or "").strip()
    err = re.sub(r"\b0x[0-9a-fA-F]+\b", "0x…", err)
    err = re.sub(r"\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z\b", "<ts>", err)
    err = re.sub(r"\b\d+\b", "<n>", err)
    err = re.sub(r"\s+", " ", err)
    return err


def _hint(tool_name: str, error: str) -> str | None:
    tl = (tool_name or "").lower()
    el = (error or "").lower()

    if "claude_project_dir" in el and ("unset" in el or "not set" in el):
        return "Set `CLAUDE_PROJECT_DIR` to the repo root (e.g. `export CLAUDE_PROJECT_DIR=$(git rev-parse --show-toplevel)`)."

    if "command not found" in el or "no such file or directory" in el:
        return "Verify required binaries are installed and on PATH (and the tool name is correct)."

    if "permission denied" in el or "operation not permitted" in el:
        return "Check file permissions / sandbox restrictions; try writing under the project dir."

    if "jq" in el and ("parse" in el or "invalid" in el):
        return "Ensure hook input is valid JSON and guard jq parsing with fallbacks."

    if "rate limit" in el or "429" in el:
        return "Reduce query frequency/limit or narrow filters; consider caching results."

    if "timeout" in el:
        return "Try a smaller query (fewer runs) or increase timeouts if supported."

    # Tool-specific nudge.
    if tl == "bash" and ("cd" in el and "no such file" in el):
        return "Double-check working directory; prefer using absolute paths via `workdir` when possible."

    return None


try:
    from langsmith import Client
except Exception:
    # SessionStart context should stay quiet if SDK isn't installed.
    sys.exit(0)

api_key = os.environ.get("CC_LANGSMITH_API_KEY") or os.environ.get("LANGSMITH_API_KEY")
project_name = os.environ.get("CC_LANGSMITH_PROJECT", "claude-code")
github_project = os.environ.get("GITHUB_PROJECT", "unknown")
folder_name = os.environ.get("FOLDER_NAME", "unknown")

if not api_key or github_project == "unknown":
    sys.exit(0)

# Limits to keep injected context small.
MAX_RUNS = int(os.environ.get("CC_LANGSMITH_MAX_RUNS", "200"))
MAX_GROUPS = int(os.environ.get("CC_LANGSMITH_MAX_GROUPS", "6"))
MAX_ERROR_CHARS = int(os.environ.get("CC_LANGSMITH_MAX_ERROR_CHARS", "280"))
MAX_INPUT_CHARS = int(os.environ.get("CC_LANGSMITH_MAX_INPUT_CHARS", "180"))
MAX_TOTAL_CHARS = int(os.environ.get("CC_LANGSMITH_MAX_TOTAL_CHARS", "3500"))

client = Client(api_key=api_key)

# Prefer very recent failures, fall back to 7d.
cutoff_24h = datetime.now(timezone.utc) - timedelta(days=1)
cutoff_7d = datetime.now(timezone.utc) - timedelta(days=7)

filters = []
if folder_name:
    # stop_hook.sh now writes: repo_name / repo_folder
    filters.append(f'metadata.repo_name:"{github_project}" AND metadata.repo_folder:"{folder_name}"')
    # older versions wrote: github_project / folder_name
    filters.append(f'metadata.github_project:"{github_project}" AND metadata.folder_name:"{folder_name}"')
else:
    filters.append(f'metadata.repo_name:"{github_project}"')
    filters.append(f'metadata.github_project:"{github_project}"')

runs = []
for flt in filters:
    try:
        runs_iter = client.list_runs(
            project_name=project_name,
            filter=flt,
            execution_order="DESC",
            limit=MAX_RUNS,
        )
        runs = list(runs_iter)
    except Exception:
        runs = []
    if runs:
        break

# Extract tool failures.
failures = []
for r in runs:
    if getattr(r, "run_type", None) != "tool":
        continue

    err = getattr(r, "error", None)
    if not err:
        continue

    start_time = getattr(r, "start_time", None)
    # Keep within 7d. We'll later prioritize 24h.
    if start_time and start_time < cutoff_7d:
        continue

    rid = _safe_str(getattr(r, "id", ""))
    name = _safe_str(getattr(r, "name", "tool"))
    error = _safe_str(err)
    inputs = getattr(r, "inputs", None)

    # Represent inputs compactly, but avoid dumping large/secret-likely blobs.
    inputs_preview = ""
    if inputs is not None:
        inputs_preview = _truncate(_safe_str(inputs), MAX_INPUT_CHARS)

    failures.append(
        {
            "id": rid,
            "name": name,
            "error": error,
            "norm": _normalize_error(error),
            "start_time": start_time,
            "start_time_iso": _iso(start_time),
            "inputs_preview": inputs_preview,
            "is_recent": bool(start_time and start_time >= cutoff_24h),
        }
    )

if not failures:
    sys.exit(0)

# Group by tool+normalized error and rank by (recency, count).
by_group = defaultdict(list)
for f in failures:
    key = (f.get("name") or "tool", f.get("norm") or "")
    by_group[key].append(f)

groups = []
for (tool_name, norm_err), items in by_group.items():
    items.sort(key=lambda x: x.get("start_time") or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    most_recent = items[0]
    recent_count = sum(1 for x in items if x.get("is_recent"))
    groups.append(
        {
            "tool": tool_name,
            "norm": norm_err,
            "count": len(items),
            "recent_count": recent_count,
            "last_seen": most_recent.get("start_time_iso"),
            "run_id": (most_recent.get("id") or "")[:8] or "unknown",
            "error": most_recent.get("error") or "",
            "inputs_preview": most_recent.get("inputs_preview") or "",
        }
    )

groups.sort(key=lambda g: (g.get("recent_count", 0) > 0, g.get("count", 0)), reverse=True)
groups = groups[:MAX_GROUPS]

lines = []
lines.append("# Learnings from recent tool failures (LangSmith)\n")
lines.append(f"Repo: {github_project} | Folder: {folder_name}\n")
lines.append("Actionable reminders derived from tool-call failures in recent Claude Code runs.\n")
lines.append("\n## Top recurring failures\n")

for g in groups:
    tool = g.get("tool") or "tool"
    count = g.get("count", 0)
    last_seen = g.get("last_seen") or "unknown"
    rid = g.get("run_id") or "unknown"
    err = _truncate(g.get("error") or "", MAX_ERROR_CHARS)
    hint = _hint(tool, err)

    lines.append(f"- {tool} • {count}× • last_seen={last_seen} • run_id={rid}")
    lines.append(f"  Error: {err}")

    if g.get("inputs_preview"):
        lines.append(f"  Inputs: {_truncate(g.get('inputs_preview') or '', MAX_INPUT_CHARS)}")

    if hint:
        lines.append(f"  Try: {hint}")

    lines.append("")

out = "\n".join(lines).strip() + "\n"

# Hard cap total output to avoid flooding the SessionStart context.
out = _truncate(out, MAX_TOTAL_CHARS)

print(out)
PY
)

    export CC_LANGSMITH_API_KEY="$API_KEY"
    export CC_LANGSMITH_PROJECT="$PROJECT"
    export GITHUB_PROJECT="$GITHUB_PROJECT"
    export FOLDER_NAME="$FOLDER_NAME"

    echo "$python_script" | python3
}

# Compute once; print to SessionStart context and also save for inspection.
LANGSMITH_CONTEXT=""
if ! LANGSMITH_CONTEXT="$(query_langsmith_tool_errors 2>>"$LOG_FILE")"; then
    log "ERROR" "LangSmith context query failed; see stderr above"
fi

if [ -z "$LANGSMITH_CONTEXT" ]; then
    log "INFO" "LangSmith context query returned no recent tool failures for repo=$GITHUB_PROJECT folder=$FOLDER_NAME"
else
    echo "$LANGSMITH_CONTEXT"

    OUT_DIR="$PROJECT_DIR/.claude"
    mkdir -p "$OUT_DIR" 2>/dev/null || true
    printf "%s" "$LANGSMITH_CONTEXT" > "$OUT_DIR/context_from_langsmith.md" 2>/dev/null || true
    log "INFO" "Saved LangSmith context to $OUT_DIR/context_from_langsmith.md (chars=${#LANGSMITH_CONTEXT})"
fi

exit 0
