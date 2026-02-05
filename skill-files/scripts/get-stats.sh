#!/bin/bash
# get-stats.sh - Read combined vault statistics
# Calls totalAssets, totalSupply, convertToAssets(1e18), maxDeposit(address(0)), asset()

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

hex_to_address() {
  # Extract last 40 hex chars from a 32-byte word and prefix with 0x
  local raw="$1"
  raw="${raw#0x}"
  raw="$(echo "$raw" | sed 's/^0*//' )"
  raw="${raw:-0}"
  printf "0x%s" "$raw"
}

# ── Main ──────────────────────────────────────────────────────────────

# totalAssets() — 0x01e1d114
total_assets_hex=$(rpc_call "$VAULT" "0x01e1d114") || exit 1
total_assets_dec=$(hex_to_dec "$total_assets_hex")

# totalSupply() — 0x18160ddd
total_supply_hex=$(rpc_call "$VAULT" "0x18160ddd") || exit 1
total_supply_dec=$(hex_to_dec "$total_supply_hex")

# convertToAssets(1e18) — 0x07a2d13a + 1e18 padded
CONVERT_DATA="0x07a2d13a0000000000000000000000000000000000000000000000000de0b6b3a7640000"
convert_hex=$(rpc_call "$VAULT" "$CONVERT_DATA") || exit 1
convert_dec=$(hex_to_dec "$convert_hex")

# maxDeposit(address(0)) — 0x402d267d + zero address padded (optional, may revert)
MAX_DEPOSIT_DATA="0x402d267d0000000000000000000000000000000000000000000000000000000000000000"
max_deposit_hex=$(rpc_call "$VAULT" "$MAX_DEPOSIT_DATA" 2>/dev/null) || max_deposit_hex=""
if [[ -n "$max_deposit_hex" && "$max_deposit_hex" != "null" ]]; then
  max_deposit_dec=$(hex_to_dec "$max_deposit_hex")
else
  max_deposit_dec="0"
fi

# asset() — 0x38d52e0f (optional, may revert on some vaults)
asset_hex=$(rpc_call "$VAULT" "0x38d52e0f" 2>/dev/null) || asset_hex=""
if [[ -n "$asset_hex" && "$asset_hex" != "null" ]]; then
  asset_address=$(hex_to_address "$asset_hex")
else
  asset_address="unknown"
fi

# Compute derived values
read -r share_price tvl_usdc total_supply_fmt max_deposit_fmt <<< "$(python -c "
ta = int('$total_assets_dec')
ts = int('$total_supply_dec')
cv = int('$convert_dec')
md = int('$max_deposit_dec')
sp = cv / 1e18
tvl = ta / 1e6
ts_fmt = ts / 1e6
md_fmt = md / 1e6
print(f'{sp:.6f} {tvl:.2f} {ts_fmt:.6f} {md_fmt:.2f}')
")"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

jq -n \
  --arg totalAssets "$tvl_usdc" \
  --arg totalAssetsRaw "$total_assets_dec" \
  --arg totalSupply "$total_supply_fmt" \
  --arg totalSupplyRaw "$total_supply_dec" \
  --arg sharePrice "$share_price" \
  --arg convertToAssetsRaw "$convert_dec" \
  --arg maxDeposit "$max_deposit_fmt" \
  --arg maxDepositRaw "$max_deposit_dec" \
  --arg asset "$asset_address" \
  --arg vault "$VAULT" \
  --arg chainId "$CHAIN_ID" \
  --arg timestamp "$TIMESTAMP" \
  '{
    vault: $vault,
    asset: $asset,
    chainId: $chainId,
    totalAssets: $totalAssets,
    totalAssetsRaw: $totalAssetsRaw,
    totalSupply: $totalSupply,
    totalSupplyRaw: $totalSupplyRaw,
    sharePrice: $sharePrice,
    convertToAssetsRaw: $convertToAssetsRaw,
    maxDeposit: $maxDeposit,
    maxDepositRaw: $maxDepositRaw,
    timestamp: $timestamp
  }'
