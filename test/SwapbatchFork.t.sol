// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapbatch} from "../src/forwarders/Swapbatch.sol";

/// @notice Swapbatch against the LIVE Swapboard, which is the board the legacy path was
///         written for. Two things get verified here that a local board cannot show:
///
///           1. The selectors actually exist in the deployed bytecode. The live board
///              takes NO recipient — `fillOrders(uint256[],uint256,uint256[])` — and has
///              no `multicall` at all, so ETH batching there is impossible without this
///              helper. Encoding it the modern way would revert; encoding it the legacy
///              way leaves the purchase sitting in the helper until `tokensOut` sweeps.
///
///           2. Real WETH behaves as the wrap/unwrap path assumes.
///
///         Orders are created here rather than borrowed from the live book, so the test
///         does not depend on someone else's resting escrow at a pinned block.
interface ILiveBoard {
    /// @dev v1's create is the narrowest of the three boards: four arguments, with
    ///      no partialFill, expiry, NFT flags or counterparty. v1 predates all of
    ///      them - which is the same reason its Order struct is six words and its
    ///      fill takes no amount.
    function createOrder(address tokenA, uint256 amountA, address tokenB, uint256 amountB)
        external
        returns (uint256);
    function nextOrderId() external view returns (uint256);
    function weth() external view returns (address);
}

contract SwapbatchForkTest is Test {
    address constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    /// @dev v1 - the board `Swapbatch` binds as `legacyBoard`, and what "legacy"
    ///      means everywhere else: `Swapbol.boardV1()` returns it and the dapp
    ///      lists it. This suite used to bind 0x...85B831, the MID board, whose
    ///      Order struct is seven words to v1's six and whose fill takes an
    ///      amount v1 has no argument for. Testing against it made the helper
    ///      agree with a board the product does not use, while the one it does -
    ///      139 live orders against the mid board's 3 - went unexercised.
    address constant _BOARD = 0x000000fF3D7A2d373615141d7489Ca66683DbecF;

    Swapbatch batch;
    address maker = makeAddr("maker");
    address taker = makeAddr("taker");

    /// @dev The live board postdates this repo's `fork_block_number = 24_880_000` (no
    ///      code there; present by 25,400,000), so this suite forks forward. Same
    ///      situation as zQuoter — see test/DutchAuctionSnwapFork.t.sol.
    function setUp() public {
        vm.createSelectFork(
            vm.envOr("FOUNDRY_ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_640_000
        );
        require(_BOARD.code.length != 0, "live board missing at fork block");
        batch = new Swapbatch(_WETH, _BOARD, address(0), address(0));
        vm.deal(address(batch), 0);
        vm.deal(taker, 100 ether);
        vm.label(_BOARD, "Swapboard(live)");
    }

    function _approve(address token, address spender, uint256 amt) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amt));
        require(ok, "approve failed");
    }

    function _bal(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory d) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return ok ? abi.decode(d, (uint256)) : 0;
    }

    function _mins(uint256 n) internal pure returns (uint256[] memory out) {
        out = new uint256[](n);
    }

    /// Maker escrows USDC and asks for WETH, so the taker pays ETH and receives USDC.
    function _makeOrder(uint256 amountUSDC, uint256 priceWeth) internal returns (uint256 id) {
        deal(_USDC, maker, _bal(_USDC, maker) + amountUSDC);
        vm.startPrank(maker);
        _approve(_USDC, _BOARD, amountUSDC);
        id = ILiveBoard(_BOARD).createOrder(_USDC, amountUSDC, _WETH, priceWeth);
        vm.stopPrank();
    }

    function test_liveBoardIsTheLegacyShape() public view {
        assertEq(ILiveBoard(_BOARD).weth(), _WETH, "live board wraps canonical WETH");
        // No multicall: batching ETH on this board is not possible any other way.
        (bool ok,) = _BOARD.staticcall(abi.encodeWithSignature("multicall(bytes[])", new bytes[](0)));
        assertFalse(ok, "live board unexpectedly exposes multicall");
    }

    /// The whole point: two live orders, one transaction, native ETH in, USDC out.
    function test_batchFillsLiveOrdersWithEth() public {
        uint256 id1 = _makeOrder(1_000e6, 0.5 ether);
        uint256 id2 = _makeOrder(2_000e6, 1 ether);

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (id1, id2);
        uint256[] memory amts = new uint256[](2);
        (amts[0], amts[1]) = (0.5 ether, 1 ether);
        address[] memory outs = new address[](2);
        outs[0] = _USDC;
        outs[1] = _USDC;

        uint256 before = taker.balance;
        vm.prank(taker);
        batch.fillOrdersWithEth{value: 2 ether}(
            _BOARD, ids, amts, _mins(ids.length), outs, type(uint256).max, taker, false, true
        );

        assertEq(_bal(_USDC, taker), 3_000e6, "both lots swept to the taker");
        assertEq(_bal(_WETH, maker), 1.5 ether, "maker paid in WETH");
        assertEq(before - taker.balance, 1.5 ether, "charged the sum, overpayment refunded");

        // The helper must retain nothing: on this board it held the entire purchase.
        assertEq(_bal(_USDC, address(batch)), 0, "helper retained USDC");
        assertEq(_bal(_WETH, address(batch)), 0, "helper retained WETH");
        assertEq(address(batch).balance, 0, "helper retained ETH");
    }

    /// Encoding the live board the modern way must revert rather than silently buy the
    /// lot into the helper.
    function test_modernEncodingRevertsAgainstLiveBoard() public {
        uint256 id1 = _makeOrder(1_000e6, 0.5 ether);

        uint256[] memory ids = new uint256[](1);
        ids[0] = id1;
        uint256[] memory amts = new uint256[](1);
        amts[0] = 0.5 ether;
        address[] memory outs = new address[](2);
        outs[0] = _USDC;
        outs[1] = address(0);

        vm.prank(taker);
        vm.expectRevert();
        batch.fillOrdersWithEth{value: 1 ether}(
            _BOARD, ids, amts, _mins(ids.length), outs, type(uint256).max, taker, false, false
        );
    }

    /// A skipped leg on the live board refunds as ETH and still delivers the rest.
    function test_liveTryFillSkipsAndRefunds() public {
        uint256 id1 = _makeOrder(1_000e6, 0.5 ether);
        uint256 unknown = ILiveBoard(_BOARD).nextOrderId() + 5_000; // never created

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (id1, unknown);
        uint256[] memory amts = new uint256[](2);
        (amts[0], amts[1]) = (0.5 ether, 1 ether);
        address[] memory outs = new address[](2);
        outs[0] = _USDC;
        outs[1] = address(0);

        uint256 before = taker.balance;
        vm.prank(taker);
        bool[] memory filled = batch.fillOrdersWithEth{value: 2 ether}(
            _BOARD, ids, amts, _mins(ids.length), outs, type(uint256).max, taker, true, true
        );

        assertTrue(filled[0], "live order filled");
        assertFalse(filled[1], "missing order skipped");
        assertEq(_bal(_USDC, taker), 1_000e6, "only the live lot delivered");
        assertEq(before - taker.balance, 0.5 ether, "only the filled leg was charged");
        assertEq(_bal(_WETH, taker), 0, "refund arrived as ETH, not WETH");
        assertEq(_bal(_WETH, address(batch)), 0, "helper retained no WETH");
    }
}
