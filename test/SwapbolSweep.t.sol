// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapbol} from "../src/forwarders/Swapbol.sol";
import {MockWETH} from "./SwapboardMocks.sol";

address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

/// A Dutch venue selling WETH for native ETH that pays the fill to its caller
/// rather than to the recipient it was handed. Boards are not obliged to honour
/// the recipient - `_sweep` exists precisely for the ones that do not - so the
/// forwarder has to deliver that output itself.
contract PayToCallerDutch {
    /// Dutchboard answers the three old getters through one packed read now, so
    /// a stand-in venue has to as well.
    function legOf(uint256)
        external
        pure
        returns (address, address, address, bool, uint128, uint256, uint256)
    {
        // seller, token, quote (address(0) = native, as the ETH -> WETH route
        // requires), isNFT, remaining, lotSize, price.
        return (address(1), WETH, address(0), false, type(uint128).max, 0, 0);
    }

    /// fill(uint256,uint128,address,uint256) - selector 0xae7a8260.
    function fill(uint256, uint128 take, address, uint256) external payable {
        MockWETH(payable(WETH)).transfer(msg.sender, take);
    }
}

contract Venue {
    receive() external payable {}
}

contract Burnable {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function burn(address from, uint256 v) external {
        balanceOf[from] -= v;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address t, uint256 v) external returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[t] += v;
        return true;
    }

    function transferFrom(address f, address t, uint256 v) external returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        balanceOf[f] -= v;
        balanceOf[t] += v;
        return true;
    }
}

/// Pulls only part of what it was approved, leaving change on the forwarder.
contract PartialVenue {
    Burnable public token;

    constructor(Burnable t) {
        token = t;
    }

    function take(uint256 v) external {
        token.transferFrom(msg.sender, address(this), v);
    }
}

/// Reports the allowance it was granted, so an unbounded one would be visible.
contract Peek {
    Burnable public token;
    uint256 public seen;

    constructor(Burnable t) {
        token = t;
    }

    receive() external payable {}

    fallback() external payable {
        seen = token.allowance(msg.sender, address(this));
    }
}

contract SwapbolSweepTest is Test {
    address taker = address(0xB0B);
    address refundTo = address(0xF00D);

    function setUp() public {
        MockWETH weth = new MockWETH();
        vm.etch(WETH, address(weth).code);
        // This repo pins a mainnet fork and these addresses hold real balances
        // on it; zero them so the assertions below measure this suite.
        vm.deal(taker, 0);
        vm.deal(refundTo, 0);
    }

    /// On the ETH -> WETH route, WETH is the output, not an intermediate the
    /// forwarder wrapped for its own use. Unwrapping the delta would convert
    /// the user's proceeds to ETH and pay them out as change to `refundTo`.
    function test_wethOutputIsSweptToRecipientNotUnwrappedToRefundAddress() public {
        PayToCallerDutch dutch = new PayToCallerDutch();
        Swapbol fwd = new Swapbol(address(new Venue()), address(new Venue()), address(dutch), address(new Venue()));
        vm.deal(address(fwd), 0);

        MockWETH(payable(WETH)).deposit{value: 2 ether}();
        MockWETH(payable(WETH)).transfer(address(dutch), 2 ether);

        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(0, address(dutch), 1 ether, 2 ether, true);

        vm.deal(taker, 1 ether);
        vm.prank(taker);
        fwd.fillPlan{value: 1 ether}(address(0), WETH, taker, refundTo, 0, legs);

        assertEq(MockWETH(payable(WETH)).balanceOf(taker), 2 ether, "output delivered as WETH to the recipient");
        assertEq(refundTo.balance, 0, "not unwrapped and paid out as change");
        assertEq(MockWETH(payable(WETH)).balanceOf(address(fwd)), 0, "nothing stranded");
        assertEq(address(fwd).balance, 0, "no ETH stranded");
    }

    /// A balance below the checkpoint means the snapshot no longer describes
    /// this call's funding. Returning a sentinel amount instead of reverting
    /// would flow into safeApprove as an unbounded allowance.
    function test_balanceBelowCheckpointRevertsRatherThanApprovingUnbounded() public {
        Burnable token = new Burnable();
        Peek venue = new Peek(token);
        Swapbol fwd = new Swapbol(address(venue), address(new Venue()), address(new Venue()), address(new Venue()));

        token.mint(address(fwd), 1_000e6);
        fwd.checkpoint(address(token)); // base = 1_000e6
        token.burn(address(fwd), 1_000e6); // rebase, admin burn, hostile token

        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fill(address(venue), address(token), address(0), taker, taker, "");

        assertEq(venue.seen(), 0, "the venue was never reached, let alone approved");
        assertEq(token.allowance(address(fwd), address(venue)), 0, "no allowance granted");
    }

    /// `fill` forwards `data` verbatim, so an unconstrained `board` would let
    /// anyone aim this contract at an ERC-20 and call `approve` directly -
    /// planting a permanent allowance that the scoped revoke never sees,
    /// because it was never granted through safeApprove. Binding the venue is
    /// what stops it: there is no calldata this contract will send to a token.
    function test_arbitraryCallCannotPlantAnApproval() public {
        Burnable token = new Burnable();
        Swapbol fwd = new Swapbol(address(new Venue()), address(new Venue()), address(new Venue()), address(new Venue()));
        address attacker = address(0xBAD);

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Swapbol.UnknownBoard.selector, address(token)));
        fwd.fill(
            address(token), // the token itself as the call target
            address(0), // ETH in, so no checkpoint is needed
            address(0),
            attacker,
            attacker,
            abi.encodeCall(Burnable.approve, (attacker, type(uint256).max))
        );

        assertEq(token.allowance(address(fwd), attacker), 0, "no allowance planted");
    }

    /// A registered board is not a licence to forward arbitrary calldata:
    /// `_validateFillData` only recognises the boards' own fill selectors, so a
    /// venue-specific call is refused before anything moves.
    ///
    /// @dev This test used to assert that unspent input reached `refundTo`, but
    ///      the call it makes has been refused since `_validateFillData` landed -
    ///      the assertions were simply never updated, and one of them demanded
    ///      that a reverted call had somehow swept the forwarder's balance. What
    ///      it can honestly check is that the refusal is total.
    function test_arbitraryVenueCalldataIsRefusedBeforeAnythingMoves() public {
        Burnable token = new Burnable();
        PartialVenue venue = new PartialVenue(token);
        Swapbol fwd = new Swapbol(address(venue), address(new Venue()), address(new Venue()), address(new Venue()));

        fwd.checkpoint(address(token));
        token.mint(address(fwd), 1_000e6);

        vm.expectRevert(Swapbol.BadPlan.selector);
        fwd.fill(
            address(venue), address(token), address(0), taker, refundTo, abi.encodeCall(PartialVenue.take, (400e6))
        );

        assertEq(token.balanceOf(refundTo), 0, "unreviewed arbitrary venue was not called");
        assertEq(token.balanceOf(taker), 0, "not to the payout recipient");
        // The revert reverted: the forwarder still holds exactly what it held.
        assertEq(token.balanceOf(address(fwd)), 1_000e6, "the refused call moved nothing");
    }
}
