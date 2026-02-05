# YieldClaw API Reference

## Shell Scripts

All scripts are located in `scripts/` and output JSON to stdout.

### scripts/yield-query.sh

**Main entry point.** Routes natural language queries to the appropriate script.

```bash
scripts/yield-query.sh "What is the current APY?"
scripts/yield-query.sh "Check balance for 0x1234..."
scripts/yield-query.sh "Prepare deposit of 1000000 for 0x1234..."
```

| Query Pattern | Routes To |
|--------------|-----------|
| Contains "apy", "yield", "rate" | get-apy.sh |
| Contains "tvl", "total", "locked" | get-tvl.sh |
| Contains "balance" + address | get-balance.sh |
| Contains "stat", "protocol", "overview" | get-stats.sh |
| Contains "deposit" + amount [+ address] | prepare-deposit.sh |
| Contains "withdraw" + amount [+ address] | prepare-withdraw.sh |
| Contains "stream" + id | get-stream.sh |
| Contains "report", "summary" | yield-report.sh |

### scripts/get-apy.sh

Returns current vault APY and share price.

**Output:**
```json
{
  "apy": "4.52%",
  "sharePrice": "1.045200",
  "totalAssets": "1000000000000",
  "totalSupply": "950000000000",
  "timestamp": "2026-02-05T12:00:00Z"
}
```

### scripts/get-tvl.sh

Returns total value locked in the vault.

**Output:**
```json
{
  "tvl": "1000000.00",
  "tvlRaw": "1000000000000",
  "unit": "USDC",
  "timestamp": "2026-02-05T12:00:00Z"
}
```

### scripts/get-balance.sh

**Args:** `<address>`

Returns vault position for a specific address.

**Output:**
```json
{
  "address": "0x1234...",
  "shares": "1000000000000000000",
  "assetValue": "1045200000000000000",
  "assetValueFormatted": "1.0452",
  "maxWithdraw": "1045200000000000000",
  "timestamp": "2026-02-05T12:00:00Z"
}
```

### scripts/get-stats.sh

Returns comprehensive protocol statistics.

**Output:**
```json
{
  "totalAssets": "1000000000000",
  "totalSupply": "950000000000",
  "sharePrice": "1.052631",
  "maxDeposit": "1000000000000000",
  "underlyingAsset": "0x3600000000000000000000000000000000000000",
  "timestamp": "2026-02-05T12:00:00Z"
}
```

### scripts/prepare-deposit.sh

**Args:** `<amount> <receiver_address>`

Returns unsigned calldata for depositing. **NEVER EXECUTES.**

**Output:**
```json
{
  "action": "deposit",
  "amount": "1000000",
  "receiver": "0x1234...",
  "expectedShares": "950000",
  "transactions": [
    {
      "step": 1,
      "description": "Approve USYC Vault to spend USDC",
      "to": "0x3600000000000000000000000000000000000000",
      "data": "0x095ea7b3...",
      "value": "0",
      "chainId": 5042002
    },
    {
      "step": 2,
      "description": "Deposit USDC into USYC Vault",
      "to": "0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25",
      "data": "0x6e553f65...",
      "value": "0",
      "chainId": 5042002
    }
  ],
  "warning": "CALLDATA ONLY — review and sign separately. YieldClaw never executes transactions."
}
```

### scripts/prepare-withdraw.sh

**Args:** `<amount> <receiver_address>`

Returns unsigned calldata for withdrawing. **NEVER EXECUTES.**

**Output:**
```json
{
  "action": "withdraw",
  "amount": "1000000",
  "receiver": "0x1234...",
  "sharesNeeded": "950000",
  "maxWithdraw": "1045200",
  "transaction": {
    "description": "Withdraw USDC from USYC Vault",
    "to": "0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25",
    "data": "0xb460af94...",
    "value": "0",
    "chainId": 5042002
  },
  "warning": "CALLDATA ONLY — review and sign separately. YieldClaw never executes transactions."
}
```

### scripts/get-stream.sh

**Args:** `<stream_id>`

Returns payment stream details.

**Output:**
```json
{
  "streamId": 1,
  "sender": "0x...",
  "recipient": "0x...",
  "token": "0x...",
  "deposit": "1000000",
  "startTime": 1706745600,
  "stopTime": 1709424000,
  "withdrawn": "500000",
  "remaining": "500000",
  "timestamp": "2026-02-05T12:00:00Z"
}
```

### scripts/yield-report.sh

Returns a formatted yield report combining all metrics.

**Output:** Plain text report (not JSON) suitable for posting on Moltbook.

## x402 HTTP API

See [x402-setup.md](x402-setup.md) for full details.

Base URL: `http://localhost:3402`

| Method | Path | Auth | Response |
|--------|------|------|----------|
| GET | `/` | none | Service info |
| GET | `/health` | none | Health check |
| GET | `/yield/apy` | x402 | APY data |
| GET | `/yield/tvl` | x402 | TVL data |
| GET | `/yield/balance/:address` | x402 | Balance data |
| GET | `/yield/stats` | x402 | Protocol stats |
| GET | `/yield/report` | x402 | Full report |
| GET | `/yield/stream/:id` | x402 | Stream data |

## Moltbook Agent API

See [Moltbook skill docs](https://moltbook.com/skill.md) for full API reference.

| Script | Purpose |
|--------|---------|
| `agent/register.sh` | Register YieldClaw on Moltbook |
| `agent/post-report.sh` | Post yield report to m/usyc |
| `agent/interact.sh` | Engage with community posts |
| `agent/submit-hackathon.sh` | Submit to OpenClaw hackathon |
