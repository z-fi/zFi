// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Floorboard} from "../src/Floorboard.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev The one thing the mocks cannot answer for: Floorboard's `receive()` is
///      reached through WETH9's `withdraw`, which pays out with `.transfer` and
///      so hands over only the 2300-gas stipend. `receive()` does an immutable
///      SLOAD-free comparison and, on the reject branch, an mstore + revert —
///      it fits, but "it fits" is a claim about the REAL WETH9's payout
///      opcode, not about a mock that happens to use `.transfer` too.
///
///      Every unwrap path is exercised: the seller taking proceeds as ETH, the
///      holder shrinking a bid with `withdraw(unwrap: true)`, and
///      `cancelUnwrap`. Each one runs `IWETH.withdraw` and then asserts against
///      `_unwrapETH`'s own delta check, which reverts if the native credit is
///      short — so a stipend that did NOT fit would fail here rather than pass
///      quietly.
contract FloorboardWethForkTest is Test {
    address constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    Floorboard board;
    MockERC20 want;

    /// The board's deterministic deploy address ALREADY HOLDS ETH on mainnet —
    /// dust force-fed to it long before this test existed. That is the stranded
    /// balance the contract documents as unrecoverable, and it is why every
    /// "the board keeps none of it" assertion here is against this baseline
    /// rather than against zero.
    uint256 strandedEth;

    address bidder = address(0xB1D);
    address seller = address(0x5E11);

    uint128 constant WANT = 1000e18;
    uint256 constant START = 1 ether;
    uint256 constant END = 2 ether;
    uint40 constant DUR = 1000;

    function setUp() public {
        // Pinned to the same block the rest of the repo forks, so this suite
        // reads one consistent state — WETH9 has been deployed at every block
        // in living memory, so the pin is for determinism, not availability.
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")), 25_640_000
        );

        board = new Floorboard(WETH9);
        strandedEth = address(board).balance;
        want = new MockERC20("W", 18);
        want.mint(seller, 1_000_000e18);
        vm.deal(bidder, 100 ether);
        vm.prank(seller);
        want.approve(address(board), type(uint256).max);
    }

    function _terms() internal view returns (Floorboard.Terms memory) {
        return Floorboard.Terms({
            token: address(want),
            quote: address(0), // native, wrapped into REAL WETH9 escrow
            want: WANT,
            startPrice: START,
            endPrice: END,
            startTime: 0,
            duration: DUR,
            isNFT: false,
            ids: new uint256[](0)
        });
    }

    function _bid() internal returns (uint256 id) {
        vm.prank(bidder);
        id = board.bid{value: END}(_terms());
    }

    function test_ethBidEscrowsRealWeth() public {
        uint256 id = _bid();
        assertEq(board.quoteOf(id), WETH9, "an ETH bid is a WETH bid");
        assertEq(board.escrowed(WETH9), END);
        assertEq(IWETH9(WETH9).balanceOf(address(board)), END, "wrapped by the real contract");
    }

    /// WETH9 pays the board with `.transfer`, so `receive()` runs on 2300 gas.
    function test_sellerUnwrapSurvivesTheStipend() public {
        uint256 id = _bid();
        uint256 before = seller.balance;

        vm.prank(seller);
        uint256 proceeds = board.hit(id, WANT / 2, 0, true);

        assertGt(proceeds, 0);
        assertEq(seller.balance - before, proceeds, "paid in native ETH");
        assertEq(address(board).balance, strandedEth, "the board keeps none of it");
    }

    function test_withdrawUnwrapSurvivesTheStipend() public {
        uint256 id = _bid();
        uint256 before = bidder.balance;

        vm.prank(bidder);
        board.withdraw(id, WANT / 2, true);

        // Half the lot released half the ceiling.
        assertEq(bidder.balance - before, END / 2, "refunded as ETH");
        assertEq(board.escrowed(WETH9), END / 2);
        assertEq(address(board).balance, strandedEth);
    }

    function test_cancelUnwrapSurvivesTheStipend() public {
        uint256 id = _bid();
        uint256 before = bidder.balance;

        vm.prank(bidder);
        board.cancelUnwrap(id);

        assertEq(bidder.balance - before, END, "the whole ceiling came back as ETH");
        assertEq(board.escrowed(WETH9), 0);
        assertEq(IWETH9(WETH9).balanceOf(address(board)), 0);
        assertEq(address(board).balance, strandedEth);
    }

    /// The other half of `receive()`: everything that is not WETH9 is refused,
    /// so the board never acquires ETH it has no rescue path for.
    function test_receiveRefusesEveryoneButWeth9() public {
        vm.deal(address(this), 1 ether);
        // A plain `.transfer` would revert without forwarding the reason, and
        // the reason is the assertion: the rejection must fit the same stipend
        // WETH9 sends on, mstore and all.
        (bool ok, bytes memory ret) = address(board).call{value: 1 ether, gas: 2300}("");
        assertFalse(ok, "refused");
        assertEq(
            ret, abi.encodeWithSelector(Floorboard.NotWETH.selector, WETH9, address(this)), "with its reason"
        );
    }
}

interface IWETH9 {
    function balanceOf(address) external view returns (uint256);
}
