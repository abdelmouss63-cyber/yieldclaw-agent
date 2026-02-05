# Contract Reference

## Network: Arc Testnet

| Property | Value |
|----------|-------|
| Chain ID | 5042002 |
| RPC | https://rpc.testnet.arc.network |
| Explorer | https://testnet.arcscan.io |
| Native Token | USDC (gas token on Arc) |

## Contract Addresses

### USYC Vault (ERC-4626)

**Address:** `0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25`

Standard ERC-4626 tokenized vault for USYC yield-bearing stablecoin.

| Function | Selector | Params | Returns |
|----------|----------|--------|---------|
| `totalAssets()` | `0x01e1d114` | — | uint256 (total USDC) |
| `totalSupply()` | `0x18160ddd` | — | uint256 (total shares) |
| `convertToAssets(uint256)` | `0x07a2d13a` | shares (32B) | uint256 (assets) |
| `convertToShares(uint256)` | `0xc6e6f592` | assets (32B) | uint256 (shares) |
| `balanceOf(address)` | `0x70a08231` | addr (32B padded) | uint256 (shares) |
| `maxDeposit(address)` | `0x402d267d` | addr (32B padded) | uint256 |
| `maxWithdraw(address)` | `0xce96cb77` | addr (32B padded) | uint256 |
| `previewDeposit(uint256)` | `0xef8b30f7` | assets (32B) | uint256 (shares) |
| `previewWithdraw(uint256)` | `0x0a28a477` | assets (32B) | uint256 (shares) |
| `deposit(uint256,address)` | `0x6e553f65` | assets + receiver | uint256 (shares) |
| `withdraw(uint256,address,address)` | `0xb460af94` | assets + receiver + owner | uint256 (shares) |
| `asset()` | `0x38d52e0f` | — | address (underlying) |

### PaymentStream

**Address:** `0x1fcb750413067Ba96Ea80B018b304226AB7365C6`

Streaming payment contract for scheduled yield distributions.

| Function | Selector | Params | Returns |
|----------|----------|--------|---------|
| `getStream(uint256)` | `0xd5a44f86` | streamId (32B) | tuple(address sender, address recipient, address token, uint256 deposit, uint256 startTime, uint256 stopTime, uint256 withdrawn) |

### USDC

**Address:** `0x3600000000000000000000000000000000000000`

Standard ERC-20 stablecoin. Native gas token on Arc.

| Function | Selector | Params | Returns |
|----------|----------|--------|---------|
| `balanceOf(address)` | `0x70a08231` | addr (32B padded) | uint256 |
| `totalSupply()` | `0x18160ddd` | — | uint256 |
| `decimals()` | `0x313ce567` | — | uint8 (6) |
| `approve(address,uint256)` | `0x095ea7b3` | spender + amount | bool |

### USYC Token

**Address:** `0xe9185F0c5F296Ed1797AaE4238D26CCaBEadb86C`

Yield-bearing stablecoin by Hashnote.

| Function | Selector | Params | Returns |
|----------|----------|--------|---------|
| `balanceOf(address)` | `0x70a08231` | addr (32B padded) | uint256 |
| `totalSupply()` | `0x18160ddd` | — | uint256 |
| `decimals()` | `0x313ce567` | — | uint8 |

## ABI Encoding Notes

- Addresses are left-padded with zeros to 32 bytes: `000000000000000000000000` + address (without 0x)
- uint256 values are left-padded with zeros to 32 bytes (64 hex characters)
- Function calls are: `selector (4 bytes)` + `params (32 bytes each)`
- All RPC queries use `eth_call` (read-only, no gas, no signing)

## Example RPC Call

```bash
curl -s -X POST https://rpc.testnet.arc.network \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "eth_call",
    "params": [{
      "to": "0x2f685b5Ef138Ac54F4CB1155A9C5922c5A58eD25",
      "data": "0x01e1d114"
    }, "latest"],
    "id": 1
  }' | jq -r '.result'
```
