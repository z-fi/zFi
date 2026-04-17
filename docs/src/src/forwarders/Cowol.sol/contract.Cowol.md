# Cowol
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/forwarders/Cowol.sol)

CoW Protocol adapter for zFi. Holds sell-side tokens while a CoW
batch-auction order is live and implements ERC-1271 so the CoW
settlement contract can verify the order on-chain.
Unlike the synchronous adapters (Matcha, Parasol, Kyberol), Cowol
holds tokens between deposit and async CoW settlement. To prevent
a third party from approving rogue order digests via the public
SafeExecutor, swap() recomputes the EIP-712 order digest on-chain
and enforces that sellAmount + feeAmount equals the contract's full
token balance (the deposit that snwap just transferred in).


## State Variables
### SAFE_EXECUTOR

```solidity
address constant SAFE_EXECUTOR = 0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db
```


### VAULT_RELAYER

```solidity
address constant VAULT_RELAYER = 0xC92E8bdf79f0507f65a392b0ab4667716BFE0110
```


### ORDER_TYPE_HASH
EIP-712 constants for GPv2Order digest computation.


```solidity
bytes32 constant ORDER_TYPE_HASH = keccak256(
    "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,"
    "uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,"
    "string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)"
)
```


### KIND_SELL

```solidity
bytes32 constant KIND_SELL = keccak256("sell")
```


### BALANCE_ERC20

```solidity
bytes32 constant BALANCE_ERC20 = keccak256("erc20")
```


### DOMAIN_SEPARATOR

```solidity
bytes32 constant DOMAIN_SEPARATOR = 0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943
```


### MAX_EXPIRY

```solidity
uint32 constant MAX_EXPIRY = 1200
```


### validDigests
order digest → approved.


```solidity
mapping(bytes32 => bool) public validDigests
```


### expiry
token → expiry timestamp for recovery.


```solidity
mapping(address => uint32) public expiry
```


### recipient
token → receiver for recovery.


```solidity
mapping(address => address) public recipient
```


## Functions
### swap

Called via SafeExecutor from zRouter.snwap(). Tokens are already
in this contract (transferred by snwap before this call).
Computes the EIP-712 order digest on-chain from the provided
parameters and validates that sellAmount + feeAmount equals this
contract's entire balance of tokenIn (the freshly-deposited amount).


```solidity
function swap(address, address tokenIn, address, address, bytes calldata data) public payable;
```
**Parameters**

|Name|Type|Description|
|----|----|-----------|
|`<none>`|`address`||
|`tokenIn`|`address`||
|`<none>`|`address`||
|`<none>`|`address`||
|`data`|`bytes`|abi.encode(buyToken, receiver, sellAmount, buyAmount, validTo, appData, feeAmount)|


### isValidSignature

ERC-1271 signature validation. GPv2Settlement calls this to
verify that Cowol authorised the order.


```solidity
function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4);
```

### recover

Recover tokens after an order expires unfilled.


```solidity
function recover(address token) external;
```

### receive


```solidity
receive() external payable;
```

