// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;
import {Test} from "../lib/forge-std/src/Test.sol";

/// @notice Can a WETH input reach a NATIVE Precision market inside ONE zRouter
///         multicall - deposit, unwrap, route - so the user is not asked to
///         unwrap in a transaction of its own?
contract PrecisionWethFoldTest is Test {
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant PROUTE = 0x000000384711c65f633Aa4487b968ecb7956DB0F;
    address constant POOL = 0xc37F8c7E9Afe897893952ABa7fD91E0AB947837d;
    address constant ZORG = 0x00a6bA94BBb5474725515De88fE04F854f2dCb12;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address trader = makeAddr("trader");

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_739_900
        );
        vm.deal(trader, 10 ether);
        vm.prank(trader);
        (bool ok,) = WETH.call{value: 5 ether}(abi.encodeWithSignature("deposit()"));
        require(ok, "wrap failed");
    }

    function _routeData(uint256 amt, uint256 minOut) internal view returns (bytes memory) {
        address[] memory pools = new address[](1);
        pools[0] = POOL;
        return abi.encodeWithSelector(0x5d6498e1, pools, address(0), ZORG, amt, minOut, trader);
    }

    /// The router forwards `msg.value` to the executor and nothing else, so
    /// ether it is holding after an in-multicall unwrap never reaches the route.
    function test_foldingTheUnwrapIntoTheMulticallDoesNotWork() public {
        uint256 amt = 0.01 ether;
        vm.startPrank(trader);
        (bool okA,) = WETH.call(abi.encodeWithSignature("approve(address,uint256)", ZROUTER, amt));
        require(okA, "approve");

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSignature("deposit(address,uint256,uint256)", WETH, 0, amt);
        calls[1] = abi.encodeWithSignature("unwrap(uint256)", amt);
        calls[2] = abi.encodeWithSelector(
            0x5f3bd1c8, address(0), amt, trader, ZORG, uint256(1), PROUTE, _routeData(amt, 1)
        );
        // No value: the whole point is that the user is paying in WETH.
        (bool ok,) = ZROUTER.call(abi.encodeWithSignature("multicall(bytes[])", calls));
        vm.stopPrank();

        assertFalse(ok, "if this passes, the unwrap CAN be folded in and the popup is removable");
    }

    /// What does work today: unwrap first, then one routed call carrying value.
    function test_unwrappingFirstThenRoutingDoesWork() public {
        uint256 amt = 0.01 ether;
        vm.startPrank(trader);
        (bool okU,) = WETH.call(abi.encodeWithSignature("withdraw(uint256)", amt));
        require(okU, "unwrap");
        uint256 before = _zorg(trader);
        (bool ok,) = ZROUTER.call{value: amt}(
            abi.encodeWithSelector(0x5f3bd1c8, address(0), amt, trader, ZORG, uint256(1), PROUTE, _routeData(amt, 1))
        );
        vm.stopPrank();
        assertTrue(ok, "the two-step path must work");
        assertGt(_zorg(trader) - before, 0, "and deliver");
    }

    function _zorg(address who) internal view returns (uint256) {
        (bool ok, bytes memory d) = ZORG.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return ok ? abi.decode(d, (uint256)) : 0;
    }
}
