// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";

interface IQuoter {
    enum AMM { UNI_V2, SUSHI, ZAMM, UNI_V3, UNI_V4, CURVE, LIDO, WETH_WRAP, V4_HOOKED }
    struct Quote { AMM source; uint256 feeBps; uint256 amountIn; uint256 amountOut; }
    
    function buildBestSwapViaETHMulticall(
        address to, address refundTo, bool exactOut,
        address tokenIn, address tokenOut, uint256 swapAmount,
        uint256 slippageBps, uint256 deadline,
        uint24 hookPoolFee, int24 hookTickSpacing, address hookAddress
    ) external view returns (Quote memory a, Quote memory b, bytes[] memory calls, bytes memory multicall, uint256 msgValue);
    
    function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        external view returns (Quote memory best, Quote[] memory quotes);
    
    function buildBestSwap(address to, bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount, uint256 slippageBps, uint256 deadline)
        external view returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue);
}

contract TestSwap is Test {
    IQuoter quoter = IQuoter(0x6370a08885fBc80861d4769a06C60FE624b5FFA8);
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    
    function test_getQuotes() public {
        (IQuoter.Quote memory best, IQuoter.Quote[] memory quotes) = quoter.getQuotes(true, address(0), DAI, 3e18);
        emit log_named_uint("best.source", uint(best.source));
        emit log_named_uint("best.feeBps", best.feeBps);
        emit log_named_uint("best.amountIn", best.amountIn);
        for (uint i; i < quotes.length; i++) {
            emit log_named_uint("---quote source", uint(quotes[i].source));
            emit log_named_uint("   feeBps", quotes[i].feeBps);
            emit log_named_uint("   amountIn", quotes[i].amountIn);
        }
    }
    
    function test_buildMulticall() public {
        (IQuoter.Quote memory a, IQuoter.Quote memory b,,bytes memory multicall, uint256 msgValue) = 
            quoter.buildBestSwapViaETHMulticall(
                address(this), address(this), true,
                address(0), DAI, 3e18, 50, type(uint256).max,
                0, 0, address(0)
            );
        emit log_named_uint("leg_a.source", uint(a.source));
        emit log_named_uint("leg_a.feeBps", a.feeBps);
        emit log_named_uint("leg_a.amountIn", a.amountIn);
        emit log_named_uint("leg_b.source", uint(b.source));
        emit log_named_uint("leg_b.feeBps", b.feeBps);
        emit log_named_uint("leg_b.amountIn", b.amountIn);
        emit log_named_uint("msgValue", msgValue);
        emit log_named_uint("multicall.length", multicall.length);
    }
    
    function test_executeSwap() public {
        vm.deal(address(this), 1 ether);
        (,,,bytes memory multicall, uint256 msgValue) = 
            quoter.buildBestSwapViaETHMulticall(
                address(this), address(this), true,
                address(0), DAI, 3e18, 50, type(uint256).max,
                0, 0, address(0)
            );
        emit log_named_uint("msgValue", msgValue);
        (bool ok, bytes memory ret) = ZROUTER.call{value: msgValue}(multicall);
        emit log_named_string("success", ok ? "true" : "false");
        if (!ok) {
            emit log_named_bytes("revert_data", ret);
        }
    }

    receive() external payable {}
}
