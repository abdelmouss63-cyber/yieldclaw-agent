#!/bin/bash
# get-tvl.sh - Read total value locked (TVL) from the YieldClaw vault
# Calls totalAssets() and converts to USDC (6 decimals).

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────
DEFAULT_RPC="https://rpc.testnet.arc.network"
DEFAULT_VAULT="0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25"
DEFAULT_CHAIN_ID="5042002"

# ── Config loading ────────────────────────────────────────────────────
CONFIG_FILE="$HOME/.clawdbot/skills/yieldclaw/config.json"

if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
  RPC=$(jq -r '.rpc // empty' "$CONFIG_FILE" 2>/dev/null)
  VAULT=$(jq -r '.vault // empty' "$CONFIG_FILE" 2>/dev/null)
  CHAIN_ID=$(jq -r '.chainId // empty' "$CONFIG_FILE" 2>/dev/null)
fi

RPC="${RPC:-$DEFAULT_RPC}"
VAULT="${VAULT:-$DEFAULT_VAULT}"
CHAIN_ID="${CHAIN_ID:-$DEFAULT_CHAIN_ID}"

# ── Helpers ───────────────────────────────────────────────────────────
rpc_call() {
  local to="$1"
  local data="$2"
  local payload
  payload=$(cat <<JSONEOF
{"jsonrpc":"2.0","id":1,"method":"eth_call","params":[{"to":"${to}","data":"${data}"},"latest"]}
JSONEOF
  )
  local result
  result=$(curl -sf -X POST "$RPC" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null)
  if [[ $? -ne 0 || -z "$result" ]]; then
    echo "error: RPC request failed" >&2
    return 1
  fi
  local err
  err=$(echo "$result" | jq -r '.error.message // empty' 2>/dev/null)
  if [[ -n "$err" ]]; then
    echo "error: RPC returned error: $err" >&2
    return 1
  fi
  echo "$result" | jq -r '.result // empty'
}

hex_to_dec() {
  local raw="$1"
  raw="${raw#0x}"
  raw="$(echo "$raw" | sed 's/^0*//' )"
  raw="${raw:-0}"
  python -c "print(int('$raw', 16))" 2>/dev/null
}

# ── Main ──────────────────────────────────────────────────────────────

# totalAssets() — selector 0x01e1d114
TOTAL_ASSETS_DATA="0x01e1d114"
total_assets_hex=$(rpc_call "$VAULT" "$TOTAL_ASSETS_DATA") || exit 1

total_assets_raw=$(hex_to_dec "$total_assets_hex")

if [[ -z "$total_assets_raw" ]]; then
  echo '{"error":"totalAssets call failed"}' | jq .
  exit 1
fi

# Convert to USDC (6 decimals)
tvl_formatted=$(python -c "
raw = int('$total_assets_raw')
print(f'{raw / 1e6:.2f}')
")

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --arg tvl "$tvl_formatted" \
  --arg tvlRaw "$total_assets_raw" \
  --arg unit "USDC" \
  --arg timestamp "$TIMESTAMP" \
  '{
    tvl: $tvl,
    tvlRaw: $tvlRaw,
    unit: $unit,
    timestamp: $timestamp
  }'
