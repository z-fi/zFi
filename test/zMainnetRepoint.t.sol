// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {zQuoter} from "../src/zQuoter.sol";

address constant NEW_V4 = 0x56033EBF90EbdEf9D74b38e5F7201c0624EFef01;
address constant OLD_V4 = 0x00005d8a3675b7b00BA172Aa85485Fc5D23121B6;
address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

/// @dev The shell staticcalls `_V4`, and a staticcall to a codeless address
/// returns empty rather than reverting — so a shell deployed before its helper
/// quotes every V4 tier as zero, silently. This pins the ordering.
contract MainnetRepointTest is Test {
    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
    }

    /// @dev Not a graceful degradation: a staticcall to a codeless address
    /// succeeds with EMPTY returndata, and the shell decodes uninitialized
    /// memory. The V4 tiers come back as nonsense large enough to win `best`
    /// and poison the route. So the helper MUST be deployed before the shell.
    function testShellBeforeHelperReturnsGarbageNotZero() public {
        assertEq(NEW_V4.code.length, 0, "premise: helper not deployed yet");
        zQuoter q = new zQuoter();
        (zQuoter.Quote memory best, zQuoter.Quote[] memory quotes) =
            q.getQuotes(false, WETH, USDC, 1 ether);

        uint256 worst;
        for (uint256 i; i < quotes.length; ++i) {
            if (quotes[i].source == zQuoter.AMM.UNI_V4 && quotes[i].amountOut > worst) {
                worst = quotes[i].amountOut;
            }
        }
        // 1 ETH is worth a few thousand USDC (6 decimals). Anything past 1e12 is
        // decoded garbage, not a quote.
        assertGt(worst, 1e12, "expected decoded garbage from the missing helper");
        assertTrue(best.source == zQuoter.AMM.UNI_V4, "and the garbage wins best");
        emit log_named_uint("garbage V4 amountOut", worst);
    }

    function testRepointedShellQuotesV4OnceTheHelperIsThere() public {
        // Put the FIXED helper at the address the shell now names.
        vm.etch(NEW_V4, OLD_V4.code); // live helper's code, as a stand-in for deployment
        zQuoter q = new zQuoter();
        (, zQuoter.Quote[] memory quotes) = q.getQuotes(false, WETH, USDC, 1 ether);
        uint256 v4 = 0;
        for (uint256 i; i < quotes.length; ++i) {
            if (quotes[i].source == zQuoter.AMM.UNI_V4) v4 += quotes[i].amountOut;
        }
        assertGt(v4, 0, "V4 must quote once the helper is deployed");
        emit log_named_uint("summed V4 out", v4);
    }
}
