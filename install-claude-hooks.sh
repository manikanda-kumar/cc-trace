#!/bin/bash
set -e

# Installs Claude hooks + a simple env file under ~/.claude
# Safe defaults: does not overwrite existing files unless --force.

FORCE=false
if [ "${1:-}" = "--force" ]; then
  FORCE=true
fi

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
ENV_FILE="$CLAUDE_DIR/hooks/env"

mkdir -p "$HOOKS_DIR"

copy_if_needed() {
  local src="$1"
  local dst="$2"

  if [ -f "$dst" ] && [ "$FORCE" != "true" ]; then
    echo "[skip] $dst exists (use --force to overwrite)"
    return 0
  fi

  cp "$src" "$dst"
  chmod +x "$dst" || true
  echo "[ok] installed $dst"
}

# Copy hooks
copy_if_needed "./start_hook.sh" "$HOOKS_DIR/start_hook.sh"
copy_if_needed "./stop_hook.sh" "$HOOKS_DIR/stop_hook.sh"

# Create env file if missing
if [ -f "$ENV_FILE" ] && [ "$FORCE" != "true" ]; then
  echo "[skip] $ENV_FILE exists"
else
  cat > "$ENV_FILE" <<'EOF'
# Claude hooks env (sourced by start_hook.sh + stop_hook.sh)

# Enable/disable LangSmith tracing
TRACE_TO_LANGSMITH=true

# LangSmith auth
# Prefer CC_LANGSMITH_API_KEY, fallback to LANGSMITH_API_KEY
CC_LANGSMITH_API_KEY=
CC_LANGSMITH_PROJECT=claude-code

# Optional debug logging
CC_LANGSMITH_DEBUG=false

# Optional output size controls for SessionStart injected context
CC_LANGSMITH_MAX_GROUPS=6
CC_LANGSMITH_MAX_ERROR_CHARS=280
CC_LANGSMITH_MAX_INPUT_CHARS=180
CC_LANGSMITH_MAX_TOTAL_CHARS=3500
CC_LANGSMITH_MAX_RUNS=200
EOF
  chmod 600 "$ENV_FILE" || true
  echo "[ok] wrote $ENV_FILE"
fi

echo ""
echo "Next: ensure Claude config points to hooks:"
echo "- SessionStart: bash ~/.claude/hooks/start_hook.sh"
echo "- Stop:        bash ~/.claude/hooks/stop_hook.sh"
