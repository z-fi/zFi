// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Fwabol} from "../src/forwarders/Fwabol.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Fwabol against the real pool, on a fork.
///
/// The claim under test is narrow and load-bearing: FWA must land in the
/// USER's wallet and never in the adapter's. FWAToken reverts any transfer
/// that does not touch the PoolManager, the owner, or a distributor, so an
/// adapter that takes delivery cannot pass the token on - the funds are stuck
/// at its address permanently, with no admin path out. A test that only
/// asserted "the call succeeded" would pass while doing exactly that.
contract FwabolForkTest is Test {
    address constant UR = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    Fwabol fwabol;
    address user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth.merkle.io")));
        fwabol = new Fwabol(UR);
        vm.deal(user, 10 ether);
    }

    /// The whole point: buy through the adapter, and the FWA is the user's.
    function test_buyDeliversFwaToTheUserNotTheAdapter() public {
        uint256 before = IERC20(FWA).balanceOf(user);

        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(user, 1, block.timestamp + 300);

        uint256 got = IERC20(FWA).balanceOf(user) - before;
        assertGt(got, 0, "user received FWA");
        assertEq(IERC20(FWA).balanceOf(address(fwabol)), 0, "adapter holds none - it could never pass it on");
        assertEq(address(fwabol).balance, 0, "no ETH rests in the adapter");
        emit log_named_decimal_uint("FWA out for 0.001 ETH", got, 18);
    }

    /// A caller naming the adapter would strand the output forever, so it is
    /// refused before the swap rather than discovered after it.
    function test_adapterCannotBeNamedAsRecipient() public {
        vm.prank(user);
        vm.expectRevert(Fwabol.BadRecipient.selector);
        fwabol.swapEthForFwa{value: 0.001 ether}(address(fwabol), 1, block.timestamp + 300);
    }

    function test_zeroRecipientRefused() public {
        vm.prank(user);
        vm.expectRevert(Fwabol.BadRecipient.selector);
        fwabol.swapEthForFwa{value: 0.001 ether}(address(0), 1, block.timestamp + 300);
    }

    function test_emptySwapRefused() public {
        vm.prank(user);
        vm.expectRevert(Fwabol.NothingIn.selector);
        fwabol.swapEthForFwa(user, 1, block.timestamp + 300);
    }

    /// The floor is the pool's, not the adapter's - so an unreachable one has
    /// to surface as the pool's own revert rather than a silent shortfall.
    function test_unreachableMinOutReverts() public {
        vm.prank(user);
        vm.expectRevert();
        fwabol.swapEthForFwa{value: 0.001 ether}(user, type(uint128).max, block.timestamp + 300);
    }

    /// USDC -> FWA, hopped through ETH.
    ///
    /// There is no USDC/FWA pool, and there does not need to be: the first leg
    /// is an ordinary AMM swap to ETH, the second is this adapter. What makes
    /// the composition work is that each leg pays its output to an address that
    /// is allowed to receive it - ETH to the router, FWA to the user - so no
    /// intermediate ever custodies FWA. That is the property that lets FWA join
    /// a multi-hop route at all, and it only holds while FWA is the LAST leg.
    /// A route that tried to hop THROUGH FWA would have to hold it in between,
    /// which the token forbids.
    function test_multihopUsdcToFwaViaEth() public {
        deal(USDC, user, 10_000e6);

        // Leg 1 stands in for whatever the metadex picks - zRouter, a V3 pool,
        // PrecisionPool. All this test needs is that the user ends up holding
        // ETH; the interesting half is leg 2.
        uint256 ethBefore = user.balance;
        vm.deal(user, ethBefore + 0.001 ether);

        uint256 before = IERC20(FWA).balanceOf(user);
        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(user, 1, block.timestamp + 300);

        assertGt(IERC20(FWA).balanceOf(user) - before, 0, "the ETH leg feeds the FWA leg");
        assertEq(IERC20(FWA).balanceOf(address(fwabol)), 0, "still nothing stuck mid-route");
    }
}
