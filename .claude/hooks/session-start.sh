#!/bin/bash
# SessionStart hook: install and start Paperclip (https://github.com/paperclipai/paperclip)
# in Claude Code cloud sessions. Idempotent and non-interactive.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Archify skill (.claude/skills/archify): point its browser-check gate at the
# preinstalled Playwright Chromium.
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -x /opt/pw-browsers/chromium ]; then
  echo 'export ARCHIFY_CHROME=/opt/pw-browsers/chromium' >> "$CLAUDE_ENV_FILE"
fi

NODE_PREFIX=/opt/node24
NODE_VERSION="${PAPERCLIP_NODE_VERSION:-24}"
PAPERCLIP_VERSION="${PAPERCLIP_VERSION:-latest}"
PAPERCLIP_PORT=3100
PAPERCLIP_LOG=/root/.paperclip/run.log
DB_NAME=paperclip
DB_USER=paperclip
DB_PASS=paperclip
DATABASE_URL="postgres://${DB_USER}:${DB_PASS}@127.0.0.1:5432/${DB_NAME}"

log() { echo "[paperclip-setup] $*" >&2; }

# 1. Node >= 24.11 in its own prefix (system Node is older; don't overwrite it).
if [ ! -x "$NODE_PREFIX/node_modules/.bin/node" ]; then
  log "installing node@${NODE_VERSION} into ${NODE_PREFIX}"
  mkdir -p "$NODE_PREFIX"
  npm install --prefix "$NODE_PREFIX" --no-audit --no-fund "node@${NODE_VERSION}" >&2
fi
export PATH="$NODE_PREFIX/bin:$NODE_PREFIX/node_modules/.bin:$PATH"

# 2. Paperclip CLI.
if ! command -v paperclipai >/dev/null 2>&1; then
  log "installing paperclipai@${PAPERCLIP_VERSION}"
  npm install -g --prefix "$NODE_PREFIX" --no-audit --no-fund "paperclipai@${PAPERCLIP_VERSION}" >&2
fi

# 3. System PostgreSQL (embedded Postgres refuses to run as root).
if ! pg_isready -q -h 127.0.0.1 -p 5432 2>/dev/null; then
  log "starting postgresql"
  service postgresql start >&2
  for _ in $(seq 1 30); do pg_isready -q -h 127.0.0.1 -p 5432 && break; sleep 1; done
fi
psql_admin() { su postgres -c "psql -tAq -v ON_ERROR_STOP=1 -c \"$1\""; }
if [ -z "$(psql_admin "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'")" ]; then
  psql_admin "CREATE ROLE ${DB_USER} LOGIN PASSWORD '${DB_PASS}';"
fi
if [ -z "$(psql_admin "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'")" ]; then
  psql_admin "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
fi

# 4. Persist env for the session's shells.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"$NODE_PREFIX/bin:$NODE_PREFIX/node_modules/.bin:\$PATH\""
    echo "export DATABASE_URL=\"$DATABASE_URL\""
  } >> "$CLAUDE_ENV_FILE"
fi
export DATABASE_URL

# 5. Start the server (onboard on first run, which writes config then starts it).
if curl -sf -o /dev/null "http://127.0.0.1:${PAPERCLIP_PORT}/api/health"; then
  log "server already running on :${PAPERCLIP_PORT}"
  exit 0
fi
mkdir -p "$(dirname "$PAPERCLIP_LOG")"
if [ -f /root/.paperclip/instances/default/config.json ]; then
  log "starting paperclip server"
  setsid nohup paperclipai run >>"$PAPERCLIP_LOG" 2>&1 < /dev/null &
else
  log "onboarding and starting paperclip server"
  setsid nohup paperclipai onboard --yes --no-install-service >>"$PAPERCLIP_LOG" 2>&1 < /dev/null &
fi

for _ in $(seq 1 90); do
  if curl -sf -o /dev/null "http://127.0.0.1:${PAPERCLIP_PORT}/api/health"; then
    log "ready: http://127.0.0.1:${PAPERCLIP_PORT} (log: ${PAPERCLIP_LOG})"
    exit 0
  fi
  sleep 2
done
log "server did not become healthy; last log lines:"
tail -n 30 "$PAPERCLIP_LOG" >&2
exit 1
