#!/bin/bash
# yield-query.sh - Main entry point for YieldClaw queries
# Takes a natural language query and routes to the appropriate script.
# Usage: yield-query.sh "<query>"
# Examples:
#   yield-query.sh "apy"
#   yield-query.sh "tvl"
#   yield-query.sh "balance 0xABC..."
#   yield-query.sh "deposit 1000000 0xABC..."
#   yield-query.sh "withdraw 500000 0xABC..."
#   yield-query.sh "stream 42"
#   yield-query.sh "stats"
#   yield-query.sh "report"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

QUERY="${1:-}"

if [[ -z "$QUERY" ]]; then
  cat <<HELP
━━━ YieldClaw Query Interface ━━━

Usage: yield-query.sh "<query>"

Commands:
  apy                           Show current APY and share price
  tvl                           Show total value locked
  stats                         Show combined vault statistics
  report                        Show full human-readable yield report
  balance <address>             Show vault balance for an address
  deposit <amount> <receiver>   Prepare deposit calldata (read-only)
  withdraw <amount> <receiver>  Prepare withdraw calldata (read-only)
  stream <id>                   Show payment stream details

Examples:
  yield-query.sh "apy"
  yield-query.sh "tvl"
  yield-query.sh "balance 0x1234...abcd"
  yield-query.sh "deposit 1000000 0x1234...abcd"
  yield-query.sh "withdraw 500000 0x1234...abcd"
  yield-query.sh "stream 1"
  yield-query.sh "report"

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
HELP
  exit 0
fi

# Normalize query to lowercase for matching
query_lower=$(echo "$QUERY" | tr '[:upper:]' '[:lower:]')

# ── Route to the appropriate script ───────────────────────────────────

# APY
if [[ "$query_lower" =~ ^(apy|yield|rate|interest) ]]; then
  exec "$SCRIPT_DIR/get-apy.sh"
fi

# TVL
if [[ "$query_lower" =~ ^(tvl|total.?value|locked|assets) ]]; then
  exec "$SCRIPT_DIR/get-tvl.sh"
fi

# Stats
if [[ "$query_lower" =~ ^(stats|statistics|info|status) ]]; then
  exec "$SCRIPT_DIR/get-stats.sh"
fi

# Report
if [[ "$query_lower" =~ ^(report|summary|overview|dashboard) ]]; then
  exec "$SCRIPT_DIR/yield-report.sh"
fi

# Balance — expects: balance <address>
if [[ "$query_lower" =~ ^(balance|bal|shares) ]]; then
  # Extract address (first 0x-prefixed token after the command word)
  ADDRESS=$(echo "$QUERY" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)
  if [[ -z "$ADDRESS" ]]; then
    echo '{"error":"balance command requires an address. Usage: balance <0x address>"}' | jq .
    exit 1
  fi
  exec "$SCRIPT_DIR/get-balance.sh" "$ADDRESS"
fi

# Deposit — expects: deposit <amount> <receiver>
if [[ "$query_lower" =~ ^(deposit|prepare.?deposit) ]]; then
  AMOUNT=$(echo "$QUERY" | grep -oE '[0-9]+' | head -1)
  ADDRESS=$(echo "$QUERY" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)
  if [[ -z "$AMOUNT" || -z "$ADDRESS" ]]; then
    echo '{"error":"deposit command requires amount and address. Usage: deposit <amount> <0x address>"}' | jq .
    exit 1
  fi
  exec "$SCRIPT_DIR/prepare-deposit.sh" "$AMOUNT" "$ADDRESS"
fi

# Withdraw — expects: withdraw <amount> <receiver>
if [[ "$query_lower" =~ ^(withdraw|prepare.?withdraw|redeem) ]]; then
  AMOUNT=$(echo "$QUERY" | grep -oE '[0-9]+' | head -1)
  ADDRESS=$(echo "$QUERY" | grep -oE '0x[0-9a-fA-F]{40}' | head -1)
  if [[ -z "$AMOUNT" || -z "$ADDRESS" ]]; then
    echo '{"error":"withdraw command requires amount and address. Usage: withdraw <amount> <0x address>"}' | jq .
    exit 1
  fi
  exec "$SCRIPT_DIR/prepare-withdraw.sh" "$AMOUNT" "$ADDRESS"
fi

# Stream — expects: stream <id>
if [[ "$query_lower" =~ ^(stream|payment.?stream) ]]; then
  STREAM_ID=$(echo "$QUERY" | grep -oE '[0-9]+' | head -1)
  if [[ -z "$STREAM_ID" ]]; then
    echo '{"error":"stream command requires an ID. Usage: stream <id>"}' | jq .
    exit 1
  fi
  exec "$SCRIPT_DIR/get-stream.sh" "$STREAM_ID"
fi

# ── Fallback: show help ──────────────────────────────────────────────
echo "Unknown query: \"$QUERY\"" >&2
echo "" >&2
exec "$0"
