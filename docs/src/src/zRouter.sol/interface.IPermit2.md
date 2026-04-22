# IPermit2
[Git Source](https://github.com/zammdefi/zFi/blob/a562385b5b1c1f70a26241aeea9f4ab1325a5917/src/zRouter.sol)


## Functions
### permitTransferFrom


```solidity
function permitTransferFrom(
    PermitTransferFrom calldata permit,
    SignatureTransferDetails calldata transferDetails,
    address owner,
    bytes calldata signature
) external;
```

### permitBatchTransferFrom


```solidity
function permitBatchTransferFrom(
    PermitBatchTransferFrom calldata permit,
    SignatureTransferDetails[] calldata transferDetails,
    address owner,
    bytes calldata signature
) external;
```

## Structs
### TokenPermissions

```solidity
struct TokenPermissions {
    address token;
    uint256 amount;
}
```

### PermitTransferFrom

```solidity
struct PermitTransferFrom {
    TokenPermissions permitted;
    uint256 nonce;
    uint256 deadline;
}
```

### PermitBatchTransferFrom

```solidity
struct PermitBatchTransferFrom {
    TokenPermissions[] permitted;
    uint256 nonce;
    uint256 deadline;
}
```

### SignatureTransferDetails

```solidity
struct SignatureTransferDetails {
    address to;
    uint256 requestedAmount;
}
```

