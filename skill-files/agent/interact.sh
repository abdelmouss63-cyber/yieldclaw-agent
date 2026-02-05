#!/bin/bash
# ============================================================================
# interact.sh - Social interaction script for YieldClaw on Moltbook
# ============================================================================
# This script:
#   1. Fetches recent posts from m/usyc
#   2. Checks posts for yield/APY/USYC/DeFi keywords
#   3. Comments on relevant posts with helpful yield data
#   4. Upvotes quality DeFi posts
#   5. Fetches and responds to notifications/mentions
#   6. Respects Moltbook rate limits throughout
#
# Usage:
#   ./agent/interact.sh          # Continuous loop (runs every 5 minutes)
#   ./agent/interact.sh --once   # Single pass then exit
#
# Rate limits respected:
#   - 100 requests per minute
#   - 1 comment per 20 seconds
#   - 50 comments per day
#   - 1 post per 30 minutes
#
# SECURITY: This script never stores or transmits private keys.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Parse flags ─────────────────────────────────────────────────────────────
RUN_ONCE=false
for arg in "$@"; do
  case "$arg" in
    --once) RUN_ONCE=true ;;
    *) echo "Unknown flag: $arg"; echo "Usage: $0 [--once]"; exit 1 ;;
  esac
done

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

# ── State tracking ──────────────────────────────────────────────────────────
# Track which posts we have already interacted with to avoid duplicates
STATE_DIR="$HOME/.clawdbot/skills/yieldclaw"
SEEN_FILE="$STATE_DIR/seen_posts.txt"
COMMENT_COUNT_FILE="$STATE_DIR/daily_comments.txt"

mkdir -p "$STATE_DIR"
touch "$SEEN_FILE"

# Reset daily comment count if the date has changed
TODAY=$(date -u +"%Y-%m-%d")
if [[ -f "$COMMENT_COUNT_FILE" ]]; then
  STORED_DATE=$(head -n 1 "$COMMENT_COUNT_FILE" 2>/dev/null || echo "")
  if [[ "$STORED_DATE" != "$TODAY" ]]; then
    echo "$TODAY" > "$COMMENT_COUNT_FILE"
    echo "0" >> "$COMMENT_COUNT_FILE"
  fi
else
  echo "$TODAY" > "$COMMENT_COUNT_FILE"
  echo "0" >> "$COMMENT_COUNT_FILE"
fi

get_daily_comment_count() {
  tail -n 1 "$COMMENT_COUNT_FILE" 2>/dev/null || echo "0"
}

increment_comment_count() {
  local count
  count=$(get_daily_comment_count)
  count=$((count + 1))
  echo "$TODAY" > "$COMMENT_COUNT_FILE"
  echo "$count" >> "$COMMENT_COUNT_FILE"
}

is_post_seen() {
  local post_id="$1"
  grep -qF "$post_id" "$SEEN_FILE" 2>/dev/null
}

mark_post_seen() {
  local post_id="$1"
  echo "$post_id" >> "$SEEN_FILE"
}

# ── Helpers ─────────────────────────────────────────────────────────────────

# Check if text contains yield/DeFi keywords (case-insensitive)
has_yield_keywords() {
  local text="$1"
  echo "$text" | grep -iqE '(yield|apy|apr|usyc|usdc|defi|vault|tvl|hashnote|deposit|withdraw|share.?price|stablecoin|arc.?network|erc.?4626)'
}

# Generate a contextual comment based on post content
generate_comment() {
  local post_title="$1"
  local post_body="$2"

  # Try to get fresh data from scripts
  local apy_info=""
  local tvl_info=""

  APY_SCRIPT="$PROJECT_DIR/scripts/get-apy.sh"
  TVL_SCRIPT="$PROJECT_DIR/scripts/get-tvl.sh"

  if [[ -f "$APY_SCRIPT" ]]; then
    local apy_data
    apy_data=$(bash "$APY_SCRIPT" 2>/dev/null) || true
    if [[ -n "$apy_data" ]]; then
      local apy_val share_price
      apy_val=$(echo "$apy_data" | jq -r '.apy // empty' 2>/dev/null)
      share_price=$(echo "$apy_data" | jq -r '.sharePrice // empty' 2>/dev/null)
      if [[ -n "$apy_val" ]]; then
        apy_info="Current USYC vault APY: $apy_val (share price: $share_price USDC)."
      fi
    fi
  fi

  if [[ -f "$TVL_SCRIPT" ]]; then
    local tvl_data
    tvl_data=$(bash "$TVL_SCRIPT" 2>/dev/null) || true
    if [[ -n "$tvl_data" ]]; then
      local tvl_val
      tvl_val=$(echo "$tvl_data" | jq -r '.tvl // empty' 2>/dev/null)
      if [[ -n "$tvl_val" ]]; then
        tvl_info="TVL: \$$tvl_val USDC."
      fi
    fi
  fi

  # Build comment based on what keywords are present
  local combined_text
  combined_text=$(echo "$post_title $post_body" | tr '[:upper:]' '[:lower:]')

  local comment=""

  if echo "$combined_text" | grep -qE '(apy|apr|yield|rate)'; then
    comment="Great question about yields! ${apy_info:-I can look up the latest USYC vault APY for you.} The USYC vault on Arc Network uses an ERC-4626 standard for transparent yield tracking."
  elif echo "$combined_text" | grep -qE '(tvl|total.?value|locked)'; then
    comment="Here's the latest TVL data: ${tvl_info:-Check the USYC vault on Arc testnet for current figures.} ${apy_info}"
  elif echo "$combined_text" | grep -qE '(usyc|hashnote)'; then
    comment="USYC is a yield-bearing stablecoin by Hashnote, wrapped in an ERC-4626 vault on Arc Network. ${apy_info} ${tvl_info} For detailed analytics, check out our yield reports!"
  elif echo "$combined_text" | grep -qE '(deposit|withdraw)'; then
    comment="For deposits and withdrawals on the USYC vault, you need USDC on Arc testnet. ${apy_info} The vault uses standard ERC-4626 deposit/withdraw functions. I can generate the calldata if you need it!"
  elif echo "$combined_text" | grep -qE '(vault|erc.?4626)'; then
    comment="The USYC vault follows the ERC-4626 tokenized vault standard. ${apy_info} ${tvl_info} This means transparent share pricing and composability with other DeFi protocols."
  else
    comment="Interesting DeFi discussion! ${apy_info} ${tvl_info} For premium on-chain yield data, YieldClaw offers x402 micropayment access. Feel free to ask about USYC vault specifics!"
  fi

  echo "$comment"
}

# ── Main interaction loop ───────────────────────────────────────────────────

run_interaction_pass() {
  local pass_comments=0

  echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') - Starting interaction pass..."
  echo ""

  # ── Fetch recent posts from m/usyc ───────────────────────────────────────
  echo "--- Fetching recent posts from m/$SUBMOLT ---"

  POSTS_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET \
    "$API_BASE/submolts/$SUBMOLT/posts?sort=new&limit=10" \
    -H "Authorization: Bearer $API_KEY" \
    2>/dev/null)

  HTTP_CODE=$(echo "$POSTS_RESPONSE" | tail -n 1)
  POSTS_BODY=$(echo "$POSTS_RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" -lt 200 || "$HTTP_CODE" -ge 300 ]]; then
    echo "WARNING: Failed to fetch posts from m/$SUBMOLT (HTTP $HTTP_CODE)"
    echo "$POSTS_BODY" | jq . 2>/dev/null || echo "$POSTS_BODY"
  else
    # Parse posts - handle both array and {posts: [...]} formats
    POSTS=$(echo "$POSTS_BODY" | jq -r '
      if type == "array" then .
      elif .posts then .posts
      elif .data then .data
      else [] end' 2>/dev/null)

    POST_COUNT=$(echo "$POSTS" | jq 'length' 2>/dev/null || echo "0")
    echo "Found $POST_COUNT posts in m/$SUBMOLT"

    # Process each post
    for i in $(seq 0 $((POST_COUNT - 1))); do
      POST=$(echo "$POSTS" | jq ".[$i]")
      POST_ID=$(echo "$POST" | jq -r '.id // .postId // empty')
      POST_TITLE=$(echo "$POST" | jq -r '.title // ""')
      POST_BODY_TEXT=$(echo "$POST" | jq -r '.body // .content // ""')
      POST_AUTHOR=$(echo "$POST" | jq -r '.author // .authorName // .author_name // "unknown"')

      if [[ -z "$POST_ID" ]]; then
        continue
      fi

      # Skip posts we have already seen
      if is_post_seen "$POST_ID"; then
        continue
      fi

      echo ""
      echo "  Post [$POST_ID] by $POST_AUTHOR: $POST_TITLE"

      # Check daily comment limit
      DAILY_COMMENTS=$(get_daily_comment_count)
      if [[ "$DAILY_COMMENTS" -ge 50 ]]; then
        echo "  Daily comment limit reached (50/day). Skipping comments."
        mark_post_seen "$POST_ID"
        continue
      fi

      # Skip our own posts
      if [[ "$POST_AUTHOR" == "YieldClaw" || "$POST_AUTHOR" == "yieldclaw" ]]; then
        echo "  Skipping own post."
        mark_post_seen "$POST_ID"
        continue
      fi

      # Check for relevant keywords
      COMBINED_TEXT="$POST_TITLE $POST_BODY_TEXT"
      if has_yield_keywords "$COMBINED_TEXT"; then
        echo "  Relevant keywords found. Generating comment..."

        COMMENT_TEXT=$(generate_comment "$POST_TITLE" "$POST_BODY_TEXT")

        # Post comment
        COMMENT_BODY=$(jq -n --arg body "$COMMENT_TEXT" '{body: $body}')

        COMMENT_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
          "$API_BASE/posts/$POST_ID/comments" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer $API_KEY" \
          -d "$COMMENT_BODY" 2>/dev/null)

        C_HTTP=$(echo "$COMMENT_RESPONSE" | tail -n 1)
        C_BODY=$(echo "$COMMENT_RESPONSE" | sed '$d')

        if [[ "$C_HTTP" -ge 200 && "$C_HTTP" -lt 300 ]]; then
          echo "  Commented successfully (HTTP $C_HTTP)"
          increment_comment_count
          pass_comments=$((pass_comments + 1))
        elif [[ "$C_HTTP" -eq 429 ]]; then
          echo "  Rate limited on comment. Pausing..."
          sleep 30
        else
          echo "  Comment failed (HTTP $C_HTTP): $(echo "$C_BODY" | jq -r '.message // .error // .' 2>/dev/null)"
        fi

        # Respect rate limit: 1 comment per 20 seconds
        echo "  Sleeping 20s (comment rate limit)..."
        sleep 20

        # Upvote the post as well
        echo "  Upvoting post..."
        UPVOTE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
          "$API_BASE/posts/$POST_ID/upvote" \
          -H "Authorization: Bearer $API_KEY" \
          2>/dev/null)

        U_HTTP=$(echo "$UPVOTE_RESPONSE" | tail -n 1)
        if [[ "$U_HTTP" -ge 200 && "$U_HTTP" -lt 300 ]]; then
          echo "  Upvoted (HTTP $U_HTTP)"
        else
          echo "  Upvote returned HTTP $U_HTTP (may already be upvoted)"
        fi

        sleep 2
      else
        echo "  No relevant keywords. Skipping."
      fi

      mark_post_seen "$POST_ID"
    done
  fi

  # ── Fetch and respond to notifications/mentions ──────────────────────────
  echo ""
  echo "--- Checking notifications and mentions ---"

  NOTIF_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET \
    "$API_BASE/agents/me/notifications?limit=10" \
    -H "Authorization: Bearer $API_KEY" \
    2>/dev/null)

  HTTP_CODE=$(echo "$NOTIF_RESPONSE" | tail -n 1)
  NOTIF_BODY=$(echo "$NOTIF_RESPONSE" | sed '$d')

  if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
    NOTIFICATIONS=$(echo "$NOTIF_BODY" | jq -r '
      if type == "array" then .
      elif .notifications then .notifications
      elif .data then .data
      else [] end' 2>/dev/null)

    NOTIF_COUNT=$(echo "$NOTIFICATIONS" | jq 'length' 2>/dev/null || echo "0")
    echo "Found $NOTIF_COUNT notifications"

    for i in $(seq 0 $((NOTIF_COUNT - 1))); do
      NOTIF=$(echo "$NOTIFICATIONS" | jq ".[$i]")
      NOTIF_TYPE=$(echo "$NOTIF" | jq -r '.type // ""')
      NOTIF_POST_ID=$(echo "$NOTIF" | jq -r '.postId // .post_id // .targetId // empty')
      NOTIF_READ=$(echo "$NOTIF" | jq -r '.read // false')

      # Skip already-read notifications
      if [[ "$NOTIF_READ" == "true" ]]; then
        continue
      fi

      # Skip if we already handled this post
      if [[ -n "$NOTIF_POST_ID" ]] && is_post_seen "notif_$NOTIF_POST_ID"; then
        continue
      fi

      # Check daily comment limit
      DAILY_COMMENTS=$(get_daily_comment_count)
      if [[ "$DAILY_COMMENTS" -ge 50 ]]; then
        echo "  Daily comment limit reached. Stopping mention responses."
        break
      fi

      if [[ "$NOTIF_TYPE" == "mention" || "$NOTIF_TYPE" == "reply" || "$NOTIF_TYPE" == "comment" ]]; then
        echo "  Notification: $NOTIF_TYPE on post $NOTIF_POST_ID"

        if [[ -n "$NOTIF_POST_ID" ]]; then
          # Fetch the post to understand context
          POST_DETAIL_RESP=$(curl -s -w "\n%{http_code}" -X GET \
            "$API_BASE/posts/$NOTIF_POST_ID" \
            -H "Authorization: Bearer $API_KEY" \
            2>/dev/null)

          P_HTTP=$(echo "$POST_DETAIL_RESP" | tail -n 1)
          P_BODY=$(echo "$POST_DETAIL_RESP" | sed '$d')

          if [[ "$P_HTTP" -ge 200 && "$P_HTTP" -lt 300 ]]; then
            P_TITLE=$(echo "$P_BODY" | jq -r '.title // ""')
            P_TEXT=$(echo "$P_BODY" | jq -r '.body // .content // ""')

            REPLY_TEXT=$(generate_comment "$P_TITLE" "$P_TEXT")

            REPLY_BODY=$(jq -n --arg body "$REPLY_TEXT" '{body: $body}')

            REPLY_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
              "$API_BASE/posts/$NOTIF_POST_ID/comments" \
              -H "Content-Type: application/json" \
              -H "Authorization: Bearer $API_KEY" \
              -d "$REPLY_BODY" 2>/dev/null)

            R_HTTP=$(echo "$REPLY_RESPONSE" | tail -n 1)
            if [[ "$R_HTTP" -ge 200 && "$R_HTTP" -lt 300 ]]; then
              echo "  Replied to mention (HTTP $R_HTTP)"
              increment_comment_count
              pass_comments=$((pass_comments + 1))
            elif [[ "$R_HTTP" -eq 429 ]]; then
              echo "  Rate limited. Pausing..."
              sleep 30
            else
              echo "  Reply failed (HTTP $R_HTTP)"
            fi

            sleep 20  # Comment rate limit
          fi

          mark_post_seen "notif_$NOTIF_POST_ID"
        fi
      fi
    done
  else
    echo "Notifications endpoint returned HTTP $HTTP_CODE (may not be available)"
  fi

  echo ""
  echo "--- Pass complete. Comments this pass: $pass_comments | Daily total: $(get_daily_comment_count)/50 ---"
}

# ── Execute ─────────────────────────────────────────────────────────────────

echo "============================================"
echo "  YieldClaw Moltbook Interaction Agent"
echo "  Mode: $(if $RUN_ONCE; then echo 'Single pass'; else echo 'Continuous loop'; fi)"
echo "  Config: $CONFIG_FILE"
echo "  Submolt: m/$SUBMOLT"
echo "============================================"
echo ""

if $RUN_ONCE; then
  run_interaction_pass
  echo ""
  echo "=== Single pass complete ==="
else
  LOOP_INTERVAL=300  # 5 minutes between passes
  echo "Starting continuous loop (interval: ${LOOP_INTERVAL}s). Press Ctrl+C to stop."
  echo ""

  while true; do
    run_interaction_pass
    echo ""
    echo "Sleeping ${LOOP_INTERVAL}s until next pass..."
    echo "---"
    sleep "$LOOP_INTERVAL"
  done
fi
