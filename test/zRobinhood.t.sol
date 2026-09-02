// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";

// Selective imports on purpose: both files declare file-scope constants named
// WETH, V2_FACTORY and so on, and a plain `import "..."` of both would collide.
import {zRouterLite} from "../src/zRouterLite.sol";
import {zQuoterRobinhood} from "../src/zQuoterRobinhood.sol";

/// @dev NOT pinned to a block, deliberately. The public Robinhood RPC keeps only
/// a rolling window of state — a fork pinned even a few hours back fails with
/// "metadata is not found" once the node prunes past it, so a pinned suite would
/// pass today and be unrunnable next week. Every assertion below is therefore
/// written to be reserve-independent: quotes are compared against what execution
/// actually returns, and sizes are derived from a live quote rather than typed in.
/// Where a venue may simply have no liquidity at the current head, the test skips
/// rather than fails — a drained pool is not a bug in this code.
string constant RPC = "https://rpc.mainnet.chain.robinhood.com";

address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
address constant V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
address constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
address constant V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
address constant SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
address constant V2_ROUTER_02 = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;

/// @dev MARIAN. Chosen because it is the one token on the chain with liquidity
/// across all three venues the router can execute — a V2 pair against WETH, a V3
/// 1% pool, and V4 pools against native ETH — so one token exercises every
/// branch. Individual pools may empty out over time; those tests skip.
address constant TKN = 0x01637b14B7378B99dE75A64d50656d98488D9a4d;

/// @dev Second token with a V2 pair against WETH, for the token->token leg.
address constant TKN2 = 0xF8c0E9B26971C5Df9b754E5E0F5AD78C35770000;

bytes32 constant V2_POOL_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
bytes32 constant V3_POOL_INIT_CODE_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

interface IV2Factory {
    function getPair(address, address) external view returns (address);
}

interface IV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IStateView {
    function poolManager() external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Stands in for a solver fill: pushes whatever `snwap` forwarded to it on
/// to the recipient. Deliberately dumb — the point of `snwap` is that the router
/// pays for the observed balance delta, not for the mechanism that produced it.
contract MockFill {
    function fill(address token, address to, uint256 amount) public payable {
        if (token == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok);
        } else {
            IERC20(token).transfer(to, amount);
        }
    }

    receive() external payable {}
}

address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @dev A real EIP-2612 token rather than a stub: the router only forwards the
/// signature, so a stub that skipped ecrecover would test nothing.
contract PermitToken {
    string public constant name = "Permit Token";
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public nonces;

    constructor() {
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        public
    {
        require(block.timestamp <= deadline, "expired");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        require(ecrecover(digest, v, r, s) == owner, "bad sig");
        allowance[owner][spender] = value;
    }
}

/// @dev Trusted `execute` target that tries to re-enter the V3 callback while it
/// holds control, and records what came back.
contract Reenterer {
    bool public called;
    bool public ok;
    uint256 public retLen;

    function poke(address router, bytes calldata data) public payable {
        called = true;
        bytes memory ret;
        (ok, ret) = router.call(data);
        retLen = ret.length;
    }
}

contract RobinhoodTest is Test {
    zRouterLite router;
    zQuoterRobinhood quoter;

    address alice = makeAddr("alice");
    address deployer = makeAddr("deployer");
    address nowhere = makeAddr("nowhere"); // a "token" that exists in no venue

    function setUp() public {
        vm.createSelectFork(RPC);
        // The constructor takes ownership from tx.origin, so set both.
        vm.prank(deployer, deployer);
        router = new zRouterLite();
        quoter = new zQuoterRobinhood(address(router));
        vm.deal(alice, 100 ether);
    }

    /// @dev Buy `who` some of `token` the honest way, so the sell-side tests have
    /// stock. Skips the calling test if that pair has nothing to sell.
    function _fund(address who, address token, uint256 amount) internal {
        (, uint256 expected) = quoter.quoteV2(false, address(0), token, amount);
        _need(expected);
        vm.deal(who, who.balance + amount);
        vm.prank(who);
        router.swapV2{value: amount}(who, false, address(0), token, amount, 0, block.timestamp);
    }

    /// @dev A venue with no liquidity at the current head is not a failure of the
    /// code under test, so say so and stop rather than assert against zero.
    function _need(uint256 quoted) internal {
        if (quoted == 0) vm.skip(true);
    }

    /// @dev An exact-out target sized from live liquidity: half of what a small
    /// exact-in actually buys is always well inside the reserve.
    function _halfOfASmallBuy(uint24 fee, bool v4) internal returns (uint256) {
        (, uint256 out) = v4
            ? quoter.quoteV4(false, address(0), TKN, fee, 0.001 ether)
            : (fee == 0 ? quoter.quoteV2(false, address(0), TKN, 0.001 ether) : quoter.quoteV3(false, address(0), TKN, fee, 0.001 ether));
        _need(out);
        return out / 2;
    }

    // ══════════════════ constants, checked against the chain ══════════════════

    function testChainIsRobinhood() public view {
        assertEq(block.chainid, 4663);
    }

    /// @dev Called by signature rather than through an interface: a method named
    /// `WETH()` would shadow the file-scope constant it is being checked against.
    function testWethAgreesAcrossBothUniswapRouters() public view {
        assertEq(_addrCall(SWAP_ROUTER_02, "WETH9()"), WETH);
        assertEq(_addrCall(V2_ROUTER_02, "WETH()"), WETH);
    }

    function _addrCall(address target, string memory sig) internal view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        assertTrue(ok && ret.length == 32, "call failed");
        return abi.decode(ret, (address));
    }

    /// @dev The load-bearing one, and the reason this port is safe at all: the
    /// quoter and the router both reach a pool by CREATE2 rather than by asking
    /// the factory. If the canonical init-code hash were wrong for this chain,
    /// every quote would be for an address the built calldata cannot reach. This
    /// compares the derivation against the factory's own registry, and needs no
    /// liquidity to do it.
    function testV3DerivationMatchesFactoryRegistry() public view {
        (address token0, address token1) = WETH < TKN ? (WETH, TKN) : (TKN, WETH);
        address derived = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            V3_FACTORY,
                            keccak256(abi.encode(token0, token1, uint24(10_000))),
                            V3_POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
        assertEq(IV3Factory(V3_FACTORY).getPool(WETH, TKN, 10_000), derived, "V3 init-code hash is wrong for 4663");
    }

    /// @dev Same check for V2, whose salt is packed rather than abi-encoded.
    function testV2DerivationMatchesFactoryRegistry() public view {
        (address token0, address token1) = WETH < TKN ? (WETH, TKN) : (TKN, WETH);
        address derived = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            V2_FACTORY,
                            keccak256(abi.encodePacked(token0, token1)),
                            V2_POOL_INIT_CODE_HASH
                        )
                    )
                )
            )
        );
        assertEq(IV2Factory(V2_FACTORY).getPair(WETH, TKN), derived, "V2 init-code hash is wrong for 4663");
    }

    function testStateViewPointsAtTheRoutersPoolManager() public view {
        assertEq(IStateView(V4_STATE_VIEW).poolManager(), V4_POOL_MANAGER);
    }

    // ══════════════════ quote == execution, per venue ══════════════════

    function testV2QuoteMatchesExecution() public {
        uint256 amountIn = 0.01 ether;
        (, uint256 quoted) = quoter.quoteV2(false, address(0), TKN, amountIn);
        _need(quoted);

        vm.prank(alice);
        (, uint256 amountOut) =
            router.swapV2{value: amountIn}(alice, false, address(0), TKN, amountIn, 0, block.timestamp);
        assertEq(amountOut, quoted, "V2 quote drifted from execution");
        assertEq(IERC20(TKN).balanceOf(alice), amountOut);
    }

    function testV3QuoteMatchesExecution() public {
        uint256 amountIn = 0.01 ether;
        (, uint256 quoted) = quoter.quoteV3(false, address(0), TKN, 10_000, amountIn);
        _need(quoted);

        vm.prank(alice);
        (, uint256 amountOut) =
            router.swapV3{value: amountIn}(alice, false, 10_000, address(0), TKN, amountIn, 0, block.timestamp);
        assertEq(amountOut, quoted, "V3 quote drifted from execution");
    }

    function testV4QuoteMatchesExecution() public {
        uint256 amountIn = 0.01 ether;
        (, uint256 quoted) = quoter.quoteV4(false, address(0), TKN, 10_000, amountIn);
        _need(quoted);

        vm.prank(alice);
        (, uint256 amountOut) =
            router.swapV4{value: amountIn}(alice, false, 10_000, 200, address(0), TKN, amountIn, 0, block.timestamp);
        assertEq(amountOut, quoted, "V4 quote drifted from execution");
    }

    function testV4QuoteMatchesExecutionAtTheOtherTier() public {
        uint256 amountIn = 0.01 ether;
        (, uint256 quoted) = quoter.quoteV4(false, address(0), TKN, 3000, amountIn);
        _need(quoted);

        vm.prank(alice);
        (, uint256 amountOut) =
            router.swapV4{value: amountIn}(alice, false, 3000, 60, address(0), TKN, amountIn, 0, block.timestamp);
        assertEq(amountOut, quoted, "V4 0.3% quote drifted from execution");
    }

    /// @dev The reverse leg: selling a token back for native ETH exercises the
    /// unwrap-and-forward tail of each swap function.
    function testV2SellForEthQuoteMatchesExecution() public {
        _fund(alice, TKN, 0.05 ether);
        uint256 bal = IERC20(TKN).balanceOf(alice);
        assertGt(bal, 0);

        (, uint256 quoted) = quoter.quoteV2(false, TKN, address(0), bal);
        _need(quoted);

        vm.startPrank(alice);
        IERC20(TKN).approve(address(router), bal);
        uint256 before = alice.balance;
        (, uint256 amountOut) = router.swapV2(alice, false, TKN, address(0), bal, 0, block.timestamp);
        vm.stopPrank();

        assertEq(amountOut, quoted, "V2 sell quote drifted from execution");
        assertEq(alice.balance, before + amountOut);
    }

    function testV3SellForEthQuoteMatchesExecution() public {
        _fund(alice, TKN, 0.05 ether);
        uint256 bal = IERC20(TKN).balanceOf(alice);

        (, uint256 quoted) = quoter.quoteV3(false, TKN, address(0), 10_000, bal);
        _need(quoted);

        vm.startPrank(alice);
        IERC20(TKN).approve(address(router), bal);
        uint256 before = alice.balance;
        (, uint256 amountOut) = router.swapV3(alice, false, 10_000, TKN, address(0), bal, 0, block.timestamp);
        vm.stopPrank();

        assertEq(amountOut, quoted, "V3 sell quote drifted from execution");
        assertEq(alice.balance, before + amountOut);
    }

    function testV4SellForEthQuoteMatchesExecution() public {
        _fund(alice, TKN, 0.05 ether);
        uint256 bal = IERC20(TKN).balanceOf(alice);

        (, uint256 quoted) = quoter.quoteV4(false, TKN, address(0), 10_000, bal);
        _need(quoted);

        vm.startPrank(alice);
        IERC20(TKN).approve(address(router), bal);
        uint256 before = alice.balance;
        (, uint256 amountOut) = router.swapV4(alice, false, 10_000, 200, TKN, address(0), bal, 0, block.timestamp);
        vm.stopPrank();

        assertEq(amountOut, quoted, "V4 sell quote drifted from execution");
        assertEq(alice.balance, before + amountOut);
    }

    /// @dev Neither side is ETH, so no wrap or unwrap runs on either end.
    function testTokenToTokenV2() public {
        _fund(alice, TKN2, 0.05 ether);
        uint256 bal = IERC20(TKN2).balanceOf(alice);
        assertGt(bal, 0);

        (, uint256 quoted) = quoter.quoteV2(false, TKN2, WETH, bal);
        _need(quoted);

        vm.startPrank(alice);
        IERC20(TKN2).approve(address(router), bal);
        (, uint256 amountOut) = router.swapV2(alice, false, TKN2, WETH, bal, 0, block.timestamp);
        vm.stopPrank();

        assertEq(amountOut, quoted);
        assertEq(IERC20(WETH).balanceOf(alice), amountOut);
    }

    // ══════════════════ exact-out ══════════════════

    /// @dev The target is sized from live liquidity rather than typed in: an
    /// exact-out at or above the reserve is not expensive, it is impossible, and
    /// the quoter answers zero for it (see the companion test below).
    function testExactOutV2() public {
        uint256 want = _halfOfASmallBuy(0, false);
        (uint256 quotedIn,) = quoter.quoteV2(true, address(0), TKN, want);
        _need(quotedIn);

        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut) =
            router.swapV2{value: quotedIn}(alice, true, address(0), TKN, want, quotedIn, block.timestamp);
        assertEq(amountOut, want);
        assertEq(amountIn, quotedIn, "V2 exact-out quote drifted from execution");
    }

    function testExactOutV3() public {
        uint256 want = _halfOfASmallBuy(10_000, false);
        (uint256 quotedIn,) = quoter.quoteV3(true, address(0), TKN, 10_000, want);
        _need(quotedIn);

        uint256 sent = quotedIn * 2; // overpay; the router must refund the rest
        uint256 before = alice.balance;

        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut) =
            router.swapV3{value: sent}(alice, true, 10_000, address(0), TKN, want, quotedIn, block.timestamp);

        assertEq(amountOut, want);
        assertEq(amountIn, quotedIn, "V3 exact-out quote drifted from execution");
        assertEq(alice.balance, before - quotedIn, "excess ETH was not refunded");
    }

    function testExactOutV4() public {
        uint256 want = _halfOfASmallBuy(10_000, true);
        (uint256 quotedIn,) = quoter.quoteV4(true, address(0), TKN, 10_000, want);
        _need(quotedIn);

        uint256 sent = quotedIn * 2;
        uint256 before = alice.balance;

        vm.prank(alice);
        (uint256 amountIn, uint256 amountOut) =
            router.swapV4{value: sent}(alice, true, 10_000, 200, address(0), TKN, want, quotedIn, block.timestamp);

        assertEq(amountOut, want);
        assertEq(amountIn, quotedIn, "V4 exact-out quote drifted from execution");
        assertEq(alice.balance, before - quotedIn, "excess ETH was not refunded");
    }

    /// @dev No V2 pair can hold `type(uint112).max`, so this is reserve-independent.
    function testExactOutBeyondV2ReserveQuotesZero() public view {
        (uint256 quotedIn,) = quoter.quoteV2(true, address(0), TKN, type(uint112).max);
        assertEq(quotedIn, 0, "quoted a trade larger than the pair holds");
    }

    // ══════════════════ guards ══════════════════

    function testDeadlineIsEnforcedOnEveryVenue() public {
        uint256 past = block.timestamp - 1;
        vm.startPrank(alice);
        vm.expectRevert(zRouterLite.Expired.selector);
        router.swapV2{value: 1 wei}(alice, false, address(0), TKN, 1 wei, 0, past);
        vm.expectRevert(zRouterLite.Expired.selector);
        router.swapV3{value: 1 wei}(alice, false, 10_000, address(0), TKN, 1 wei, 0, past);
        vm.expectRevert(zRouterLite.Expired.selector);
        router.swapV4{value: 1 wei}(alice, false, 10_000, 200, address(0), TKN, 1 wei, 0, past);
        vm.stopPrank();
    }

    /// @dev A max deadline is just "no deadline" here. On mainnet the same value
    /// is the Sushi sentinel, and this is the test that pins the difference.
    function testMaxDeadlineIsNotASushiSentinel() public {
        (, uint256 q) = quoter.quoteV2(false, address(0), TKN, 0.01 ether);
        _need(q);
        vm.prank(alice);
        (, uint256 amountOut) =
            router.swapV2{value: 0.01 ether}(alice, false, address(0), TKN, 0.01 ether, 0, type(uint256).max);
        assertGt(amountOut, 0);
    }

    function testSlippageBoundIsEnforced() public {
        (, uint256 quoted) = quoter.quoteV2(false, address(0), TKN, 0.01 ether);
        _need(quoted);

        vm.startPrank(alice);
        vm.expectRevert(zRouterLite.Slippage.selector);
        router.swapV2{value: 0.01 ether}(alice, false, address(0), TKN, 0.01 ether, quoted + 1, block.timestamp);

        vm.expectRevert(zRouterLite.Slippage.selector);
        router.swapV3{value: 0.01 ether}(
            alice, false, 10_000, address(0), TKN, 0.01 ether, type(uint128).max, block.timestamp
        );

        vm.expectRevert(zRouterLite.Slippage.selector);
        router.swapV4{value: 0.01 ether}(
            alice, false, 10_000, 200, address(0), TKN, 0.01 ether, type(uint128).max, block.timestamp
        );
        vm.stopPrank();
    }

    function testZeroAmountWithNoBalanceIsBadSwap() public {
        vm.startPrank(alice);
        vm.expectRevert(zRouterLite.BadSwap.selector);
        router.swapV2(alice, false, TKN, address(0), 0, 0, block.timestamp);
        vm.expectRevert(zRouterLite.BadSwap.selector);
        router.swapV3(alice, false, 10_000, TKN, address(0), 0, 0, block.timestamp);
        vm.expectRevert(zRouterLite.BadSwap.selector);
        router.swapV4(alice, false, 10_000, 200, TKN, address(0), 0, 0, block.timestamp);
        vm.stopPrank();
    }

    /// @dev The V3 callback must refuse anyone who is not the pool the swap
    /// arguments derive to.
    function testV3CallbackRejectsStrangers() public {
        vm.prank(alice);
        (bool ok,) = address(router).call(_v3Callback());
        assertFalse(ok, "callback accepted a stranger");
    }

    function testUnlockCallbackRejectsStrangers() public {
        vm.prank(alice);
        vm.expectRevert(zRouterLite.Unauthorized.selector);
        router.unlockCallback("");
    }

    function _v3Callback() internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "uniswapV3SwapCallback(int256,int256,bytes)",
            int256(1),
            int256(-1),
            abi.encodePacked(false, false, alice, WETH, TKN, alice, uint24(10_000))
        );
    }

    // ══════════════════ transient balances and multicall ══════════════════

    function testMulticallChainsDepositSwapSweep() public {
        _fund(alice, TKN, 0.05 ether);
        uint256 bal = IERC20(TKN).balanceOf(alice);

        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(zRouterLite.deposit.selector, TKN, bal);
        // `to` is the router, so the output stays credited inside it...
        calls[1] = abi.encodeWithSelector(
            zRouterLite.swapV2.selector, address(router), false, TKN, WETH, bal, uint256(0), block.timestamp
        );
        // ...until this sweeps the whole WETH balance out to alice.
        calls[2] = abi.encodeWithSelector(zRouterLite.sweep.selector, WETH, uint256(0), alice);

        vm.startPrank(alice);
        IERC20(TKN).approve(address(router), bal);
        router.multicall(calls);
        vm.stopPrank();

        assertGt(IERC20(WETH).balanceOf(alice), 0, "chained output never landed");
        assertEq(IERC20(WETH).balanceOf(address(router)), 0, "router kept the output");
    }

    function testMulticallBubblesTheInnerRevert() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(
            zRouterLite.swapV2.selector, alice, false, address(0), TKN, uint256(1), uint256(0), block.timestamp - 1
        );
        vm.prank(alice);
        vm.expectRevert(zRouterLite.Expired.selector);
        router.multicall(calls);
    }

    function testDepositRejectsMismatchedMsgValue() public {
        vm.startPrank(alice);
        vm.expectRevert(zRouterLite.InvalidMsgVal.selector);
        router.deposit{value: 1 ether}(WETH, 2 ether);
        vm.expectRevert(zRouterLite.InvalidMsgVal.selector);
        router.deposit{value: 1 ether}(TKN, 1 ether);
        vm.stopPrank();
    }

    /// @dev Depositing WETH with ether attached wraps on the way in.
    function testDepositWithEtherWrapsToWeth() public {
        vm.prank(alice);
        router.deposit{value: 1 ether}(WETH, 1 ether);
        assertEq(IERC20(WETH).balanceOf(address(router)), 1 ether);
    }

    function testSweepEther() public {
        vm.deal(address(router), 1 ether);
        uint256 before = alice.balance;
        router.sweep(address(0), 0, alice);
        assertEq(alice.balance, before + 1 ether);
    }

    function testWrapAndUnwrapDirectly() public {
        vm.prank(alice);
        router.wrap{value: 1 ether}(0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 1 ether);

        router.unwrap(0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
        assertEq(address(router).balance, 1 ether);
    }

    function testReceiveAcceptsEther() public {
        vm.prank(alice);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(router).balance, 1 ether);
    }

    // ══════════════════ ownable / trust / execute ══════════════════

    function testDeployerOwnsTheRouter() public view {
        assertEq(router.owner(), deployer);
    }

    function testOnlyOwnerCanTrustOrTransfer() public {
        vm.startPrank(alice);
        vm.expectRevert(zRouterLite.Unauthorized.selector);
        router.trust(alice, true);
        vm.expectRevert(zRouterLite.Unauthorized.selector);
        router.transferOwnership(alice);
        vm.expectRevert(zRouterLite.Unauthorized.selector);
        router.ensureAllowance(TKN, alice);
        vm.stopPrank();
    }

    function testTransferOwnershipEmitsAndMoves() public {
        vm.expectEmit(true, true, false, false);
        emit zRouterLite.OwnershipTransferred(deployer, alice);
        vm.prank(deployer);
        router.transferOwnership(alice);
        assertEq(router.owner(), alice);
    }

    function testEnsureAllowanceApproves() public {
        vm.prank(deployer);
        router.ensureAllowance(TKN, alice);
        (, bytes memory ret) =
            TKN.staticcall(abi.encodeWithSignature("allowance(address,address)", address(router), alice));
        assertEq(abi.decode(ret, (uint256)), type(uint256).max);
    }

    function testExecuteRejectsUntrustedTargets() public {
        Reenterer target = new Reenterer();
        assertFalse(router.isTrustedForCall(address(target)));
        vm.prank(deployer);
        vm.expectRevert(zRouterLite.Unauthorized.selector);
        router.execute(address(target), 0, abi.encodeWithSelector(Reenterer.poke.selector, address(router), bytes("")));
    }

    function testExecuteRunsATrustedTarget() public {
        Reenterer target = new Reenterer();
        vm.prank(deployer);
        router.trust(address(target), true);
        assertTrue(router.isTrustedForCall(address(target)));

        router.execute(address(target), 0, abi.encodeWithSelector(Reenterer.poke.selector, address(router), bytes("")));
        assertTrue(target.called(), "trusted target was never reached");
    }

    function testTrustCanBeRevoked() public {
        Reenterer target = new Reenterer();
        vm.startPrank(deployer);
        router.trust(address(target), true);
        router.trust(address(target), false);
        vm.stopPrank();

        vm.expectRevert(zRouterLite.Unauthorized.selector);
        router.execute(address(target), 0, abi.encodeWithSelector(Reenterer.poke.selector, address(router), bytes("")));
    }

    /// @dev The lock, pinned by the shape of the failure. Outside `execute` the
    /// V3 callback reverts with a 4-byte custom error; inside it, the lock fires
    /// first and reverts with empty returndata. Same call, two different reverts —
    /// which is what proves the lock, and not just the pool check, did the work.
    function testExecuteLocksTheV3Callback() public {
        bytes memory cb = _v3Callback();

        (bool okOutside, bytes memory retOutside) = address(router).call(cb);
        assertFalse(okOutside);
        assertEq(retOutside.length, 4, "expected a 4-byte custom error outside the lock");

        Reenterer target = new Reenterer();
        vm.prank(deployer);
        router.trust(address(target), true);
        router.execute(address(target), 0, abi.encodeWithSelector(Reenterer.poke.selector, address(router), cb));

        assertFalse(target.ok(), "callback was reachable during execute");
        assertEq(target.retLen(), 0, "lock did not fire first");
    }

    function testExecuteLocksTheV4Callback() public {
        bytes memory cb = abi.encodeWithSelector(zRouterLite.unlockCallback.selector, bytes(""));

        Reenterer target = new Reenterer();
        vm.prank(deployer);
        router.trust(address(target), true);

        // Called as the PoolManager so the sender check passes and only the lock
        // can be what stops it.
        vm.etch(V4_POOL_MANAGER, address(target).code);
        vm.prank(deployer);
        router.trust(V4_POOL_MANAGER, true);
        router.execute(V4_POOL_MANAGER, 0, abi.encodeWithSelector(Reenterer.poke.selector, address(router), cb));

        assertFalse(Reenterer(V4_POOL_MANAGER).ok(), "v4 callback was reachable during execute");
        assertEq(Reenterer(V4_POOL_MANAGER).retLen(), 0, "lock did not fire first");
    }

    function testExecuteUnlocksAfterwards() public {
        Reenterer target = new Reenterer();
        vm.prank(deployer);
        router.trust(address(target), true);
        router.execute(address(target), 0, abi.encodeWithSelector(Reenterer.poke.selector, address(router), bytes("")));

        // A normal swap still works in the same transaction.
        vm.prank(alice);
        (, uint256 out) =
            router.swapV2{value: 0.01 ether}(alice, false, address(0), TKN, 0.01 ether, 0, block.timestamp);
        assertGt(out, 0, "lock was left set");
    }

    // ══════════════════ snwap ══════════════════

    function testSnwapPaysForTheBalanceDelta() public {
        _fund(address(this), TKN, 0.05 ether);
        uint256 bal = IERC20(TKN).balanceOf(address(this));
        assertGt(bal, 0);

        MockFill filler = new MockFill();
        IERC20(TKN).approve(address(router), bal);

        uint256 amountOut = router.snwap(
            TKN,
            bal,
            alice,
            TKN,
            bal, // the filler forwards the whole amount straight through
            address(filler),
            abi.encodeWithSelector(MockFill.fill.selector, TKN, alice, bal)
        );

        assertEq(amountOut, bal);
        assertEq(IERC20(TKN).balanceOf(alice), bal);
    }

    function testSnwapEnforcesItsMinimum() public {
        _fund(address(this), TKN, 0.05 ether);
        uint256 bal = IERC20(TKN).balanceOf(address(this));

        MockFill filler = new MockFill();
        IERC20(TKN).approve(address(router), bal);

        vm.expectRevert(abi.encodeWithSelector(zRouterLite.SnwapSlippage.selector, TKN, bal - 1, bal));
        router.snwap(
            TKN, bal, alice, TKN, bal, address(filler), abi.encodeWithSelector(MockFill.fill.selector, TKN, alice, bal - 1)
        );
    }

    /// @dev With the router itself as recipient, the fill must land as a
    /// transient credit so a following `multicall` leg can spend it.
    function testSnwapToRouterCreditsTransiently() public {
        _fund(address(this), TKN, 0.05 ether);
        uint256 bal = IERC20(TKN).balanceOf(address(this));

        MockFill filler = new MockFill();
        IERC20(TKN).approve(address(router), bal);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            zRouterLite.snwap.selector,
            TKN,
            bal,
            address(router),
            TKN,
            bal,
            address(filler),
            abi.encodeWithSelector(MockFill.fill.selector, TKN, address(router), bal)
        );
        calls[1] = abi.encodeWithSelector(zRouterLite.sweep.selector, TKN, uint256(0), alice);

        router.multicall(calls);
        assertEq(IERC20(TKN).balanceOf(alice), bal);
    }

    function testSnwapWithEtherIn() public {
        MockFill filler = new MockFill();
        uint256 before = alice.balance;

        vm.prank(alice);
        uint256 amountOut = router.snwap{value: 1 ether}(
            address(0),
            0,
            alice,
            address(0),
            1 ether,
            address(filler),
            abi.encodeWithSelector(MockFill.fill.selector, address(0), alice, 1 ether)
        );

        assertEq(amountOut, 1 ether);
        assertEq(alice.balance, before); // paid one ether, received it back
    }

    function testSnwapMultiTracksEveryOutput() public {
        _fund(address(this), TKN, 0.05 ether);
        uint256 bal = IERC20(TKN).balanceOf(address(this));

        MockFill filler = new MockFill();
        IERC20(TKN).approve(address(router), bal);

        address[] memory tokensOut = new address[](2);
        tokensOut[0] = TKN;
        tokensOut[1] = address(0);
        uint256[] memory mins = new uint256[](2);
        mins[0] = bal;
        mins[1] = 0;

        uint256[] memory outs = router.snwapMulti(
            TKN,
            bal,
            alice,
            tokensOut,
            mins,
            address(filler),
            abi.encodeWithSelector(MockFill.fill.selector, TKN, alice, bal)
        );

        assertEq(outs[0], bal);
        assertEq(outs[1], 0);
    }

    function testSnwapMultiEnforcesEveryMinimum() public {
        _fund(address(this), TKN, 0.05 ether);
        uint256 bal = IERC20(TKN).balanceOf(address(this));

        MockFill filler = new MockFill();
        IERC20(TKN).approve(address(router), bal);

        address[] memory tokensOut = new address[](2);
        tokensOut[0] = TKN;
        tokensOut[1] = address(0);
        uint256[] memory mins = new uint256[](2);
        mins[0] = bal;
        mins[1] = 1; // no ether is ever delivered, so this one must trip

        vm.expectRevert(abi.encodeWithSelector(zRouterLite.SnwapSlippage.selector, address(0), 0, 1));
        router.snwapMulti(
            TKN,
            bal,
            alice,
            tokensOut,
            mins,
            address(filler),
            abi.encodeWithSelector(MockFill.fill.selector, TKN, alice, bal)
        );
    }

    /// @dev The helper the whole design leans on: separate contract, no balance,
    /// so handing it an arbitrary target grants that target no authority.
    function testSafeExecutorIsSeparateAndEmpty() public view {
        address se = address(router.safeExecutor());
        assertTrue(se != address(router));
        assertGt(se.code.length, 0);
        assertEq(se.balance, 0);
    }

    // ══════════════════ permit legs, for one-transaction UX ══════════════════

    /// @dev The point is the batching: a `permit` leg and the leg that spends the
    /// allowance ride in one `multicall`, so the user signs instead of sending a
    /// separate approve first. `multicall` delegatecalls, so `msg.sender` inside
    /// the permit leg is still the signer.
    function testPermitLegBatchesWithASpend() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        PermitToken token = new PermitToken();
        token.mint(signer, 10 ether);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                token.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        token.PERMIT_TYPEHASH(), signer, address(router), uint256(10 ether), uint256(0), deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(pk, digest);

        bytes[] memory calls = new bytes[](3);
        calls[0] =
            abi.encodeWithSelector(zRouterLite.permit.selector, address(token), uint256(10 ether), deadline, v, r, sg);
        calls[1] = abi.encodeWithSelector(zRouterLite.deposit.selector, address(token), uint256(10 ether));
        calls[2] = abi.encodeWithSelector(zRouterLite.sweep.selector, address(token), uint256(0), alice);

        vm.prank(signer);
        router.multicall(calls);

        assertEq(token.balanceOf(alice), 10 ether, "permit leg did not authorise the spend");
        assertEq(token.balanceOf(signer), 0);
    }

    function testPermitSelectorMatchesTheFrontEnd() public pure {
        assertEq(zRouterLite.permit.selector, bytes4(0x7ac2ff7b));
        assertEq(zRouterLite.permit2TransferFrom.selector, bytes4(0x09d31579));
    }

    /// @dev End to end against the Permit2 actually deployed on 4663 — the
    /// signature is verified by that contract, not by a mock.
    function testPermit2TransferFromPullsAndCreditsTransiently() public {
        assertGt(PERMIT2.code.length, 0, "Permit2 is not deployed on this chain");

        (address signer, uint256 pk) = makeAddrAndKey("p2signer");
        PermitToken token = new PermitToken();
        token.mint(signer, 10 ether);

        vm.prank(signer);
        token.approve(PERMIT2, type(uint256).max);

        uint256 nonce = 1;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPermit2(pk, address(token), 10 ether, nonce, deadline);

        // Pull, then hand the credited balance straight back out to alice.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(
            zRouterLite.permit2TransferFrom.selector, address(token), uint256(10 ether), nonce, deadline, sig
        );
        calls[1] = abi.encodeWithSelector(zRouterLite.sweep.selector, address(token), uint256(0), alice);

        vm.prank(signer);
        router.multicall(calls);

        assertEq(token.balanceOf(alice), 10 ether, "permit2 pull never landed");
        assertEq(token.balanceOf(signer), 0);
    }

    function testPermit2RejectsASignatureForSomeoneElse() public {
        (, uint256 pk) = makeAddrAndKey("p2signer");
        (address mallory,) = makeAddrAndKey("mallory");
        PermitToken token = new PermitToken();
        token.mint(mallory, 10 ether);
        vm.prank(mallory);
        token.approve(PERMIT2, type(uint256).max);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signPermit2(pk, address(token), 10 ether, 2, deadline);

        // Signed by `signer`, submitted by `mallory`: Permit2 recovers the wrong
        // owner and refuses.
        vm.prank(mallory);
        vm.expectRevert();
        router.permit2TransferFrom(address(token), 10 ether, 2, deadline, sig);
    }

    function _signPermit2(uint256 pk, address token, uint256 amount, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 tokenPermissions =
            keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), token, amount));
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
                ),
                tokenPermissions,
                address(router),
                nonce,
                deadline
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", IPermit2Domain(PERMIT2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ══════════════════ quoter aggregate surface ══════════════════

    function testBuildBestSwapIsExecutableAsIs() public {
        uint256 amountIn = 0.01 ether;
        (zQuoterRobinhood.Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) =
            quoter.buildBestSwap(alice, false, address(0), TKN, amountIn, 100, block.timestamp);

        _need(best.amountOut);
        assertEq(msgValue, amountIn);

        vm.prank(alice);
        (bool ok,) = address(router).call{value: msgValue}(callData);
        assertTrue(ok, "quoter-built calldata reverted");
        assertGe(IERC20(TKN).balanceOf(alice), amountLimit, "landed under the embedded slippage bound");
    }

    function testBuildBestSwapExactOutIsExecutableAsIs() public {
        uint256 want = _halfOfASmallBuy(0, false);
        (zQuoterRobinhood.Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) =
            quoter.buildBestSwap(alice, true, address(0), TKN, want, 100, block.timestamp);

        _need(best.amountIn);
        assertEq(msgValue, amountLimit, "exact-out must attach the upper bound");

        vm.prank(alice);
        (bool ok,) = address(router).call{value: msgValue}(callData);
        assertTrue(ok, "quoter-built exact-out calldata reverted");
        assertEq(IERC20(TKN).balanceOf(alice), want);
    }

    /// @dev Selling a token through the built calldata, which is the leg that
    /// needs an ERC20 approval rather than attached value.
    function testBuildBestSwapSellSideIsExecutableAsIs() public {
        _fund(alice, TKN, 0.05 ether);
        uint256 bal = IERC20(TKN).balanceOf(alice);

        (zQuoterRobinhood.Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue) =
            quoter.buildBestSwap(alice, false, TKN, address(0), bal, 100, block.timestamp);
        _need(best.amountOut);
        assertEq(msgValue, 0, "selling a token must not attach value");

        vm.startPrank(alice);
        IERC20(TKN).approve(address(router), bal);
        uint256 before = alice.balance;
        (bool ok,) = address(router).call(callData);
        vm.stopPrank();

        assertTrue(ok, "sell-side calldata reverted");
        assertGe(alice.balance - before, amountLimit);
    }

    function testBestBeatsOrTiesEveryVenue() public view {
        (zQuoterRobinhood.Quote memory best, zQuoterRobinhood.Quote[] memory quotes) =
            quoter.getQuotes(false, address(0), TKN, 0.01 ether);
        assertEq(quotes.length, 9);
        for (uint256 i; i < quotes.length; ++i) {
            assertGe(best.amountOut, quotes[i].amountOut);
        }
    }

    /// @dev Slot order is part of the ABI: callers index by venue, and entries
    /// that did not quote are left at zero rather than dropped.
    function testQuoteSlotsAreStablyOrdered() public view {
        (, zQuoterRobinhood.Quote[] memory q) = quoter.getQuotes(false, address(0), TKN, 0.01 ether);
        assertTrue(q[0].source == zQuoterRobinhood.AMM.UNI_V2);
        assertEq(q[0].feeBps, 30);
        uint256[4] memory tiers = [uint256(1), 5, 30, 100];
        for (uint256 i; i < 4; ++i) {
            assertTrue(q[1 + i].source == zQuoterRobinhood.AMM.UNI_V3);
            assertEq(q[1 + i].feeBps, tiers[i]);
            assertTrue(q[5 + i].source == zQuoterRobinhood.AMM.UNI_V4);
            assertEq(q[5 + i].feeBps, tiers[i]);
        }
    }

    /// @dev The enum ordinals are shared with mainnet's zQuoter so a `source`
    /// crossing the wire means the same thing on both chains.
    function testAmmOrdinalsMatchMainnet() public pure {
        assertEq(uint256(zQuoterRobinhood.AMM.UNI_V2), 0);
        assertEq(uint256(zQuoterRobinhood.AMM.UNI_V3), 3);
        assertEq(uint256(zQuoterRobinhood.AMM.UNI_V4), 4);
        assertEq(uint256(zQuoterRobinhood.AMM.WETH_WRAP), 7);
    }

    function testExactOutPicksTheCheapestInput() public {
        (zQuoterRobinhood.Quote memory best, zQuoterRobinhood.Quote[] memory quotes) =
            quoter.getQuotes(true, address(0), TKN, _halfOfASmallBuy(0, false));
        _need(best.amountIn);
        for (uint256 i; i < quotes.length; ++i) {
            if (quotes[i].amountIn != 0) assertLe(best.amountIn, quotes[i].amountIn);
        }
    }

    function testNoRouteReverts() public {
        vm.expectRevert(zQuoterRobinhood.NoRoute.selector);
        quoter.buildBestSwap(alice, false, address(0), nowhere, 1 ether, 100, block.timestamp);
    }

    function testUnknownTokenQuotesZeroRatherThanReverting() public view {
        (zQuoterRobinhood.Quote memory best, zQuoterRobinhood.Quote[] memory quotes) =
            quoter.getQuotes(false, address(0), nowhere, 1 ether);
        assertEq(best.amountOut, 0);
        for (uint256 i; i < quotes.length; ++i) {
            assertEq(quotes[i].amountOut, 0);
        }
    }

    function testIdenticalTokensReverts() public {
        vm.expectRevert(zQuoterRobinhood.IdenticalTokens.selector);
        quoter.getQuotes(false, address(0), WETH, 1 ether);
    }

    function testSlippageBpsCeilingIsEnforced() public {
        vm.expectRevert(zQuoterRobinhood.SlippageBpsTooHigh.selector);
        quoter.buildBestSwap(alice, false, address(0), TKN, 1 ether, 10_000, block.timestamp);
    }

    function testZeroAmountQuotesZero() public view {
        (, uint256 outV2) = quoter.quoteV2(false, address(0), TKN, 0);
        (, uint256 outV3) = quoter.quoteV3(false, address(0), TKN, 10_000, 0);
        (, uint256 outV4) = quoter.quoteV4(false, address(0), TKN, 10_000, 0);
        assertEq(outV2, 0);
        assertEq(outV3, 0);
        assertEq(outV4, 0);
    }

    function testQuoterKnowsItsRouter() public view {
        assertEq(quoter.ZROUTER(), address(router));
    }

    /// @dev When the caller asks for the output to stay in the router, the built
    /// calldata must not end with a sweep — that is the chaining branch.
    function testBuildBestSwapLeavesFundsInRouterWhenAsked() public view {
        (, bytes memory chained,,) =
            quoter.buildBestSwap(address(router), false, address(0), WETH, 1 ether, 50, block.timestamp);
        (, bytes memory swept,,) = quoter.buildBestSwap(alice, false, address(0), WETH, 1 ether, 50, block.timestamp);

        assertEq(bytes4(chained), zRouterLite.wrap.selector, "chained wrap should be a bare wrap");
        assertEq(bytes4(swept), zRouterLite.multicall.selector, "unchained wrap should sweep");
        assertTrue(chained.length < swept.length);
    }

    /// @dev The quoter and the router ship as a pair, so the selectors the quoter
    /// emits must be the ones the router actually exposes. The unwrap path is the
    /// only place `deposit` and `sweep` appear in built calldata, so decode it and
    /// check the inner legs rather than trusting the round-trip alone.
    function testBuiltCalldataUsesTheRoutersOwnSelectors() public view {
        (, bytes memory callData,,) = quoter.buildBestSwap(alice, false, WETH, address(0), 1 ether, 50, block.timestamp);
        assertEq(bytes4(callData), zRouterLite.multicall.selector);

        bytes[] memory legs = abi.decode(_tail(callData), (bytes[]));
        assertEq(legs.length, 3);
        assertEq(bytes4(legs[0]), zRouterLite.deposit.selector, "deposit selector drifted");
        assertEq(bytes4(legs[1]), zRouterLite.unwrap.selector, "unwrap selector drifted");
        assertEq(bytes4(legs[2]), zRouterLite.sweep.selector, "sweep selector drifted");

        // And the arguments decode against the new, id-free signatures.
        (address depToken, uint256 depAmount) = abi.decode(_tail(legs[0]), (address, uint256));
        assertEq(depToken, WETH);
        assertEq(depAmount, 1 ether);
        (address swToken, uint256 swAmount, address swTo) = abi.decode(_tail(legs[2]), (address, uint256, address));
        assertEq(swToken, address(0));
        assertEq(swAmount, 1 ether);
        assertEq(swTo, alice);
    }

    function _tail(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }

    // ══════════════════ ETH <-> WETH is not a swap ══════════════════

    function testWrapIsQuotedOneToOneAndExecutes() public {
        uint256 amount = 1 ether;
        (zQuoterRobinhood.Quote memory best, bytes memory callData,, uint256 msgValue) =
            quoter.buildBestSwap(alice, false, address(0), WETH, amount, 50, block.timestamp);

        assertTrue(best.source == zQuoterRobinhood.AMM.WETH_WRAP);
        assertEq(best.amountOut, amount);
        assertEq(msgValue, amount);

        vm.prank(alice);
        (bool ok,) = address(router).call{value: msgValue}(callData);
        assertTrue(ok, "wrap multicall reverted");
        assertEq(IERC20(WETH).balanceOf(alice), amount);
    }

    function testUnwrapRoundTrips() public {
        vm.prank(alice);
        (bool wrapped,) = WETH.call{value: 1 ether}("");
        assertTrue(wrapped);

        (, bytes memory callData,,) = quoter.buildBestSwap(alice, false, WETH, address(0), 1 ether, 50, block.timestamp);

        vm.startPrank(alice);
        IERC20(WETH).approve(address(router), 1 ether);
        uint256 before = alice.balance;
        (bool ok,) = address(router).call(callData);
        vm.stopPrank();

        assertTrue(ok, "unwrap multicall reverted");
        assertEq(alice.balance, before + 1 ether);
    }

    receive() external payable {}
}
