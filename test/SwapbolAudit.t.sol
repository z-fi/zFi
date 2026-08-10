// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapbol} from "../src/forwarders/Swapbol.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockWETH} from "./SwapboardMocks.sol";

contract USD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) public virtual returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address t, uint256 v) public returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        balanceOf[f] -= v;
        balanceOf[t] += v;
        return true;
    }
}

/// The attacker's own payout token. Any token may run code on transfer; this one
/// calls back into a contract the attacker controls, which is all the exploit
/// needs — the board is the real Swapboard and behaves correctly throughout.
contract HookToken is USD {
    address public hook;

    function setHook(address h) external {
        hook = h;
    }

    function transfer(address to, uint256 v) public override returns (bool) {
        if (hook != address(0)) Hook(hook).onTransfer();
        return super.transfer(to, v);
    }
}

interface Hook {
    function onTransfer() external;
}

/// Pre-approved by the attacker via a throwaway `fill`, then used to pull the
/// victim's unspent input out of the forwarder mid-settlement.
contract Thief is Hook {
    USD public usd;
    address public fwd;
    address public owner;

    constructor(USD u, address o) {
        usd = u;
        owner = o;
    }

    function aim(address f) external {
        fwd = f;
    }

    function onTransfer() external {
        uint256 bal = usd.balanceOf(fwd);
        if (bal != 0) usd.transferFrom(fwd, owner, bal);
    }

    fallback() external payable {}
    receive() external payable {}
}

/// Second, independent path to the same theft: no approval, just re-enter the
/// forwarder and let its own sweep deliver the victim's input to the attacker.
contract Reenterer is Hook {
    Swapbol public fwd;
    USD public usd;
    address public owner;
    bool armed = true;

    constructor(USD u, address o) {
        usd = u;
        owner = o;
    }

    function aim(Swapbol f) external {
        fwd = f;
    }

    function onTransfer() external {
        if (!armed) return;
        armed = false;
        // tokenOut = the victim's input, recipient = the attacker.
        fwd.fill(address(this), address(0), address(usd), owner, owner, "");
    }

    fallback() external payable {}
    receive() external payable {}
}

contract SwapbolAuditTest is Test {
    Swapbol fwd;
    Swapboard board;
    Refunder dutch;
    Refunder floor;
    MockWETH weth;
    USD usd;

    address victim = address(0xB0B);
    address attacker = address(0xBAD);

    function setUp() public {
        weth = new MockWETH();
        board = new Swapboard(address(weth));
        usd = new USD();
        dutch = new Refunder(); // a distinct third venue; the token must never be one
        floor = new Refunder(); // a distinct fourth venue
        fwd = new Swapbol(address(weth), address(board), address(dutch), address(floor));
        vm.deal(address(fwd), 0); // neutralise the forked address's real balance
    }

    /// `fill` only accepts the three immutable venues, so a test that needs the
    /// board to misbehave has to bind the misbehaving contract at deployment.
    /// That is the strongest form of these assertions anyway: even a venue this
    /// contract was built to trust must not be able to take anything.
    function _bind(address venue) internal returns (Swapbol bound) {
        bound = new Swapbol(venue, address(board), address(dutch), address(floor));
        vm.deal(address(bound), 0);
    }

    // ------------------------------------------------------- planted approval

    /// The board is a calldata parameter, so an approval that outlived the call
    /// would be a capability anyone could plant: call `fill` once naming an
    /// address you control, and hold a standing claim on every later user's
    /// deposit. Every sibling forwarder is safe from this only because its
    /// spender is a hardcoded constant. Here the approval must not survive.
    function test_NoApprovalSurvivesTheCall() public {
        address spender = address(new Refunder()); // accepts the bare call
        Swapbol f = _bind(spender);

        vm.startPrank(attacker);
        f.checkpoint(address(usd));
        vm.expectRevert(Swapbol.BadPlan.selector);
        f.fill(spender, address(usd), address(0), attacker, attacker, "");
        vm.stopPrank();

        assertEq(usd.allowance(address(f), spender), 0, "nothing planted");
    }

    /// The other half of that property, and the one the revoke cannot provide:
    /// `data` is forwarded verbatim, so an unconstrained `board` would let
    /// anyone aim this contract at an ERC-20 and call `approve` directly,
    /// planting an allowance no revoke ever sees. The venue binding is what
    /// stops it - there is no calldata this contract will send to a token.
    function test_ArbitraryCallCannotPlantAnApproval() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Swapbol.UnknownBoard.selector, address(usd)));
        fwd.fill(
            address(usd), // the token itself as the call target
            address(0), // ETH in, so no checkpoint is needed
            address(0),
            attacker,
            attacker,
            abi.encodeCall(USD.approve, (attacker, type(uint256).max))
        );

        assertEq(usd.allowance(address(fwd), attacker), 0, "no allowance planted");
    }

    /// And the approval that is granted is bounded by what was actually
    /// forwarded, so a hostile board cannot pull more than the caller sent.
    function test_ApprovalIsBoundedByTheForwardedBalance() public {
        Peeker peeker = new Peeker(usd);
        Swapbol f = _bind(address(peeker));

        f.checkpoint(address(usd));
        usd.mint(address(f), 1_000e6);
        vm.expectRevert(Swapbol.BadPlan.selector);
        f.fill(address(peeker), address(usd), address(0), victim, victim, abi.encodeCall(Peeker.peek, ()));

        assertEq(peeker.seen(), 0, "arbitrary venue calldata was rejected before approval");
        assertEq(usd.allowance(address(f), address(peeker)), 0, "and revoked afterwards");
    }

    /// The planted approval, used against a real victim. The board is the
    /// genuine Swapboard and does everything right; the loss was entirely in the
    /// forwarder. snwap does not measure tokenIn, so the router's amountOutMin
    /// check could not see it.
    function test_PlantedApprovalCannotStealVictimsUnspentInput() public {
        HookToken payout = new HookToken();
        Thief thief = new Thief(usd, attacker);
        payout.setHook(address(thief));

        // The thief is bound as a venue, the strongest version of this test:
        // the attacker gets the board slot handed to them for free.
        Swapbol fwd = _bind(address(thief));
        thief.aim(address(fwd));

        // 1. attacker plants the approval
        vm.startPrank(attacker);
        fwd.checkpoint(address(usd));
        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fill(address(thief), address(usd), address(0), attacker, attacker, "");
        vm.stopPrank();

        // 2. attacker lists 100 payout-token for 6,000 USD on the real board
        payout.mint(attacker, 100e18);
        vm.startPrank(attacker);
        payout.approve(address(board), type(uint256).max);
        uint256 id = board.createOrder(address(payout), 100e18, address(usd), 6000e6, true, 0, false, false, address(0));
        vm.stopPrank();

        // 3. victim routes 10,000 USD in, expecting 4,000 back. The thief's pull
        //    now has no allowance to draw on, so the settlement fails closed
        //    rather than quietly shipping the refund to the attacker.
        vm.prank(victim);
        fwd.checkpoint(address(usd));
        usd.mint(address(fwd), 10_000e6);
        vm.prank(victim);
        vm.expectRevert();
        fwd.fill(
            address(board),
            address(usd),
            address(payout),
            victim,
            victim,
            abi.encodeCall(Swapboard.fillOrder, (id, 0, 6000e6, 0, victim))
        );

        assertEq(usd.balanceOf(attacker), 0, "nothing taken");
        assertEq(usd.balanceOf(address(fwd)), 10_000e6, "the victim's input never moved");
    }

    /// The same theft with no approval at all: `fill` sweeps to a caller-supplied
    /// recipient, so any code running during the board call could re-enter and
    /// point the sweep at itself. Revoking approvals does not close this one -
    /// the guard does.
    function test_ReentrantSweepCannotStealVictimsUnspentInput() public {
        HookToken payout = new HookToken();
        Reenterer re = new Reenterer(usd, attacker);
        payout.setHook(address(re));

        Swapbol fwd = _bind(address(re));
        re.aim(fwd);

        payout.mint(attacker, 100e18);
        vm.startPrank(attacker);
        payout.approve(address(board), type(uint256).max);
        uint256 id = board.createOrder(address(payout), 100e18, address(usd), 6000e6, true, 0, false, false, address(0));
        vm.stopPrank();

        vm.prank(victim);
        fwd.checkpoint(address(usd));
        usd.mint(address(fwd), 10_000e6);
        vm.prank(victim);
        vm.expectRevert();
        fwd.fill(
            address(board),
            address(usd),
            address(payout),
            victim,
            victim,
            abi.encodeCall(Swapboard.fillOrder, (id, 0, 6000e6, 0, victim))
        );

        assertEq(usd.balanceOf(attacker), 0, "nothing swept");
        assertEq(usd.balanceOf(address(fwd)), 10_000e6, "the victim's input never moved");
    }

    /// A direct re-entrant call is refused outright, whatever it is aimed at.
    function test_FillIsNotReentrant() public {
        Reenterer re = new Reenterer(usd, attacker);
        Swapbol fwd = _bind(address(re));
        re.aim(fwd);

        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fill(address(re), address(0), address(0), victim, victim, abi.encodeCall(Hook.onTransfer, ()));
    }

    // ------------------------------------------------------------------- ETH

    /// With ETH in and a token out, the unspent ETH refund used to fall through
    /// every sweep - the ETH branch was gated on tokenOut being ETH - and rested
    /// here until the next caller handed it to a board of their choosing.
    function test_EthRefundIsSweptEvenWhenTokenOutIsAToken() public {
        Refunder r = new Refunder();
        Swapbol fwd = _bind(address(r));

        vm.deal(victim, 10 ether);
        uint256 before = victim.balance;
        vm.prank(victim);
        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fill{value: 10 ether}(
            address(r), address(0), address(usd), victim, victim, abi.encodeCall(Refunder.keep, (6 ether))
        );

        assertEq(address(fwd).balance, 0, "nothing stranded");
        assertEq(victim.balance, before, "rejected unreviewed venue");
    }

    /// The call value must be what the caller sent, not the contract's whole
    /// balance: otherwise ETH that was already here - donated, refunded by an
    /// earlier leg, or simply present at the deployment address - is spent on
    /// this caller's behalf. This is not hypothetical: on the pinned mainnet
    /// fork, the address Forge deploys Swapbol to already holds 0.000577 ETH,
    /// which is what made the repo's own `test_HoldsNothingBetweenCalls` red.
    function test_CallValueIsMsgValueNotTheWholeBalance() public {
        Refunder sink = new Refunder();
        Swapbol fwd = _bind(address(sink));
        vm.deal(address(fwd), 5 ether); // pre-existing / donated

        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fill{value: 1 ether}(
            address(sink), address(0), address(0), attacker, attacker, abi.encodeCall(Refunder.keep, (6 ether))
        );

        assertEq(address(sink).balance, 0, "unreviewed venue was not called");
    }

    /// A pre-existing balance is not attributable to this call. Keeping it
    /// isolated also prevents a forced donation from DoSing an ERC-20 route
    /// whose recipient cannot accept ETH.
    function test_ForcedEthBaselineIsNotSwept() public {
        Refunder sink = new Refunder();
        Swapbol fwd = _bind(address(sink));
        vm.deal(address(fwd), 3 ether);

        fwd.checkpoint(address(usd));
        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fill(address(sink), address(usd), address(0), victim, victim, abi.encodeCall(Refunder.keep, (0)));

        assertEq(address(fwd).balance, 3 ether, "forced ETH remains isolated");
        assertEq(victim.balance, 0, "recipient cannot claim pre-existing ETH");
    }

    function test_forwarderCannotBeItsOwnBoardRecipientOrRefundTarget() public {
        // Not a venue, so it is refused as a board before anything else.
        vm.expectRevert(abi.encodeWithSelector(Swapbol.UnknownBoard.selector, address(fwd)));
        fwd.fill(address(fwd), address(0), address(usd), victim, victim, "");

        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fill(address(board), address(0), address(usd), address(fwd), address(fwd), "");

        Swapbol.Fill[] memory fills = new Swapbol.Fill[](1);
        fills[0] = Swapbol.Fill({orderId: 0, board: address(board), payIn: 0, getOut: 1, isPartial: false});

        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fillPlan(address(0), address(usd), address(fwd), victim, 0, fills);

        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fillPlan(address(0), address(usd), victim, address(fwd), 0, fills);
    }
}

/// Reports back the allowance it was granted, so the bound can be asserted.
contract Peeker {
    USD public usd;
    uint256 public seen;

    constructor(USD u) {
        usd = u;
    }

    function peek() external {
        seen = usd.allowance(msg.sender, address(this));
    }
}

contract Refunder {
    function keep(uint256 amount) external payable {
        if (msg.value > amount) {
            (bool ok,) = msg.sender.call{value: msg.value - amount}("");
            require(ok);
        }
    }

    receive() external payable {}
}
