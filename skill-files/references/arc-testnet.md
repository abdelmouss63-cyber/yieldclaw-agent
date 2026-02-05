# Arc Testnet Reference

## Network Details

| Property | Value |
|----------|-------|
| Network Name | Arc Testnet |
| Chain ID | 5042002 |
| RPC Endpoint | https://rpc.testnet.arc.network |
| Block Explorer | https://testnet.arcscan.io |
| Native Gas Token | USDC |
| Consensus | Proof of Stake |

## Key Characteristics

- **USDC as gas**: Arc uses USDC as the native gas token, eliminating the need for a separate native token
- **Low fees**: Sub-cent transaction costs, ideal for x402 micropayments
- **Fast finality**: Sub-second block confirmation times
- **EVM compatible**: Standard Ethereum tooling works out of the box

## Contract Addresses on Arc Testnet

| Contract | Address |
|----------|---------|
| USYC Vault | `0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25` |
| PaymentStream | `0x1fcb750413067Ba96Ea80B018b304226AB7365C6` |
| USDC | `0x3600000000000000000000000000000000000000` |
| USYC | `0xe9185F0c5F296Ed1797AaE4238D26CCaBEadb86C` |

## RPC Usage

All YieldClaw queries use `eth_call` (read-only). No transaction signing required.

```bash
curl -s -X POST https://rpc.testnet.arc.network \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "eth_call",
    "params": [{
      "to": "CONTRACT_ADDRESS",
      "data": "FUNCTION_SELECTOR_AND_PARAMS"
    }, "latest"],
    "id": 1
  }'
```

## Block Explorer

View contracts and transactions at:
- Vault: `https://testnet.arcscan.io/address/0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25`
- PaymentStream: `https://testnet.arcscan.io/address/0x1fcb750413067Ba96Ea80B018b304226AB7365C6`

## Why Arc for YieldClaw

1. **USDC-native gas**: Agents pay gas in the same token they trade, simplifying economics
2. **Micropayment viable**: Sub-cent gas means x402 queries at $0.001-0.005 are economically rational
3. **EVM standard**: All ERC-4626 and ERC-20 function selectors work identically to Ethereum
4. **Testnet safety**: No real funds at risk during development and hackathon
