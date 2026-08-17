// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";

/// @notice Does a seller actually get routed into the treasury's bid, and does
///         the split against the pool land the way the dapp promises?
///
///         The lens says bid 3 is a live candidate for a ZORG seller and the
///         arithmetic says it beats the pool above ~430 ZORG. Neither of those
///         is the same claim as "a seller pressing SWAP receives more ether than
///         the pool alone would have paid them", which is the only claim that
///         matters to the person selling.
interface IFloorboard {
    function hit(uint256 id, uint128 give, uint256 minProceeds, bool unwrap) external;
    function priceOf(uint256 id) external view returns (uint256);
}

interface IPrecisionPool {
    function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external payable returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract ZorgBidRoutingTest is Test {
    IFloorboard constant BOARD = IFloorboard(0x00000080198137F790DA4C52bb902cf87c276748);
    address constant ZORG = 0x00a6bA94BBb5474725515De88fE04F854f2dCb12;
    address constant POOL = 0xc37F8c7E9Afe897893952ABa7fD91E0AB947837d;
    uint256 constant BID = 3;

    address constant seller = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")));
    }

    function _sellToPool(uint256 amount) internal returns (uint256 out) {
        vm.startPrank(seller);
        IERC20(ZORG).approve(POOL, type(uint256).max);
        out = IPrecisionPool(POOL).swapExactIn(ZORG, amount, 0, seller);
        vm.stopPrank();
    }

    function _hitBid(uint256 amount) internal returns (uint256 out) {
        uint256 before = seller.balance;
        vm.startPrank(seller);
        IERC20(ZORG).approve(address(BOARD), type(uint256).max);
        BOARD.hit(BID, uint128(amount), 0, true);
        vm.stopPrank();
        out = seller.balance - before;
    }

    /// The headline: at size, the bid pays more than the pool. Measured on the
    /// same amount, from the same block, so the comparison is like for like.
    ///
    /// THE CROSSOVER MOVES, and quoting it as one number is how this was first
    /// got wrong: the bid CLIMBS, so it beats the pool at ~2,400 ZORG on the day
    /// it opens and at ~470 by the time it reaches its cap. Sizes here are above
    /// the opening crossover, which is the only one true today.
    function test_atSizeTheBidBeatsThePool() public {
        uint256[3] memory sizes = [uint256(3_000 ether), 5_000 ether, 10_000 ether];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 viaPool = _sellToPool(sizes[i]);
            vm.revertToState(snap);
            uint256 viaBid = _hitBid(sizes[i]);
            vm.revertToState(snap);

            emit log_named_decimal_uint("ZORG sold          ", sizes[i], 18);
            emit log_named_decimal_uint("   ETH via pool    ", viaPool, 18);
            emit log_named_decimal_uint("   ETH via the bid ", viaBid, 18);
            assertGt(viaBid, viaPool, "the bid did not beat the pool at this size");
        }
    }

    /// And below the crossover the POOL wins, which is why a router that always
    /// preferred the bid would be wrong. A small seller must be sent elsewhere.
    function test_belowTheCrossoverThePoolIsBetter() public {
        uint256 amount = 500 ether;
        uint256 snap = vm.snapshotState();
        uint256 viaPool = _sellToPool(amount);
        vm.revertToState(snap);
        uint256 viaBid = _hitBid(amount);
        vm.revertToState(snap);

        emit log_named_decimal_uint("500 ZORG via pool  ", viaPool, 18);
        emit log_named_decimal_uint("500 ZORG via bid   ", viaBid, 18);
        assertGt(viaPool, viaBid, "a small seller should be routed to the pool");
    }

    /// THE SPLIT. A seller with more than the bid can absorb takes the bid
    /// first - it pays better - and routes the remainder into the pool. The
    /// combined proceeds must beat either venue alone.
    function test_aSellerLargerThanTheBidTakesBothAndBeatsEither() public {
        uint256 total = 20_000 ether;
        uint256 bidCap = 10770563238853896830976;

        uint256 snap = vm.snapshotState();
        uint256 poolOnly = _sellToPool(total);
        vm.revertToState(snap);

        // The route the dapp builds: fill the better venue first, sweep the
        // rest into the pool, one transaction.
        uint256 fromBid = _hitBid(bidCap);
        uint256 fromPool = _sellToPool(total - bidCap);
        uint256 combined = fromBid + fromPool;

        emit log_named_decimal_uint("pool alone         ", poolOnly, 18);
        emit log_named_decimal_uint("   bid leg         ", fromBid, 18);
        emit log_named_decimal_uint("   pool leg        ", fromPool, 18);
        emit log_named_decimal_uint("   combined        ", combined, 18);
        assertGt(combined, poolOnly, "splitting was worse than dumping into the pool");
    }

    /// Once the bid is exhausted it stops being a venue, and a second seller
    /// gets the pool - no phantom liquidity, no failed fill.
    function test_onceExhaustedTheBidIsGoneAndThePoolTakesOver() public {
        uint256 bidCap = 10770563238853896830976;
        _hitBid(bidCap);

        vm.startPrank(seller);
        IERC20(ZORG).approve(address(BOARD), type(uint256).max);
        vm.expectRevert();
        BOARD.hit(BID, 1 ether, 0, true);
        vm.stopPrank();

        // The pool is still there and still works.
        assertGt(_sellToPool(500 ether), 0, "the pool stopped working");
    }
}
