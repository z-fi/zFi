# CollectorVault
[Git Source](https://github.com/zammdefi/zFi/blob/6183adaa9032e920e34fd7d86cacdbe7b6a9d306/src/dao/CollectorVault.sol)

**Title:**
CollectorVault - Reusable collector DAO vault (clone-compatible)

Two modes:
Mode 0 (Fixed Call): Accumulates ETH, anyone calls execute() to fire a
preconfigured call `quantity` times. Tracks callsMade vs maxCalls.
Mode 1 (Token Fill): Open bid — ETH accumulates, anyone calls fill() to
deliver a token/NFT (via transferFrom) and claim all ETH. One-shot.
Share burning is handled by the ShareBurner singleton (separate contract).
The factory wires a permit at deploy time so anyone can call
ShareBurner.closeSale(dao, shares, deadline, nonce) after the deadline.
Deployed as minimal proxy clones via CollectorVaultFactory.


## State Variables
### DAICO

```solidity
address constant DAICO = 0x000000000033e92DB97B4B3beCD2c255126C60aC
```


### mode

```solidity
uint8 public mode
```


### dao

```solidity
address public dao
```


### deadline

```solidity
uint256 public deadline
```


### target

```solidity
address public target
```


### ethPerCall

```solidity
uint256 public ethPerCall
```


### maxCalls

```solidity
uint256 public maxCalls
```


### token

```solidity
address public token
```


### minBalance

```solidity
uint256 public minBalance
```


### specificId

```solidity
bool public specificId
```


### shares

```solidity
address public shares
```


### shareRate

```solidity
uint256 public shareRate
```


### _callData

```solidity
bytes _callData
```


### callsMade

```solidity
uint256 public callsMade
```


### filled

```solidity
bool public filled
```


### _REENTRANCY_GUARD_SLOT

```solidity
uint256 constant _REENTRANCY_GUARD_SLOT = 0x929eee149b4bd21268
```


## Functions
### constructor


```solidity
constructor() ;
```

### nonReentrant


```solidity
modifier nonReentrant() ;
```

### init


```solidity
function init(
    uint8 _mode,
    address _dao,
    uint256 _deadline,
    address _target,
    uint256 _ethPerCall,
    uint256 _maxCalls,
    bytes calldata _payload,
    address _token,
    uint256 _minBalance,
    bool _specificId,
    address _shares,
    uint256 _shareRate
) public payable;
```

### execute

Fire the preconfigured call `quantity` times.


```solidity
function execute(uint256 quantity) public nonReentrant;
```

### executeFromTap

Claim DAICO tap then execute (Mode 0 only).


```solidity
function executeFromTap(uint256 quantity) public nonReentrant;
```

### _execute


```solidity
function _execute(uint256 quantity) internal;
```

### executable

How many calls can be made from current balance.


```solidity
function executable() public view returns (uint256);
```

### executableFromTap

How many calls can be made including claimable tap.


```solidity
function executableFromTap() public view returns (uint256);
```

### fill

Deliver token/NFT, claim all ETH. Caller must have approved this contract.


```solidity
function fill() public nonReentrant;
```

### isFilled

Whether the token condition has been met.


```solidity
function isFilled() public view returns (bool);
```

### claimTap

Claim vested tap from DAICO factory.


```solidity
function claimTap() public returns (uint256 claimed);
```

### claimableTap

View claimable tap amount.


```solidity
function claimableTap() public view returns (uint256);
```

### buy

Buy shares with ETH (only when shareRate != 0).
ETH stays in vault to fund calls/fills. Remainder goes to DAO via clawback.
Disabled after deadline, when all calls are spent, or after fill.


```solidity
function buy() public payable nonReentrant;
```

### clawback

Send remaining ETH to DAO. Permissionless after deadline, when all
calls are spent, or after fill. Otherwise DAO-only.


```solidity
function clawback() public nonReentrant;
```

### receive


```solidity
receive() external payable;
```

### onERC721Received


```solidity
function onERC721Received(address, address, uint256, bytes calldata) public pure returns (bytes4);
```

## Events
### Executed

```solidity
event Executed(uint256 quantity, uint256 ethSpent);
```

### Filled

```solidity
event Filled(address indexed caller, uint256 ethPaid);
```

### Clawback

```solidity
event Clawback(uint256 amount);
```

### TapClaimed

```solidity
event TapClaimed(uint256 amount);
```

### Buy

```solidity
event Buy(address indexed buyer, uint256 ethPaid, uint256 sharesAmount);
```

## Errors
### WrongMode

```solidity
error WrongMode();
```

### NoFunds

```solidity
error NoFunds();
```

### MaxReached

```solidity
error MaxReached();
```

### AlreadyFilled

```solidity
error AlreadyFilled();
```

### NotDAO

```solidity
error NotDAO();
```

### BadQuantity

```solidity
error BadQuantity();
```

### AlreadyInitialized

```solidity
error AlreadyInitialized();
```

### BuyDisabled

```solidity
error BuyDisabled();
```

