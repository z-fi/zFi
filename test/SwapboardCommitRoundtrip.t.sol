// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";

/// A commitment used to end with the seller's ownership. It does not any more,
/// because ownership is recoverable and escrow is not: the receipt could be
/// round-tripped through a second wallet, cancelled from there, and handed back,
/// leaving an off-board buyer paying for a spent ticket.
contract SwapboardCommitRoundtripTest is Test {
    Swapboard board;
    MockWETH weth;
    MockERC20 tokA;
    MockERC20 tokB;

    address seller = address(0xA11CE);
    address alt = address(0xA17);

    function setUp() public {
        weth = new MockWETH();
        board = new Swapboard(address(weth));
        tokA = new MockERC20("T", 18);
        tokB = new MockERC20("T", 18);
        tokA.mint(seller, 100e18);
        vm.prank(seller);
        tokA.approve(address(board), type(uint256).max);
    }

    function test_commitmentSurvivesRoundTripThroughSecondWallet() public {
        vm.startPrank(seller);
        uint256 id = board.createOrder(address(tokA), 100e18, address(tokB), 1e18, false, 0, false, false, address(0));
        uint64 until = uint64(block.timestamp + 7 days);
        board.commitFrozen(id, until);

        vm.expectRevert(abi.encodeWithSelector(Swapboard.CommitmentActive.selector, id, until));
        board.cancelOrder(id);

        // The escape hatch: hand it to a second wallet and cancel from there.
        board.transferFrom(seller, alt, id);
        vm.stopPrank();

        assertEq(board.frozenUntil(id), until, "the commitment rides with the token");

        vm.startPrank(alt);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.CommitmentActive.selector, id, until));
        board.cancelOrder(id);
        vm.stopPrank();

        // The escrow is still whole and still on the board.
        (, bool active,,,,,,, uint256 amountA,,) = board.orders(id);
        assertTrue(active, "order still live");
        assertEq(amountA, 100e18);
        assertEq(tokA.balanceOf(address(board)), 100e18, "escrow untouched");
        assertEq(tokA.balanceOf(alt), 0);
    }

    /// Every path that could change the claim stays shut after the receipt
    /// changes hands - the buyer's own paths included.
    function test_everyMutationBlockedForTheNewOwnerWhileCommitted() public {
        vm.startPrank(seller);
        uint256 id = board.createOrder(
            address(tokA), 100e18, address(tokB), 1e18, true, uint64(block.timestamp + 1 hours), false, false, address(0)
        );
        uint64 until = uint64(block.timestamp + 7 days);
        board.commitFrozen(id, until);
        board.transferFrom(seller, alt, id);
        vm.stopPrank();

        // Filling: blocked for anyone.
        address taker = address(0xBEEF);
        tokB.mint(taker, 1e18);
        vm.startPrank(taker);
        tokB.approve(address(board), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderFrozen.selector, id));
        board.fillOrder(id, 0, 1e18, 0, taker);
        vm.stopPrank();

        // Repricing and cancelling: blocked for the owner too.
        vm.startPrank(alt);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderFrozen.selector, id));
        board.replaceOrder(id, 1, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.CommitmentActive.selector, id, until));
        board.cancelOrder(id);
        vm.stopPrank();

        // Sweeping once expired: blocked, and the skip-variant skips.
        vm.warp(block.timestamp + 2 hours);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.expectRevert(abi.encodeWithSelector(Swapboard.OrderFrozen.selector, id));
        board.cancelExpired(ids);
        assertFalse(board.trySweepExpired(ids)[0], "sweep steps over it");

        assertEq(tokA.balanceOf(address(board)), 100e18, "escrow never moved");
    }

    /// The new owner inherits the live window untouched, not a clean slate -
    /// and cannot rewrite it in either direction while it stands.
    function test_newOwnerInheritsTheWindowAndCannotRewriteIt() public {
        vm.startPrank(seller);
        uint256 id = board.createOrder(address(tokA), 100e18, address(tokB), 1e18, false, 0, false, false, address(0));
        uint64 until = uint64(block.timestamp + 7 days);
        board.commitFrozen(id, until);
        board.transferFrom(seller, alt, id);
        vm.stopPrank();

        vm.startPrank(alt);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.CommitmentActive.selector, id, until));
        board.commitFrozen(id, until - 1);
        vm.expectRevert(abi.encodeWithSelector(Swapboard.CommitmentActive.selector, id, until));
        board.commitFrozen(id, until + 1);
        vm.stopPrank();
        assertEq(board.frozenUntil(id), until, "the window a buyer read is the window they got");

        // Once it lapses the owner may open a fresh one.
        vm.warp(until + 1);
        vm.prank(alt);
        board.commitFrozen(id, uint64(block.timestamp + 1 days));
        assertEq(board.frozenUntil(id), uint64(block.timestamp + 1 days));
    }

    /// The finding this rule closes: a seller could commit a short, palatable
    /// window, list the receipt off-board, then front-run the buyer's purchase
    /// with a year-long commitment - handing over a position no one can fill,
    /// cancel, reprice or sweep for that year.
    function test_sellerCannotLengthenTheWindowUnderABuyer() public {
        vm.startPrank(seller);
        uint256 id = board.createOrder(address(tokA), 100e18, address(tokB), 1e18, false, 0, false, false, address(0));
        uint64 shown = uint64(block.timestamp + 3 days);
        board.commitFrozen(id, shown);

        // Read the cap BEFORE arming the cheat code: an external call in the
        // argument list is evaluated after `expectRevert` arms, so it would be
        // the call the cheat code matched against.
        uint64 aYear = uint64(block.timestamp) + board.MAX_COMMITMENT();

        // What the buyer simulated against is what settlement can deliver.
        vm.expectRevert(abi.encodeWithSelector(Swapboard.CommitmentActive.selector, id, shown));
        board.commitFrozen(id, aYear);
        vm.stopPrank();

        assertEq(board.frozenUntil(id), shown);
    }

    /// A cancelled order keeps its last live terms on purpose: cleared amounts
    /// are how the renderer tells a FILLED order from a CLOSED one, and slot 0
    /// has no spare flag to carry that distinction instead. `active` is the
    /// field that says whether the claim is live.
    function test_cancelledOrderIsClosedNotFilled() public {
        vm.startPrank(seller);
        uint256 id = board.createOrder(address(tokA), 100e18, address(tokB), 1e18, false, 0, false, false, address(0));
        board.cancelOrder(id);
        vm.stopPrank();

        (, bool active,,,,,,, uint256 amountA,,) = board.orders(id);
        assertFalse(active, "the claim is closed");
        assertEq(amountA, 100e18, "and its terminal terms survive");
        assertEq(tokA.balanceOf(seller), 100e18, "escrow returned");

        // The metadata is a base64 data URI, so decode before reading it.
        string memory json = _decodeDataURI(board.tokenURI(id));
        assertTrue(LibString.contains(json, "CLOSED"), "cancelled reads CLOSED");
        assertFalse(LibString.contains(json, "FILLED"), "and never FILLED");
    }

    /// The companion: a fully filled order zeroes both legs, and that is the
    /// only signal separating the two closed states.
    function test_filledOrderIsFilledNotClosed() public {
        vm.prank(seller);
        uint256 id = board.createOrder(address(tokA), 100e18, address(tokB), 1e18, false, 0, false, false, address(0));

        address taker = address(0xBEEF);
        tokB.mint(taker, 1e18);
        vm.startPrank(taker);
        tokB.approve(address(board), type(uint256).max);
        board.fillOrder(id, 0, 1e18, 0, taker);
        vm.stopPrank();

        string memory json = _decodeDataURI(board.tokenURI(id));
        assertTrue(LibString.contains(json, "FILLED"), "filled reads FILLED");
        assertFalse(LibString.contains(json, "CLOSED"), "and never CLOSED");
    }

    function _decodeDataURI(string memory uri) internal pure returns (string memory) {
        bytes memory raw = bytes(uri);
        uint256 comma;
        for (uint256 i; i < raw.length; ++i) {
            if (raw[i] == ",") {
                comma = i + 1;
                break;
            }
        }
        bytes memory payload = new bytes(raw.length - comma);
        for (uint256 i; i < payload.length; ++i) {
            payload[i] = raw[comma + i];
        }
        return string(Base64.decode(string(payload)));
    }
}
