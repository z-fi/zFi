// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Fwabol} from "../src/forwarders/Fwabol.sol";
import {PoolKey} from "../src/V4QuoteLens.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata) external returns (bytes memory);
    function swap(PoolKey memory, SwapParams memory, bytes calldata) external returns (int256);
    function sync(address) external;
    function settle() external payable returns (uint256);
    function take(address, address, uint256) external;
}

/// @notice Can FWA be SOLD through an adapter after all?
///
/// The received answer is no, and it is the Universal Router's answer, not
/// v4's: UR's `SETTLE` pays with `permit2.transferFrom(_msgSender(), ...)`, so
/// routed through an adapter the payer is the adapter, which would have to hold
/// FWA first - the one thing FWAToken forbids.
///
/// But settling in v4 is not that. It is `sync()`, get the tokens to the
/// PoolManager by ANY means, `settle()` - the credit comes from the measured
/// balance change, and nothing requires the payer to be the locker. So an
/// adapter can unlock, swap, and then pull FWA straight from the seller to the
/// PoolManager. It never takes custody, and `to == poolManager` is a transfer
/// shape the token explicitly permits.
///
/// Whether that is enough is one question this cannot answer from the armchair:
/// the pm branch is gated on a TRANSIENT allowance the hook raises during the
/// swap, and whether the hook raises one that covers an inbound user payment is
/// the hook's business. So: build the thing and run it.
contract FwaSellAdapterProbe {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address constant HOOK = 0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444;
    uint160 constant MAX_SQRT_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    error MinOut(uint256 got, uint256 min);

    /// @param seller Whose FWA is sold. Must have approved this contract.
    function sell(address seller, uint128 amountIn, address recipient, uint128 minOut)
        external
        returns (uint256 ethOut)
    {
        return abi.decode(
            PM.unlock(abi.encode(seller, amountIn, recipient, minOut)), (uint256)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM), "only pm");
        (address seller, uint128 amountIn, address recipient, uint128 minOut) =
            abi.decode(data, (address, uint128, address, uint128));

        // currency0 is native ETH, currency1 is FWA, so selling FWA is !zeroForOne.
        int256 packed = PM.swap(
            PoolKey(address(0), FWA, 0, 60, HOOK),
            SwapParams(false, -int256(uint256(amountIn)), MAX_SQRT_MINUS_ONE),
            ""
        );
        // BalanceDelta: amount0 in the high 128 bits, amount1 in the low.
        int128 ethDelta = int128(packed >> 128);
        int128 fwaDelta = int128(packed);
        require(ethDelta > 0, "no ETH owed");
        require(fwaDelta < 0, "no FWA owed");

        // Settle the FWA WITHOUT ever holding it: the seller pays the
        // PoolManager directly, and `settle` credits the measured difference.
        uint256 owed = uint256(uint128(-fwaDelta));
        PM.sync(FWA);
        (bool ok, bytes memory ret) = FWA.call(
            abi.encodeWithSelector(0x23b872dd, seller, address(PM), owed) // transferFrom
        );
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        PM.settle();

        uint256 ethOut = uint256(uint128(ethDelta));
        if (ethOut < minOut) revert MinOut(ethOut, minOut);
        PM.take(address(0), recipient, ethOut);
        return abi.encode(ethOut);
    }
}

contract FwaSellProbeTest is Test {
    address constant UR = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;

    Fwabol fwabol;
    FwaSellAdapterProbe sellProbe;
    address user = makeAddr("seller");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        fwabol = new Fwabol(UR);
        sellProbe = new FwaSellAdapterProbe();
        vm.deal(user, 10 ether);

        // Get real FWA the honest way - buy it through the live buy path.
        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.05 ether}(user, 1, block.timestamp + 300);
        assertGt(IERC20(FWA).balanceOf(user), 0, "the seller holds FWA to sell");
    }

    /// The whole question, in one assertion.
    function test_canFwaBeSoldWithoutAnAdapterEverHoldingIt() public {
        uint128 amountIn = uint128(IERC20(FWA).balanceOf(user) / 2);

        vm.prank(user);
        IERC20(FWA).approve(address(sellProbe), type(uint256).max);

        uint256 ethBefore = user.balance;
        uint256 fwaBefore = IERC20(FWA).balanceOf(user);
        // A delta, not a zero-check - mainnet already holds a wei at the
        // address Foundry deploys this to, exactly as it does for Fwabol's.
        uint256 probeEthBefore = address(sellProbe).balance;

        uint256 ethOut = sellProbe.sell(user, amountIn, user, 1);

        assertGt(ethOut, 0, "the sell produced ETH");
        assertEq(user.balance - ethBefore, ethOut, "and it reached the seller");
        assertEq(fwaBefore - IERC20(FWA).balanceOf(user), amountIn, "the FWA left the seller");
        assertEq(IERC20(FWA).balanceOf(address(sellProbe)), 0, "the adapter never held any");
        assertEq(address(sellProbe).balance, probeEthBefore, "nor gained any ETH");
        emit log_named_decimal_uint("ETH out", ethOut, 18);
    }
}
