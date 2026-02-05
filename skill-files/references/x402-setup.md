# x402 Integration Guide

## Overview

YieldClaw implements the [x402 protocol](https://x402.org) to monetize yield data access. Other AI agents can pay micro-amounts in USDC per query, creating a self-sustaining agent economy.

## How x402 Works

The x402 protocol uses the HTTP `402 Payment Required` status code:

1. **Agent requests data** → `GET /yield/apy`
2. **Server responds 402** → Includes payment details (amount, token, recipient)
3. **Agent constructs payment** → Signs a USDC transfer on Arc testnet
4. **Agent retries with payment** → Includes `Payment` header with signed tx
5. **Server validates & responds** → Returns yield data

## Architecture

```
┌─────────────┐     HTTP GET        ┌──────────────────┐
│  Agent       │ ──────────────────> │  YieldClaw x402  │
│  (buyer)     │                     │  Server (:3402)  │
│              │ <── 402 + details── │                  │
│              │                     │  ┌────────────┐  │
│  Signs USDC  │ ── GET + Payment ─> │  │ Middleware  │  │
│  payment     │                     │  │ validates   │  │
│              │ <── 200 + data ──── │  │ payment     │  │
└─────────────┘                     │  └────────────┘  │
                                    │  ┌────────────┐  │
                                    │  │ Shell       │  │
                                    │  │ scripts     │  │
                                    │  └────────────┘  │
                                    └──────────────────┘
```

## Endpoints & Pricing

| Endpoint | Price (USDC) | Base Units | Description |
|----------|-------------|------------|-------------|
| `GET /yield/apy` | 0.001 | 1000 | Current APY |
| `GET /yield/tvl` | 0.001 | 1000 | Total value locked |
| `GET /yield/balance/:address` | 0.002 | 2000 | Address balance |
| `GET /yield/stats` | 0.003 | 3000 | Protocol statistics |
| `GET /yield/report` | 0.005 | 5000 | Complete yield report |
| `GET /yield/stream/:id` | 0.002 | 2000 | Payment stream info |
| `GET /health` | free | — | Server health check |
| `GET /` | free | — | Service info |

## Running the Server

```bash
# Set your payment receiving address
export YIELDCLAW_PAY_ADDRESS=0xYourAddress

# Optional: custom port (default 3402)
export PORT=3402

# Start the server
node x402/server.js
```

## 402 Response Format

When an agent hits a paid endpoint without payment:

```json
{
  "status": 402,
  "message": "Payment Required",
  "x402": {
    "version": "1.0",
    "network": "arc-testnet",
    "chainId": 5042002,
    "payTo": "0xRecipientAddress",
    "token": "0x3600000000000000000000000000000000000000",
    "amount": "1000",
    "description": "Current vault APY"
  }
}
```

## Payment Header Format

The agent includes a `Payment` header with a JSON payload:

```json
{
  "from": "0xAgentAddress",
  "to": "0xRecipientAddress",
  "amount": "1000",
  "token": "0x3600000000000000000000000000000000000000",
  "chainId": 5042002,
  "signature": "0x..."
}
```

## Client Example (curl)

```bash
# Step 1: Get payment requirements
curl -s http://localhost:3402/yield/apy
# Returns 402 with payment details

# Step 2: Pay and get data (with payment header)
curl -s http://localhost:3402/yield/apy \
  -H 'Payment: {"from":"0x...","to":"0x...","amount":"1000","token":"0x3600000000000000000000000000000000000000","chainId":5042002,"signature":"0x..."}'
```

## Security

- Server never holds or manages private keys
- Payment validation checks signature format and required fields
- All yield data comes from read-only onchain queries
- USDC on Arc testnet only — no real funds at risk
- Rate limited to 100 requests per minute per IP
