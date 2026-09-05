// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";

address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
address constant DEEPSTATE = 0x6cf19308C22FC82ea620Fa0B3E94948d20f27B96;
address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}
interface IDeep { function poolId(address,address) external pure returns (bytes32);
                  function poolEpoch(bytes32) external view returns (uint256); }

/// @dev zSwap builds the book leg as a multicall of swapDeep + a 3-arg sweep,
/// exactly as encoded here. Quoting it has been proven; this executes it.
contract DeepLegTest is Test {
    address alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork("https://rpc.mainnet.chain.robinhood.com");
        vm.deal(alice, 10 ether);
    }

    function testTheLegZSwapEmitsActuallyExecutes() public {
        uint256 epoch = IDeep(DEEPSTATE).poolEpoch(IDeep(DEEPSTATE).poolId(USDG, NVDA));
        uint256 amtIn = 1e17;                       // 0.1 NVDA
        // quantity is TOKEN0 — USDG at 6 decimals — not the token being sold.
        // The page probes for a fillable value; 1e17 here would ask the book for
        // a hundred billion USDG and fail when it pulls against the router.
        bytes32 order = bytes32((uint256(uint32(type(int32).max)) << 224) | (uint256(23e6) << 64));

        vm.prank(DEEPSTATE);
        IERC20(NVDA).transfer(alice, amtIn);

        // byte-for-byte the two legs the page encodes
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            bytes4(0xad33b1d0), alice, USDG, NVDA, epoch, order, true, amtIn, uint256(1), type(uint256).max
        );
        calls[1] = abi.encodeWithSelector(bytes4(0xdc2c256f), NVDA, uint256(0), alice);

        vm.startPrank(alice);
        IERC20(NVDA).approve(ZROUTER, amtIn);
        (bool ok, bytes memory ret) = ZROUTER.call(abi.encodeWithSelector(bytes4(0xac9650d8), calls));
        vm.stopPrank();

        if (!ok) {
            emit log_named_bytes("revert data", ret);
            if (ret.length >= 4) emit log_named_bytes32("selector", bytes32(ret));
        }
        assertTrue(ok, "the page's book leg reverted on the live router");
        bytes[] memory res = abi.decode(ret, (bytes[]));
        (uint256 usedIn, uint256 gotOut) = abi.decode(res[0], (uint256, uint256));
        assertGt(gotOut, 0, "book filled nothing");
        assertEq(IERC20(USDG).balanceOf(alice), gotOut, "output delivered to the user");
        assertEq(IERC20(NVDA).balanceOf(ZROUTER), 0, "nothing left in the router");
        emit log_named_uint("NVDA in ", usedIn);
        emit log_named_uint("USDG out", gotOut);
    }
}
