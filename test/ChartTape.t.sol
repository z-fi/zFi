// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {PrecisionLauncher, LaunchToken} from "../src/pools/PrecisionLauncher.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";

/// @notice Real swaps against a real pool, so the tape it writes is one the
///         curve actually produced.
///
///         The earlier charts were drawn by the app's own renderer but from a
///         tape written BY HAND: the volume bars bore no arithmetic relation to
///         the price moves, so an eight-fold move sat above a few small bars
///         that could never have caused it. Here the pool prices every swap
///         itself and records its own bars, so price and volume agree by
///         construction - which is the only way a chart in a screenshot is
///         worth anything.
contract ChartTapeTest is Test {
    address constant FACTORY = 0x000000Eb27B557aB426d9E99cFd54EC455799e81;
    address constant TREASURY = 0x000000aA142133107c7D2664F900f80e28BbfFbd;
    uint256 constant SUPPLY = 1_000_000_000e18;

    PrecisionLauncher L;
    address trader = makeAddr("trader");
    address creator = makeAddr("creator");

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_745_140
        );
        L = new PrecisionLauncher(PrecisionPoolFactory(payable(FACTORY)), TREASURY);
        vm.deal(trader, 100_000 ether);
    }

    /// @dev One 5-minute bar per step. `seq` is a per-step signed ether size:
    ///      positive buys, negative sells, zero is a quiet bar.
    function _run(string memory name, int256[] memory seq) internal {
        (address t, address p) = L.launch(name, name, "", SUPPLY, 0, 30 ether, creator);
        PrecisionPool pool = PrecisionPool(payable(p));

        for (uint256 i; i < seq.length; ++i) {
            vm.warp(block.timestamp + 5 minutes);
            int256 s = seq[i];
            if (s > 0) {
                vm.prank(trader);
                pool.swapExactIn{value: uint256(s)}(address(0), uint256(s), 0, trader);
            } else if (s < 0) {
                uint256 bal = LaunchToken(t).balanceOf(trader);
                uint256 sell = bal * uint256(-s) / 1e20;   // -s is a percentage x1e18
                if (sell == 0) continue;
                vm.startPrank(trader);
                LaunchToken(t).approve(p, sell);
                pool.swapExactIn(t, sell, 0, trader);
                vm.stopPrank();
            }
        }

        uint256[] memory bars = pool.tape(5 minutes, 96);
        string memory out = "[";
        for (uint256 i; i < bars.length; ++i) {
            out = string.concat(out, i == 0 ? "" : ",", LibString.toString(bars[i]));
        }
        vm.writeFile(string.concat("out/tape-", name, ".json"), string.concat(out, "]"));
        emit log_named_uint(string.concat(name, " bars"), bars.length);
    }

    function _seq(uint256 n) internal pure returns (int256[] memory a) { a = new int256[](n); }

    function test_dumpRealTapes() public {
        // A launch that runs: steady buying, growing.
        int256[] memory up = _seq(88);
        for (uint256 i; i < 88; ++i) up[i] = int256(1 ether + (i * 6e16));
        _run("climb", up);

        // Sharp discovery then chop: heavy early buys, then two-way flow.
        int256[] memory pump = _seq(88);
        for (uint256 i; i < 88; ++i) {
            pump[i] = i < 22 ? int256(6 ether) : (i % 3 == 0 ? -int256(4e18) : int256(1 ether));
        }
        _run("launch", pump);

        // Two-way, no trend.
        int256[] memory chop = _seq(88);
        for (uint256 i; i < 88; ++i) {
            chop[i] = i % 4 < 2 ? int256(3 ether) : -int256(9e18);
        }
        _run("volatile", chop);

        // Buying, then persistent distribution.
        int256[] memory fade = _seq(88);
        for (uint256 i; i < 88; ++i) {
            fade[i] = i < 26 ? int256(5 ether) : -int256(6e18);
        }
        _run("fade", fade);
    }
}
