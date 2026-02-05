#!/bin/bash
# get-balance.sh - Read vault share balance for a given address
# Reads balanceOf, convertToAssets on that balance, and maxWithdraw.
# Usage: get-balance.sh <address>

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

# ── Input validation ─────────────────────────────────────────────────
ADDRESS="${1:-}"
if [[ -z "$ADDRESS" ]]; then
  echo '{"error":"Usage: get-balance.sh <address>"}' | jq .
  exit 1
fi

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

pad_address() {
  # Strip 0x prefix and left-pad to 64 hex chars (32 bytes)
  local addr="$1"
  addr="${addr#0x}"
  addr=$(echo "$addr" | tr '[:upper:]' '[:lower:]')
  printf "%064s" "$addr" | tr ' ' '0'
}

# ── Main ──────────────────────────────────────────────────────────────

ADDR_PADDED=$(pad_address "$ADDRESS")

# balanceOf(address) — selector 0x70a08231
BALANCE_DATA="0x70a08231${ADDR_PADDED}"
balance_hex=$(rpc_call "$VAULT" "$BALANCE_DATA") || exit 1

balance_dec=$(hex_to_dec "$balance_hex")

if [[ -z "$balance_dec" ]]; then
  echo '{"error":"balanceOf call failed"}' | jq .
  exit 1
fi

# convertToAssets(shares) — selector 0x07a2d13a
# Only call if balance > 0 (some vaults revert on convertToAssets(0))
asset_value_dec="0"
if [[ "$balance_dec" != "0" ]]; then
  balance_hex_raw=$(python -c "print(hex(int('$balance_dec'))[2:])")
  balance_padded=$(printf "%064s" "$balance_hex_raw" | tr ' ' '0')
  CONVERT_DATA="0x07a2d13a${balance_padded}"
  convert_hex=$(rpc_call "$VAULT" "$CONVERT_DATA" 2>/dev/null) || convert_hex=""
  if [[ -n "$convert_hex" && "$convert_hex" != "null" ]]; then
    asset_value_dec=$(hex_to_dec "$convert_hex")
  fi
fi

# maxWithdraw(address) — selector 0xce96cb77 (may revert)
MAX_WITHDRAW_DATA="0xce96cb77${ADDR_PADDED}"
max_withdraw_hex=$(rpc_call "$VAULT" "$MAX_WITHDRAW_DATA" 2>/dev/null) || max_withdraw_hex=""
max_withdraw_dec="0"
if [[ -n "$max_withdraw_hex" && "$max_withdraw_hex" != "null" ]]; then
  max_withdraw_dec=$(hex_to_dec "$max_withdraw_hex")
fi

# Format values (vault shares use 18 decimals, USDC uses 6)
read -r shares_fmt asset_fmt max_fmt <<< "$(python -c "
shares = int('$balance_dec')
asset_val = int('${asset_value_dec:-0}')
max_w = int('${max_withdraw_dec:-0}')
print(f'{shares / 1e6:.6f} {asset_val / 1e6:.6f} {max_w / 1e6:.6f}')
")"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --arg address "$ADDRESS" \
  --arg shares "$shares_fmt" \
  --arg sharesRaw "$balance_dec" \
  --arg assetValue "$asset_fmt" \
  --arg assetValueRaw "${asset_value_dec:-0}" \
  --arg maxWithdraw "$max_fmt" \
  --arg maxWithdrawRaw "${max_withdraw_dec:-0}" \
  --arg unit "USDC" \
  --arg timestamp "$TIMESTAMP" \
  '{
    address: $address,
    shares: $shares,
    sharesRaw: $sharesRaw,
    assetValue: $assetValue,
    assetValueRaw: $assetValueRaw,
    maxWithdraw: $maxWithdraw,
    maxWithdrawRaw: $maxWithdrawRaw,
    unit: $unit,
    timestamp: $timestamp
  }'
