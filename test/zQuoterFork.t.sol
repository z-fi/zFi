// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";

contract zQuoterForkTest is Test {
    zQuoter quoter;

    address constant ETH = address(0);
    address constant _DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant _BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address constant _WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    address constant USER = address(0xBEEF);

    function setUp() public {
        // Deploy fresh zQuoter with our fixes on the fork
        quoter = new zQuoter();
    }

    // ====== EXACT-OUT SINGLE-HOP TESTS ======

    function test_exactOut_ETH_to_DAI_100() public {
        uint256 amount = 100e18; // 100 DAI
        (zQuoter.Quote memory best,) = quoter.getQuotes(true, ETH, _DAI, amount);

        // Should NOT be the bogus V3 1bp result (~5e14). Should be ~5e16.
        assertGt(best.amountIn, 1e16, "DAI exact-out: amountIn too low (bogus V3 1bp?)");
        assertLt(best.amountIn, 1e18, "DAI exact-out: amountIn unreasonably high");
        assertEq(best.amountOut, amount, "DAI exact-out: amountOut should equal requested");

        emit log_named_uint("ETH needed for 100 DAI", best.amountIn);
        emit log_named_uint("AMM source", uint256(best.source));
    }

    function test_exactOut_ETH_to_USDC_100() public {
        uint256 amount = 100e6; // 100 USDC
        (zQuoter.Quote memory best,) = quoter.getQuotes(true, ETH, _USDC, amount);

        assertGt(best.amountIn, 1e16, "USDC exact-out: amountIn too low");
        assertLt(best.amountIn, 1e18, "USDC exact-out: amountIn unreasonably high");
        assertEq(best.amountOut, amount);

        emit log_named_uint("ETH needed for 100 USDC", best.amountIn);
    }

    function test_exactOut_DAI_vs_USDC_sanity() public {
        // 100 DAI and 100 USDC should require roughly the same ETH (both ~$1)
        (zQuoter.Quote memory daiQ,) = quoter.getQuotes(true, ETH, _DAI, 100e18);
        (zQuoter.Quote memory usdcQ,) = quoter.getQuotes(true, ETH, _USDC, 100e6);

        // They should be within 5% of each other
        uint256 diff = daiQ.amountIn > usdcQ.amountIn ? daiQ.amountIn - usdcQ.amountIn : usdcQ.amountIn - daiQ.amountIn;
        uint256 avg = (daiQ.amountIn + usdcQ.amountIn) / 2;

        assertLt(diff * 100 / avg, 5, "DAI and USDC exact-out should need similar ETH (within 5%)");

        emit log_named_uint("ETH for 100 DAI", daiQ.amountIn);
        emit log_named_uint("ETH for 100 USDC", usdcQ.amountIn);
    }

    // ====== EXACT-IN SINGLE-HOP TESTS (should be unaffected) ======

    function test_exactIn_ETH_to_DAI() public {
        uint256 amount = 1e16; // 0.01 ETH
        (zQuoter.Quote memory best,) = quoter.getQuotes(false, ETH, _DAI, amount);

        assertGt(best.amountOut, 0, "exact-in: should get some DAI");
        assertEq(best.amountIn, amount, "exact-in: amountIn should equal input");

        emit log_named_uint("DAI out for 0.01 ETH", best.amountOut);
    }

    function test_exactIn_ETH_to_USDC() public {
        uint256 amount = 1e16; // 0.01 ETH
        (zQuoter.Quote memory best,) = quoter.getQuotes(false, ETH, _USDC, amount);

        assertGt(best.amountOut, 0, "exact-in: should get some USDC");

        emit log_named_uint("USDC out for 0.01 ETH", best.amountOut);
    }

    // ====== DIAGNOSTIC: why does buildBestSwapViaETHMulticall revert? ======

    function test_diag_buildBestSwap_selfCall() public {
        // Replicate what _bestSingleHop does: this.buildBestSwap(...)
        // If this reverts, the multicall function falls through to hub routing
        try quoter.buildBestSwap(USER, true, ETH, _DAI, 100e18, 100, block.timestamp + 300) returns (
            zQuoter.Quote memory q, bytes memory, uint256, uint256
        ) {
            emit log_named_uint("DIAG: buildBestSwap ok, amountIn", q.amountIn);
            emit log_named_uint("DIAG: source", uint256(q.source));
        } catch Error(string memory reason) {
            emit log_named_string("DIAG: buildBestSwap reverted", reason);
        } catch (bytes memory data) {
            emit log_named_uint("DIAG: buildBestSwap reverted, data len", data.length);
        }
    }

    // ====== buildBestSwapViaETHMulticall TESTS ======

    function test_buildBest_exactOut_ETH_to_DAI() public {
        uint256 amount = 100e18; // 100 DAI
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,, uint256 msgValue) = quoter.buildBestSwapViaETHMulticall(
            USER, USER, true, ETH, _DAI, amount, 100, block.timestamp + 300, 0, 0, address(0)
        );

        bool isTwoHop = b.amountOut > 0;

        emit log_named_uint("Leg A amountIn (ETH needed)", a.amountIn);
        emit log_named_uint("Leg A source", uint256(a.source));
        emit log_named_string("Two-hop", isTwoHop ? "yes" : "no");
        if (isTwoHop) {
            emit log_named_uint("Leg B amountIn", b.amountIn);
            emit log_named_uint("Leg B source", uint256(b.source));
        }
        emit log_named_uint("msgValue", msgValue);

        // The required ETH should be reasonable (~0.03-0.1 ETH for 100 DAI)
        assertGt(a.amountIn, 1e16, "buildBest DAI: ETH needed too low");
        assertLt(a.amountIn, 1e18, "buildBest DAI: ETH needed too high");
        assertGt(msgValue, 0, "buildBest DAI: msgValue should be > 0 for ETH input");
    }

    function test_buildBest_exactOut_ETH_to_USDC() public {
        uint256 amount = 100e6; // 100 USDC
        (zQuoter.Quote memory a,,,, uint256 msgValue) = quoter.buildBestSwapViaETHMulticall(
            USER, USER, true, ETH, _USDC, amount, 100, block.timestamp + 300, 0, 0, address(0)
        );

        assertGt(a.amountIn, 1e16, "buildBest USDC: ETH needed too low");
        assertLt(a.amountIn, 1e18, "buildBest USDC: ETH needed too high");

        emit log_named_uint("ETH needed for 100 USDC", a.amountIn);
    }

    function test_buildBest_exactIn_ETH_to_DAI() public {
        uint256 amount = 5e16; // 0.05 ETH
        (zQuoter.Quote memory a, zQuoter.Quote memory b,,,) = quoter.buildBestSwapViaETHMulticall(
            USER, USER, false, ETH, _DAI, amount, 100, block.timestamp + 300, 0, 0, address(0)
        );

        bool isTwoHop = b.amountOut > 0;
        uint256 output = isTwoHop ? b.amountOut : a.amountOut;

        // 0.05 ETH should get roughly ~100 DAI (depending on price)
        assertGt(output, 50e18, "exactIn DAI: output too low");
        assertLt(output, 500e18, "exactIn DAI: output unreasonably high");

        emit log_named_uint("DAI out for 0.05 ETH", output);
    }

    // ====== EXACT-OUT ERC20->ERC20 ======

    function test_exactOut_USDC_to_DAI() public {
        uint256 amount = 100e18; // 100 DAI
        (zQuoter.Quote memory best,) = quoter.getQuotes(true, _USDC, _DAI, amount);

        if (best.amountIn > 0) {
            // ~100 USDC for 100 DAI (both $1 stables)
            assertGt(best.amountIn, 90e6, "USDC->DAI: need at least ~90 USDC");
            assertLt(best.amountIn, 110e6, "USDC->DAI: need at most ~110 USDC");

            emit log_named_uint("USDC needed for 100 DAI", best.amountIn);
        }
    }

    // ====== EXACT-OUT with buildBestSwap (single-hop calldata builder) ======

    function test_buildBestSwap_exactOut_ETH_to_DAI() public {
        uint256 amount = 100e18;
        (zQuoter.Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) =
            quoter.buildBestSwap(USER, true, ETH, _DAI, amount, 100, block.timestamp + 300);

        assertGt(best.amountIn, 1e16, "buildBestSwap DAI: too low");
        assertGt(callData.length, 0, "buildBestSwap DAI: empty calldata");
        assertGt(amountLimit, best.amountIn, "amountLimit should exceed quoted input");
        assertGt(msgValue, 0, "msgValue should be > 0 for ETH input");

        emit log_named_uint("best.amountIn", best.amountIn);
        emit log_named_uint("amountLimit", amountLimit);
        emit log_named_uint("source", uint256(best.source));
    }

    // ====== Curve dedup fix verification ======

    function test_quoteCurve_exactOut_ETH_to_DAI() public {
        (uint256 amountIn, uint256 amountOut, address bestPool,,,,) = quoter.quoteCurve(true, ETH, _DAI, 100e18, 8);

        if (bestPool != address(0)) {
            assertGt(amountIn, 1e16, "Curve DAI exact-out: too low");
            assertEq(amountOut, 100e18);

            emit log_named_uint("Curve: ETH needed for 100 DAI", amountIn);
            emit log_named_address("Curve: best pool", bestPool);
        } else {
            emit log("No Curve pool found for ETH->DAI");
        }
    }

    // ====== Lido exact-out ======

    function test_quoteLido_exactOut_stETH() public {
        (uint256 amountIn, uint256 amountOut) = quoter.quoteLido(true, STETH, 1e18);
        assertEq(amountIn, 1e18, "stETH exact-out should be 1:1");
        assertEq(amountOut, 1e18);
    }

    function test_quoteLido_exactOut_wstETH() public {
        (uint256 amountIn, uint256 amountOut) = quoter.quoteLido(true, WSTETH, 1e18);
        assertGt(amountIn, 1e18, "wstETH exact-out: ETH needed should exceed 1:1");
        assertLt(amountIn, 2e18, "wstETH exact-out: ETH needed unreasonably high");
        assertEq(amountOut, 1e18);

        emit log_named_uint("ETH needed for 1 wstETH", amountIn);
    }
}
