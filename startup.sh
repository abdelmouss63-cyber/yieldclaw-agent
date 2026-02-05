#!/usr/bin/env bash
set -euo pipefail

# ─── YieldClaw Startup Script ──────────────────────────────────────────────────
# Initializes the OpenClaw agent with skills, env vars, and background services.

log() { echo "[YieldClaw] $(date -u '+%H:%M:%S') $*"; }

# ─── Validate required env vars ────────────────────────────────────────────────
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  log "ERROR: ANTHROPIC_API_KEY is required"
  exit 1
fi

ARC_RPC_URL="${ARC_RPC_URL:-https://rpc.testnet.arc.network}"
VAULT_ADDRESS="${VAULT_ADDRESS:-0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25}"
STREAM_ADDRESS="${STREAM_ADDRESS:-0x1fcb750413067Ba96Ea80B018b304226AB7365C6}"
MOLTBOOK_API_KEY="${MOLTBOOK_API_KEY:-}"

export ARC_RPC_URL VAULT_ADDRESS STREAM_ADDRESS

# ─── Inject env vars into OpenClaw config ──────────────────────────────────────
CONFIG_FILE="${OPENCLAW_STATE_DIR}/openclaw.json"
log "Injecting environment variables into $CONFIG_FILE"

if command -v python3 &>/dev/null; then
  PY=python3
else
  PY=python
fi

$PY - "$CONFIG_FILE" "$ARC_RPC_URL" "$VAULT_ADDRESS" "$STREAM_ADDRESS" <<'PYEOF'
import json, sys
config_path, rpc, vault, stream = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(config_path, 'r') as f:
    config = json.load(f)
yc = config.get('skills', {}).get('entries', {}).get('yieldclaw', {})
if 'env' not in yc:
    yc['env'] = {}
yc['env']['ARC_RPC_URL'] = rpc
yc['env']['VAULT_ADDRESS'] = vault
yc['env']['STREAM_ADDRESS'] = stream
config['skills']['entries']['yieldclaw'] = yc
with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)
PYEOF

log "Config updated: RPC=$ARC_RPC_URL VAULT=$VAULT_ADDRESS"

# ─── Install YieldClaw skill files ────────────────────────────────────────────
SKILL_DIR="/data/workspace/skills/yieldclaw"
log "Installing YieldClaw skill to $SKILL_DIR"

mkdir -p "$SKILL_DIR"
cp -r /home/claw/skill-files/* "$SKILL_DIR/"
chmod +x "$SKILL_DIR/scripts/"*.sh 2>/dev/null || true
chmod +x "$SKILL_DIR/agent/"*.sh 2>/dev/null || true

log "YieldClaw skill installed"

# ─── Download Moltbook skill ──────────────────────────────────────────────────
MOLTBOOK_DIR="/data/workspace/skills/moltbook"
log "Downloading Moltbook skill"

mkdir -p "$MOLTBOOK_DIR"
if curl -sf --max-time 30 "https://moltbook.com/skill.md" -o "$MOLTBOOK_DIR/SKILL.md"; then
  log "Moltbook skill downloaded"
else
  log "WARN: Failed to download Moltbook skill — agent will run without it"
fi

# ─── Configure Moltbook API key if provided ───────────────────────────────────
if [ -n "$MOLTBOOK_API_KEY" ]; then
  log "Configuring Moltbook API key"
  AGENT_CONFIG="$SKILL_DIR/agent/config.json"
  if [ -f "$AGENT_CONFIG" ]; then
    $PY - "$AGENT_CONFIG" "$MOLTBOOK_API_KEY" <<'PYEOF2'
import json, sys
path, key = sys.argv[1], sys.argv[2]
with open(path, 'r') as f:
    cfg = json.load(f)
cfg['moltbook']['apiKey'] = key
with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
PYEOF2
    log "Moltbook API key configured"
  fi
fi

# ─── Install Node dependencies for x402 gateway ──────────────────────────────
if [ -f "$SKILL_DIR/package.json" ]; then
  log "Installing x402 gateway dependencies"
  cd "$SKILL_DIR"
  npm install --production --silent 2>/dev/null || log "WARN: npm install failed"
  cd /home/claw
fi

# ─── Start x402 gateway in background ────────────────────────────────────────
X402_SERVER="$SKILL_DIR/x402/server.js"
if [ -f "$X402_SERVER" ]; then
  log "Starting x402 gateway on port 3402"
  node "$X402_SERVER" &
  X402_PID=$!
  log "x402 gateway started (PID: $X402_PID)"
fi

# ─── Verify connectivity ─────────────────────────────────────────────────────
log "Verifying Arc testnet connectivity..."
BLOCK=$(curl -sf --max-time 10 -X POST "$ARC_RPC_URL" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  | jq -r '.result' 2>/dev/null || echo "")

if [ -n "$BLOCK" ]; then
  log "Arc testnet connected — block: $BLOCK"
else
  log "WARN: Could not reach Arc testnet at $ARC_RPC_URL"
fi

# ─── Start OpenClaw agent ────────────────────────────────────────────────────
log "Starting OpenClaw agent..."
log "Workspace: ${OPENCLAW_WORKSPACE_DIR}"
log "State dir: ${OPENCLAW_STATE_DIR}"

exec openclaw start \
  --workspace "${OPENCLAW_WORKSPACE_DIR}" \
  --port "${PORT:-8080}"
