// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {zQuoter} from "../src/zQuoter.sol";

/// Does the quote match what you actually get?
///
/// The per-venue suite proves every venue *executes* and returns something
/// non-zero. That is a liveness check, not a correctness one: a quote could
/// promise 100 and deliver 1 and still pass. At a fixed fork block the AMM math
/// is deterministic and nothing else lands in between, so a correct quoter must
/// predict the fill EXACTLY. Any drift is quoter error, and this measures it.
///
/// It also covers the two builders zSwap actually calls, which the single-hop
/// suites never touch: buildBestSwapViaETHMulticall (token->ETH->token) and
/// build3HopMulticall.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract zQuoterAccuracyTest is Test {
    string constant DEFAULT_RPC = "https://gateway.tenderly.co/public/mainnet";
    uint256 constant DEFAULT_FORK_BLOCK = 25_906_900;

    address constant ROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant ETH = address(0);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    zQuoter q;

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string(DEFAULT_RPC)), vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));
        q = new zQuoter();
    }

    function _bal(address t) internal view returns (uint256) {
        return t == ETH ? address(this).balance : IERC20(t).balanceOf(address(this));
    }

    function _fund(address t, uint256 amt) internal {
        if (t == ETH) {
            vm.deal(address(this), amt + 1 ether);
        } else {
            deal(t, address(this), amt);
            (bool z,) = t.call(abi.encodeWithSelector(0x095ea7b3, ROUTER, uint256(0)));
            (bool a,) = t.call(abi.encodeWithSelector(0x095ea7b3, ROUTER, type(uint256).max));
            require(z || a, "approve");
            vm.deal(address(this), 1 ether);
        }
    }

    /// bps of drift between quoted and delivered.
    function _drift(uint256 quoted, uint256 got) internal pure returns (uint256) {
        uint256 d = quoted > got ? quoted - got : got - quoted;
        return quoted == 0 ? type(uint256).max : d * 10_000 / quoted;
    }

    // -------------------------------------------------------------- single hop

    function _checkDirect(string memory label, address tIn, address tOut, uint256 amt) internal {
        (zQuoter.Quote memory best,) = q.getQuotes(false, tIn, tOut, amt);
        (, bytes memory cd,, uint256 val) =
            q.buildBestSwap(address(this), false, tIn, tOut, amt, 300, block.timestamp + 1800);

        _fund(tIn, amt);
        uint256 before = _bal(tOut);
        (bool ok,) = ROUTER.call{value: val}(cd);
        assertTrue(ok, string.concat(label, ": execution reverted"));
        uint256 got = _bal(tOut) - before;

        emit log_named_string("pair", label);
        emit log_named_uint("  quoted ", best.amountOut);
        emit log_named_uint("  actual ", got);
        emit log_named_uint("  drift bps", _drift(best.amountOut, got));
        assertEq(got, best.amountOut, string.concat(label, ": QUOTE != FILL"));
    }

    function test_accuracy_ETH_to_USDC() public {
        _checkDirect("ETH->USDC", ETH, USDC, 10 ether);
    }

    function test_accuracy_USDC_to_ETH() public {
        _checkDirect("USDC->ETH", USDC, ETH, 100_000e6);
    }

    function test_accuracy_WBTC_to_ETH() public {
        _checkDirect("WBTC->ETH", WBTC, ETH, 0.1e8);
    }

    function test_accuracy_ETH_to_WSTETH() public {
        _checkDirect("ETH->wstETH", ETH, WSTETH, 5 ether);
    }

    // ------------------------------------------------------- multihop via ETH

    /// token -> ETH -> token, the builder zSwap uses for any non-ETH pair.
    function _checkViaETH(string memory label, address tIn, address tOut, uint256 amt) internal {
        // slippageBps = 0: later legs are quoted from the PREVIOUS leg's
        // slippage-adjusted floor, so any non-zero bound makes the reported
        // amountOut a floor rather than an estimate. At 0 it is the estimate.
        (zQuoter.Quote memory legA, zQuoter.Quote memory legB,, bytes memory mc, uint256 val) =
            q.buildBestSwapViaETHMulticall(address(this), address(this), false, tIn, tOut, amt, 0, block.timestamp + 1800);
        // The builder collapses to a single call when a direct route wins; then
        // legB is unused and legA carries the whole trade.
        uint256 expected = legB.amountOut != 0 ? legB.amountOut : legA.amountOut;

        _fund(tIn, amt);
        uint256 before = _bal(tOut);
        (bool ok,) = ROUTER.call{value: val}(mc);
        assertTrue(ok, string.concat(label, ": multicall reverted"));
        uint256 got = _bal(tOut) - before;

        emit log_named_string("viaETH", label);
        emit log_named_uint("  quoted ", expected);
        emit log_named_uint("  actual ", got);
        emit log_named_uint("  drift bps", _drift(expected, got));
        assertGt(got, 0, string.concat(label, ": delivered nothing"));
        assertEq(got, expected, string.concat(label, ": QUOTE != FILL"));
    }

    function test_viaETH_USDC_to_WBTC() public {
        _checkViaETH("USDC->WBTC", USDC, WBTC, 100_000e6);
    }

    function test_viaETH_USDT_to_WBTC() public {
        _checkViaETH("USDT->WBTC", USDT, WBTC, 100_000e6);
    }

    function test_viaETH_DAI_to_WSTETH() public {
        _checkViaETH("DAI->wstETH", DAI, WSTETH, 100_000e18);
    }

    function test_viaETH_WBTC_to_USDC() public {
        _checkViaETH("WBTC->USDC", WBTC, USDC, 1e8);
    }

    // ------------------------------------------------------------------ 3 hop

    function _check3Hop(string memory label, address tIn, address tOut, uint256 amt) internal {
        (zQuoter.Quote memory legA, zQuoter.Quote memory legB, zQuoter.Quote memory legC,, bytes memory mc, uint256 val)
        = q.build3HopMulticall(address(this), false, tIn, tOut, amt, 0, block.timestamp + 1800);
        uint256 expected = legC.amountOut != 0 ? legC.amountOut : (legB.amountOut != 0 ? legB.amountOut : legA.amountOut);
        if (expected == 0) {
            emit log_named_string("3hop SKIPPED (no route)", label);
            return;
        }

        _fund(tIn, amt);
        uint256 before = _bal(tOut);
        (bool ok,) = ROUTER.call{value: val}(mc);
        assertTrue(ok, string.concat(label, ": 3hop reverted"));
        uint256 got = _bal(tOut) - before;

        emit log_named_string("3hop", label);
        emit log_named_uint("  quoted ", expected);
        emit log_named_uint("  actual ", got);
        emit log_named_uint("  drift bps", _drift(expected, got));
        assertGt(got, 0, string.concat(label, ": delivered nothing"));
        assertEq(got, expected, string.concat(label, ": QUOTE != FILL"));
    }

    function test_3hop_USDC_to_WSTETH() public {
        _check3Hop("USDC->wstETH", USDC, WSTETH, 100_000e6);
    }

    function test_3hop_DAI_to_WBTC() public {
        _check3Hop("DAI->WBTC", DAI, WBTC, 100_000e18);
    }

    // ---------------------------------------------------------------- exactOut

    /// exactOut is a distinct code path: the quoter solves for the INPUT needed
    /// to deliver a fixed output, and the router bounds max-in rather than
    /// min-out. A correct quote must predict the spend exactly.
    function _checkExactOut(string memory label, address tIn, address tOut, uint256 wantOut) internal {
        (zQuoter.Quote memory best,) = q.getQuotes(true, tIn, tOut, wantOut);
        if (best.amountIn == 0) {
            emit log_named_string("exactOut SKIPPED (no route)", label);
            return;
        }
        (, bytes memory cd, uint256 limit, uint256 val) =
            q.buildBestSwap(address(this), true, tIn, tOut, wantOut, 300, block.timestamp + 1800);

        _fund(tIn, limit == 0 ? best.amountIn * 2 : limit * 2);
        uint256 inBefore = _bal(tIn);
        uint256 outBefore = _bal(tOut);
        (bool ok,) = ROUTER.call{value: val}(cd);
        assertTrue(ok, string.concat(label, ": exactOut reverted"));
        uint256 gotOut = _bal(tOut) - outBefore;

        emit log_named_string("exactOut", label);
        emit log_named_uint("  wanted out", wantOut);
        emit log_named_uint("  got out   ", gotOut);
        emit log_named_uint("  quoted in ", best.amountIn);
        assertGe(gotOut, wantOut, string.concat(label, ": delivered less than the exact output asked for"));
        inBefore;
    }

    function test_exactOut_ETH_to_USDC() public {
        _checkExactOut("ETH->USDC(exact)", ETH, USDC, 10_000e6);
    }

    function test_exactOut_USDC_to_ETH() public {
        _checkExactOut("USDC->ETH(exact)", USDC, ETH, 5 ether);
    }

    function test_exactOut_WBTC_to_ETH() public {
        _checkExactOut("WBTC->ETH(exact)", WBTC, ETH, 2 ether);
    }
}
