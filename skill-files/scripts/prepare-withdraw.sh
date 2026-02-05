#!/bin/bash
# prepare-withdraw.sh - Prepare calldata for a vault withdrawal (READ-ONLY, never executes)
# Outputs JSON calldata for vault withdraw. Also queries previewWithdraw and maxWithdraw.
# Usage: prepare-withdraw.sh <amount_raw> <receiver_address>

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
AMOUNT="${1:-}"
RECEIVER="${2:-}"

if [[ -z "$AMOUNT" || -z "$RECEIVER" ]]; then
  echo '{"error":"Usage: prepare-withdraw.sh <amount_raw> <receiver_address>"}' | jq .
  exit 1
fi

# Owner is same as receiver
OWNER="$RECEIVER"

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
  local addr="$1"
  addr="${addr#0x}"
  addr=$(echo "$addr" | tr '[:upper:]' '[:lower:]')
  printf "%064s" "$addr" | tr ' ' '0'
}

pad_uint256() {
  local dec="$1"
  local hex_val
  hex_val=$(python -c "print(hex(int('$dec'))[2:])")
  printf "%064s" "$hex_val" | tr ' ' '0'
}

# ── Main ──────────────────────────────────────────────────────────────

RECEIVER_PADDED=$(pad_address "$RECEIVER")
OWNER_PADDED=$(pad_address "$OWNER")
AMOUNT_PADDED=$(pad_uint256 "$AMOUNT")

# ── Build withdraw calldata ───────────────────────────────────────────
# withdraw(uint256 assets, address receiver, address owner) — selector 0xb460af94
WITHDRAW_CALLDATA="0xb460af94${AMOUNT_PADDED}${RECEIVER_PADDED}${OWNER_PADDED}"

# ── previewWithdraw (read-only query) ─────────────────────────────────
# previewWithdraw(uint256 assets) — selector 0x0a28a477
PREVIEW_DATA="0x0a28a477${AMOUNT_PADDED}"
preview_hex=$(rpc_call "$VAULT" "$PREVIEW_DATA" 2>/dev/null) || preview_hex=""

preview_shares_dec="0"
preview_shares_fmt="0.000000"
if [[ -n "$preview_hex" && "$preview_hex" != "null" ]]; then
  preview_shares_dec=$(hex_to_dec "$preview_hex")
  preview_shares_fmt=$(python -c "print(f'{int(\"$preview_shares_dec\") / 1e18:.6f}')")
fi

# ── maxWithdraw (read-only query) ─────────────────────────────────────
# maxWithdraw(address owner) — selector 0xce96cb77
MAX_WITHDRAW_DATA="0xce96cb77${OWNER_PADDED}"
max_withdraw_hex=$(rpc_call "$VAULT" "$MAX_WITHDRAW_DATA" 2>/dev/null) || max_withdraw_hex=""

max_withdraw_dec="0"
max_withdraw_fmt="0.00"
if [[ -n "$max_withdraw_hex" && "$max_withdraw_hex" != "null" ]]; then
  max_withdraw_dec=$(hex_to_dec "$max_withdraw_hex")
  max_withdraw_fmt=$(python -c "print(f'{int(\"$max_withdraw_dec\") / 1e6:.2f}')")
fi

amount_usdc=$(python -c "print(f'{int(\"$AMOUNT\") / 1e6:.2f}')")

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --arg amountRaw "$AMOUNT" \
  --arg amountUSDC "$amount_usdc" \
  --arg receiver "$RECEIVER" \
  --arg owner "$OWNER" \
  --arg sharesRequired "$preview_shares_fmt" \
  --arg sharesRequiredRaw "$preview_shares_dec" \
  --arg maxWithdraw "$max_withdraw_fmt" \
  --arg maxWithdrawRaw "$max_withdraw_dec" \
  --arg withdrawTo "$VAULT" \
  --arg withdrawCalldata "$WITHDRAW_CALLDATA" \
  --arg chainId "$CHAIN_ID" \
  --arg timestamp "$TIMESTAMP" \
  '{
    description: "Withdraw calldata (NOT executed, read-only preparation)",
    amount: $amountUSDC,
    amountRaw: $amountRaw,
    unit: "USDC",
    receiver: $receiver,
    owner: $owner,
    sharesRequired: $sharesRequired,
    sharesRequiredRaw: $sharesRequiredRaw,
    maxWithdraw: $maxWithdraw,
    maxWithdrawRaw: $maxWithdrawRaw,
    transaction: {
      action: "withdraw from vault",
      to: $withdrawTo,
      data: $withdrawCalldata,
      value: "0x0"
    },
    chainId: $chainId,
    timestamp: $timestamp
  }'
