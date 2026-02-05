#!/bin/bash
# get-stream.sh - Read a PaymentStream by ID from the PaymentStream contract
# Parses the ABI-encoded result tuple: sender, recipient, token, deposit,
# startTime, stopTime, withdrawn.
# Usage: get-stream.sh <stream_id>

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────
DEFAULT_RPC="https://rpc.testnet.arc.network"
DEFAULT_PAYMENT_STREAM="0x1fcb750413067Ba96Ea80B018b304226AB7365C6"
DEFAULT_CHAIN_ID="5042002"

# ── Config loading ────────────────────────────────────────────────────
CONFIG_FILE="$HOME/.clawdbot/skills/yieldclaw/config.json"

if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
  RPC=$(jq -r '.rpc // empty' "$CONFIG_FILE" 2>/dev/null)
  PAYMENT_STREAM=$(jq -r '.paymentStream // empty' "$CONFIG_FILE" 2>/dev/null)
  CHAIN_ID=$(jq -r '.chainId // empty' "$CONFIG_FILE" 2>/dev/null)
fi

RPC="${RPC:-$DEFAULT_RPC}"
PAYMENT_STREAM="${PAYMENT_STREAM:-$DEFAULT_PAYMENT_STREAM}"
CHAIN_ID="${CHAIN_ID:-$DEFAULT_CHAIN_ID}"

# ── Input validation ─────────────────────────────────────────────────
STREAM_ID="${1:-}"

if [[ -z "$STREAM_ID" ]]; then
  echo '{"error":"Usage: get-stream.sh <stream_id>"}' | jq .
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

pad_uint256() {
  local dec="$1"
  local hex_val
  hex_val=$(python -c "print(hex(int('$dec'))[2:])")
  printf "%064s" "$hex_val" | tr ' ' '0'
}

# ── Main ──────────────────────────────────────────────────────────────

STREAM_ID_PADDED=$(pad_uint256 "$STREAM_ID")

# getStream(uint256 streamId) — selector 0xd5a44f86
STREAM_DATA="0xd5a44f86${STREAM_ID_PADDED}"
result_hex=$(rpc_call "$PAYMENT_STREAM" "$STREAM_DATA" 2>/dev/null) || {
  jq -n --arg id "$STREAM_ID" --arg contract "$PAYMENT_STREAM" --arg chainId "$CHAIN_ID" \
    '{"error":"Stream not found or contract reverted","streamId":$id,"contract":$contract,"chainId":$chainId}'
  exit 1
}

if [[ -z "$result_hex" || "$result_hex" == "null" || ${#result_hex} -lt 450 ]]; then
  jq -n --arg id "$STREAM_ID" --arg contract "$PAYMENT_STREAM" --arg chainId "$CHAIN_ID" \
    '{"error":"Stream not found or invalid response","streamId":$id,"contract":$contract,"chainId":$chainId}'
  exit 1
fi

# Strip 0x prefix
raw="${result_hex#0x}"

# Parse 7 consecutive 32-byte (64 hex char) words
# Word 0: sender (address — last 40 chars)
# Word 1: recipient (address)
# Word 2: token (address)
# Word 3: deposit (uint256)
# Word 4: startTime (uint256)
# Word 5: stopTime (uint256)
# Word 6: withdrawn (uint256)

word() {
  local idx=$1
  local start=$((idx * 64))
  echo "${raw:$start:64}"
}

extract_address() {
  local w="$1"
  # Last 40 hex chars
  echo "0x${w:24:40}"
}

sender=$(extract_address "$(word 0)")
recipient=$(extract_address "$(word 1)")
token=$(extract_address "$(word 2)")
deposit_dec=$(hex_to_dec "$(word 3)")
start_time_dec=$(hex_to_dec "$(word 4)")
stop_time_dec=$(hex_to_dec "$(word 5)")
withdrawn_dec=$(hex_to_dec "$(word 6)")

# Format times as ISO timestamps
start_time_iso=$(python -c "
import datetime
ts = int('$start_time_dec')
if ts > 0:
    print(datetime.datetime.utcfromtimestamp(ts).strftime('%Y-%m-%dT%H:%M:%SZ'))
else:
    print('N/A')
")

stop_time_iso=$(python -c "
import datetime
ts = int('$stop_time_dec')
if ts > 0:
    print(datetime.datetime.utcfromtimestamp(ts).strftime('%Y-%m-%dT%H:%M:%SZ'))
else:
    print('N/A')
")

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --arg streamId "$STREAM_ID" \
  --arg sender "$sender" \
  --arg recipient "$recipient" \
  --arg token "$token" \
  --arg deposit "$deposit_dec" \
  --arg startTime "$start_time_dec" \
  --arg startTimeISO "$start_time_iso" \
  --arg stopTime "$stop_time_dec" \
  --arg stopTimeISO "$stop_time_iso" \
  --arg withdrawn "$withdrawn_dec" \
  --arg contract "$PAYMENT_STREAM" \
  --arg chainId "$CHAIN_ID" \
  --arg timestamp "$TIMESTAMP" \
  '{
    streamId: $streamId,
    sender: $sender,
    recipient: $recipient,
    token: $token,
    deposit: $deposit,
    startTime: $startTime,
    startTimeISO: $startTimeISO,
    stopTime: $stopTime,
    stopTimeISO: $stopTimeISO,
    withdrawn: $withdrawn,
    contract: $contract,
    chainId: $chainId,
    timestamp: $timestamp
  }'
