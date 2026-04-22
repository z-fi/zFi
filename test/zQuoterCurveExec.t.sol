// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";

interface IZROUTER {
    function swapCurve(
        address to,
        bool exactOut,
        address[11] calldata route,
        uint256[4][5] calldata swapParams,
        address[5] calldata basePools,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}

/// @notice FORK execution tests for Curve routes — directly constructs `swapCurve`
///         calldata from `quoteCurve` results and executes against mainnet zRouter.
///         The motivating concern: zRouter's swapCurve may not correctly deliver ETH
///         when the chosen Curve pool holds WETH (WETH-representation pool) and the
///         user wants ETH out. These tests exercise that code path directly.
contract zQuoterCurveExecTest is Test {
    zQuoter quoter;

    address constant ETH = address(0);
    address constant _DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant _USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant _WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant _WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant _STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant _ROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

    uint256 constant SLIPPAGE = 100; // 1%
    uint256 constant DEADLINE = type(uint256).max;

    function setUp() public {
        quoter = new zQuoter();
    }

    function _bal(address token, address who) internal view returns (uint256) {
        if (token == ETH) return who.balance;
        (bool ok, bytes memory d) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return ok ? abi.decode(d, (uint256)) : 0;
    }

    function _approve(address token, address spender, uint256 amt) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amt));
        require(ok, "approve failed");
    }

    /// @dev Build a single-hop swapCurve call manually and execute it.
    function _execCurveDirect(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address pool,
        uint8 i,
        uint8 j,
        bool isStable,
        uint256 expectedOut,
        uint256 msgValue
    ) internal returns (bool ok, bytes memory ret, uint256 received) {
        address[11] memory route;
        route[0] = tokenIn;
        route[1] = pool;
        route[2] = tokenOut;

        uint256[4][5] memory swapParams;
        swapParams[0][0] = i;
        swapParams[0][1] = j;
        swapParams[0][2] = 1; // st = 1 (direct exchange)
        swapParams[0][3] = isStable ? 10 : 20; // pt

        address[5] memory basePools;
        uint256 amountLimit = (expectedOut * 99) / 100; // 1% slippage

        bytes memory cd = abi.encodeWithSelector(
            IZROUTER.swapCurve.selector,
            address(this),
            false, // exactIn
            route,
            swapParams,
            basePools,
            amountIn,
            amountLimit,
            DEADLINE
        );

        uint256 balBefore = _bal(tokenOut, address(this));
        (ok, ret) = _ROUTER.call{value: msgValue}(cd);
        received = ok ? _bal(tokenOut, address(this)) - balBefore : 0;
    }

    // ------------------------------------------------------------------
    // CASE A: ETH → token via Curve (WETH-representation pool)
    //         e.g. tricrypto2 has (USDT, WBTC, WETH) — WETH-rep, so this
    //         exercises ethIn + router auto-wrap behavior.
    // ------------------------------------------------------------------
    function test_curve_ETH_to_WBTC_via_tricrypto() public {
        uint256 amtIn = 10 ether;
        (, uint256 cout, address pool,, bool stable, uint8 i, uint8 j) = quoter.quoteCurve(false, ETH, _WBTC, amtIn, 8);
        if (pool == address(0)) {
            emit log("skip: no Curve route for ETH->WBTC");
            return;
        }
        emit log_named_address("pool ETH->WBTC", pool);
        emit log_named_uint("i", i);
        emit log_named_uint("j", j);
        emit log_named_uint("quoted WBTC", cout);

        vm.deal(address(this), amtIn);
        (bool ok, bytes memory ret, uint256 received) =
            _execCurveDirect(ETH, _WBTC, amtIn, pool, i, j, stable, cout, amtIn);

        if (!ok) {
            emit log_named_bytes("REVERT ETH->WBTC Curve", ret);
        }
        assertTrue(ok, "Curve ETH->WBTC reverted");
        assertGt(received, 0, "no WBTC received");
        emit log_named_uint("received WBTC", received);
    }

    // ------------------------------------------------------------------
    // CASE B (the critical one): TOKEN → ETH via Curve WETH-representation pool
    //         Pool outputs WETH, user wants ETH. This is where zRouter's
    //         output balance tracking + _safeTransferETH may misbehave.
    // ------------------------------------------------------------------
    function test_curve_WBTC_to_ETH_via_tricrypto() public {
        uint256 amtIn = 0.1e8; // 0.1 WBTC
        (, uint256 cout, address pool,, bool stable, uint8 i, uint8 j) = quoter.quoteCurve(false, _WBTC, ETH, amtIn, 8);
        if (pool == address(0)) {
            emit log("skip: no Curve route for WBTC->ETH");
            return;
        }
        emit log_named_address("pool WBTC->ETH", pool);
        emit log_named_uint("i", i);
        emit log_named_uint("j", j);
        emit log_named_uint("quoted ETH", cout);

        deal(_WBTC, address(this), amtIn);
        _approve(_WBTC, _ROUTER, amtIn);

        (bool ok, bytes memory ret, uint256 received) = _execCurveDirect(_WBTC, ETH, amtIn, pool, i, j, stable, cout, 0);

        if (!ok) {
            emit log_named_bytes("REVERT WBTC->ETH Curve (ETH-out bug?)", ret);
        }
        assertTrue(ok, "Curve WBTC->ETH reverted - ETH-output path broken");
        assertGt(received, 0, "no ETH received - Curve WETH-rep pool ETH-out misbehavior");
        emit log_named_uint("received ETH wei", received);
    }

    function test_curve_USDT_to_ETH_via_tricrypto() public {
        uint256 amtIn = 1000e6; // 1000 USDT
        (, uint256 cout, address pool,, bool stable, uint8 i, uint8 j) = quoter.quoteCurve(false, _USDT, ETH, amtIn, 8);
        if (pool == address(0)) {
            emit log("skip: no Curve route for USDT->ETH");
            return;
        }
        emit log_named_address("pool USDT->ETH", pool);

        deal(_USDT, address(this), amtIn);
        _approve(_USDT, _ROUTER, amtIn);

        (bool ok, bytes memory ret, uint256 received) = _execCurveDirect(_USDT, ETH, amtIn, pool, i, j, stable, cout, 0);

        if (!ok) {
            emit log_named_bytes("REVERT USDT->ETH Curve", ret);
        }
        assertTrue(ok, "Curve USDT->ETH reverted");
        assertGt(received, 0, "no ETH received");
        emit log_named_uint("received ETH wei", received);
    }

    // ------------------------------------------------------------------
    // CANDIDATE FIX: WBTC → ETH via Curve + explicit WETH→ETH unwrap hop
    // Route: [WBTC, tricrypto, WETH, WETH_dummy, ETH]
    // swapParams: [[i, j, 1, 20], [0, 0, 8, 0]]
    // ------------------------------------------------------------------
    function test_curve_WBTC_to_ETH_TWO_HOP_unwrap() public {
        uint256 amtIn = 0.1e8;
        (, uint256 cout, address pool,,, uint8 i, uint8 j) = quoter.quoteCurve(false, _WBTC, ETH, amtIn, 8);
        if (pool == address(0)) {
            emit log("skip: no Curve route for WBTC->ETH");
            return;
        }

        address[11] memory route;
        route[0] = _WBTC;
        route[1] = pool;
        route[2] = _WETH; // pool outputs WETH
        route[3] = _WETH; // non-zero dummy so loop continues to unwrap hop
        route[4] = ETH; // final output is ETH (address(0))

        uint256[4][5] memory swapParams;
        swapParams[0][0] = i;
        swapParams[0][1] = j;
        swapParams[0][2] = 1; // st=1 (Curve exchange)
        swapParams[0][3] = 20; // pt=20 (crypto)
        swapParams[1][2] = 8; // st=8 (WETH→ETH unwrap)

        address[5] memory basePools;
        uint256 amountLimit = (cout * 99) / 100;

        bytes memory cd = abi.encodeWithSelector(
            IZROUTER.swapCurve.selector,
            address(this),
            false,
            route,
            swapParams,
            basePools,
            amtIn,
            amountLimit,
            DEADLINE
        );

        deal(_WBTC, address(this), amtIn);
        _approve(_WBTC, _ROUTER, amtIn);

        uint256 balBefore = address(this).balance;
        (bool ok, bytes memory ret) = _ROUTER.call(cd);

        if (!ok) {
            emit log_named_bytes("2-hop unwrap REVERT", ret);
        }
        assertTrue(ok, "2-hop Curve+unwrap reverted");
        uint256 received = address(this).balance - balBefore;
        assertGt(received, 0, "no ETH received even with 2-hop workaround");
        emit log_named_uint("2-hop received ETH wei", received);
    }

    // ------------------------------------------------------------------
    // VALIDATE THE QUOTER'S FIX: force Curve as winner via pairs where Curve dominates,
    // then call the quoter's buildBestSwap (which internally routes through our patched
    // _buildCurveSwapCalldata with the 2-hop unwrap for ethOut).
    // ------------------------------------------------------------------
    function test_quoter_buildBestSwap_WSTETH_to_ETH_if_Curve_wins() public {
        uint256 amtIn = 1 ether;
        (zQuoter.Quote memory q, bytes memory callData,, uint256 msgValue) =
            quoter.buildBestSwap(address(this), false, _WSTETH, ETH, amtIn, SLIPPAGE, DEADLINE);
        emit log_named_string("source", _srcName(uint8(q.source)));
        emit log_named_uint("quoted ETH", q.amountOut);

        if (q.source != zQuoter.AMM.CURVE) {
            emit log("not Curve - skipping (fix still applies; just not exercised here)");
            return;
        }

        deal(_WSTETH, address(this), amtIn);
        _approve(_WSTETH, _ROUTER, amtIn);

        uint256 balBefore = address(this).balance;
        (bool ok, bytes memory ret) = _ROUTER.call{value: msgValue}(callData);
        if (!ok) emit log_named_bytes("REVERT quoter wstETH->ETH Curve", ret);
        assertTrue(ok, "quoter-built wstETH->ETH Curve path reverted");
        uint256 received = address(this).balance - balBefore;
        assertGt(received, 0, "no ETH received from quoter-built Curve path");
        emit log_named_uint("received ETH via quoter+fix", received);
    }

    function _srcName(uint8 s) internal pure returns (string memory) {
        if (s == 0) return "UNI_V2";
        if (s == 1) return "SUSHI";
        if (s == 2) return "ZAMM";
        if (s == 3) return "UNI_V3";
        if (s == 4) return "UNI_V4";
        if (s == 5) return "CURVE";
        if (s == 6) return "LIDO";
        if (s == 7) return "WETH_WRAP";
        return "?";
    }

    receive() external payable {}
}
