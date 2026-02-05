#!/bin/bash
# prepare-deposit.sh - Prepare calldata for a vault deposit (READ-ONLY, never executes)
# Outputs two calldata objects: USDC approve + vault deposit
# Also calls previewDeposit to show expected shares.
# Usage: prepare-deposit.sh <amount_raw> <receiver_address>

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────
DEFAULT_RPC="https://rpc.testnet.arc.network"
DEFAULT_VAULT="0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25"
DEFAULT_USDC="0x3600000000000000000000000000000000000000"
DEFAULT_CHAIN_ID="5042002"

# ── Config loading ────────────────────────────────────────────────────
CONFIG_FILE="$HOME/.clawdbot/skills/yieldclaw/config.json"

if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
  RPC=$(jq -r '.rpc // empty' "$CONFIG_FILE" 2>/dev/null)
  VAULT=$(jq -r '.vault // empty' "$CONFIG_FILE" 2>/dev/null)
  USDC=$(jq -r '.usdc // empty' "$CONFIG_FILE" 2>/dev/null)
  CHAIN_ID=$(jq -r '.chainId // empty' "$CONFIG_FILE" 2>/dev/null)
fi

RPC="${RPC:-$DEFAULT_RPC}"
VAULT="${VAULT:-$DEFAULT_VAULT}"
USDC="${USDC:-$DEFAULT_USDC}"
CHAIN_ID="${CHAIN_ID:-$DEFAULT_CHAIN_ID}"

# ── Input validation ─────────────────────────────────────────────────
AMOUNT="${1:-}"
RECEIVER="${2:-}"

if [[ -z "$AMOUNT" || -z "$RECEIVER" ]]; then
  echo '{"error":"Usage: prepare-deposit.sh <amount_raw> <receiver_address>"}' | jq .
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
  local addr="$1"
  addr="${addr#0x}"
  addr=$(echo "$addr" | tr '[:upper:]' '[:lower:]')
  printf "%064s" "$addr" | tr ' ' '0'
}

pad_uint256() {
  # Convert decimal to hex and pad to 64 hex chars
  local dec="$1"
  local hex_val
  hex_val=$(python -c "print(hex(int('$dec'))[2:])")
  printf "%064s" "$hex_val" | tr ' ' '0'
}

# ── Main ──────────────────────────────────────────────────────────────

VAULT_PADDED=$(pad_address "$VAULT")
RECEIVER_PADDED=$(pad_address "$RECEIVER")
AMOUNT_PADDED=$(pad_uint256 "$AMOUNT")

# ── Build approve calldata ────────────────────────────────────────────
# approve(address spender, uint256 amount) — selector 0x095ea7b3
APPROVE_CALLDATA="0x095ea7b3${VAULT_PADDED}${AMOUNT_PADDED}"

# ── Build deposit calldata ────────────────────────────────────────────
# deposit(uint256 assets, address receiver) — selector 0x6e553f65
DEPOSIT_CALLDATA="0x6e553f65${AMOUNT_PADDED}${RECEIVER_PADDED}"

# ── Preview deposit (read-only query) ─────────────────────────────────
# previewDeposit(uint256 assets) — selector 0xef8b30f7
PREVIEW_DATA="0xef8b30f7${AMOUNT_PADDED}"
preview_hex=$(rpc_call "$VAULT" "$PREVIEW_DATA") || preview_hex=""

preview_shares_dec="0"
preview_shares_fmt="0.000000"
if [[ -n "$preview_hex" && "$preview_hex" != "null" ]]; then
  preview_shares_dec=$(hex_to_dec "$preview_hex")
  preview_shares_fmt=$(python -c "print(f'{int(\"$preview_shares_dec\") / 1e18:.6f}')")
fi

amount_usdc=$(python -c "print(f'{int(\"$AMOUNT\") / 1e6:.2f}')")

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --arg amountRaw "$AMOUNT" \
  --arg amountUSDC "$amount_usdc" \
  --arg receiver "$RECEIVER" \
  --arg expectedShares "$preview_shares_fmt" \
  --arg expectedSharesRaw "$preview_shares_dec" \
  --arg approveTo "$USDC" \
  --arg approveCalldata "$APPROVE_CALLDATA" \
  --arg depositTo "$VAULT" \
  --arg depositCalldata "$DEPOSIT_CALLDATA" \
  --arg chainId "$CHAIN_ID" \
  --arg timestamp "$TIMESTAMP" \
  '{
    description: "Deposit calldata (NOT executed, read-only preparation)",
    amount: $amountUSDC,
    amountRaw: $amountRaw,
    unit: "USDC",
    receiver: $receiver,
    expectedShares: $expectedShares,
    expectedSharesRaw: $expectedSharesRaw,
    transactions: [
      {
        step: 1,
        action: "approve USDC spending",
        to: $approveTo,
        data: $approveCalldata,
        value: "0x0"
      },
      {
        step: 2,
        action: "deposit into vault",
        to: $depositTo,
        data: $depositCalldata,
        value: "0x0"
      }
    ],
    chainId: $chainId,
    timestamp: $timestamp
  }'
