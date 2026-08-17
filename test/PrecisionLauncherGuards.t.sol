// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {LaunchToken, PrecisionLauncher} from "../src/pools/PrecisionLauncher.sol";

/// @dev The argument guards and the slippage bound.
///
/// These exist because an audit of the suite found every one of the eleven
/// `redeem` call sites passing `minEthOut = 0` — so the launcher's ONLY
/// user-facing protection had never once executed. A guard that is never
/// exercised is indistinguishable from a guard that does not work, and this is
/// the sort of gap a suite full of economic property tests hides especially
/// well: the interesting assertions were all about the floor, and nobody was
/// checking the door handles.
contract PrecisionLauncherGuardsTest is Test {
    PrecisionPoolFactory factory;
    PrecisionLauncher launcher;

    address creator = address(0xC0FFEE);
    address treasury = address(0x7EA);
    address alice = address(0xA11CE);

    uint256 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        launcher = new PrecisionLauncher(factory, treasury);
        vm.deal(alice, 1_000 ether);
    }

    function _live() internal returns (LaunchToken token, PrecisionPool pool) {
        (address t, address p) = launcher.launch("G", "G", "ipfs://g", SUPPLY, 0, 3 ether, creator);
        (token, pool) = (LaunchToken(t), PrecisionPool(payable(p)));
        vm.prank(alice);
        pool.swapExactIn{value: 30 ether}(address(0), 30 ether, 0, alice);
        vm.prank(alice);
        token.approve(address(launcher), type(uint256).max);
    }

    // --------------------------------------------------------------- SLIPPAGE

    /// The bound must actually bind. Ask for one wei more than the quote pays.
    function testRedeemRespectsMinEthOut() public {
        (LaunchToken token,) = _live();

        uint256 amount = token.balanceOf(alice) / 4;
        uint256 quoted = launcher.quoteRedeem(address(token), amount);
        assertGt(quoted, 0, "nothing to redeem");

        vm.prank(alice);
        vm.expectRevert(PrecisionLauncher.Slippage.selector);
        launcher.redeem(address(token), amount, quoted + 1, alice);

        // And must not bind one wei early: the quote is exactly achievable.
        vm.prank(alice);
        uint256 got = launcher.redeem(address(token), amount, quoted, alice);
        assertEq(got, quoted, "quote did not settle at the quoted amount");
    }

    /// A redemption that would pay nothing must revert rather than burn tokens
    /// for free. This is the one that matters: the burn happens BEFORE the
    /// payout check in program order, so a missing guard here is a token
    /// incinerator.
    function testRedeemPayingNothingRevertsAndBurnsNothing() public {
        (address t, address p) = launcher.launch("Z", "Z", "", SUPPLY, 1_000, 3 ether, creator);
        LaunchToken token = LaunchToken(t);

        // No buy yet, so the position holds no ETH at all.
        assertEq(PrecisionPool(payable(p)).reserve0(), 0);
        uint256 supplyBefore = token.totalSupply();
        uint256 balBefore = token.balanceOf(creator);

        vm.startPrank(creator);
        token.approve(address(launcher), type(uint256).max);
        vm.expectRevert();
        launcher.redeem(t, balBefore, 0, creator);
        vm.stopPrank();

        assertEq(token.totalSupply(), supplyBefore, "tokens burned for a zero payout");
        assertEq(token.balanceOf(creator), balBefore, "caller's tokens were taken");
    }

    // -------------------------------------------------------------- ARGUMENTS

    function testRedeemRejectsBadArguments() public {
        (LaunchToken token,) = _live();
        uint256 amount = token.balanceOf(alice) / 8;

        vm.startPrank(alice);

        vm.expectRevert(PrecisionLauncher.NoToken.selector);
        launcher.redeem(address(0xDEAD), amount, 0, alice);

        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.redeem(address(token), amount, 0, address(0));

        vm.expectRevert(PrecisionLauncher.Bad.selector);
        launcher.redeem(address(token), 0, 0, alice);

        vm.stopPrank();
    }

    /// A recipient that cannot take ETH must fail the caller's own redemption
    /// and nothing else - `to` is the caller's choice, so this reverts rather
    /// than being forced. Contrast `collectFees`, where the destination is not
    /// chosen per call and therefore IS forced.
    function testRedeemToAHostileRecipientRevertsWithoutSideEffects() public {
        (LaunchToken token,) = _live();
        address hostile = address(new Rejector());

        uint256 supplyBefore = token.totalSupply();
        uint256 balBefore = token.balanceOf(alice);
        uint256 amount = balBefore / 4;

        vm.prank(alice);
        vm.expectRevert();
        launcher.redeem(address(token), amount, 0, hostile);

        assertEq(token.totalSupply(), supplyBefore, "supply moved on a reverted redemption");
        assertEq(token.balanceOf(alice), balBefore, "tokens taken on a reverted redemption");
    }

    /// The guard must actually catch a REENTRANT recipient, not merely a
    /// reverting one.
    ///
    /// `Rejector` above tests the revert path. It does not test the guard: §4.6
    /// of the brief asks specifically about ordering around the callouts, and
    /// `redeem` hands control to an arbitrary `to` with all the gas. Nothing
    /// demonstrated that `nonReentrant` held there - the guard was assumed, and
    /// an assumed guard is the same thing as an untested one.
    ///
    /// The recipient SWALLOWS the failed reentry rather than propagating it, so
    /// the outer redemption succeeds and the assertion is about the guard alone.
    /// Letting the revert propagate would have made this indistinguishable from
    /// `Rejector` above - the outer call would fail either way, and a test that
    /// cannot tell "the guard refused" from "the recipient threw" is not
    /// testing the guard. `tried` and `reenteredOk` separate the two: the
    /// fallback must have RUN, and its reentry must have FAILED.
    function testReentrantRecipientCannotReenterRedeem() public {
        (LaunchToken token,) = _live();
        Reenterer hostile = new Reenterer(launcher, token);

        uint256 amount = token.balanceOf(alice) / 4;

        vm.prank(alice);
        uint256 got = launcher.redeem(address(token), amount, 0, address(hostile));

        assertGt(got, 0, "the redemption paid nothing");
        assertTrue(hostile.tried(), "the recipient never got to attempt reentry");
        assertFalse(hostile.reenteredOk(), "REENTRANCY: the guard let a recipient back in");
        assertEq(address(hostile).balance, got, "payout did not land");
    }

    /// The other entry point that hands control out: `collectFees` force-pays
    /// the creator, and a forced payment still runs the recipient's code. Here
    /// the sweep must SURVIVE - that is the whole point of forcing - so a
    /// reentrant creator changes nothing about the outcome.
    ///
    /// Deliberately NOT asserting `tried` here. `forceSafeTransferETH` hands
    /// over a 100k stipend and, if that call fails for any reason including
    /// out-of-gas, rolls back everything the recipient did before force-sending
    /// anyway - so `tried` is not reliably observable on this path, and
    /// asserting it would make the test flaky rather than strict. The property
    /// that matters is that the money lands and the sweep completes.
    function testReentrantCreatorCannotWedgeCollectFees() public {
        (address t, address p) = launcher.launch("R", "R", "", SUPPLY, 0, 3 ether, creator);
        Reenterer hostile = new Reenterer(launcher, LaunchToken(t));

        vm.prank(creator);
        launcher.setCreator(t, address(hostile));
        hostile.acceptStream(t);

        vm.prank(alice);
        PrecisionPool(payable(p)).swapExactIn{value: 30 ether}(address(0), 30 ether, 0, alice);

        uint256 before = address(hostile).balance;
        (uint256 creatorEth,,,,) = launcher.collectFees(t);

        assertGt(creatorEth, 0, "nothing was paid");
        assertEq(address(hostile).balance - before, creatorEth, "forced payment did not land");

        // And the stream is not wedged: a second sweep still works.
        vm.prank(alice);
        PrecisionPool(payable(p)).swapExactIn{value: 5 ether}(address(0), 5 ether, 0, alice);
        (uint256 again,,,,) = launcher.collectFees(t);
        assertGt(again, 0, "the stream wedged behind a reentrant creator");
    }

    /// Redeeming more than the caller holds must fail at the transfer, not
    /// somewhere stranger.
    ///
    /// The balance is HOISTED, and every other cheatcode call in this file does
    /// the same for the same reason: `vm.prank` and `vm.expectRevert` each arm
    /// exactly one call, and an argument that is itself an external call is
    /// that call. Written inline, `balanceOf` consumes the cheatcode and the
    /// test asserts nothing about `redeem` at all.
    function testRedeemBeyondBalanceReverts() public {
        (LaunchToken token,) = _live();
        uint256 tooMuch = token.balanceOf(alice) + 1;

        vm.prank(alice);
        vm.expectRevert();
        launcher.redeem(address(token), tooMuch, 0, alice);
    }

    // ------------------------------------------------------------- THE TOKEN

    /// A holder burning voluntarily is a gift to everyone else, and the floor
    /// must actually register it.
    function testVoluntaryBurnRaisesTheFloorForEveryoneElse() public {
        (LaunchToken token,) = _live();

        uint256 before = launcher.floorPrice(address(token));
        uint256 supplyBefore = token.totalSupply();
        uint256 half = token.balanceOf(alice) / 2; // hoisted - see testRedeemBeyondBalanceReverts

        vm.prank(alice);
        token.burn(half);

        assertLt(token.totalSupply(), supplyBefore, "burn did not retire supply");
        assertGt(launcher.floorPrice(address(token)), before, "voluntary burn did not raise the floor");
    }

    /// FOUND BY THE INVARIANT RUNNER, in three calls, on its first run:
    /// `buy` -> `burnVoluntarily` -> `sell`.
    ///
    /// Burning collapses `circulating` without touching the pool, so the floor
    /// jumps; a sell then crashes the market underneath it. The two prices are
    /// decoupled, and buy-and-redeem CAN profit in that state - which falsifies
    /// the unconditional form of the "round trips are always lossy" claim that
    /// the fuzz tests appeared to establish. They missed it because none of
    /// them burns.
    ///
    /// It is nonetheless NOT an attack, and this test pins both halves so the
    /// distinction cannot quietly rot into either "safe, ignore it" or "a
    /// drain vector". The profit is exactly the burner's forfeited backing: the
    /// burner destroys their own claim, and whoever buys afterwards picks it
    /// up. A bystander is not harmed - they are the other beneficiary.
    /// @dev The burner must DOMINATE circulating supply for the crossing to
    ///      happen - that is the condition, not an artifact of the setup. A
    ///      bystander holding a comparable stake keeps `C` large enough that
    ///      burning 99% of one holder barely moves the floor, which is itself
    ///      reassuring: the effect scales with how much of the token the burner
    ///      was willing to destroy.
    function testExternalBurnLiftsFloorOverMarket() public {
        // Allocation to alice AND a large buy: the burner has to dominate
        // circulating supply for the crossing, and the residual they sell
        // afterwards has to be big enough to move the market. A burner holding
        // only what one buy gave them cannot do it - which is itself the useful
        // bound on how reachable this is.
        (address t, address p) = launcher.launch("X", "X", "", SUPPLY, 1_000, 3 ether, creator);
        LaunchToken token = LaunchToken(t);
        PrecisionPool pool = PrecisionPool(payable(p));

        uint256 alloc = token.balanceOf(creator);
        vm.prank(creator);
        token.transfer(alice, alloc);

        vm.prank(alice);
        pool.swapExactIn{value: 500 ether}(address(0), 500 ether, 0, alice);

        // The bystander buys AFTER, deliberately. At a 3 ETH opening valuation
        // an early buy of even 2 ETH takes a large share of the whole supply,
        // and that share is circulating supply the burner cannot destroy - so
        // an early bystander alone prevents the crossing. Buying later, at a
        // price alice's own buy raised, leaves them a small enough holding for
        // the burn to dominate. Worth stating: the reachability of this depends
        // on the burner owning most of what is circulating.
        address bystander = address(0xB0B);
        vm.deal(bystander, 1_000 ether);
        vm.prank(bystander);
        uint256 held = pool.swapExactIn{value: 2 ether}(address(0), 2 ether, 0, bystander);
        uint256 bystanderBefore = launcher.quoteRedeem(address(token), held);

        // The sequence the runner found.
        uint256 burnAmt = token.balanceOf(alice) * 99 / 100;
        vm.prank(alice);
        token.burn(burnAmt);
        uint256 rest = token.balanceOf(alice);
        vm.startPrank(alice);
        token.approve(address(pool), type(uint256).max);
        pool.swapExactIn(address(token), rest, 0, alice);
        vm.stopPrank();

        // The ordering really is broken.
        uint256 lpTotal = pool.totalSupply();
        uint256 x = lpTotal * 1e18 / pool.sqrtPHigh() + pool.reserve0();
        uint256 y = lpTotal * pool.sqrtPLow() / 1e18 + pool.reserve1();
        assertGt(launcher.floorPrice(address(token)), x * 1e18 / y, "expected the floor to overtake the market");

        // And the bystander is better off, not worse - which is what makes this
        // a gift rather than a theft.
        assertGe(
            launcher.quoteRedeem(address(token), held), bystanderBefore, "a burn cost an uninvolved holder value"
        );

        // Solvency is untouched: the pool still covers what it owes.
        uint256 backing = uint256(pool.reserve0()) * pool.balanceOf(address(launcher)) / lpTotal;
        assertLe(backing, pool.reserve0(), "claimed backing exceeds the pool's ETH");
    }

    /// ERC-7572 requires the event; indexers key off it.
    function testSetContractURIEmitsTheStandardEvent() public {
        (address t,) = launcher.launch("E", "E", "ipfs://a", SUPPLY, 0, 3 ether, creator);

        vm.expectEmit(false, false, false, true, t);
        emit LaunchToken.ContractURIUpdated();

        vm.prank(creator);
        LaunchToken(t).setContractURI("ipfs://b");
    }

    /// Ownership is initialized once in the constructor and must not be
    /// re-initializable - `_guardInitializeOwner` is the only thing stopping it.
    function testOwnershipCannotBeReinitialized() public {
        (address t,) = launcher.launch("O", "O", "", SUPPLY, 0, 3 ether, creator);

        (bool ok,) = t.call(abi.encodeWithSignature("initializeOwner(address)", alice));
        assertFalse(ok, "ownership was re-initializable");
        assertEq(LaunchToken(t).owner(), creator);
    }

    // ------------------------------------------------------------ THE LEDGER

    /// Tokens sent directly to the launcher are unredeemable but still counted
    /// as circulating. That must be CONSERVATIVE - understating the floor, never
    /// overstating it - because the alternative is a griefing vector: anyone
    /// could buy tokens, strand them here, and inflate everyone else's floor
    /// beyond what the position can actually pay.
    function testStrandedTokensDoNotInflateTheFloor() public {
        (LaunchToken token, PrecisionPool pool) = _live();

        uint256 floorBefore = launcher.floorPrice(address(token));
        uint256 half = token.balanceOf(alice) / 2; // hoisted - see testRedeemBeyondBalanceReverts

        vm.prank(alice);
        token.transfer(address(launcher), half);

        // The stranded tokens are still in `totalSupply` and are not inside the
        // position, so `circulating` still counts them: the floor is unchanged
        // and the ETH they will never claim simply stays for everyone else.
        assertEq(launcher.floorPrice(address(token)), floorBefore, "stranding moved the floor");

        // Solvency must survive it: what every remaining holder could claim
        // cannot exceed what the position actually holds.
        uint256 lpHeld = pool.balanceOf(address(launcher));
        uint256 backing = uint256(pool.reserve0()) * lpHeld / pool.totalSupply();
        uint256 circulating =
            token.totalSupply() - (uint256(pool.reserve1()) * lpHeld / pool.totalSupply());
        assertLe(
            launcher.quoteRedeem(address(token), circulating), backing, "claims exceed the position"
        );
    }
}

contract Rejector {
    receive() external payable {
        revert("no");
    }
}

/// @dev Takes the ETH and tries to re-enter on the way in. `tried` is what
///      stops the test passing vacuously: without it, a receiver whose fallback
///      was never reached would look identical to one the guard turned away.
contract Reenterer {
    PrecisionLauncher immutable launcher;
    LaunchToken immutable token;
    bool public tried;
    bool public reenteredOk;

    constructor(PrecisionLauncher l, LaunchToken t) {
        (launcher, token) = (l, t);
    }

    function acceptStream(address t) external {
        launcher.acceptCreator(t);
    }

    receive() external payable {
        tried = true;
        // Swallowed, so this contract's own failure is not what the caller
        // sees: the assertion is that the LAUNCHER refused, which is only
        // distinguishable from "the recipient threw" if the recipient does not
        // throw. `collectFees` is the cheap probe - it needs no token balance
        // and no approval, so nothing but the guard can be what turns it away.
        try launcher.collectFees(address(token)) {
            reenteredOk = true;
        } catch {}
    }
}
