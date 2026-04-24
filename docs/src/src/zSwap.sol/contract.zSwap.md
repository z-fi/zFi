# zSwap
[Git Source](https://github.com/zammdefi/zFi/blob/89402c36d8f5e171a084bcf805fdd36cce1574e2/src/zSwap.sol)

**Title:**
zSwap v0.1

Permanently-deployed onchain HTML swap dapp for Ethereum mainnet.

Architecture: the HTML payload (24549 B) is the runtime bytecode of
a separate data contract created at construction. html() returns it
via EXTCODECOPY with proper ABI encoding (offset + length + padded
data) so any RPC client decodes directly. request() implements
ERC-5219 for first-class web3:// gateway compatibility (ERC-4804).
Wrapper runtime stays small while the dapp fits under EIP-170
(24576 B cap, 27 B headroom).
HOW TO READ THE DAPP
cast call <addr> "html()(string)" --rpc-url <rpc> > zSwap.html
# then open zSwap.html in any browser
HOW TO BROWSE THE DAPP
- Via an ERC-4804 web3:// HTTP gateway, e.g.:
https://<addr>.1.w3link.io/
- Via a wallet/browser with web3:// protocol support (e.g. the
Web3URL Browser Extension on Chrome/Firefox/Brave).
- Or via the "HOW TO READ THE DAPP" path above.
HOW TO REGENERATE FROM zSwap.html
node script/build-zSwap.mjs       (re-encodes payload, source comment, and sizes)
forge test --match-path test/zSwap.t.sol
HOW TO USE THE DAPP (in browser)
1. Connect a wallet (MetaMask, Rabby, etc.) on Ethereum mainnet.
2. Pick "from" and "to" tokens; type an amount in either field.
3. Review the rate line: rate, source DEX, and Min received / Max paid.
4. Click Swap. ERC-20 inputs trigger an exact-amount approval first.


## State Variables
### NAME

```solidity
string public constant NAME = "zSwap"
```


### VERSION

```solidity
string public constant VERSION = "0.1"
```


### DATA

```solidity
address public immutable DATA
```


## Functions
### constructor


```solidity
constructor() payable;
```

### html


```solidity
function html() external view returns (string memory);
```

### request

ERC-5219 request handler. Returns the HTML for any path with
`Content-Type: text/html` and a permanent cache hint (the
response is byte-identical forever since the bytecode is
immutable). Path/query params are ignored — the dapp is a
single-page app served from any URL on this contract.


```solidity
function request(
    string[] memory,
    /*resource*/
    KeyValue[] memory /*params*/
)
    external
    view
    returns (uint16 statusCode, string memory body, KeyValue[] memory headers);
```

### resolveMode

ERC-4804/5219 resolution mode. Returns bytes32("5219") to
signal that web3:// gateways should call request() per the
ERC-5219 interface (rather than auto-mode URL→function-call
resolution or legacy "manual" fallback dispatch).


```solidity
function resolveMode() external pure returns (bytes32);
```

### _html


```solidity
function _html() private view returns (string memory s);
```

## Structs
### KeyValue

```solidity
struct KeyValue {
    string key;
    string value;
}
```

