// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";

/// @notice The buyback as a CLIMBING BID, rehearsed against the deployed
///         Floorboard.
///
///         Same economics as the Dutchboard version and one difference that
///         decided it: `hit` takes an `unwrap` flag, so a holder selling ZORG
///         walks away with NATIVE ETHER in the same transaction. Dutchboard's
///         lot is WETH and its taker has no such flag - it hands retail holders
///         a wrapped token and a second transaction to do at exactly the moment
///         they are being asked to act.
///
///         The bid escrows `endPrice`, which is the entire liability it can
///         ever incur, so the number the signers approve IS the worst case.
interface IFloorboard {
    struct Terms {
        address token;
        address quote;
        uint128 want;
        uint256 startPrice;
        uint256 endPrice;
        uint40 startTime;
        uint40 duration;
        bool isNFT;
        uint256[] ids;
    }

    function bid(Terms calldata terms) external payable returns (uint256 id);
    function hit(uint256 id, uint128 give, uint256 minProceeds, bool unwrap) external;
    function priceOf(uint256 id) external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract ZorgBuybackBidTest is Test {
    IFloorboard constant BOARD = IFloorboard(0x00000080198137F790DA4C52bb902cf87c276748);
    address constant ZORG = 0x00a6bA94BBb5474725515De88fE04F854f2dCb12;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant OPS = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;

    uint128 constant WANT = 10770563238853896830976; // ZORG sought — the whole ops balance at the same price
    uint256 constant START = 26926408097134744; // opening bid for the lot
    uint256 constant END = 59836462438077211; // cap, and what is escrowed — the full ops balance
    uint40 constant DURATION = 7 days;

    /// A real holder. `deal` writes a balance without moving supply and ZORG's
    /// own accounting rejects the result with `Overflow()` on the next transfer,
    /// so a dealt fixture would be testing a token that cannot exist.
    address constant seller = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")));
        vm.deal(OPS, END);  // exactly what ops holds: the bid must fit with nothing spare
    }

    function _terms() internal view returns (IFloorboard.Terms memory t) {
        t = IFloorboard.Terms({
            token: ZORG,
            quote: address(0), // native ETH
            want: WANT,
            startPrice: START,
            endPrice: END,
            startTime: 0,
            duration: DURATION,
            isNFT: false,
            ids: new uint256[](0)
        });
    }

    function _bid() internal returns (uint256 id) {
        vm.prank(OPS);
        id = BOARD.bid{value: END}(_terms());
    }

    /// The escrow is the cap, and the cap is all that can ever leave.
    function test_theBidEscrowsExactlyTheCapAndNoMore() public {
        uint256 id = _bid();
        assertEq(BOARD.ownerOf(id), OPS, "the multisig does not own the bid");
        assertEq(OPS.balance, 0, "the whole balance did not go into the bid");
        emit log_named_uint("bid id", id);
    }

    /// It opens below what the market would charge and climbs to the cap.
    function test_itOpensCheapAndClimbsToTheCap() public {
        uint256 id = _bid();
        uint256 atOpen = BOARD.priceOf(id);
        vm.warp(block.timestamp + DURATION / 2);
        uint256 halfway = BOARD.priceOf(id);
        vm.warp(block.timestamp + DURATION);
        uint256 atEnd = BOARD.priceOf(id);

        emit log_named_decimal_uint("ETH bid at open   ", atOpen, 18);
        emit log_named_decimal_uint("ETH bid at halfway", halfway, 18);
        emit log_named_decimal_uint("ETH bid at the end", atEnd, 18);

        assertEq(atOpen, START, "did not open where it was signed");
        assertGt(halfway, atOpen, "the bid is not climbing");
        assertLt(halfway, atEnd, "the climb is not monotonic");
        assertEq(atEnd, END, "did not stop at the cap");
    }

    /// THE REASON FOR THIS BOARD: the seller takes native ether, in one call.
    function test_aHolderIsPaidNativeEtherNotWeth() public {
        uint256 id = _bid();
        /* One second INSIDE the window. A bid is takeable on [start, start +
           duration) - exclusive at the end - so warping to exactly `DURATION`
           lands on the first expired second and reverts `Expired()`. That is
           the no-babysitting property working, not a bug. */
        vm.warp(block.timestamp + DURATION - 1);

        uint256 ethBefore = seller.balance;
        uint256 wethBefore = IERC20(WETH).balanceOf(seller);
        uint256 zorgBefore = IERC20(ZORG).balanceOf(seller);

        vm.startPrank(seller);
        IERC20(ZORG).approve(address(BOARD), type(uint256).max);
        BOARD.hit(id, WANT, 0, true); // unwrap = true
        vm.stopPrank();

        uint256 gotEth = seller.balance - ethBefore;
        emit log_named_decimal_uint("ETH paid to the seller", gotEth, 18);
        emit log_named_decimal_uint("ZORG bought           ", zorgBefore - IERC20(ZORG).balanceOf(seller), 18);

        assertGt(gotEth, 0, "the seller was paid nothing in ether");
        assertEq(IERC20(WETH).balanceOf(seller), wethBefore, "the seller was handed WETH after all");
        assertEq(IERC20(ZORG).balanceOf(OPS), WANT, "the treasury did not receive the ZORG");
    }

    /// A holder who prefers WETH may still have it - the flag is theirs.
    function test_theSellerChoosesAndMayTakeWeth() public {
        uint256 id = _bid();
        vm.warp(block.timestamp + DURATION - 1);
        uint256 wethBefore = IERC20(WETH).balanceOf(seller);

        vm.startPrank(seller);
        IERC20(ZORG).approve(address(BOARD), type(uint256).max);
        BOARD.hit(id, WANT, 0, false);
        vm.stopPrank();

        assertGt(IERC20(WETH).balanceOf(seller), wethBefore, "the WETH path is broken");
    }

    /// Several small holders, not one whale.
    function test_aPartialHitLeavesTheRestOnTheSameSchedule() public {
        uint256 id = _bid();
        vm.warp(block.timestamp + DURATION - 1);

        vm.startPrank(seller);
        IERC20(ZORG).approve(address(BOARD), type(uint256).max);
        BOARD.hit(id, WANT / 2, 0, true);
        vm.stopPrank();

        assertEq(IERC20(ZORG).balanceOf(OPS), WANT / 2, "the first half did not settle");
        assertEq(BOARD.ownerOf(id), OPS, "the bid closed on a partial hit");
    }

    /// A seller wanting more than the bid offers is refused, and the refusal is
    /// THEIRS - the bid is untouched and still live.
    function test_aSellersOwnBoundProtectsThemAndNotTheBid() public {
        uint256 id = _bid();
        vm.startPrank(seller);
        IERC20(ZORG).approve(address(BOARD), type(uint256).max);
        vm.expectRevert();
        BOARD.hit(id, WANT, 1 ether, true); // will not sell for under 1 ETH
        vm.stopPrank();

        assertEq(BOARD.ownerOf(id), OPS, "a refused hit damaged the bid");
        assertEq(BOARD.priceOf(id), START, "the schedule moved");
    }
}
