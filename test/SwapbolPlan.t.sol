// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapbol} from "../src/forwarders/Swapbol.sol";
import {SwapboardView} from "../src/SwapboardView.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {zRouter} from "../src/zRouter.sol";
import {zQuoter} from "../src/zQuoter.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

contract ExecutableLegacyV1 {
    struct Order {
        address maker;
        bool active;
        address tokenA;
        uint256 amountA;
        address tokenB;
        uint256 amountB;
    }

    uint256 public nextOrderId;
    mapping(uint256 => Order) internal _orders;

    function list(address tokenA, uint256 amountA, address tokenB, uint256 amountB) external returns (uint256 id) {
        tokenA.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), amountA)
        );
        id = nextOrderId++;
        _orders[id] = Order(msg.sender, true, tokenA, amountA, tokenB, amountB);
    }

    function fillOrder(uint256 id, uint256 deadline) external {
        require(deadline == 0 || block.timestamp <= deadline, "expired");
        Order storage o = _orders[id];
        require(o.active, "inactive");
        o.active = false;
        (bool paid,) = o.tokenB
            .call(abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, o.maker, o.amountB));
        require(paid, "pay");
        (bool sent,) = o.tokenA.call(abi.encodeWithSignature("transfer(address,uint256)", msg.sender, o.amountA));
        require(sent, "send");
    }

    function getOrders(uint256[] calldata ids) external view returns (Order[] memory out) {
        out = new Order[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            out[i] = _orders[ids[i]];
        }
    }
}

contract FixedOutputExecutor {
    function swap(address tokenOut, address recipient, uint256 amountOut) external {
        MockERC20(tokenOut).transfer(recipient, amountOut);
    }
}

contract MockMetaAmmRouter {
    function spendFunded(address tokenIn, address tokenOut, address recipient, uint256 amountIn, uint256 amountOut)
        external
    {
        require(MockERC20(tokenIn).balanceOf(address(this)) >= amountIn, "funding");
        _send(tokenOut, recipient, amountOut);
    }

    function exactIn(address tokenIn, address tokenOut, address recipient, uint256 amountIn, uint256 amountOut)
        external
        payable
    {
        _take(tokenIn, amountIn);
        _send(tokenOut, recipient, amountOut);
    }

    function exactOut(
        address tokenIn,
        address tokenOut,
        address recipient,
        uint256 maxIn,
        uint256 actualIn,
        uint256 amountOut
    ) external payable {
        require(actualIn <= maxIn, "limit");
        if (tokenIn == address(0)) require(msg.value == maxIn, "value");
        else MockERC20(tokenIn).transferFrom(msg.sender, address(this), actualIn);
        _send(tokenOut, recipient, amountOut);
        if (tokenIn == address(0) && maxIn != actualIn) {
            (bool ok,) = msg.sender.call{value: maxIn - actualIn}("");
            require(ok, "refund");
        }
    }

    function _take(address token, uint256 amount) internal {
        if (token == address(0)) require(msg.value == amount, "value");
        else MockERC20(token).transferFrom(msg.sender, address(this), amount);
    }

    function _send(address token, address recipient, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok,) = recipient.call{value: amount}("");
            require(ok, "eth");
        } else {
            MockERC20(token).transfer(recipient, amount);
        }
    }

    receive() external payable {}
}

/// @dev Implements the two zRouter calls emitted by zQuoter's canonical
///      ETH -> WETH builder. `multicall` deliberately delegatecalls, matching
///      zRouter's msg.value semantics closely enough to execute the real bytes.
contract MockCanonicalWrapRouter {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        results = new bytes[](data.length);
        for (uint256 i; i < data.length; ++i) {
            (bool ok, bytes memory result) = address(this).delegatecall(data[i]);
            require(ok, "multicall");
            results[i] = result;
        }
    }

    function wrap(uint256 amount) external payable {
        require(msg.value == amount, "value");
        MockWETH(payable(WETH)).deposit{value: amount}();
    }

    function sweep(address token, uint256 id, uint256 amount, address to) external payable {
        require(token == WETH && id == 0, "asset");
        uint256 sendAmount = amount == 0 ? MockERC20(token).balanceOf(address(this)) : amount;
        MockERC20(token).transfer(to, sendAmount);
    }
}

contract NativeLegacyV1 {
    MockERC20 immutable out;
    uint256 immutable price;
    uint256 immutable amount;

    constructor(MockERC20 out_, uint256 price_, uint256 amount_) {
        out = out_;
        price = price_;
        amount = amount_;
    }

    function fillOrder(uint256, uint256 deadline) external payable {
        require(deadline == 0 || block.timestamp <= deadline, "expired");
        require(msg.value == price, "price");
        out.transfer(msg.sender, amount);
    }
}

contract MockPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata details,
        address owner,
        bytes calldata
    ) external {
        require(details.requestedAmount <= permit.permitted.amount, "amount");
        MockERC20(permit.permitted.token).transferFrom(owner, details.to, details.requestedAmount);
    }
}

contract MockPermitERC20 is MockERC20 {
    mapping(address => uint256) public nonces;

    constructor() MockERC20("PERMIT", 18) {}

    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external {
        allowance[owner][spender] = value;
        ++nonces[owner];
    }
}

contract RejectEtherReceiver {
    receive() external payable {
        revert("no ETH");
    }
}

contract SwapbolPlanTest is Test {
    address internal maker = address(0xA11CE);
    address internal taker = address(0xB0B);

    Swapbol internal executor;
    SwapboardView internal lens;
    Swapboard internal current;
    ExecutableLegacyV1 internal legacy;
    Dutchboard internal dutch;
    MockERC20 internal pay;
    MockERC20 internal out;
    address internal constant META_AMM = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    function setUp() public {
        MockWETH wethImplementation = new MockWETH();
        vm.etch(WETH, address(wethImplementation).code);
        vm.deal(WETH, 0);

        // The refund tests assert an absolute balance, so the refund address has
        // to start empty. 0xF00D is a vanity address that holds real dust on
        // mainnet (47240000000000 wei), which a fork inherits and which would
        // otherwise be read as the contract over-refunding by that exact amount.
        vm.deal(address(0xF00D), 0);

        lens = new SwapboardView();
        current = new Swapboard(WETH);
        legacy = new ExecutableLegacyV1();
        dutch = new Dutchboard();
        executor = new Swapbol(address(legacy), address(current), address(dutch));
        pay = new MockERC20("PAY", 18);
        out = new MockERC20("OUT", 18);

        out.mint(maker, 1_000e18);
        vm.startPrank(maker);
        out.approve(address(legacy), type(uint256).max);
        out.approve(address(current), type(uint256).max);
        out.approve(address(dutch), type(uint256).max);
        legacy.list(address(out), 10e18, address(pay), 20e18);
        current.createOrder(address(out), 15e18, address(pay), 30e18, true, 0, false, false, address(0));
        dutch.listERC20(address(out), address(pay), 20e18, 40e18, 40e18, 0, 1 days);
        vm.stopPrank();
    }

    function _plan() internal view returns (Swapbol.Fill[] memory legs, uint256 bookIn, uint256 bookOut) {
        SwapboardView.OrderView[] memory swaps =
            lens.candidates(address(legacy), address(current), address(pay), address(out), address(executor), 0);
        (SwapboardView.OrderView[] memory auctions,) =
            lens.dutchCandidatesFrom(address(dutch), address(pay), address(out), address(executor), 0, 100);

        SwapboardView.OrderView[] memory merged = new SwapboardView.OrderView[](swaps.length + auctions.length);
        for (uint256 i; i < swaps.length; ++i) {
            merged[i] = swaps[i];
        }
        for (uint256 i; i < auctions.length; ++i) {
            merged[swaps.length + i] = auctions[i];
        }

        (SwapboardView.Fill[] memory quoted, uint256 spent, uint256 received) = lens.previewPlanAtRate(merged, 90e18, 1);
        legs = new Swapbol.Fill[](quoted.length);
        for (uint256 i; i < quoted.length; ++i) {
            legs[i] = Swapbol.Fill(
                quoted[i].orderId, quoted[i].board, quoted[i].payIn, quoted[i].getOut, quoted[i].isPartial
            );
        }
        return (legs, spent, received);
    }

    function _data(Swapbol.Fill[] memory legs) internal view returns (bytes memory) {
        return abi.encodeCall(
            Swapbol.fillPlan, (address(pay), address(out), taker, taker, block.timestamp + 30 minutes, legs)
        );
    }

    function _fundExecutor(uint256 amount) internal {
        executor.checkpoint(address(pay));
        pay.mint(address(executor), amount);
    }

    function _checkpointCall(zRouter router, address token, address recipient) internal view returns (bytes memory) {
        return abi.encodeCall(
            router.snwap,
            (address(0), 0, recipient, address(0), 0, address(executor), abi.encodeCall(Swapbol.checkpoint, (token)))
        );
    }

    function test_executesMixedLensPlanWithExactScopedApprovals() public {
        (Swapbol.Fill[] memory legs, uint256 bookIn, uint256 bookOut) = _plan();
        assertEq(legs.length, 3, "all three supported books planned");
        assertEq(bookIn, 90e18, "planned input");
        assertEq(bookOut, 45e18, "planned output");

        _fundExecutor(bookIn); // checkpoint + what zRouter.snwap does before execution
        executor.fillPlan(address(pay), address(out), taker, taker, block.timestamp + 30 minutes, legs);

        assertEq(out.balanceOf(taker), bookOut, "aggregate output");
        assertEq(pay.balanceOf(maker), bookIn, "makers paid");
        assertEq(pay.balanceOf(address(executor)), 0, "no input retained");
        assertEq(out.balanceOf(address(executor)), 0, "no output retained");
        assertEq(pay.allowance(address(executor), address(legacy)), 0, "legacy approval revoked");
        assertEq(pay.allowance(address(executor), address(current)), 0, "current approval revoked");
        assertEq(pay.allowance(address(executor), address(dutch)), 0, "Dutch approval revoked");
    }

    function test_mixedPlanCannotCaptureDonatedInputOrOutput() public {
        (Swapbol.Fill[] memory legs, uint256 bookIn, uint256 bookOut) = _plan();
        uint256 donatedIn = 7e18;
        uint256 donatedOut = 11e18;
        pay.mint(address(executor), donatedIn);
        out.mint(address(executor), donatedOut);

        _fundExecutor(bookIn);
        executor.fillPlan(address(pay), address(out), taker, taker, block.timestamp + 30 minutes, legs);

        assertEq(out.balanceOf(taker), bookOut, "caller receives only this plan's output");
        assertEq(pay.balanceOf(taker), 0, "caller receives no donated input");
        assertEq(pay.balanceOf(address(executor)), donatedIn, "donated input baseline preserved");
        assertEq(out.balanceOf(address(executor)), donatedOut, "donated output baseline preserved");
    }

    function test_routerMulticallMakesBookAndAmmRemainderAtomic() public {
        (Swapbol.Fill[] memory legs, uint256 bookIn, uint256 bookOut) = _plan();
        MockERC20 constructorDependency = new MockERC20("wstETH", 18);
        vm.etch(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, address(constructorDependency).code);
        zRouter router = new zRouter();
        FixedOutputExecutor amm = new FixedOutputExecutor();
        out.mint(address(amm), 5e18);
        pay.mint(taker, bookIn + 10e18);

        vm.startPrank(taker);
        pay.approve(address(router), bookIn + 10e18);

        bytes[] memory calls = new bytes[](3);
        calls[0] = _checkpointCall(router, address(pay), taker);
        calls[1] = abi.encodeCall(
            router.snwap, (address(pay), bookIn, taker, address(out), bookOut, address(executor), _data(legs))
        );
        calls[2] = abi.encodeCall(
            router.snwap,
            (
                address(pay),
                10e18,
                taker,
                address(out),
                6e18,
                address(amm),
                abi.encodeCall(FixedOutputExecutor.swap, (address(out), taker, 5e18))
            )
        );

        vm.expectRevert(abi.encodeWithSelector(zRouter.SnwapSlippage.selector, address(out), 5e18, 6e18));
        router.multicall(calls);
        vm.stopPrank();

        assertEq(out.balanceOf(taker), 0, "book output rolled back with AMM failure");
        assertEq(pay.balanceOf(taker), bookIn + 10e18, "all input rolled back");
        assertEq(pay.balanceOf(maker), 0, "maker payments rolled back");
    }

    function test_singleSnwapExecutesBookAndAmmWithScopedApprovals() public {
        (Swapbol.Fill[] memory legs, uint256 bookIn, uint256 bookOut) = _plan();
        MockMetaAmmRouter amm = new MockMetaAmmRouter();
        vm.etch(META_AMM, address(amm).code);
        out.mint(META_AMM, 5e18);

        uint256 ammIn = 10e18;
        _fundExecutor(bookIn + ammIn);
        executor.fillPlanAndSwap(
            address(pay),
            address(out),
            taker,
            taker,
            block.timestamp + 30 minutes,
            legs,
            ammIn,
            abi.encodeCall(MockMetaAmmRouter.exactIn, (address(pay), address(out), taker, ammIn, 5e18))
        );

        assertEq(out.balanceOf(taker), bookOut + 5e18, "aggregate route output");
        assertEq(pay.balanceOf(address(executor)), 0, "no input retained");
        assertEq(pay.allowance(address(executor), META_AMM), 0, "AMM approval revoked");
    }

    function test_exactOutSingleSnwapRefundsUnusedMaximumInput() public {
        MockERC20 constructorDependency = new MockERC20("wstETH", 18);
        vm.etch(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, address(constructorDependency).code);
        zRouter router = new zRouter();
        MockMetaAmmRouter amm = new MockMetaAmmRouter();
        vm.etch(META_AMM, address(amm).code);
        out.mint(META_AMM, 5e18);

        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(0, address(legacy), 20e18, 10e18, false);
        uint256 ammMax = 12e18;
        uint256 ammActual = 10e18;
        uint256 maxIn = 20e18 + ammMax;
        address refund = address(0xF00D);
        bytes memory data = abi.encodeCall(
            Swapbol.fillPlanAndSwap,
            (
                address(pay),
                address(out),
                taker,
                refund,
                block.timestamp + 30 minutes,
                legs,
                ammMax,
                abi.encodeCall(MockMetaAmmRouter.exactOut, (address(pay), address(out), taker, ammMax, ammActual, 5e18))
            )
        );

        pay.mint(taker, maxIn);
        vm.startPrank(taker);
        pay.approve(address(router), maxIn);
        bytes[] memory calls = new bytes[](2);
        calls[0] = _checkpointCall(router, address(pay), taker);
        calls[1] =
            abi.encodeCall(router.snwap, (address(pay), maxIn, taker, address(out), 15e18, address(executor), data));
        router.multicall(calls);
        vm.stopPrank();

        assertEq(out.balanceOf(taker), 15e18, "exact output");
        assertEq(pay.balanceOf(refund), ammMax - ammActual, "unused maximum refunded separately");
        assertEq(pay.balanceOf(taker), 0, "output recipient did not receive input change");
        assertEq(pay.balanceOf(maker), 20e18, "book paid");
        assertEq(pay.allowance(address(executor), META_AMM), 0, "AMM approval revoked");
    }

    function test_nativeDepositSequenceForwardsValueOnlyOnce() public {
        MockERC20 constructorDependency = new MockERC20("wstETH", 18);
        vm.etch(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, address(constructorDependency).code);
        zRouter router = new zRouter();
        MockMetaAmmRouter amm = new MockMetaAmmRouter();
        vm.etch(META_AMM, address(amm).code);

        vm.prank(maker);
        uint256 nativeBookId = legacy.list(address(out), 10e18, WETH, 2 ether);
        out.mint(META_AMM, 5e18);
        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(nativeBookId, address(legacy), 2 ether, 10e18, false);
        bytes memory plan = abi.encodeCall(
            Swapbol.fillPlanAndSwap,
            (
                address(0),
                address(out),
                taker,
                taker,
                block.timestamp + 30 minutes,
                legs,
                1 ether,
                abi.encodeCall(MockMetaAmmRouter.exactIn, (address(0), address(out), taker, 1 ether, 5e18))
            )
        );
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(router.deposit, (address(0), 0, 3 ether));
        calls[1] =
            abi.encodeCall(router.snwap, (address(0), 3 ether, taker, address(out), 15e18, address(executor), plan));

        vm.deal(taker, 3 ether);
        vm.prank(taker);
        router.multicall{value: 3 ether}(calls);

        assertEq(out.balanceOf(taker), 15e18, "native hybrid output");
        assertEq(address(executor).balance, 0, "executor retained no ETH");
        assertEq(META_AMM.balance, 1 ether, "AMM received only its partition");
    }

    function test_nativeExactOutDepositSequenceRefundsUnusedMaximum() public {
        MockERC20 constructorDependency = new MockERC20("wstETH", 18);
        vm.etch(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, address(constructorDependency).code);
        zRouter router = new zRouter();
        MockMetaAmmRouter amm = new MockMetaAmmRouter();
        vm.etch(META_AMM, address(amm).code);

        vm.prank(maker);
        uint256 nativeBookId = legacy.list(address(out), 10e18, WETH, 2 ether);
        out.mint(META_AMM, 5e18);
        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(nativeBookId, address(legacy), 2 ether, 10e18, false);
        address refund = address(0xF00D);
        bytes memory plan = abi.encodeCall(
            Swapbol.fillPlanAndSwap,
            (
                address(0),
                address(out),
                taker,
                refund,
                block.timestamp + 30 minutes,
                legs,
                2 ether,
                abi.encodeCall(MockMetaAmmRouter.exactOut, (address(0), address(out), taker, 2 ether, 1 ether, 5e18))
            )
        );
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(router.deposit, (address(0), 0, 4 ether));
        calls[1] =
            abi.encodeCall(router.snwap, (address(0), 4 ether, taker, address(out), 15e18, address(executor), plan));

        vm.deal(taker, 4 ether);
        vm.prank(taker);
        router.multicall{value: 4 ether}(calls);

        assertEq(out.balanceOf(taker), 15e18, "native exact output");
        assertEq(refund.balance, 1 ether, "unused native maximum refunded separately");
        assertEq(taker.balance, 0, "output recipient did not receive native change");
        assertEq(address(executor).balance, 0, "executor retained no ETH");
    }

    function test_permit2DepositSweepAndZeroPullSnwapFundExactRoute() public {
        MockERC20 constructorDependency = new MockERC20("wstETH", 18);
        vm.etch(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, address(constructorDependency).code);
        zRouter router = new zRouter();
        MockMetaAmmRouter amm = new MockMetaAmmRouter();
        MockPermit2 permit2 = new MockPermit2();
        vm.etch(META_AMM, address(amm).code);
        vm.etch(PERMIT2, address(permit2).code);
        out.mint(META_AMM, 5e18);

        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(0, address(legacy), 20e18, 10e18, false);
        uint256 routeIn = 30e18;
        bytes memory plan = abi.encodeCall(
            Swapbol.fillPlan, (address(pay), address(out), taker, taker, block.timestamp + 30 minutes, legs)
        );
        vm.prank(tx.origin);
        router.trust(META_AMM, true);
        bytes[] memory calls = new bytes[](7);
        calls[0] = abi.encodeCall(
            router.permit2TransferFrom, (address(pay), routeIn, 0, block.timestamp + 30 minutes, bytes(""))
        );
        calls[1] = abi.encodeCall(router.sweep, (address(pay), 0, 10e18, META_AMM));
        calls[2] = abi.encodeCall(
            router.execute,
            (
                META_AMM,
                0,
                abi.encodeCall(MockMetaAmmRouter.spendFunded, (address(pay), address(out), taker, 10e18, 5e18))
            )
        );
        calls[3] = _checkpointCall(router, address(pay), taker);
        calls[4] = abi.encodeCall(router.sweep, (address(pay), 0, 20e18, address(executor)));
        calls[5] = abi.encodeCall(router.snwap, (address(0), 0, taker, address(out), 10e18, address(executor), plan));
        calls[6] = abi.encodeCall(router.sweep, (address(pay), 0, 0, taker));

        pay.mint(taker, routeIn);
        vm.prank(taker);
        pay.approve(PERMIT2, routeIn);
        vm.prank(taker);
        router.multicall(calls);

        assertEq(out.balanceOf(taker), 15e18, "Permit2 hybrid output");
        assertEq(pay.balanceOf(taker), 0, "exact input funded");
        assertEq(pay.balanceOf(address(router)), 0, "router retained no input");
        assertEq(pay.balanceOf(address(executor)), 0, "executor retained no input");
    }

    function test_eip2612PermitAndDirectSnwapRemainOneTransaction() public {
        MockERC20 constructorDependency = new MockERC20("wstETH", 18);
        vm.etch(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, address(constructorDependency).code);
        zRouter router = new zRouter();
        MockMetaAmmRouter amm = new MockMetaAmmRouter();
        MockPermitERC20 permitCode = new MockPermitERC20();
        vm.etch(META_AMM, address(amm).code);
        vm.etch(address(pay), address(permitCode).code);
        out.mint(META_AMM, 5e18);

        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(0, address(legacy), 20e18, 10e18, false);
        uint256 routeIn = 30e18;
        bytes memory plan = abi.encodeCall(
            Swapbol.fillPlanAndSwap,
            (
                address(pay),
                address(out),
                taker,
                taker,
                block.timestamp + 30 minutes,
                legs,
                10e18,
                abi.encodeCall(MockMetaAmmRouter.exactIn, (address(pay), address(out), taker, 10e18, 5e18))
            )
        );
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(router.permit, (address(pay), routeIn, block.timestamp + 30 minutes, 27, 0, 0));
        calls[1] = _checkpointCall(router, address(pay), taker);
        calls[2] =
            abi.encodeCall(router.snwap, (address(pay), routeIn, taker, address(out), 15e18, address(executor), plan));

        pay.mint(taker, routeIn);
        vm.prank(taker);
        router.multicall(calls);

        assertEq(out.balanceOf(taker), 15e18, "permit hybrid output");
        assertEq(pay.balanceOf(taker), 0, "permit route input");
        assertEq(pay.allowance(taker, address(router)), 0, "exact permit consumed");
    }

    function test_nativeInputComposesWethSwapboardsAndEthDutchboard() public {
        vm.startPrank(maker);
        uint256 legacyId = legacy.list(address(out), 10e18, WETH, 2 ether);
        uint256 currentId = current.createOrder(address(out), 15e18, WETH, 3 ether, true, 0, false, false, address(0));
        uint256 dutchId = dutch.listERC20(address(out), address(0), 20e18, 4 ether, 4 ether, 0, 1 days);
        vm.stopPrank();

        Swapbol.Fill[] memory legs = new Swapbol.Fill[](3);
        legs[0] = Swapbol.Fill(legacyId, address(legacy), 2 ether, 10e18, false);
        legs[1] = Swapbol.Fill(currentId, address(current), 3 ether, 15e18, true);
        legs[2] = Swapbol.Fill(dutchId, address(dutch), 4 ether, 20e18, true);

        uint256 makerEthBefore = maker.balance;
        executor.fillPlan{value: 9 ether}(
            address(0), address(out), taker, address(0xF00D), block.timestamp + 30 minutes, legs
        );

        assertEq(out.balanceOf(taker), 45e18, "all native-input books composed");
        assertEq(MockERC20(WETH).balanceOf(maker), 5 ether, "Swapboards paid maker in WETH");
        assertEq(maker.balance - makerEthBefore, 4 ether, "Dutchboard paid maker in ETH");
        assertEq(MockERC20(WETH).balanceOf(address(executor)), 0, "no wrapped input retained");
        assertEq(address(executor).balance, 0, "no native input retained");
    }

    function test_nativeInputAlsoPaysWethQuotedDutchAndRefundsUnusedMaximum() public {
        vm.prank(maker);
        uint256 dutchId = dutch.listERC20(address(out), WETH, 20e18, 4 ether, 4 ether, 0, 1 days);

        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(dutchId, address(dutch), 5 ether, 20e18, true);
        address refund = address(0xF00D);

        executor.fillPlan{value: 5 ether}(address(0), address(out), taker, refund, block.timestamp + 30 minutes, legs);

        assertEq(out.balanceOf(taker), 20e18, "Dutch lot delivered");
        assertEq(MockERC20(WETH).balanceOf(maker), 4 ether, "seller paid in the listing's WETH quote");
        assertEq(refund.balance, 1 ether, "unused wrapped maximum returned as native ETH");
        assertEq(MockERC20(WETH).balanceOf(address(executor)), 0, "no WETH retained");
        assertEq(address(executor).balance, 0, "no ETH retained");
    }

    function test_ethToWethComposesNativeQuotedDutchWithCanonicalWrapRemainder() public {
        MockERC20(WETH).mint(maker, 2 ether);
        vm.startPrank(maker);
        MockERC20(WETH).approve(address(dutch), 2 ether);
        uint256 dutchId = dutch.listERC20(WETH, address(0), 2 ether, 1 ether, 1 ether, 0, 1 days);
        vm.stopPrank();

        MockERC20 constructorDependency = new MockERC20("wstETH", 18);
        vm.etch(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, address(constructorDependency).code);
        zRouter outerRouter = new zRouter();
        MockCanonicalWrapRouter routerCode = new MockCanonicalWrapRouter();
        vm.etch(META_AMM, address(routerCode).code);

        uint256 ammIn = 1 ether;
        zQuoter quoter = new zQuoter();
        (zQuoter.Quote memory quote, bytes memory ammData, uint256 limit, uint256 msgValue) =
            quoter.buildBestSwap(taker, false, address(0), WETH, ammIn, 0, block.timestamp + 30 minutes);
        assertEq(uint256(quote.source), uint256(zQuoter.AMM.WETH_WRAP), "canonical remainder");
        assertEq(limit, ammIn, "canonical 1:1 limit");
        assertEq(msgValue, ammIn, "canonical call value");

        uint256 bookMax = 5 ether / 4;
        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(dutchId, address(dutch), bookMax, 2 ether, true);
        address refund = address(0xF00D);
        uint256 makerEthBefore = maker.balance;
        uint256 totalIn = bookMax + ammIn;
        bytes memory plan = abi.encodeCall(
            Swapbol.fillPlanAndSwap,
            (address(0), WETH, taker, refund, block.timestamp + 30 minutes, legs, ammIn, ammData)
        );
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(outerRouter.deposit, (address(0), 0, totalIn));
        calls[1] =
            abi.encodeCall(outerRouter.snwap, (address(0), totalIn, taker, WETH, 3 ether, address(executor), plan));

        vm.deal(taker, totalIn);
        vm.prank(taker);
        outerRouter.multicall{value: totalIn}(calls);

        assertEq(MockERC20(WETH).balanceOf(taker), 3 ether, "discounted book plus 1:1 wrap");
        assertEq(maker.balance - makerEthBefore, 1 ether, "Dutch seller paid native ETH");
        assertEq(refund.balance, bookMax - 1 ether, "unused Dutch maximum refunded natively");
        assertEq(MockERC20(WETH).balanceOf(address(executor)), 0, "executor retained no WETH");
        assertEq(address(executor).balance, 0, "executor retained no ETH");
        assertEq(MockERC20(WETH).balanceOf(META_AMM), 0, "router swept wrapped remainder");
    }

    function test_exactOutEthToWethPreservesMaximumAndNativeRefund() public {
        MockERC20(WETH).mint(maker, 2 ether);
        vm.startPrank(maker);
        MockERC20(WETH).approve(address(dutch), 2 ether);
        uint256 dutchId = dutch.listERC20(WETH, address(0), 2 ether, 1 ether, 1 ether, 0, 1 days);
        vm.stopPrank();

        MockERC20 constructorDependency = new MockERC20("wstETH", 18);
        vm.etch(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, address(constructorDependency).code);
        zRouter outerRouter = new zRouter();
        MockCanonicalWrapRouter routerCode = new MockCanonicalWrapRouter();
        vm.etch(META_AMM, address(routerCode).code);

        uint256 ammOut = 1 ether;
        zQuoter quoter = new zQuoter();
        (zQuoter.Quote memory quote, bytes memory ammData, uint256 ammMax, uint256 msgValue) =
            quoter.buildBestSwap(taker, true, address(0), WETH, ammOut, 0, block.timestamp + 30 minutes);
        assertEq(uint256(quote.source), uint256(zQuoter.AMM.WETH_WRAP), "canonical remainder");
        assertEq(quote.amountIn, ammOut, "exact-out remainder input");
        assertEq(ammMax, ammOut, "canonical maximum");
        assertEq(msgValue, ammMax, "canonical call value");

        uint256 bookMax = 5 ether / 4;
        uint256 totalMax = bookMax + ammMax;
        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(dutchId, address(dutch), bookMax, 2 ether, true);
        address refund = address(0xF00D);
        bytes memory plan = abi.encodeCall(
            Swapbol.fillPlanAndSwap,
            (address(0), WETH, taker, refund, block.timestamp + 30 minutes, legs, ammMax, ammData)
        );
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(outerRouter.deposit, (address(0), 0, totalMax));
        calls[1] =
            abi.encodeCall(outerRouter.snwap, (address(0), totalMax, taker, WETH, 3 ether, address(executor), plan));

        vm.deal(taker, totalMax);
        vm.prank(taker);
        outerRouter.multicall{value: totalMax}(calls);

        assertEq(MockERC20(WETH).balanceOf(taker), 3 ether, "exact WETH target");
        assertEq(refund.balance, bookMax - 1 ether, "unused book maximum refunded natively");
        assertEq(taker.balance, 0, "refund remains separate from output recipient");
        assertEq(MockERC20(WETH).balanceOf(address(executor)), 0, "executor retained no WETH");
        assertEq(address(executor).balance, 0, "executor retained no ETH");
    }

    function test_ethToWethRejectsNonDutchOrNonNativeQuotedBookLegs() public {
        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(0, address(legacy), 20e18, 10e18, false);

        vm.expectRevert(Swapbol.BadPlan.selector);
        executor.fillPlan(address(0), WETH, taker, taker, 0, legs);

        vm.prank(maker);
        uint256 wrongLot = dutch.listERC20(address(out), address(0), 1 ether, 1 ether, 1 ether, 0, 1 days);
        legs[0] = Swapbol.Fill(wrongLot, address(dutch), 1 ether, 1 ether, true);

        vm.expectRevert(Swapbol.BadPlan.selector);
        executor.fillPlan(address(0), WETH, taker, taker, 0, legs);

        vm.prank(maker);
        uint256 wethQuoted = dutch.listERC20(address(out), WETH, 1 ether, 1 ether, 1 ether, 0, 1 days);
        legs[0] = Swapbol.Fill(wethQuoted, address(dutch), 1 ether, 1 ether, true);

        vm.expectRevert(Swapbol.BadPlan.selector);
        executor.fillPlan(address(0), WETH, taker, taker, 0, legs);
    }

    function test_nativeInputUnwrapsUnusedSwapboardMaximumToRefundAddress() public {
        vm.prank(maker);
        uint256 id = legacy.list(address(out), 10e18, WETH, 2 ether);

        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(id, address(legacy), 3 ether, 10e18, false);
        address refund = address(0xF00D);

        executor.fillPlan{value: 3 ether}(address(0), address(out), taker, refund, block.timestamp + 30 minutes, legs);

        assertEq(out.balanceOf(taker), 10e18, "book output delivered");
        assertEq(refund.balance, 1 ether, "unused wrapped maximum returned as ETH");
        assertEq(taker.balance, 0, "refund is independent from output recipient");
        assertEq(MockERC20(WETH).balanceOf(address(executor)), 0, "no WETH retained");
    }

    function test_nativeOutputComposesWethLiquidityAcrossAllBooks() public {
        MockERC20(WETH).mint(maker, 6 ether);
        vm.deal(WETH, 6 ether);
        vm.startPrank(maker);
        MockERC20(WETH).approve(address(legacy), type(uint256).max);
        MockERC20(WETH).approve(address(current), type(uint256).max);
        MockERC20(WETH).approve(address(dutch), type(uint256).max);
        uint256 legacyId = legacy.list(WETH, 1 ether, address(pay), 2e18);
        uint256 currentId = current.createOrder(WETH, 2 ether, address(pay), 4e18, true, 0, false, false, address(0));
        uint256 dutchId = dutch.listERC20(WETH, address(pay), 3 ether, 6e18, 6e18, 0, 1 days);
        vm.stopPrank();

        Swapbol.Fill[] memory legs = new Swapbol.Fill[](3);
        legs[0] = Swapbol.Fill(legacyId, address(legacy), 2e18, 1 ether, false);
        legs[1] = Swapbol.Fill(currentId, address(current), 4e18, 2 ether, true);
        legs[2] = Swapbol.Fill(dutchId, address(dutch), 6e18, 3 ether, true);
        _fundExecutor(12e18);

        executor.fillPlan(address(pay), address(0), taker, address(0xF00D), block.timestamp + 30 minutes, legs);

        assertEq(taker.balance, 6 ether, "WETH book outputs unwrapped to native ETH");
        assertEq(pay.balanceOf(maker), 12e18, "all makers paid");
        assertEq(MockERC20(WETH).balanceOf(address(executor)), 0, "no output WETH retained");
        assertEq(address(executor).balance, 0, "no output ETH retained");
    }

    function test_forcedEthBaselineCannotDoSNonpayableErc20Recipient() public {
        RejectEtherReceiver receiver = new RejectEtherReceiver();
        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(0, address(legacy), 20e18, 10e18, false);
        _fundExecutor(20e18);
        vm.deal(address(executor), 1 ether);

        executor.fillPlan(
            address(pay), address(out), address(receiver), address(receiver), block.timestamp + 30 minutes, legs
        );

        assertEq(out.balanceOf(address(receiver)), 10e18, "ERC20 output delivered");
        assertEq(address(executor).balance, 1 ether, "pre-existing ETH baseline untouched");
    }

    function test_rejectsExpiredSameOrUnsafeNativeWethCanonicalPlans() public {
        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(0, address(legacy), 20e18, 10e18, false);

        vm.warp(100);
        vm.expectRevert(Swapbol.DeadlineExpired.selector);
        executor.fillPlan(address(pay), address(out), taker, taker, 99, legs);

        vm.expectRevert(Swapbol.BadPlan.selector);
        executor.fillPlan(address(pay), address(pay), taker, taker, 0, legs);

        vm.expectRevert(Swapbol.BadPlan.selector);
        executor.fillPlan(address(0), WETH, taker, taker, 0, legs);

        vm.expectRevert(Swapbol.BadPlan.selector);
        executor.fillPlan(WETH, address(0), taker, taker, 0, legs);

        vm.expectRevert(Swapbol.BadPlan.selector);
        executor.fillPlan(address(pay), address(out), taker, address(0), 0, legs);
    }

    function test_constructorRejectsUnboundOrAmbiguousVenues() public {
        vm.expectRevert(Swapbol.BadVenue.selector);
        new Swapbol(address(0), address(current), address(dutch));

        vm.expectRevert(Swapbol.BadVenue.selector);
        new Swapbol(address(legacy), address(legacy), address(dutch));

        vm.expectRevert(Swapbol.BadVenue.selector);
        new Swapbol(address(0xBEEF), address(current), address(dutch));
    }

    function test_rejectsDeprecatedOrUnknownBoard() public {
        Swapbol.Fill[] memory legs = new Swapbol.Fill[](1);
        legs[0] = Swapbol.Fill(0, address(0x85B831), 1, 1, false);
        _fundExecutor(1);

        vm.expectRevert(abi.encodeWithSelector(Swapbol.UnknownBoard.selector, address(0x85B831)));
        executor.fillPlan(address(pay), address(out), taker, taker, 0, legs);
    }

    function test_rejectsEmptyPlanAndZeroRecipient() public {
        Swapbol.Fill[] memory none = new Swapbol.Fill[](0);
        vm.expectRevert(Swapbol.BadPlan.selector);
        executor.fillPlan(address(pay), address(out), taker, taker, 0, none);

        Swapbol.Fill[] memory one = new Swapbol.Fill[](1);
        one[0] = Swapbol.Fill(0, address(legacy), 20e18, 10e18, false);
        vm.expectRevert(Swapbol.BadPlan.selector);
        executor.fillPlan(address(pay), address(out), address(0), taker, 0, one);
    }
}
