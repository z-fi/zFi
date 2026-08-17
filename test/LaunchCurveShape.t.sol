// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {PrecisionLauncher, LaunchToken} from "../src/pools/PrecisionLauncher.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";

/// @notice What `startMcapWei` actually DOES, in numbers rather than prose.
///
///         It is not a fee, a cap, or a target. It is the pool's opening
///         VIRTUAL ether reserve - the pool holds no real ether at launch, so
///         this number alone decides where on the curve the market opens. Two
///         consequences fall out of it, and the second is the one nobody
///         guesses: it sets the opening price, AND it sets how hard the price
///         is to move.
contract LaunchCurveShapeTest is Test {
    address constant FACTORY = 0x000000Eb27B557aB426d9E99cFd54EC455799e81;
    address constant TREASURY = 0x000000aA142133107c7D2664F900f80e28BbfFbd;

    PrecisionLauncher L;
    address creator = address(0xC0FFEE);
    address buyer = address(0xB0B);

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_745_140
        );
        L = new PrecisionLauncher(PrecisionPoolFactory(payable(FACTORY)), TREASURY);
        vm.deal(buyer, 1000 ether);
    }

    /// One supply, four valuations, the same 1 ETH buy into each.
    function test_whatTheStartingMarketCapDoes() public {
        uint256 supply = 1_000_000_000e18;
        uint256[4] memory caps = [uint256(1 ether), 3 ether, 30 ether, 300 ether];

        emit log("mcap | 1 ETH buys | share of supply | price x after");
        for (uint256 i; i < caps.length; ++i) {
            (address t, address p) = L.launch("C", "C", "", supply, 0, caps[i], creator);

            uint256 before = LaunchToken(t).balanceOf(buyer);
            vm.prank(buyer);
            PrecisionPool(payable(p)).swapExactIn{value: 1 ether}(address(0), 1 ether, 0, buyer);
            uint256 got = LaunchToken(t).balanceOf(buyer) - before;

            // Price before and after the same 1 ETH, in tokens per ETH.
            uint256 pxBefore = supply * 1e18 / caps[i];   // tokens per ETH at open
            uint256 pxAfter = got * 1e18 / 1 ether;       // tokens this ETH actually got

            emit log_named_uint("--- starting mcap (ETH)", caps[i] / 1e18);
            emit log_named_uint("    1 ETH buys (tokens)", got / 1e18);
            emit log_named_uint("    that is % of supply", got * 100 / supply);
            emit log_named_uint("    open px (tok per ETH)", pxBefore / 1e18);
            emit log_named_uint("    realised (tok per ETH)", pxAfter / 1e18);
        }
    }

    /// The claim in one assertion: a bigger number is a DEEPER market. The same
    /// ether buys a smaller share of the supply, because the curve resists more.
    function test_aBiggerNumberIsAHarderMarketToMove() public {
        uint256 supply = 1_000_000_000e18;

        (address tA, address pA) = L.launch("A", "A", "", supply, 0, 3 ether, creator);
        (address tB, address pB) = L.launch("B", "B", "", supply, 0, 300 ether, creator);

        vm.startPrank(buyer);
        PrecisionPool(payable(pA)).swapExactIn{value: 1 ether}(address(0), 1 ether, 0, buyer);
        PrecisionPool(payable(pB)).swapExactIn{value: 1 ether}(address(0), 1 ether, 0, buyer);
        vm.stopPrank();

        uint256 shareA = LaunchToken(tA).balanceOf(buyer) * 10000 / supply;
        uint256 shareB = LaunchToken(tB).balanceOf(buyer) * 10000 / supply;
        emit log_named_uint("1 ETH into a 3 ETH open, bps of supply", shareA);
        emit log_named_uint("1 ETH into a 300 ETH open, bps of supply", shareB);
        assertGt(shareA, shareB, "the cheaper open must hand over more of the supply");
    }

    /// And the thing that surprises people: NO ether is required to launch, and
    /// none is in the pool afterwards. The number is virtual until someone buys.
    function test_theNumberIsVirtualUntilSomebodyBuys() public {
        (, address p) = L.launch("C", "C", "", 1_000_000_000e18, 0, 30 ether, creator);
        assertEq(p.balance, 0, "a 30 ETH 'market cap' holds no ether at all");
    }
}
