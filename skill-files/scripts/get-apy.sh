#!/bin/bash
# get-apy.sh - Calculate APY for the YieldClaw ERC-4626 vault
# Reads convertToAssets(1e18), totalAssets, totalSupply from the vault
# and computes a simplified APY estimate.

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
  # Remove leading zeros but keep at least one digit
  raw="$(echo "$raw" | sed 's/^0*//' )"
  raw="${raw:-0}"
  python -c "print(int('$raw', 16))" 2>/dev/null
}

# ── Main ──────────────────────────────────────────────────────────────

# convertToAssets(1e18) — selector 0x07a2d13a
# param: 1e18 = 0x0de0b6b3a7640000 padded to 32 bytes
CONVERT_DATA="0x07a2d13a0000000000000000000000000000000000000000000000000de0b6b3a7640000"
convert_hex=$(rpc_call "$VAULT" "$CONVERT_DATA") || exit 1

# totalAssets() — selector 0x01e1d114
TOTAL_ASSETS_DATA="0x01e1d114"
total_assets_hex=$(rpc_call "$VAULT" "$TOTAL_ASSETS_DATA") || exit 1

# totalSupply() — selector 0x18160ddd
TOTAL_SUPPLY_DATA="0x18160ddd"
total_supply_hex=$(rpc_call "$VAULT" "$TOTAL_SUPPLY_DATA") || exit 1

# Convert results
convert_dec=$(hex_to_dec "$convert_hex")
total_assets_dec=$(hex_to_dec "$total_assets_hex")
total_supply_dec=$(hex_to_dec "$total_supply_hex")

if [[ -z "$convert_dec" || "$convert_dec" == "0" ]]; then
  echo '{"error":"convertToAssets returned zero or failed"}' | jq .
  exit 1
fi

# Compute share price and APY via python for precision
read -r share_price apy_pct <<< "$(python -c "
cv = int('$convert_dec')
# share price = convertToAssets(1e18) / 1e18
sp = cv / 1e18
# simplified APY = (sharePrice - 1) * 365.25 * 100
apy = (sp - 1.0) * 365.25 * 100.0
print(f'{sp:.6f} {apy:.2f}')
")"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --arg apy "${apy_pct}%" \
  --arg sharePrice "$share_price" \
  --arg totalAssets "$total_assets_dec" \
  --arg totalSupply "$total_supply_dec" \
  --arg timestamp "$TIMESTAMP" \
  '{
    apy: $apy,
    sharePrice: $sharePrice,
    totalAssets: $totalAssets,
    totalSupply: $totalSupply,
    timestamp: $timestamp
  }'
