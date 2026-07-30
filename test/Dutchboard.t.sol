// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {Swapbol} from "../src/forwarders/Swapbol.sol";

/// @notice Dutchboard: decaying, partially-fillable limit orders over an arbitrary pair.
///         The headline case is the one DutchAuction cannot express at all — "sell WETH,
///         be paid in USDC" — because there the payment asset is always native ETH.
contract DutchboardTest is Test {
    address constant ETH = address(0);
    address constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant _ROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;

    Dutchboard board;
    Swapbol swapbol;

    /// @dev ETH already at Dutchboard's fork address before any call; see the assertion
    ///      in testEthQuotePathRefundsOverpayment.
    uint256 boardEthAtDeploy;

    address maker = makeAddr("maker");
    address taker = makeAddr("taker");
    address third = makeAddr("third");

    uint128 constant LOT = 10 ether; // 10 WETH to sell
    uint256 constant ASK_HI = 44_000e6; // open at $4,400/ETH
    uint256 constant ASK_LO = 38_000e6; // floor at $3,800/ETH

    function setUp() public {
        board = new Dutchboard();
        swapbol = new Swapbol(address(this), address(new Dutchboard()), address(board));
        boardEthAtDeploy = address(board).balance;
        vm.label(address(board), "Dutchboard");
        vm.label(_USDC, "USDC");
        vm.label(_WETH, "WETH");

        // No WETH pre-funding: _listTakeProfit funds and approves its own lot, so the
        // maker's balance reflects only what listings have returned to them.
        deal(_USDC, taker, 1_000_000e6);
        deal(_USDC, third, 1_000_000e6);
        vm.deal(taker, 1_000 ether);
    }

    // ------------------------------------------------------------------ HELPERS

    function _approve(address token, address spender, uint256 amt) internal {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amt));
        require(ok, "approve failed");
    }

    function _bal(address token, address who) internal view returns (uint256) {
        if (token == ETH) return who.balance;
        (bool ok, bytes memory d) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return ok ? abi.decode(d, (uint256)) : 0;
    }

    /// The take-profit listing: sell WETH, get paid USDC, decaying toward market.
    /// @dev Funds and approves a fresh lot each time, so a test can list more than once.
    function _listTakeProfit() internal returns (uint256 id) {
        deal(_WETH, maker, _bal(_WETH, maker) + LOT);
        vm.startPrank(maker);
        _approve(_WETH, address(board), LOT);
        id = board.listERC20(_WETH, _USDC, LOT, ASK_HI, ASK_LO, 0, 1 hours);
        vm.stopPrank();
    }

    function _prorate(uint256 price, uint128 take) internal pure returns (uint256) {
        return (price * take + LOT - 1) / LOT;
    }

    // -------------------------------------------- THE PREVIOUSLY IMPOSSIBLE ORDER

    /// Sell 10 WETH for USDC, partially filled mid-decay. Inexpressible on DutchAuction.
    function testTakeProfitOrderPartiallyFilledInUSDC() public {
        uint256 id = _listTakeProfit();
        assertEq(_bal(_WETH, address(board)), LOT, "lot escrowed");

        skip(30 minutes);
        uint256 price = board.priceOf(id);
        assertApproxEqRel(price, 41_000e6, 1e15, "decay midpoint is $4,100/ETH");

        uint128 take = 4 ether;
        uint256 cost = board.costOf(id, take);
        assertApproxEqRel(cost, 16_400e6, 1e15, "4 ETH at $4,100");

        uint256 makerUsdcBefore = _bal(_USDC, maker);
        uint256 takerUsdcBefore = _bal(_USDC, taker);

        vm.startPrank(taker);
        _approve(_USDC, address(board), cost);
        board.fill(id, take, taker, cost);
        vm.stopPrank();

        assertEq(_bal(_WETH, taker), take, "taker got WETH");
        assertEq(_bal(_USDC, maker) - makerUsdcBefore, cost, "maker was paid in USDC");
        assertEq(takerUsdcBefore - _bal(_USDC, taker), cost, "taker paid exactly cost");

        Dutchboard.ListingView memory v = board.getListing(id);
        assertEq(v.quote, _USDC, "quote asset recorded");
        assertEq(v.initial, LOT, "initial preserved");
        assertEq(v.remaining, LOT - take, "remainder rests");
    }

    /// The invariant that justifies a separate contract rather than a decaying order
    /// book: unit price is a pure function of time, unaffected by fill history.
    function testUnitPriceIsPureFunctionOfTime() public {
        uint256 id = _listTakeProfit();
        uint128 take = 1 ether;

        skip(6 minutes);
        uint256 costEarly = board.costOf(id, take);
        vm.startPrank(taker);
        _approve(_USDC, address(board), type(uint256).max);
        board.fill(id, take, taker, costEarly);

        skip(30 minutes);
        uint256 costLate = board.costOf(id, take);
        board.fill(id, take, taker, costLate);
        vm.stopPrank();

        assertLt(costLate, costEarly, "same size costs less later");
        // Two fills in, cost still equals the schedule prorated off `initial`.
        assertEq(board.costOf(id, take), _prorate(board.priceOf(id), take), "priceOf x take / initial");
        assertEq(_bal(_WETH, taker), 2 * take, "both fills delivered");
    }

    /// `maxCost` is the taker's bound on the ERC20 path, where cost is pulled by
    /// transferFrom and cannot be capped by attaching an exact value.
    function testMaxCostBindsOnERC20Quote() public {
        uint256 id = _listTakeProfit();
        uint128 take = 1 ether;
        uint256 cost = board.costOf(id, take);

        vm.startPrank(taker);
        _approve(_USDC, address(board), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Dutchboard.CostExceeded.selector, cost, cost - 1));
        board.fill(id, take, taker, cost - 1);
        vm.stopPrank();
    }

    /// The schedule only decays, so a stale quote can only ever favour the taker.
    function testPriceOnlyImprovesForTaker() public {
        uint256 id = _listTakeProfit();
        uint128 take = 1 ether;
        uint256 quoted = board.costOf(id, take);

        skip(17 minutes);
        uint256 atExecution = board.costOf(id, take);
        assertLe(atExecution, quoted, "never moves against a pending taker");

        uint256 before = _bal(_USDC, taker);
        vm.startPrank(taker);
        _approve(_USDC, address(board), type(uint256).max);
        board.fill(id, take, taker, quoted); // bound at the stale, worse quote
        vm.stopPrank();
        assertEq(before - _bal(_USDC, taker), atExecution, "billed the improved price");
    }

    /// `to` is explicit, so a router or forwarder never takes custody of the lot.
    function testFillPaysNamedRecipient() public {
        uint256 id = _listTakeProfit();
        uint128 take = 2 ether;
        uint256 cost = board.costOf(id, take);

        vm.startPrank(taker);
        _approve(_USDC, address(board), cost);
        board.fill(id, take, third, cost);
        vm.stopPrank();

        assertEq(_bal(_WETH, third), take, "lot went to the named recipient");
        assertEq(_bal(_WETH, taker), 0, "payer received nothing");
    }

    function testFillRejectsZeroRecipient() public {
        uint256 id = _listTakeProfit();
        vm.startPrank(taker);
        _approve(_USDC, address(board), type(uint256).max);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill(id, 1 ether, address(0), type(uint256).max);
        vm.stopPrank();
    }

    /// ETH on an ERC20-quoted fill buys nothing, so it must not be accepted and left
    /// resting for the next caller to sweep.
    function testERC20QuoteRejectsValue() public {
        uint256 id = _listTakeProfit();
        vm.startPrank(taker);
        _approve(_USDC, address(board), type(uint256).max);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fill{value: 1 wei}(id, 1 ether, taker, type(uint256).max);
        vm.stopPrank();
    }

    // ----------------------------------------------------- ETH-QUOTE COMPATIBILITY

    /// quote == address(0) reproduces DutchAuction's behaviour, refund included.
    function testEthQuotePathRefundsOverpayment() public {
        deal(_USDC, maker, 100_000e6);
        vm.startPrank(maker);
        _approve(_USDC, address(board), 100_000e6);
        uint256 id = board.listERC20(_USDC, ETH, 100_000e6, 30 ether, 20 ether, 0, 1 hours);
        vm.stopPrank();

        skip(30 minutes);
        uint128 take = 25_000e6;
        uint256 cost = board.costOf(id, take);

        uint256 makerEthBefore = maker.balance;
        uint256 takerEthBefore = taker.balance;
        uint256 takerUsdcBefore = _bal(_USDC, taker); // seeded in setUp
        vm.prank(taker);
        board.fill{value: cost + 1 ether}(id, take, taker, type(uint256).max);

        assertEq(_bal(_USDC, taker) - takerUsdcBefore, take, "taker got USDC");
        assertEq(maker.balance - makerEthBefore, cost, "maker paid in ETH");
        assertEq(takerEthBefore - taker.balance, cost, "overpayment refunded");
        // The fork's CREATE address holds pre-existing mainnet ETH, so compare against
        // the opening balance. Unlike Swapbol, Dutchboard never sweeps `selfbalance()`:
        // it pays out `cost` and `msg.value - cost` only, so stray ETH is inert rather
        // than collectable by whoever fills next.
        assertEq(address(board).balance, boardEthAtDeploy, "board retained nothing from the fill");
    }

    function testEthQuoteRequiresSufficientValue() public {
        deal(_USDC, maker, 100_000e6);
        vm.startPrank(maker);
        _approve(_USDC, address(board), 100_000e6);
        uint256 id = board.listERC20(_USDC, ETH, 100_000e6, 30 ether, 20 ether, 0, 1 hours);
        vm.stopPrank();

        uint256 cost = board.costOf(id, 25_000e6);
        vm.prank(taker);
        vm.expectRevert(Dutchboard.Insufficient.selector);
        board.fill{value: cost - 1}(id, 25_000e6, taker, type(uint256).max);
    }

    // ------------------------------------------------------------------- LISTING

    /// The uint96 price ceiling must fail at listing, never silently truncate the ask.
    function testPriceAboveUint96Reverts() public {
        vm.startPrank(maker);
        _approve(_WETH, address(board), LOT);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(_WETH, _USDC, LOT, uint256(type(uint96).max) + 1, ASK_LO, 0, 1 hours);
        vm.stopPrank();
    }

    function testRejectsBadListings() public {
        vm.startPrank(maker);
        _approve(_WETH, address(board), LOT);
        // startPrice < endPrice
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(_WETH, _USDC, LOT, ASK_LO, ASK_HI, 0, 1 hours);
        // zero startPrice
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(_WETH, _USDC, LOT, 0, 0, 0, 1 hours);
        // zero duration
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(_WETH, _USDC, LOT, ASK_HI, ASK_LO, 0, 0);
        // token == quote
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(_WETH, _WETH, LOT, ASK_HI, ASK_LO, 0, 1 hours);
        // startTime in the past
        skip(100);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.listERC20(_WETH, _USDC, LOT, ASK_HI, ASK_LO, uint40(block.timestamp - 1), 1 hours);
        vm.stopPrank();
    }

    function testCancelReturnsRemainder() public {
        uint256 id = _listTakeProfit();
        uint128 take = 3 ether;
        uint256 cost = board.costOf(id, take);
        vm.startPrank(taker);
        _approve(_USDC, address(board), cost);
        board.fill(id, take, taker, cost);
        vm.stopPrank();

        vm.prank(maker);
        board.cancel(id);
        assertEq(_bal(_WETH, maker), LOT - take, "unsold remainder returned");
        assertEq(board.priceOf(id), 0, "listing closed");
        assertEq(_bal(_WETH, address(board)), 0, "no escrow left");
    }

    function testOnlySellerCancels() public {
        uint256 id = _listTakeProfit();
        vm.prank(taker);
        vm.expectRevert(Dutchboard.NotSeller.selector);
        board.cancel(id);
    }

    /// Proves the packing documented on the struct: `quote` is free because prices are
    /// uint96. slot1 = token | startPrice<<160, slot2 = quote | endPrice<<160.
    function testStoragePackingKeepsQuoteFree() public {
        uint256 id = _listTakeProfit();
        bytes32 base = keccak256(abi.encode(id, uint256(1))); // listings is slot 1

        uint256 slot1 = uint256(vm.load(address(board), bytes32(uint256(base) + 1)));
        assertEq(address(uint160(slot1)), _WETH, "slot1 low 160 is token");
        assertEq(slot1 >> 160, ASK_HI, "slot1 high 96 is startPrice");

        uint256 slot2 = uint256(vm.load(address(board), bytes32(uint256(base) + 2)));
        assertEq(address(uint160(slot2)), _USDC, "slot2 low 160 is quote");
        assertEq(slot2 >> 160, ASK_LO, "slot2 high 96 is endPrice");

        uint256 slot3 = uint256(vm.load(address(board), bytes32(uint256(base) + 3)));
        assertEq(uint128(slot3), LOT, "slot3 low 128 is initial");
        assertEq(slot3 >> 128, LOT, "slot3 high 128 is remaining");
    }

    // --------------------------------------------------------------- COMPOSITION

    /// The payoff: with an arbitrary quote asset, the LIVE router can now fill a
    /// take-profit order. USDC in, WETH out, through the existing Swapbol forwarder
    /// with no changes to it — `board` and the fill calldata are already parameters.
    /// Dutchboard's explicit `to` means the forwarder's sweeps are no-ops rather than
    /// the delivery path.
    function testFillTakeProfitOrderViaLiveRouter() public {
        uint256 id = _listTakeProfit();
        skip(30 minutes);

        uint128 take = 4 ether;
        uint256 cost = board.costOf(id, take);

        bytes memory boardCall = abi.encodeCall(Dutchboard.fill, (id, take, taker, cost));
        bytes memory executorData = abi.encodeCall(Swapbol.fill, (address(board), _USDC, _WETH, taker, taker, boardCall));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature(
            "snwap(address,uint256,address,address,uint256,address,bytes)",
            ETH,
            uint256(0),
            taker,
            ETH,
            uint256(0),
            address(swapbol),
            abi.encodeCall(Swapbol.checkpoint, (_USDC))
        );
        calls[1] = abi.encodeWithSignature(
            "snwap(address,uint256,address,address,uint256,address,bytes)",
            _USDC,
            cost,
            taker,
            _WETH,
            uint256(take),
            address(swapbol),
            executorData
        );

        vm.startPrank(taker);
        _approve(_USDC, _ROUTER, cost);
        (bool ok, bytes memory ret) = _ROUTER.call(abi.encodeWithSignature("multicall(bytes[])", calls));
        vm.stopPrank();
        require(ok, "snwap failed");

        bytes[] memory results = abi.decode(ret, (bytes[]));
        assertEq(abi.decode(results[1], (uint256)), take, "router measured WETH at the recipient");
        assertEq(_bal(_WETH, taker), take, "taker holds the lot");
        assertEq(_bal(_USDC, address(swapbol)), 0, "forwarder holds no USDC");
        assertEq(_bal(_WETH, address(swapbol)), 0, "forwarder holds no WETH");
        (bool k, bytes memory d) =
            _USDC.staticcall(abi.encodeWithSignature("allowance(address,address)", address(swapbol), address(board)));
        assertTrue(k);
        assertEq(abi.decode(d, (uint256)), 0, "forwarder left no approval");
    }

    // ------------------------------------------------------------------ FILLMANY

    function _u(uint256 a, uint256 b) internal pure returns (uint256[] memory o) {
        o = new uint256[](2);
        (o[0], o[1]) = (a, b);
    }

    function _t(uint128 a, uint128 b) internal pure returns (uint128[] memory o) {
        o = new uint128[](2);
        (o[0], o[1]) = (a, b);
    }

    /// Two ERC20-quoted legs in one call.
    function testFillManyERC20Quoted() public {
        uint256 id1 = _listTakeProfit();
        uint256 id2 = _listTakeProfit();
        skip(30 minutes);

        uint256 c1 = board.costOf(id1, 2 ether);
        uint256 c2 = board.costOf(id2, 3 ether);
        uint256 makerBefore = _bal(_USDC, maker);

        vm.startPrank(taker);
        _approve(_USDC, address(board), c1 + c2);
        uint256 ethSpent = board.fillMany(_u(id1, id2), _t(2 ether, 3 ether), _u(c1, c2), taker);
        vm.stopPrank();

        assertEq(ethSpent, 0, "no ETH on an all-ERC20 batch");
        assertEq(_bal(_WETH, taker), 5 ether, "both legs delivered");
        assertEq(_bal(_USDC, maker) - makerBefore, c1 + c2, "maker paid for both");
    }

    /// THE property: one msg.value cannot settle two ETH-quoted legs. Each leg is bounded
    /// by what remains UNSPENT, so a batch that only covers one must revert.
    function testFillManyCannotReuseValueAcrossEthLegs() public {
        uint256 id1 = _listEthQuoted();
        uint256 id2 = _listEthQuoted();
        skip(30 minutes);

        uint128 take = 25_000e6;
        uint256 c1 = board.costOf(id1, take);
        uint256 c2 = board.costOf(id2, take);

        // Enough for ONE leg only.
        vm.prank(taker);
        vm.expectRevert(Dutchboard.Insufficient.selector);
        board.fillMany{value: c1}(_u(id1, id2), _t(take, take), _u(c1, c2), taker);

        // Enough for both: settles, and the sum is charged exactly once each.
        uint256 makerBefore = maker.balance;
        uint256 takerBefore = taker.balance;
        vm.prank(taker);
        uint256 ethSpent = board.fillMany{value: c1 + c2}(_u(id1, id2), _t(take, take), _u(c1, c2), taker);

        assertEq(ethSpent, c1 + c2, "reported spend");
        assertEq(maker.balance - makerBefore, c1 + c2, "seller paid for both legs");
        assertEq(takerBefore - taker.balance, c1 + c2, "charged exactly the sum");
        assertEq(address(board).balance, boardEthAtDeploy, "board retained nothing");
    }

    /// Mixed quote assets in one batch, with the ETH excess refunded.
    function testFillManyMixedQuotesRefundsExcess() public {
        uint256 idUsdc = _listTakeProfit();
        uint256 idEth = _listEthQuoted();
        skip(30 minutes);

        uint256 cUsdc = board.costOf(idUsdc, 1 ether);
        uint256 cEth = board.costOf(idEth, 10_000e6);

        uint256 takerBefore = taker.balance;
        vm.startPrank(taker);
        _approve(_USDC, address(board), cUsdc);
        uint256 ethSpent =
            board.fillMany{value: cEth + 5 ether}(_u(idUsdc, idEth), _t(1 ether, 10_000e6), _u(cUsdc, cEth), taker);
        vm.stopPrank();

        assertEq(ethSpent, cEth, "only the ETH leg drew value");
        assertEq(takerBefore - taker.balance, cEth, "excess refunded");
        assertEq(address(board).balance, boardEthAtDeploy, "board retained nothing");
    }

    /// Per-leg bounds are honoured independently.
    function testFillManyRespectsPerLegMaxCost() public {
        uint256 id1 = _listTakeProfit();
        uint256 id2 = _listTakeProfit();
        skip(30 minutes);

        uint256 c1 = board.costOf(id1, 2 ether);
        uint256 c2 = board.costOf(id2, 3 ether);

        vm.startPrank(taker);
        _approve(_USDC, address(board), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Dutchboard.CostExceeded.selector, c2, c2 - 1));
        board.fillMany(_u(id1, id2), _t(2 ether, 3 ether), _u(c1, c2 - 1), taker);
        vm.stopPrank();
    }

    /// Atomic: a dead leg aborts the whole batch.
    function testFillManyIsAtomic() public {
        uint256 id1 = _listTakeProfit();
        uint256 id2 = _listTakeProfit();
        vm.prank(maker);
        board.cancel(id2);

        vm.startPrank(taker);
        _approve(_USDC, address(board), type(uint256).max);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fillMany(_u(id1, id2), _t(1 ether, 1 ether), _u(type(uint256).max, type(uint256).max), taker);
        vm.stopPrank();
        assertEq(_bal(_WETH, taker), 0, "nothing settled");
    }

    function testFillManyRejectsBadLengths() public {
        uint256 id1 = _listTakeProfit();
        uint128[] memory takes = new uint128[](1);
        takes[0] = 1 ether;
        vm.prank(taker);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fillMany(_u(id1, id1), takes, _u(0, 0), taker);

        vm.prank(taker);
        vm.expectRevert(Dutchboard.Bad.selector);
        board.fillMany(new uint256[](0), new uint128[](0), new uint256[](0), taker);
    }

    /// @dev An ETH-quoted lot: USDC sold for ETH.
    function _listEthQuoted() internal returns (uint256 id) {
        deal(_USDC, maker, _bal(_USDC, maker) + 100_000e6);
        vm.startPrank(maker);
        _approve(_USDC, address(board), 100_000e6);
        id = board.listERC20(_USDC, ETH, 100_000e6, 30 ether, 20 ether, 0, 1 hours);
        vm.stopPrank();
    }
}
