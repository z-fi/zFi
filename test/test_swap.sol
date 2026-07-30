// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";

interface IQuoter {
    enum AMM {
        UNI_V2,
        SUSHI,
        ZAMM,
        UNI_V3,
        UNI_V4,
        CURVE,
        LIDO,
        WETH_WRAP
    }

    struct Quote {
        AMM source;
        uint256 feeBps;
        uint256 amountIn;
        uint256 amountOut;
    }

    function buildBestSwapViaETHMulticall(
        address to,
        address refundTo,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    )
        external
        view
        returns (Quote memory a, Quote memory b, bytes[] memory calls, bytes memory multicall, uint256 msgValue);

    function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        external
        view
        returns (Quote memory best, Quote[] memory quotes);

    function buildBestSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    ) external view returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue);
}

contract TestSwap is Test {
    // Current zQuoter. The previous pin (0x6370a0…5FFA8) predates the repoint and
    // no longer carries buildBestSwapViaETHMulticall (0xe453166e) at all, so both
    // builder tests reverted on a missing function while getQuotes still passed.
    IQuoter quoter = IQuoter(0x0000002d9a651b729e3aFBE57Fc84FFDa4a98a13);
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

    // These read live mainnet state. Without a fork they run against a blank EVM
    // and every call reverts on a codeless address, so the fork is part of the
    // fixture rather than something the caller has to remember to pass.
    //
    // OPT-IN. This is a manual probe against live mainnet, not a suite that
    // should gate `forge test`. getQuotes sweeps every venue for thousands of
    // storage reads, so at an unpinned head it is slow and it needs the network
    // to be up; pinning a block instead would need an archive endpoint, since a
    // free node serves only the last few thousand blocks (publicnode answers
    // anything older with 403 "Archive requests require a personal token").
    // Rather than pick a poison, it runs only when asked:
    //
    //   MAINNET_RPC=https://... forge test --match-path test/test_swap.sol
    //   MAINNET_RPC=https://<archive> FORK_BLOCK=25640000 forge test ...
    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 blk = vm.envOr("FORK_BLOCK", uint256(0));
        if (blk == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blk);
    }

    function test_getQuotes() public {
        (IQuoter.Quote memory best, IQuoter.Quote[] memory quotes) = quoter.getQuotes(true, address(0), DAI, 3e18);
        emit log_named_uint("best.source", uint256(best.source));
        emit log_named_uint("best.feeBps", best.feeBps);
        emit log_named_uint("best.amountIn", best.amountIn);
        for (uint256 i; i < quotes.length; i++) {
            emit log_named_uint("---quote source", uint256(quotes[i].source));
            emit log_named_uint("   feeBps", quotes[i].feeBps);
            emit log_named_uint("   amountIn", quotes[i].amountIn);
        }
    }

    function test_buildMulticall() public {
        (IQuoter.Quote memory a, IQuoter.Quote memory b,, bytes memory multicall, uint256 msgValue) = quoter.buildBestSwapViaETHMulticall(
            address(this), address(this), true, address(0), DAI, 3e18, 50, type(uint256).max
        );
        emit log_named_uint("leg_a.source", uint256(a.source));
        emit log_named_uint("leg_a.feeBps", a.feeBps);
        emit log_named_uint("leg_a.amountIn", a.amountIn);
        emit log_named_uint("leg_b.source", uint256(b.source));
        emit log_named_uint("leg_b.feeBps", b.feeBps);
        emit log_named_uint("leg_b.amountIn", b.amountIn);
        emit log_named_uint("msgValue", msgValue);
        emit log_named_uint("multicall.length", multicall.length);
    }

    function test_executeSwap() public {
        vm.deal(address(this), 1 ether);
        (,,, bytes memory multicall, uint256 msgValue) = quoter.buildBestSwapViaETHMulticall(
            address(this), address(this), true, address(0), DAI, 3e18, 50, type(uint256).max
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
