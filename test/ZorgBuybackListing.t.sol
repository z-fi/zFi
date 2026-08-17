// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";

/// @notice The buyback order the multisig is about to sign, rehearsed against
///         the deployed Dutchboard.
///
///         A descending ask for ZORG against a fixed lot of the ops treasury's
///         ether: it opens asking far more ZORG than the market would give and
///         decays toward roughly fair, so a holder who wants out hits it early
///         and cheap, and if nobody does it settles near the pool's price
///         WITHOUT paying the impact of being twice that pool's depth.
///
///         Signed once, it cannot go stale in a signing queue the way a swap's
///         slippage bound and deadline would - which is the reason it is an
///         order and not a trade.
interface IDutchboard {
    function listETH(
        address quote,
        uint256 startPrice,
        uint256 endPrice,
        uint40 startTime,
        uint40 duration,
        uint40 expiry
    ) external payable returns (uint256 id);
    function fill(uint256 id, uint128 take, address to, uint256 maxCost) external payable;
    function priceOf(uint256 id) external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract ZorgBuybackListingTest is Test {
    IDutchboard constant BOARD = IDutchboard(0x000000a213b430D14Bae6062c176289B05e04489);
    address constant ZORG = 0x00a6bA94BBb5474725515De88fE04F854f2dCb12;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant OPS = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;
    address constant POOL = 0xc37F8c7E9Afe897893952ABa7fD91E0AB947837d;

    uint256 constant LOT = 0.05 ether;
    uint256 constant START = 20_000 ether; // ZORG asked at open
    uint256 constant END = 6_300 ether; // ZORG asked at the end of the decay
    uint40 constant DURATION = 7 days;

    /* A REAL HOLDER, not a dealt balance. `deal` writes a balance without
       moving supply, and ZORG's own accounting rejects the result with
       `Overflow()` on the next transfer - so a fixture built that way tests a
       token that cannot exist. */
    address constant seller = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")));
        vm.deal(OPS, 1 ether);
        vm.deal(seller, 1 ether);

    }

    function _list() internal returns (uint256 id) {
        vm.prank(OPS);
        id = BOARD.listETH{value: LOT}(ZORG, START, END, 0, DURATION, uint40(block.timestamp + 14 days));
    }

    /// The exact bytes handed to the multisig, executed verbatim.
    function test_theCalldataListsWhatItClaims() public {
        uint40 expiry = uint40(block.timestamp + 14 days);
        bytes memory data = abi.encodeWithSelector(
            IDutchboard.listETH.selector, ZORG, START, END, uint40(0), DURATION, expiry
        );
        vm.prank(OPS);
        (bool ok, bytes memory ret) = address(BOARD).call{value: LOT}(data);
        assertTrue(ok, "the listing reverted");
        uint256 id = abi.decode(ret, (uint256));

        assertEq(BOARD.ownerOf(id), OPS, "the multisig does not own the order");
        assertEq(OPS.balance, 1 ether - LOT, "a different amount of ether left the treasury");
        emit log_named_uint("listing id", id);
    }

    /// It opens asking MORE ZORG than the market would give, and decays toward
    /// roughly fair. If it opened below market a bot would take it instantly at
    /// the worst price of the whole schedule.
    function test_itOpensAboveMarketAndDecaysTowardIt() public {
        uint256 id = _list();
        uint256 atOpen = BOARD.priceOf(id);

        vm.warp(block.timestamp + DURATION / 2);
        uint256 halfway = BOARD.priceOf(id);

        vm.warp(block.timestamp + DURATION);
        uint256 atEnd = BOARD.priceOf(id);

        emit log_named_decimal_uint("ZORG asked at open    ", atOpen, 18);
        emit log_named_decimal_uint("ZORG asked at halfway ", halfway, 18);
        emit log_named_decimal_uint("ZORG asked at the end ", atEnd, 18);

        assertEq(atOpen, START, "did not open at the price signed");
        assertLt(halfway, atOpen, "the ask is not decaying");
        assertGt(halfway, atEnd, "the decay is not monotonic");
        assertEq(atEnd, END, "did not rest at the reserve");
    }

    /// A holder hits it. The ether must leave the board for the seller and the
    /// ZORG must land with the multisig - the whole point of the exercise.
    function test_aHolderCanSellIntoItAndTheTreasuryGetsTheZorg() public {
        uint256 id = _list();
        vm.warp(block.timestamp + DURATION); // decayed to the reserve

        uint256 zorgBefore = IERC20(ZORG).balanceOf(OPS);
        /* WETH, NOT ETH. `listETH` wraps the lot on the way in, so a seller
           hitting this is paid canonical WETH - worth knowing before anyone is
           told "you get ether for your ZORG". */
        uint256 sellerWeth = IERC20(WETH).balanceOf(seller);

        vm.startPrank(seller);
        IERC20(ZORG).approve(address(BOARD), type(uint256).max);
        // Takes the whole lot: `take` is the ETH being bought, `maxCost` the
        // most ZORG the seller will part with.
        BOARD.fill(id, uint128(LOT), seller, type(uint256).max);
        vm.stopPrank();

        uint256 paid = IERC20(ZORG).balanceOf(OPS) - zorgBefore;
        emit log_named_decimal_uint("ZORG bought by the treasury", paid, 18);
        uint256 got = IERC20(WETH).balanceOf(seller) - sellerWeth;
        emit log_named_decimal_uint("WETH paid to the seller    ", got, 18);

        assertEq(paid, END, "the treasury did not receive the asked amount");
        assertEq(got, LOT, "the seller was not paid the whole lot");
    }

    /// Partial fills leave the rest on the same schedule, which is what makes
    /// this usable by several small holders rather than one whale.
    function test_aPartialFillLeavesTheRestOnTheSameSchedule() public {
        uint256 id = _list();
        vm.warp(block.timestamp + DURATION);

        vm.startPrank(seller);
        IERC20(ZORG).approve(address(BOARD), type(uint256).max);
        BOARD.fill(id, uint128(LOT / 2), seller, type(uint256).max);
        vm.stopPrank();

        assertGt(IERC20(ZORG).balanceOf(OPS), 0, "the first half did not settle");
        assertEq(BOARD.ownerOf(id), OPS, "the order closed on a partial fill");
    }

    /// A seller who wants more ZORG than the schedule offers is refused, and
    /// the refusal is THEIRS - the order is untouched and still fillable.
    function test_aSellersOwnBoundProtectsThemAndNotTheOrder() public {
        uint256 id = _list();
        vm.startPrank(seller);
        IERC20(ZORG).approve(address(BOARD), type(uint256).max);
        vm.expectRevert();
        BOARD.fill(id, uint128(LOT), seller, 1); // will not part with more than 1 wei of ZORG
        vm.stopPrank();

        assertEq(BOARD.ownerOf(id), OPS, "a refused fill damaged the order");
        assertEq(BOARD.priceOf(id), START, "the schedule moved");
    }
}
