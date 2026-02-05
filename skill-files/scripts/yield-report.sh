#!/bin/bash
# yield-report.sh - Generate a human-readable yield report
# Calls get-apy.sh, get-tvl.sh, get-stats.sh and formats the results.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Collect data ──────────────────────────────────────────────────────
apy_json=$("$SCRIPT_DIR/get-apy.sh" 2>/dev/null) || apy_json='{"error":"failed"}'
tvl_json=$("$SCRIPT_DIR/get-tvl.sh" 2>/dev/null) || tvl_json='{"error":"failed"}'
stats_json=$("$SCRIPT_DIR/get-stats.sh" 2>/dev/null) || stats_json='{"error":"failed"}'

# ── Extract values ────────────────────────────────────────────────────
apy=$(echo "$apy_json" | jq -r '.apy // "N/A"')
share_price=$(echo "$apy_json" | jq -r '.sharePrice // "N/A"')
tvl=$(echo "$tvl_json" | jq -r '.tvl // "N/A"')
tvl_unit=$(echo "$tvl_json" | jq -r '.unit // "USDC"')
total_assets=$(echo "$stats_json" | jq -r '.totalAssets // "N/A"')
total_supply=$(echo "$stats_json" | jq -r '.totalSupply // "N/A"')
max_deposit=$(echo "$stats_json" | jq -r '.maxDeposit // "N/A"')
asset_addr=$(echo "$stats_json" | jq -r '.asset // "N/A"')
vault_addr=$(echo "$stats_json" | jq -r '.vault // "N/A"')
chain_id=$(echo "$stats_json" | jq -r '.chainId // "N/A"')
timestamp=$(echo "$stats_json" | jq -r '.timestamp // "N/A"')

# ── Print report ──────────────────────────────────────────────────────
cat <<REPORT

━━━ YieldClaw Report ━━━

  Vault:          $vault_addr
  Asset (USDC):   $asset_addr
  Chain ID:       $chain_id
  Timestamp:      $timestamp

  APY:            $apy
  Share Price:    $share_price

  TVL:            $tvl $tvl_unit
  Total Assets:   $total_assets $tvl_unit
  Total Supply:   $total_supply shares
  Max Deposit:    $max_deposit $tvl_unit

━━━━━━━━━━━━━━━━━━━━━━━━

REPORT
