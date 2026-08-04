// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.36;

import {Test, console} from "forge-std/Test.sol";
import {Collectol} from "../src/forwarders/Collectol.sol";
import {CollectolLens} from "../src/forwarders/CollectolLens.sol";

interface IFactory {
    function create2Deploy(bytes calldata creationCode, bytes32 salt) external payable returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IZRouterSwap {
    function swapV3(
        address to,
        bool exactOut,
        uint24 swapFee,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline
    ) external payable returns (uint256 amountIn, uint256 amountOut);
}

interface IZRouter {
    function multicall(bytes[] calldata) external payable returns (bytes[] memory);
}

/// The whole point of the exercise: an arbitrary ERC-20 reaching the continuous
/// sale. USDC -> ETH via the aggregator, wrapped, swept into the forwarder by
/// snwap, unwrapped there, and minted - all in one zRouter multicall.
contract CollectolRouteTest is Test {
    address constant FACTORY = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant ZQUOTER = 0x0000002d9a651b729e3aFBE57Fc84FFDa4a98a13;
    address constant SALE = 0x824d11a46F32cd16cdF46380314343e9697e2491;
    address constant SHARES = 0x883d646d0C8202Aa23F01d4aF45E4E73804c3a49;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 constant SALE_RATE = 1_000_000 ether;
    uint256 constant FEE = 30;

    address col;
    CollectolLens lens;
    address user = address(0xB0B);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));
        bytes memory initcode = vm.readFileBinary("deploy/Collectol.initcode.bin");
        bytes32 salt = vm.parseBytes32(vm.trim(vm.readFile("deploy/Collectol.salt.txt")));
        address predicted = vm.parseAddress(vm.trim(vm.readFile("deploy/Collectol.address.txt")));
        // Idempotent: the address may already be live on the fork being used.
        col = predicted.code.length == 0 ? IFactory(FACTORY).create2Deploy(initcode, salt) : predicted;
        assertEq(col, predicted, "mined address drift");
        lens = new CollectolLens();
    }

    /// zRouter's snwap sweeps `balance - 1` when it funds an executor from its
    /// own token balance, so a WETH-funded route arrives one wei short of what
    /// was wrapped. The plan is therefore solved for what actually lands.
    ///
    /// There is deliberately no companion test asserting that planning the
    /// unswept wei reverts: whether it does depends on whether zRouter happens
    /// to be holding WETH dust, which covers the shortfall and lets the route
    /// through. That made the assertion pass on a private fork and fail against
    /// mainnet head. The underlying rule - funding below the plan is rejected -
    /// is pinned unconditionally by Collectol.t.sol:testUnderfundingReverts,
    /// where no shared balance can mask it.
    function testUsdcHopsIntoTheContinuousSale() public {
        uint256 amountIn = 2000e6; // 2,000 USDC
        uint256 deadline = block.timestamp + 300;
        uint256 splitSlip = 300;

        deal(USDC, user, amountIn);
        vm.prank(user);
        IERC20(USDC).approve(ZROUTER, type(uint256).max);

        // Leg 1: USDC -> ETH on Uniswap V3 0.05%, output left in the router.
        uint256 gross;
        {
            uint256 snap = vm.snapshotState();
            vm.prank(user);
            (, gross) = IZRouterSwap(ZROUTER).swapV3(ZROUTER, false, 500, USDC, address(0), amountIn, 0, deadline);
            vm.revertToState(snap);
        }
        uint256 ethFloor = gross * (10000 - splitSlip) / 10000;

        uint256 cap = lens.maxSaleEth(SALE, SALE_RATE);
        // Solve for the wei that actually reaches the forwarder, not the wei wrapped.
        CollectolLens.Plan memory p = lens.planExactIn(SHARES, FEE, ethFloor - 1, SALE_RATE, cap, splitSlip);
        console.log("leg1 ETH quoted :", gross);
        console.log("mint ETH        :", p.ethToSale);
        console.log("pool ETH        :", p.poolAmount);
        console.log("FWC expected    :", p.totalOut);

        bytes memory buyData = abi.encodeCall(
            Collectol.buy, (p.ethToSale, p.poolAmount, p.poolLimit, p.poolExactOut, p.minTotalOut, user, user, deadline)
        );

        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeWithSignature(
            "swapV3(address,bool,uint24,address,address,uint256,uint256,uint256)",
            ZROUTER,
            false,
            uint24(500),
            USDC,
            address(0),
            amountIn,
            uint256(0),
            deadline
        );
        calls[1] = abi.encodeWithSignature("wrap(uint256)", ethFloor);
        calls[2] = abi.encodeWithSignature(
            "snwap(address,uint256,address,address,uint256,address,bytes)",
            WETH,
            uint256(0),
            user,
            SHARES,
            p.minTotalOut,
            col,
            buyData
        );
        calls[3] = abi.encodeWithSignature("sweep(address,uint256,uint256,address)", WETH, 0, 0, user);
        calls[4] = abi.encodeWithSignature("sweep(address,uint256,uint256,address)", address(0), 0, 0, user);
        calls[5] = abi.encodeWithSignature("sweep(address,uint256,uint256,address)", USDC, 0, 0, user);

        vm.prank(user);
        IZRouter(ZROUTER).multicall(calls);

        uint256 got = IERC20(SHARES).balanceOf(user);
        console.log("FWC received    :", got);

        assertGe(got, p.minTotalOut, "route delivered less than the protected minimum");
        assertEq(IERC20(USDC).balanceOf(user), 0, "input not fully spent");
        assertEq(IERC20(SHARES).balanceOf(col), 0, "output stranded in forwarder");
        assertEq(IERC20(WETH).balanceOf(col), 0, "WETH stranded in forwarder");
        assertEq(col.balance, 0, "ETH stranded in forwarder");
        assertGt(p.ethToSale, 0, "sale leg skipped");
    }
}
