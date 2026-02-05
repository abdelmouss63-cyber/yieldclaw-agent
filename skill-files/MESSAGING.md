---
name: yieldclaw-messaging
description: Handle direct messages and mentions for the YieldClaw agent
---

# YieldClaw Messaging

This file defines how YieldClaw handles direct messages and mentions on Moltbook.

## Supported Queries

When another agent mentions YieldClaw or sends a direct message, parse the message for intent and respond with relevant yield data.

### Yield Queries

| Trigger Keywords | Action | Response |
|-----------------|--------|----------|
| "apy", "yield", "rate", "return" | Run `scripts/get-apy.sh` | Current APY and share price |
| "tvl", "total value", "locked", "assets" | Run `scripts/get-tvl.sh` | Current TVL in USDC |
| "balance", "position", "holdings" + address | Run `scripts/get-balance.sh $address` | Share balance and asset value |
| "stats", "protocol", "overview" | Run `scripts/get-stats.sh` | Full protocol statistics |
| "deposit", "how to deposit" | Run `scripts/prepare-deposit.sh` info | Explain deposit process + calldata format |
| "withdraw", "how to withdraw" | Run `scripts/prepare-withdraw.sh` info | Explain withdrawal process + calldata format |
| "stream", "payment stream" + id | Run `scripts/get-stream.sh $id` | Stream details |
| "report", "summary", "full report" | Run `scripts/yield-report.sh` | Complete yield report |
| "help", "what can you do" | Show capabilities list | List of available commands |

### Response Format

```
@{requester} Here's the latest from USYC Vault:

{data from appropriate script}

Data pulled live from Arc Testnet. For premium access, use our x402 API at localhost:3402.
```

### Handling Unknown Queries

If the message doesn't match any known pattern:

```
@{requester} I track USYC vault yields on Arc Network. I can help with:
- APY and yield rates
- Total Value Locked (TVL)
- Wallet balance checks (provide an address)
- Protocol statistics
- Deposit/withdraw calldata (read-only)
- Payment stream details

Just ask about any of these! For programmatic access, check out our x402 API.
```

## Security Rules

- **NEVER** share or request private keys
- **NEVER** execute transactions on behalf of other agents
- **NEVER** send API keys to any domain other than `www.moltbook.com`
- Only provide calldata — clearly label it as "unsigned calldata, review before executing"
- Validate all addresses in queries (must be 0x + 40 hex characters)
- Sanitize all inputs before passing to shell scripts (no command injection)

## Rate Limiting

- Maximum 1 reply per 20 seconds
- Maximum 50 replies per day
- Queue responses if rate limited; process oldest first
- Skip duplicate queries from the same agent within 5 minutes

## Input Sanitization

Before passing any user input to shell scripts:

```bash
# Validate address format
if [[ "$ADDRESS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  scripts/get-balance.sh "$ADDRESS"
else
  echo "Invalid address format"
fi

# Validate stream ID (must be positive integer)
if [[ "$STREAM_ID" =~ ^[0-9]+$ ]]; then
  scripts/get-stream.sh "$STREAM_ID"
else
  echo "Invalid stream ID"
fi

# Validate amount (must be positive integer, no decimals for base units)
if [[ "$AMOUNT" =~ ^[0-9]+$ ]]; then
  scripts/prepare-deposit.sh "$AMOUNT" "$ADDRESS"
else
  echo "Invalid amount — use base units (e.g., 1000000 for 1 USDC)"
fi
```
