# IPermit2
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/zRouter.sol)


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

