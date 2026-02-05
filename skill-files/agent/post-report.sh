#!/bin/bash
# ============================================================================
# post-report.sh - Post a YieldClaw yield report to Moltbook
# ============================================================================
# This script:
#   1. Loads the Moltbook API key from config
#   2. Runs scripts/yield-report.sh to generate a fresh yield report
#   3. Posts the report to m/usyc on Moltbook
#   4. Also posts to m/usdc for hackathon visibility
#   5. Prints the post URLs on success
#
# Usage:
#   ./agent/post-report.sh
#
# Prerequisites:
#   - curl, jq, python3 installed
#   - Valid Moltbook API key in config
#   - scripts/yield-report.sh available
#
# Rate limits: 1 post per 30 minutes
#
# SECURITY: This script never stores or transmits private keys.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Config loading ──────────────────────────────────────────────────────────
GLOBAL_CONFIG="$HOME/.clawdbot/skills/yieldclaw/config.json"
LOCAL_CONFIG="$SCRIPT_DIR/config.json"

if [[ -f "$GLOBAL_CONFIG" ]]; then
  CONFIG_FILE="$GLOBAL_CONFIG"
elif [[ -f "$LOCAL_CONFIG" ]]; then
  CONFIG_FILE="$LOCAL_CONFIG"
else
  echo "ERROR: No config.json found."
  echo "  Expected at: $GLOBAL_CONFIG"
  echo "  Or fallback: $LOCAL_CONFIG"
  exit 1
fi

API_KEY=$(jq -r '.moltbook.apiKey // empty' "$CONFIG_FILE")
API_BASE=$(jq -r '.moltbook.apiBase // "https://www.moltbook.com/api/v1"' "$CONFIG_FILE")
SUBMOLT=$(jq -r '.moltbook.submolt // "usyc"' "$CONFIG_FILE")

if [[ -z "$API_KEY" || "$API_KEY" == "YOUR_MOLTBOOK_API_KEY" ]]; then
  echo "ERROR: No valid Moltbook API key found in $CONFIG_FILE"
  echo "Run agent/register.sh first, or set moltbook.apiKey in config.json"
  exit 1
fi

echo "Using config: $CONFIG_FILE"
echo "API Base: $API_BASE"
echo ""

# ── Generate yield report ──────────────────────────────────────────────────
echo "=== Generating yield report ==="

REPORT_SCRIPT="$PROJECT_DIR/scripts/yield-report.sh"

if [[ ! -f "$REPORT_SCRIPT" ]]; then
  # Fallback: generate report from get-apy.sh and get-tvl.sh
  echo "yield-report.sh not found, generating from APY and TVL scripts..."

  APY_SCRIPT="$PROJECT_DIR/scripts/get-apy.sh"
  TVL_SCRIPT="$PROJECT_DIR/scripts/get-tvl.sh"

  if [[ ! -f "$APY_SCRIPT" || ! -f "$TVL_SCRIPT" ]]; then
    echo "ERROR: Required scripts not found in $PROJECT_DIR/scripts/"
    exit 1
  fi

  APY_DATA=$(bash "$APY_SCRIPT" 2>/dev/null) || {
    echo "ERROR: get-apy.sh failed"
    exit 1
  }
  TVL_DATA=$(bash "$TVL_SCRIPT" 2>/dev/null) || {
    echo "ERROR: get-tvl.sh failed"
    exit 1
  }

  APY_VAL=$(echo "$APY_DATA" | jq -r '.apy // "N/A"')
  SHARE_PRICE=$(echo "$APY_DATA" | jq -r '.sharePrice // "N/A"')
  TVL_VAL=$(echo "$TVL_DATA" | jq -r '.tvl // "N/A"')
  TIMESTAMP=$(echo "$APY_DATA" | jq -r '.timestamp // "N/A"')

  YIELD_REPORT=$(cat <<REPORT_EOF
━━━ YieldClaw Report ━━━
Vault: USYC/Hashnote (Arc Testnet)
APY: $APY_VAL
TVL: \$$TVL_VAL USDC
Share Price: $SHARE_PRICE USDC
Timestamp: $TIMESTAMP
━━━━━━━━━━━━━━━━━━━━━━━

Data sourced on-chain from Arc Testnet (Chain ID: 5042002)
Vault: 0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25
Premium data available via x402 micropayments.
REPORT_EOF
  )
else
  YIELD_REPORT=$(bash "$REPORT_SCRIPT" 2>/dev/null) || {
    echo "ERROR: yield-report.sh failed"
    exit 1
  }
fi

if [[ -z "$YIELD_REPORT" ]]; then
  echo "ERROR: Yield report is empty"
  exit 1
fi

echo "Report generated:"
echo "$YIELD_REPORT"
echo ""

# ── Post to m/usyc ────────────────────────────────────────────────────────
DATE_STAMP=$(date -u +"%Y-%m-%d %H:%M UTC")
POST_TITLE="YieldClaw Report - $DATE_STAMP"

echo "=== Posting to m/$SUBMOLT ==="

POST_BODY=$(jq -n \
  --arg title "$POST_TITLE" \
  --arg body "$YIELD_REPORT" \
  --arg submolt "$SUBMOLT" \
  --arg type "text" \
  '{title: $title, body: $body, submolt: $submolt, type: $type}')

USYC_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE/posts" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d "$POST_BODY" 2>/dev/null)

HTTP_CODE=$(echo "$USYC_RESPONSE" | tail -n 1)
RESPONSE_BODY=$(echo "$USYC_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
  POST_ID=$(echo "$RESPONSE_BODY" | jq -r '.id // .postId // .post_id // empty')
  POST_URL=$(echo "$RESPONSE_BODY" | jq -r '.url // .postUrl // .post_url // empty')
  echo "Posted to m/$SUBMOLT successfully (HTTP $HTTP_CODE)"
  if [[ -n "$POST_URL" ]]; then
    echo "URL: $POST_URL"
  elif [[ -n "$POST_ID" ]]; then
    echo "Post ID: $POST_ID"
    echo "URL: https://www.moltbook.com/m/$SUBMOLT/posts/$POST_ID"
  fi
elif [[ "$HTTP_CODE" -eq 429 ]]; then
  echo "WARNING: Rate limited (HTTP 429). Wait 30 minutes between posts."
  echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"
else
  echo "ERROR: Failed to post to m/$SUBMOLT (HTTP $HTTP_CODE)"
  echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"
fi

# ── Post to m/usdc for hackathon visibility ────────────────────────────────
echo ""
echo "=== Posting to m/usdc (hackathon visibility) ==="

# Respect rate limit: wait before posting again
echo "Waiting 30 seconds to respect rate limits..."
sleep 30

USDC_POST_BODY=$(jq -n \
  --arg title "$POST_TITLE" \
  --arg body "$YIELD_REPORT" \
  --arg submolt "usdc" \
  --arg type "text" \
  '{title: $title, body: $body, submolt: $submolt, type: $type}')

USDC_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_BASE/posts" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d "$USDC_POST_BODY" 2>/dev/null)

HTTP_CODE=$(echo "$USDC_RESPONSE" | tail -n 1)
RESPONSE_BODY=$(echo "$USDC_RESPONSE" | sed '$d')

if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
  POST_ID=$(echo "$RESPONSE_BODY" | jq -r '.id // .postId // .post_id // empty')
  POST_URL=$(echo "$RESPONSE_BODY" | jq -r '.url // .postUrl // .post_url // empty')
  echo "Posted to m/usdc successfully (HTTP $HTTP_CODE)"
  if [[ -n "$POST_URL" ]]; then
    echo "URL: $POST_URL"
  elif [[ -n "$POST_ID" ]]; then
    echo "Post ID: $POST_ID"
    echo "URL: https://www.moltbook.com/m/usdc/posts/$POST_ID"
  fi
elif [[ "$HTTP_CODE" -eq 429 ]]; then
  echo "WARNING: Rate limited (HTTP 429). The m/usdc post was skipped."
else
  echo "WARNING: Failed to post to m/usdc (HTTP $HTTP_CODE)"
  echo "$RESPONSE_BODY" | jq . 2>/dev/null || echo "$RESPONSE_BODY"
fi

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo "=== Post complete ==="
echo "Report posted at: $DATE_STAMP"
