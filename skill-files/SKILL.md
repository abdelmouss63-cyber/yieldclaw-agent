---
name: yieldclaw
description: Autonomous DeFi yield agent for USYC/Hashnote on Arc Network. Use when the user wants to check USYC vault APY, read TVL or total assets, check wallet balances in the vault, view protocol statistics, prepare deposit or withdrawal calldata (read-only, never executes), read payment stream details, or generate formatted yield reports. All interactions are read-only onchain queries against the Arc testnet. Supports x402 micropayments for premium yield data access.
metadata:
  {
    "clawdbot":
      {
        "emoji": "🦞",
        "category": "DeFi / Yield",
        "homepage": "https://github.com/yieldclaw/yieldclaw",
        "requires": { "bins": ["curl", "jq"] },
      },
  }
---

# YieldClaw

Autonomous DeFi yield intelligence for USYC/Hashnote on Arc Network. Query real-time APY, vault TVL, wallet balances, payment streams, and generate yield reports — all from the command line.

**Network:** Arc Testnet (Chain ID: `5042002`)
**RPC:** `https://rpc.testnet.arc.network`

## Contracts

| Contract | Address | Purpose |
|----------|---------|---------|
| USYC Vault | `0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25` | ERC-4626 yield vault |
| PaymentStream | `0x1fcb750413067Ba96Ea80B018b304226AB7365C6` | Streaming payments |
| USDC | `0x3600000000000000000000000000000000000000` | Stablecoin (gas token on Arc) |
| USYC | `0xe9185F0c5F296Ed1797AaE4238D26CCaBEadb86C` | Yield-bearing stablecoin |

## Quick Start

### First-Time Setup

```bash
mkdir -p ~/.clawdbot/skills/yieldclaw
cat > ~/.clawdbot/skills/yieldclaw/config.json << 'EOF'
{
  "rpc": "https://rpc.testnet.arc.network",
  "chainId": 5042002,
  "vault": "0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25",
  "paymentStream": "0x1fcb750413067Ba96Ea80B018b304226AB7365C6",
  "usdc": "0x3600000000000000000000000000000000000000",
  "usyc": "0xe9185F0c5F296Ed1797AaE4238D26CCaBEadb86C"
}
EOF
```

### Verify Setup

```bash
scripts/yield-query.sh "What is the current APY?"
```

## Core Functions

### 1. getAPY — Real-Time Vault Yield

Calculates APY from the vault's share-to-asset exchange rate over time.

```bash
scripts/get-apy.sh
```

**How it works:** Reads `convertToAssets(1e18)` at two time points and computes annualized yield from the rate of change. Falls back to `totalAssets / totalSupply` ratio if historical data is unavailable.

**Contract calls:**
| Function | Selector | Returns |
|----------|----------|---------|
| `convertToAssets(uint256)` | `0x07a2d13a` | uint256 (assets per share) |
| `totalAssets()` | `0x01e1d114` | uint256 |
| `totalSupply()` | `0x18160ddd` | uint256 |

**RPC template:**
```bash
# Get assets per 1 share (1e18)
curl -s -X POST https://rpc.testnet.arc.network \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_call","params":[{
    "to":"0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25",
    "data":"0x07a2d13a0000000000000000000000000000000000000000000000000de0b6b3a7640000"
  },"latest"],"id":1}' | jq -r '.result'
```

---

### 2. getTVL — Total Value Locked

Reads the total assets held in the USYC vault.

```bash
scripts/get-tvl.sh
```

**Contract calls:**
| Function | Selector | Returns |
|----------|----------|---------|
| `totalAssets()` | `0x01e1d114` | uint256 (total USDC in vault) |
| `totalSupply()` | `0x18160ddd` | uint256 (total shares minted) |

**RPC template:**
```bash
curl -s -X POST https://rpc.testnet.arc.network \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_call","params":[{
    "to":"0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25",
    "data":"0x01e1d114"
  },"latest"],"id":1}' | jq -r '.result'
```

---

### 3. getBalance — User Vault Balance

Checks a specific address's share balance and its equivalent asset value.

```bash
scripts/get-balance.sh 0xYOUR_ADDRESS
```

**Contract calls:**
| Function | Selector | Params | Returns |
|----------|----------|--------|---------|
| `balanceOf(address)` | `0x70a08231` | address (32B padded) | uint256 (shares) |
| `convertToAssets(uint256)` | `0x07a2d13a` | shares amount | uint256 (asset value) |
| `maxWithdraw(address)` | `0xce96cb77` | address (32B padded) | uint256 (max withdrawable) |

**RPC template:**
```bash
# Replace ADDRESS with zero-padded address (remove 0x, pad to 64 hex chars)
curl -s -X POST https://rpc.testnet.arc.network \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_call","params":[{
    "to":"0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25",
    "data":"0x70a08231000000000000000000000000ADDRESS"
  },"latest"],"id":1}' | jq -r '.result'
```

---

### 4. getProtocolStats — Protocol Overview

Aggregated view of vault statistics: total assets, total supply, share price, and deposit cap.

```bash
scripts/get-stats.sh
```

**Contract calls:**
| Function | Selector | Returns |
|----------|----------|---------|
| `totalAssets()` | `0x01e1d114` | uint256 |
| `totalSupply()` | `0x18160ddd` | uint256 |
| `convertToAssets(1e18)` | `0x07a2d13a` | uint256 (share price) |
| `maxDeposit(address(0))` | `0x402d267d` | uint256 (deposit cap) |
| `asset()` | `0x38d52e0f` | address (underlying asset) |

---

### 5. prepareDeposit — Deposit Calldata (READ ONLY)

Generates encoded calldata for depositing USDC into the vault. **Never executes transactions.** Returns two calldata payloads: USDC approval and vault deposit.

```bash
scripts/prepare-deposit.sh 1000000 0xYOUR_ADDRESS
```

**Parameters:**
- `amount` — USDC amount in base units (6 decimals, e.g., `1000000` = 1 USDC)
- `receiver` — Address to receive vault shares

**Returns two transactions (calldata only):**

**Transaction 1: USDC Approval**
```json
{
  "to": "0x3600000000000000000000000000000000000000",
  "data": "0x095ea7b3{vault_padded}{amount_padded}",
  "value": "0",
  "chainId": 5042002,
  "description": "Approve USYC Vault to spend USDC"
}
```

**Transaction 2: Vault Deposit**
```json
{
  "to": "0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25",
  "data": "0x6e553f65{amount_padded}{receiver_padded}",
  "value": "0",
  "chainId": 5042002,
  "description": "Deposit USDC into USYC Vault"
}
```

**Function selectors:**
| Function | Selector | Params |
|----------|----------|--------|
| `approve(address,uint256)` | `0x095ea7b3` | spender + amount |
| `deposit(uint256,address)` | `0x6e553f65` | assets + receiver |
| `previewDeposit(uint256)` | `0xef8b30f7` | assets → expected shares |

---

### 6. prepareWithdraw — Withdrawal Calldata (READ ONLY)

Generates encoded calldata for withdrawing from the vault. **Never executes transactions.**

```bash
scripts/prepare-withdraw.sh 1000000 0xYOUR_ADDRESS
```

**Parameters:**
- `amount` — USDC amount to withdraw in base units
- `receiver` — Address to receive withdrawn USDC

**Returns calldata only:**
```json
{
  "to": "0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25",
  "data": "0xb460af94{amount_padded}{receiver_padded}{owner_padded}",
  "value": "0",
  "chainId": 5042002,
  "description": "Withdraw USDC from USYC Vault"
}
```

**Function selectors:**
| Function | Selector | Params |
|----------|----------|--------|
| `withdraw(uint256,address,address)` | `0xb460af94` | assets + receiver + owner |
| `previewWithdraw(uint256)` | `0x0a28a477` | assets → shares needed |
| `maxWithdraw(address)` | `0xce96cb77` | owner → max amount |

---

### 7. getStreamInfo — Payment Stream Details

Reads payment stream data from the PaymentStream contract.

```bash
scripts/get-stream.sh 1
```

**Parameters:**
- `streamId` — Numeric stream identifier

**Contract calls:**
| Function | Selector | Params | Returns |
|----------|----------|--------|---------|
| `getStream(uint256)` | `0xd5a44f86` | streamId | (sender, recipient, token, amount, startTime, stopTime, withdrawn) |

**RPC template:**
```bash
# Replace STREAM_ID with hex-padded stream ID
curl -s -X POST https://rpc.testnet.arc.network \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_call","params":[{
    "to":"0x1fcb750413067Ba96Ea80B018b304226AB7365C6",
    "data":"0xd5a44f86STREAM_ID_PADDED"
  },"latest"],"id":1}' | jq -r '.result'
```

---

### 8. getYieldReport — Formatted Yield Summary

Generates a comprehensive yield report suitable for posting on Moltbook. Combines APY, TVL, share price, and protocol stats into a formatted summary.

```bash
scripts/yield-report.sh
```

**Output format:**
```
━━━ YieldClaw Report ━━━
Vault: USYC/Hashnote (Arc Testnet)
APY: X.XX%
TVL: $X,XXX,XXX USDC
Share Price: X.XXXXXX USDC
Total Shares: X,XXX,XXX
Deposit Cap: $X,XXX,XXX
Timestamp: YYYY-MM-DD HH:MM UTC
━━━━━━━━━━━━━━━━━━━━━━━
```

## x402 Paid Data Access

YieldClaw offers premium yield data via the x402 payment protocol. Other agents can pay micro-amounts in USDC per query.

### Pricing

| Endpoint | Price | Description |
|----------|-------|-------------|
| `/yield/apy` | 0.001 USDC | Current APY |
| `/yield/tvl` | 0.001 USDC | Total value locked |
| `/yield/balance/:address` | 0.002 USDC | Address balance lookup |
| `/yield/stats` | 0.003 USDC | Full protocol stats |
| `/yield/report` | 0.005 USDC | Complete yield report |
| `/yield/stream/:id` | 0.002 USDC | Payment stream info |

### x402 Flow

1. Agent requests yield data endpoint
2. Server responds with HTTP `402 Payment Required` + payment details
3. Agent constructs USDC payment on Arc testnet
4. Agent retries request with `Payment` header containing signed transaction
5. Server validates payment and returns yield data

See [references/x402-setup.md](references/x402-setup.md) for integration details.

## Moltbook Integration

YieldClaw operates as an autonomous agent on Moltbook:

- **Posts yield reports** to `m/usyc` every few hours
- **Responds to questions** about USYC yield, vault mechanics, DeFi
- **Upvotes** quality DeFi discussions
- **Creates community** at `m/usyc` for yield-focused agents

### Agent Commands

```bash
# Register on Moltbook
agent/register.sh

# Post a yield report
agent/post-report.sh

# Respond to mentions
agent/interact.sh
```

## Error Handling

| Error | Cause | Fix |
|-------|-------|-----|
| RPC timeout | Arc testnet congestion | Retry after 5 seconds |
| Empty result | Contract not deployed at address | Verify contract addresses |
| Invalid hex | Malformed address input | Ensure 0x-prefixed, 40 hex chars |
| Zero balance | No vault position | Address has not deposited |

## Security

- **Read-only**: All onchain interactions are `eth_call` (no state changes)
- **No private keys**: Never stored, requested, or transmitted
- **Calldata only**: Deposit/withdraw functions return encoded data, never execute
- **No mainnet**: Operates exclusively on Arc testnet
- **API key isolation**: Moltbook API key stored locally, never sent elsewhere

## Resources

- **Arc Testnet Explorer**: https://testnet.arcscan.io
- **USYC Documentation**: https://docs.hashnote.com
- **OpenClaw Skills**: https://github.com/BankrBot/openclaw-skills
- **x402 Protocol**: https://x402.org
- **Moltbook**: https://moltbook.com
