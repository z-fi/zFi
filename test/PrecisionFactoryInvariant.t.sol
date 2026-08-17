// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Stands in for the zRouter executor. The real one is 252 bytes, has one
/// selector, no storage, and bubbles every revert - verified on-chain, see
/// deploy/Precision.md. This mirrors the property the factory's safety argument
/// actually depends on: a failed settlement takes the transaction down rather
/// than being swallowed.
contract BubblingExecutor {
    function exec(address target, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call{value: msg.value}(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}

/// @dev A token that hands control back mid-transfer, so the funding interval
/// between `checkpoint` and settlement is genuinely reachable.
contract HookedToken is MockERC20("HOOK", 18) {
    address public target;
    bytes public payload;
    bool public armed;
    uint256 public reenteredCount;

    function arm(address t, bytes calldata p) external {
        target = t;
        payload = p;
        armed = true;
    }

    function disarm() external {
        armed = false;
    }

    function _cb() internal {
        if (!armed) return;
        armed = false; // one shot per arming
        ++reenteredCount;
        (bool ok,) = target.call(payload);
        ok; // outcome is the test's business, not the token's
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        bool r = super.transfer(to, amt);
        _cb();
        return r;
    }

    function transferFrom(address f, address t, uint256 amt) public override returns (bool) {
        bool r = super.transferFrom(f, t, amt);
        _cb();
        return r;
    }
}

/// @dev Drives the prefunded-route lifecycle the way the executor does, with a
/// token that can re-enter at every transfer.
contract FactoryHandler is Test {
    PrecisionPoolFactory public factory;
    PrecisionPool public pool;
    HookedToken public tok;
    BubblingExecutor public exec;

    address constant PAYER = address(0xA11CE);

    /// @dev Baseline of tokens sitting in the factory that no route may ever
    ///      touch. `checkpoint` snapshots `balanceOf(this)`, so anything here
    ///      before a route opens is structurally unreachable.
    uint256 public strandedBaseline;

    /// @dev The factory's ETH at construction. Not necessarily zero: these
    ///      tests run against a fork, and a nonce-derived deployment address
    ///      can collide with a funded mainnet account - the first version of
    ///      this file asserted an absolute zero and tripped over exactly that.
    ///      The property is that the factory never ACCUMULATES, so the baseline
    ///      is what it must stay at.
    uint256 public ethBaseline;

    /// @dev Worst observed violation of "a settlement moves exactly what it
    ///      declared". Any nonzero value is a broken factory→pool invariant.
    uint256 public declaredVsMovedMismatch;

    /// @dev Settlements that actually completed, so the suite can prove it
    ///      exercised the path rather than reverting through every sequence.
    uint256 public settlements;
    uint256 public aborts;
    uint256 public reentrantAttempts;

    constructor(PrecisionPoolFactory f, PrecisionPool p, HookedToken t, BubblingExecutor e) {
        (factory, pool, tok, exec) = (f, p, t, e);
        tok.mint(PAYER, 1e26);
        vm.deal(PAYER, 1_000 ether);
        // Strand some tokens in the factory up front. Nothing may ever spend
        // these; they are the "stuck but never stealable" case.
        tok.mint(address(factory), 5e18);
        strandedBaseline = 5e18;
        ethBaseline = address(factory).balance;
    }

    function _route(uint256 amountIn) internal view returns (PrecisionPoolFactory.Route memory r) {
        r = PrecisionPoolFactory.Route({
            pool: address(pool),
            originator: PAYER,
            tokenIn: address(tok),
            amountIn: amountIn,
            minOut: 0,
            to: PAYER,
            refundTo: PAYER
        });
    }

    /// @dev The full happy path: checkpoint, fund, settle. The token may
    ///      re-enter during the funding transfer.
    function settle(uint256 amountIn, bool arm) public {
        amountIn = bound(amountIn, 1e12, 1e22);
        if (tok.balanceOf(PAYER) < amountIn) return;
        PrecisionPoolFactory.Route memory r = _route(amountIn);

        try exec.exec(address(factory), abi.encodeCall(PrecisionPoolFactory.checkpoint, (r))) {}
        catch {
            return;
        }

        if (arm) {
            // Try to settle the SAME route from inside the funding transfer.
            ++reentrantAttempts;
            tok.arm(
                address(exec),
                abi.encodeCall(
                    BubblingExecutor.exec,
                    (address(factory), abi.encodeCall(PrecisionPoolFactory.executePrefundedSwap, (r)))
                )
            );
        }

        uint256 poolBefore = tok.balanceOf(address(pool));
        vm.prank(PAYER);
        tok.transfer(address(factory), amountIn);
        tok.disarm();

        try exec.exec(address(factory), abi.encodeCall(PrecisionPoolFactory.executePrefundedSwap, (r))) {
            ++settlements;
            // Exactly the declared amount reached the pool.
            uint256 moved = tok.balanceOf(address(pool)) - poolBefore;
            if (moved != amountIn) {
                uint256 d = moved > amountIn ? moved - amountIn : amountIn - moved;
                if (d > declaredVsMovedMismatch) declaredVsMovedMismatch = d;
            }
        } catch {
            // Failed settlement must leave the funding recoverable, not eaten.
            try exec.exec(address(factory), abi.encodeCall(PrecisionPoolFactory.abortCheckpoint, (r))) {
                ++aborts;
            } catch {}
        }
    }

    /// @dev Checkpoint, fund, then abort instead of settling.
    function abortRoute(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 1e22);
        if (tok.balanceOf(PAYER) < amountIn) return;
        PrecisionPoolFactory.Route memory r = _route(amountIn);
        try exec.exec(address(factory), abi.encodeCall(PrecisionPoolFactory.checkpoint, (r))) {}
        catch {
            return;
        }
        vm.prank(PAYER);
        tok.transfer(address(factory), amountIn);
        try exec.exec(address(factory), abi.encodeCall(PrecisionPoolFactory.abortCheckpoint, (r))) {
            ++aborts;
        } catch {}
    }

    /// @dev Settlement with no checkpoint at all, which must never move funds.
    function settleUnfunded(uint256 amountIn) public {
        amountIn = bound(amountIn, 1, 1e22);
        PrecisionPoolFactory.Route memory r = _route(amountIn);
        try exec.exec(address(factory), abi.encodeCall(PrecisionPoolFactory.executePrefundedSwap, (r))) {
            ++settlements;
        } catch {}
    }

    receive() external payable {}
}

/// @dev The two properties the factory's safety actually rests on, which the
/// audit asked for as invariants rather than unit tests.
contract PrecisionFactoryInvariantTest is Test {
    PrecisionPoolFactory factory;
    PrecisionPool pool;
    HookedToken tok;
    BubblingExecutor exec;
    FactoryHandler handler;

    function setUp() public {
        exec = new BubblingExecutor();
        factory = new PrecisionPoolFactory(address(exec), type(PrecisionPool).creationCode);
        tok = new HookedToken();

        address seeder = address(0xC11);
        tok.mint(seeder, 1e26);
        vm.deal(seeder, 10_000 ether);
        vm.startPrank(seeder);
        tok.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 500 ether}(
            PrecisionPoolFactory.Market({
                token0: address(0),
                token1: address(tok),
                sqrtPLow: 0.5e18,
                sqrtPHigh: 2e18,
                fee: 500,
                hook: address(0),
                feeRecipient: address(0),
                creatorFeeBps: 0
            }),
            1e18, 500 ether, 1e24, 0, seeder
        );
        vm.stopPrank();
        pool = PrecisionPool(payable(p));

        handler = new FactoryHandler(factory, pool, tok, exec);
        targetContract(address(handler));
        targetSender(address(0xC0FFEE));
    }

    /// @dev THE FACTORY IS NOT AN ESCROW. Whatever was stranded in it before a
    /// route opened is still there afterwards, and no route ever leaves its own
    /// funding behind. `checkpoint` snapshots the balance and every settlement
    /// spends only the delta since, so the factory's holdings can never fall
    /// below the baseline and can never grow across a completed operation.
    function invariant_FactoryRetainsExactlyItsStrandedBaseline() public view {
        assertEq(
            tok.balanceOf(address(factory)),
            handler.strandedBaseline(),
            "factory holdings moved; a route either ate stranded tokens or left its own funding"
        );
    }

    /// @dev The factory has no `receive`/`fallback`, so native value can only
    /// arrive with a call and must be forwarded within it.
    function invariant_FactoryNeverAccumulatesEth() public view {
        assertEq(address(factory).balance, handler.ethBaseline(), "factory accumulated ETH across a route");
    }

    /// @dev DECLARED EQUALS FORWARDED - the invariant the pool's own NatSpec
    /// defers upstream, and the reason `swapFromFactory` can trust an amount it
    /// did not pull. Every completed settlement moved exactly what it declared.
    function invariant_EverySettlementMovedWhatItDeclared() public view {
        assertEq(
            handler.declaredVsMovedMismatch(),
            0,
            "a settlement moved a different amount than it declared to the pool"
        );
    }

    /// @dev Proves the run exercised the paths rather than reverting through
    /// every sequence, which would make the three invariants above vacuous.
    function afterInvariant() public view {
        assertGt(handler.settlements(), 0, "no settlement ever completed");
        assertGt(handler.reentrantAttempts(), 0, "the reentrant path was never attempted");
    }
}
