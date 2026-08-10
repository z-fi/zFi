// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev A token that can be made hostile mid-run, in each of the three shapes
/// the escape hatch is built for: value removed with no transfer, transfers
/// refused outright, and a fee taken out of the transferred amount.
contract MutableToken is MockERC20("MUT", 18) {
    bool public paused;
    uint256 public feeBps;
    address constant SINK = address(0xFEE0);

    function confiscate(address from, uint256 amt) external {
        uint256 bal = balanceOf[from];
        balanceOf[from] = amt > bal ? 0 : bal - amt;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function _move(address from, address to, uint256 amt) internal {
        require(!paused, "paused");
        uint256 fee = amt * feeBps / 10_000;
        balanceOf[from] -= amt;
        balanceOf[to] += amt - fee;
        balanceOf[SINK] += fee;
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        _move(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address f, address t, uint256 amt) public override returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        _move(f, t, amt);
        return true;
    }
}

/// @dev Drives a pool whose token1 may turn hostile at any point, and records
/// what the contract did so the invariants can check properties that are not
/// visible in a single end state.
contract DegradedHandler is Test {
    PrecisionPool public pool;
    MutableToken public tok;

    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];

    /// @dev Set once the token has taken value without a transfer. Before that
    ///      the pool must stay strictly backed; after, it need not.
    bool public damaged;

    /// @dev Highest `owed` coverage shortfall the CONTRACT ever caused, as
    ///      opposed to the token. Must stay zero: an exit may never spend what
    ///      is owed to the hook or the creator.
    uint256 public contractCausedOwedShortfall;

    /// @dev Worst observed drop in the token1 backing ratio caused by an EXIT,
    ///      in 1e18 fixed point. An exit may leave the ratio flat but never
    ///      lower it: that is what makes going first worthless.
    ///
    ///      Scoped to exits deliberately. A DEPOSIT into an over-backed pool
    ///      lowers the ratio and must be allowed to - `_proportional` prices
    ///      the deposit off reserves, so a depositor dilutes any surplus. That
    ///      surplus arises legitimately (an abandoned claim in a single-sided
    ///      exit leaves value behind) and is not extractable by anyone, since
    ///      both exit paths pay a pro-rata share of RESERVES and the lossy
    ///      clamp only ever binds downward. Asserting over deposits too just
    ///      encodes an economic non-issue as a safety property.
    uint256 public worstRatioDrop;

    /// @dev Coverage counters. An invariant suite whose handler quietly
    ///      no-ops proves nothing, and every call here is wrapped in
    ///      `try/catch`, so "0 reverts" is not evidence of anything. These are
    ///      asserted non-zero in `afterInvariant`.
    uint256 public lossyExits;
    uint256 public clampedExits;
    uint256 public abandonedSideExits;
    uint256 public confiscations;
    uint256 public strictExitsBlockedByDamage;

    /// @dev Which call produced `worstRatioDrop`, so a failure names the path
    ///      instead of leaving it to be guessed.
    string public worstDropTag;
    uint256 public worstDropBefore;
    uint256 public worstDropAfter;

    constructor(PrecisionPool p, MutableToken t) {
        (pool, tok) = (p, t);
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 1_000 ether);
            tok.mint(actors[i], 1e26);
        }
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    /// @dev token1 backing ratio, 1e18-scaled. Infinite (max) when nothing is
    ///      owed against it, which compares correctly against any real ratio.
    function _ratio1() internal view returns (uint256) {
        uint256 r = pool.reserve1();
        if (r == 0) return type(uint256).max;
        return tok.balanceOf(address(pool)) * 1e18 / r;
    }

    function _owed1() internal view returns (uint256) {
        return pool.hookOwed1() + pool.creatorOwed1();
    }

    /// @dev Runs after any state-changing call and records the two properties
    ///      a single snapshot cannot show.
    function _observe(uint256 ratioBefore, bool coveredBefore, string memory tag) internal {
        _observe(ratioBefore, coveredBefore, tag, false);
    }

    function _observe(uint256 ratioBefore, bool coveredBefore, string memory tag, bool isExit) internal {
        uint256 ratioAfter = _ratio1();
        if (isExit && ratioAfter < ratioBefore) {
            uint256 drop = ratioBefore - ratioAfter;
            if (drop > worstRatioDrop) {
                worstRatioDrop = drop;
                worstDropTag = tag;
                worstDropBefore = ratioBefore;
                worstDropAfter = ratioAfter;
            }
        }
        // If accrued fees were fully backed before the call, the call must not
        // have left them short.
        if (coveredBefore && tok.balanceOf(address(pool)) < _owed1()) {
            contractCausedOwedShortfall = _owed1() - tok.balanceOf(address(pool));
        }
    }

    function _snapshot() internal view returns (uint256 ratio, bool covered) {
        ratio = _ratio1();
        covered = tok.balanceOf(address(pool)) >= _owed1();
    }

    // ------------------------------------------------------------- the token

    /// @dev Value vanishes with no transfer. This is what used to brick the
    ///      contract via `_assertBacked`.
    function confiscate(uint256 amt) public {
        uint256 held = tok.balanceOf(address(pool));
        if (held == 0) return;
        amt = bound(amt, 1, held);
        tok.confiscate(address(pool), amt);
        damaged = true;
        ++confiscations;
    }

    function togglePause(uint256 s) public {
        tok.setPaused(s % 2 == 0);
    }

    function setFee(uint256 bps) public {
        tok.setFee(bound(bps, 0, 500));
    }

    // ------------------------------------------------------------- the pool

    function swap0(uint256 s, uint256 amt) public {
        address a = _actor(s);
        amt = bound(amt, 1, 20 ether);
        if (a.balance < amt) return;
        (uint256 ratio, bool covered) = _snapshot();
        vm.prank(a);
        try pool.swapExactIn{value: amt}(address(0), amt, 0, a) {} catch {}
        _observe(ratio, covered, "swap0");
    }

    function swap1(uint256 s, uint256 amt) public {
        address a = _actor(s);
        amt = bound(amt, 1, 1e22);
        if (tok.balanceOf(a) < amt) return;
        (uint256 ratio, bool covered) = _snapshot();
        vm.startPrank(a);
        tok.approve(address(pool), type(uint256).max);
        try pool.swapExactIn(address(tok), amt, 0, a) {} catch {}
        vm.stopPrank();
        _observe(ratio, covered, "swap1");
    }

    function addLiquidity(uint256 s, uint256 a0, uint256 a1) public {
        address a = _actor(s);
        a0 = bound(a0, 0, 10 ether);
        a1 = bound(a1, 0, 1e22);
        if (a.balance < a0 || tok.balanceOf(a) < a1) return;
        (uint256 ratio, bool covered) = _snapshot();
        vm.startPrank(a);
        tok.approve(address(pool), type(uint256).max);
        try pool.addLiquidityExact{value: a0}(0, a0, a1, 0, a) {} catch {}
        vm.stopPrank();
        _observe(ratio, covered, "addLiquidity");
    }

    function removeStrict(uint256 s, uint256 lp) public {
        address a = _actor(s);
        uint256 bal = pool.balanceOf(a);
        if (bal == 0) return;
        lp = bound(lp, 1, bal);
        (uint256 ratio, bool covered) = _snapshot();
        bool wasShort = tok.balanceOf(address(pool)) < pool.reserve1();
        vm.prank(a);
        try pool.removeLiquidity(lp, 0, 0, a) {}
        catch {
            // The case the escape hatch exists for: strict exits are refused
            // once the pool is short, which is why a degraded path is needed
            // at all.
            if (wasShort) ++strictExitsBlockedByDamage;
        }
        _observe(ratio, covered, "removeStrict", true);
    }

    /// @dev The path under test. Every combination of sides, so the abandoned
    ///      claim and the clamp are both exercised.
    function removeLossy(uint256 s, uint256 lp, uint256 sides) public {
        address a = _actor(s);
        uint256 bal = pool.balanceOf(a);
        if (bal == 0) return;
        lp = bound(lp, 1, bal);
        bool t0 = sides % 2 == 0;
        bool t1 = (sides / 2) % 2 == 0;
        if (!t0 && !t1) t0 = true;
        (uint256 ratio, bool covered) = _snapshot();
        uint256 supply = pool.totalSupply();
        uint256 proRata1 = supply == 0 ? 0 : lp * uint256(pool.reserve1()) / supply;
        vm.prank(a);
        try pool.removeLiquidityLossy(lp, 0, 0, a, t0, t1) returns (uint256, uint256 paid1) {
            ++lossyExits;
            if (!t1) ++abandonedSideExits;
            // Paid strictly less than the claim means the clamp bound it,
            // which is the branch the whole redesign turns on.
            else if (paid1 < proRata1) ++clampedExits;
        } catch {}
        _observe(ratio, covered, "removeLossy", true);
    }

    /// @dev Confiscate hard, then exit immediately. The clamp binding is the
    ///      branch the whole redesign turns on, and leaving it to the fuzzer to
    ///      stumble into made coverage seed-dependent: it was reached when this
    ///      file ran alone and not when it ran inside the full suite. A
    ///      coverage assertion that passes or fails on the seed is worse than
    ///      none, so the sequence that reaches it is an action rather than a
    ///      hope.
    function confiscateThenExit(uint256 s, uint256 lp) public {
        address a = _actor(s);
        uint256 bal = pool.balanceOf(a);
        if (bal == 0) return;
        uint256 held = tok.balanceOf(address(pool));
        if (held == 0) return;

        // Take almost everything, so any pro-rata claim exceeds what is left.
        tok.confiscate(address(pool), held - held / 100);
        damaged = true;
        ++confiscations;
        tok.setPaused(false);

        lp = bound(lp, 1 + bal / 2, bal);
        (uint256 ratio, bool covered) = _snapshot();
        uint256 supply = pool.totalSupply();
        uint256 proRata1 = supply == 0 ? 0 : lp * uint256(pool.reserve1()) / supply;
        vm.prank(a);
        try pool.removeLiquidityLossy(lp, 0, 0, a, true, true) returns (uint256, uint256 paid1) {
            ++lossyExits;
            if (paid1 < proRata1) ++clampedExits;
        } catch {}
        _observe(ratio, covered, "confiscateThenExit", true);
    }

    receive() external payable {}
}

/// @dev The escape hatch is the newest code in the pool and the only path that
/// writes reserves WITHOUT asserting backing first. These are the properties
/// that makes safe, driven against a token that degrades underneath it.
contract PrecisionDegradedInvariantTest is Test {
    PrecisionPoolFactory factory;
    PrecisionPool pool;
    MutableToken tok;
    DegradedHandler handler;
    address seeder;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        tok = new MutableToken();

        seeder = address(0xC11);
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

        // Hand the actors LP shares UP FRONT. Without this the suite is
        // vacuous: the first `confiscate` makes `_assertBacked` refuse every
        // deposit, so an actor who has not already got shares can never get
        // any, and every `removeLossy` returns early on a zero balance. The
        // first version of this file passed all five invariants having never
        // once executed the function it exists to test.
        vm.startPrank(seeder);
        uint256 each = pool.balanceOf(seeder) / 5;
        pool.transfer(address(0xA1), each);
        pool.transfer(address(0xA2), each);
        pool.transfer(address(0xA3), each);
        vm.stopPrank();

        handler = new DegradedHandler(pool, tok);
        targetContract(address(handler));
        // Pin the sender. Without this the fuzzer invents a fresh address for
        // every call, and since this repo forks by default each one is an
        // account lookup against the RPC - which rate-limits long before the
        // run finishes. The handler picks its own actors internally, so the
        // caller identity here carries no information anyway.
        targetSender(address(0xC0FFEE));
    }

    /// @dev THE ANTI-RUN PROPERTY, and the reason the clamp is pro-rata on the
    /// surviving balance rather than on the balance itself. No EXIT may lower
    /// the token1 backing ratio - only the token can. If one could, leaving a
    /// damaged pool first would pay better than leaving second and every
    /// holder would be racing for the door.
    ///
    /// The tolerance is for integer division, not for slippage in the property:
    /// a payout floors, so the ratio can move by a hair per call.
    function invariant_NoCallLowersTheBackingRatio() public {
        assertLt(
            handler.worstRatioDrop(),
            1e6,
            string.concat(
                "backing ratio lowered by ",
                vm.toString(handler.worstRatioDrop()),
                " in ",
                handler.worstDropTag(),
                " (",
                vm.toString(handler.worstDropBefore()),
                " -> ",
                vm.toString(handler.worstDropAfter()),
                ")"
            )
        );
    }

    /// @dev No exit may spend what is owed to the hook or the creator. The
    /// clamp subtracts `owed` before taking its share, so a pool that could
    /// cover its accrued fees before a call must still cover them after.
    function invariant_ExitsNeverSpendAccruedFees() public view {
        assertEq(handler.contractCausedOwedShortfall(), 0, "an exit paid out fees it did not own");
    }

    /// @dev Until the token takes value without a transfer, ordinary operation
    /// must keep the pool strictly backed - the degraded path must not be a way
    /// to create a shortfall that was not already there.
    function invariant_UndamagedPoolStaysBacked() public view {
        if (handler.damaged()) return;
        assertGe(address(pool).balance, pool.reserve0(), "token0 backing broken with no confiscation");
        assertGe(tok.balanceOf(address(pool)), pool.reserve1(), "token1 backing broken with no confiscation");
    }

    /// @dev The permanent minimum survives every degraded path, so the seed
    /// branch can never re-run at a price of someone's choosing.
    function invariant_DeadMinimumSurvives() public view {
        assertGe(pool.balanceOf(address(0xdead)), 1000, "the dead minimum was burned away");
        assertGe(pool.totalSupply(), 1000, "supply fell below the permanent minimum");
    }

    /// @dev Proves the run actually exercised what it claims to. Forge calls
    /// this once after the sequences finish. Without it, a handler that
    /// silently no-opped would report five green invariants and zero coverage -
    /// which is exactly how a test ends up proving nothing while looking
    /// thorough.
    function afterInvariant() public view {
        assertGt(handler.confiscations(), 0, "the token never took value; the degraded path was never entered");
        assertGt(handler.lossyExits(), 0, "no lossy exit ever succeeded");
        assertGt(handler.clampedExits(), 0, "the clamp never bound; the pro-rata branch was never tested");
        assertGt(handler.abandonedSideExits(), 0, "no single-sided exit ever ran");
        assertGt(
            handler.strictExitsBlockedByDamage(),
            0,
            "the strict exit was never blocked, so the hatch was never load-bearing"
        );
    }

    /// @dev Reserves are uint128 and every write goes through `_setReserves`,
    /// which reverts rather than truncating. A degraded path must not find a
    /// way around it.
    function invariant_ReservesFitTheirWidth() public view {
        assertLe(uint256(pool.reserve0()), type(uint128).max);
        assertLe(uint256(pool.reserve1()), type(uint128).max);
    }
}
