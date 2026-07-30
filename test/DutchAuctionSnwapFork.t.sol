// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {DutchAuction} from "../src/DutchAuction.sol";
import {Swapbol} from "../src/forwarders/Swapbol.sol";

/// @notice Proves that a decaying, partially-fillable limit order composes with the
///         LIVE zRouter today, with no new contract and no allowlisting:
///
///           zRouter.snwap --> SafeExecutor --> Swapbol --> DutchAuction.fill
///
///         `snwap` does not gate its `executor` against `_isTrustedForCall` (only
///         `execute` does), so Swapbol needs no trust grant. And because Swapbol
///         takes `board` and the fill calldata as parameters, it forwards to
///         DutchAuction exactly as readily as to Swapboard.
///
///         What each side contributes:
///           - DutchAuction supplies the decay and the partial fill, and prices
///             every fill off `initial` rather than `remaining`, so unit price is a
///             pure function of time and is unaffected by fill history.
///           - Swapbol supplies the recipient indirection DutchAuction.fill lacks
///             (it pays msg.sender) and sweeps the ETH overpayment refund.
///           - snwap supplies the amountOutMin that DutchAuction.fill lacks.
///
///         DutchAuction and Swapbol are deployed fresh here; only zRouter and
///         zQuoter are the live mainnet contracts under test.
contract DutchAuctionSnwapForkTest is Test {
    address constant ETH = address(0);
    address constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant _ROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant _QUOTER = 0x0000002d9a651b729e3aFBE57Fc84FFDa4a98a13;

    DutchAuction auction;
    Swapbol swapbol;

    /// @dev ETH already sitting at Swapbol's address before any call. The
    ///      forwarder snapshots that baseline and never attributes it to a later
    ///      caller; only ETH created by the active call is refundable.
    uint256 dust;

    address maker = makeAddr("maker");
    address taker = makeAddr("taker");

    /// Lot: 100k USDC, sold for ETH.
    uint128 constant LOT = 100_000e6;

    function setUp() public {
        auction = new DutchAuction();
        swapbol = new Swapbol(address(this), address(new DutchAuction()), address(auction));
        vm.label(address(auction), "DutchAuction");
        vm.label(address(swapbol), "Swapbol");
        vm.label(_ROUTER, "zRouter");
        dust = address(swapbol).balance;

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

    /// @dev The composed call. `value` is what the taker sends; anything above the
    ///      auction's cost comes back to `recipient` via Swapbol's delta sweep.
    function _fillViaRouter(uint256 id, uint128 take, uint256 amountOutMin, uint256 value, address recipient)
        internal
        returns (uint256 amountOut)
    {
        bytes memory boardCall = abi.encodeCall(DutchAuction.fill, (id, take));
        bytes memory executorData = abi.encodeCall(Swapbol.fill, (address(auction), ETH, _USDC, recipient, recipient, boardCall));
        bytes memory snwap = abi.encodeWithSignature(
            "snwap(address,uint256,address,address,uint256,address,bytes)",
            ETH,
            uint256(0),
            recipient,
            _USDC,
            amountOutMin,
            address(swapbol),
            executorData
        );
        (bool ok, bytes memory ret) = _ROUTER.call{value: value}(snwap);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        amountOut = abi.decode(ret, (uint256));
    }

    /// @dev Funds and approves a fresh lot each time, so a test can list more than once.
    function _list(uint128 startPrice, uint128 endPrice, uint40 duration) internal returns (uint256 id) {
        deal(_USDC, maker, _bal(_USDC, maker) + LOT);
        vm.startPrank(maker);
        _approve(_USDC, address(auction), LOT);
        id = auction.listERC20(_USDC, LOT, startPrice, endPrice, 0, duration);
        vm.stopPrank();
    }

    /// @dev No route-owned funds or approvals may remain. Counterfactual /
    ///      pre-existing ETH is deliberately left at its baseline.
    function _assertSwapbolClean() internal view {
        assertEq(_bal(_USDC, address(swapbol)), 0, "swapbol holds USDC");
        assertEq(address(swapbol).balance, dust, "swapbol changed forced-ETH baseline");
        (bool ok, bytes memory d) =
            _USDC.staticcall(abi.encodeWithSignature("allowance(address,address)", address(swapbol), address(auction)));
        assertTrue(ok);
        assertEq(abi.decode(d, (uint256)), 0, "swapbol left an approval");
    }

    // -------------------------------------------------------------------- TESTS

    /// Baseline: a mid-decay partial fill routed through the live router.
    function testForkPartialFillViaSnwap() public {
        uint256 id = _list(30 ether, 20 ether, 1 hours);

        // Halfway through the decay: price is ~25 ETH for the whole lot.
        skip(30 minutes);
        uint256 price = auction.priceOf(id);
        assertApproxEqRel(price, 25 ether, 1e15, "decay midpoint");

        uint128 take = LOT / 4; // buy 25k USDC of the 100k lot
        uint256 cost = auction.costOf(id, take);
        assertApproxEqRel(cost, price / 4, 1e15, "cost prorates from initial");

        uint256 takerEthBefore = taker.balance;
        uint256 makerEthBefore = maker.balance;

        // Overpay deliberately: the refund must reach the taker, not rest in Swapbol.
        vm.prank(taker);
        uint256 out = _fillViaRouter(id, take, take, cost + 1 ether, taker);

        assertEq(out, take, "snwap measured the delta at the recipient");
        assertEq(_bal(_USDC, taker), take, "taker received USDC");
        assertEq(maker.balance - makerEthBefore, cost, "maker was paid exactly cost");
        assertEq(takerEthBefore - taker.balance, cost, "overpayment refunded to taker");
        _assertSwapbolClean();

        // The lot is still live for the remainder, and still decaying.
        DutchAuction.AuctionView memory v = auction.getAuction(id);
        assertEq(v.initial, LOT, "initial is preserved");
        assertEq(v.remaining, LOT - take, "remainder rests");
    }

    /// The core property: successive partial fills price off `initial`, so the unit
    /// price falls monotonically with time and never depends on how much was already
    /// taken. This is what makes decay + partial fill safe, and it is the reason this
    /// belongs in DutchAuction rather than in Swapboard's destructively-decremented
    /// amountA/amountB.
    function testForkUnitPriceFallsAndIgnoresFillHistory() public {
        uint256 id = _list(30 ether, 20 ether, 1 hours);
        uint128 take = LOT / 10;

        skip(6 minutes);
        vm.prank(taker);
        uint256 costEarly = auction.costOf(id, take);
        _fillViaRouter(id, take, take, costEarly, taker);
        _assertSwapbolClean();

        skip(30 minutes);
        uint256 costLate = auction.costOf(id, take);
        vm.prank(taker);
        _fillViaRouter(id, take, take, costLate, taker);
        _assertSwapbolClean();

        assertLt(costLate, costEarly, "same size costs less later");
        assertEq(_bal(_USDC, taker), 2 * take, "both fills delivered");

        // Unit price for an identical take is the schedule alone: the second fill's
        // cost equals what a fresh, never-filled lot would charge at the same instant.
        uint256 id2 = _list(30 ether, 20 ether, 1 hours);
        // id2 started 36 minutes later, so compare the pure function instead.
        assertEq(auction.costOf(id, take), _prorate(auction.priceOf(id), take), "cost is priceOf x take / initial");
        assertGt(auction.priceOf(id2), auction.priceOf(id), "fresh lot sits earlier on its own schedule");
    }

    function _prorate(uint256 price, uint128 take) internal pure returns (uint256) {
        return (price * take + LOT - 1) / LOT;
    }

    /// DutchAuction.fill takes no min-out and no max-price. snwap supplies the
    /// missing guard, measured at the recipient.
    function testForkSnwapMinOutGuardsTheFill() public {
        uint256 id = _list(30 ether, 20 ether, 1 hours);
        skip(30 minutes);

        uint128 take = LOT / 4;
        uint256 cost = auction.costOf(id, take);

        vm.prank(taker);
        vm.expectRevert(); // SnwapSlippage
        _fillViaRouter(id, take, uint256(take) + 1, cost, taker);
    }

    /// A pending fill can never be filled worse than quoted: the schedule is
    /// monotone non-increasing and reads no pool state, so no filler and no
    /// pool-displacing attacker can move the price against the taker.
    function testForkPriceOnlyImprovesForTaker() public {
        uint256 id = _list(30 ether, 20 ether, 1 hours);
        uint128 take = LOT / 4;

        uint256 quoted = auction.costOf(id, take);
        skip(17 minutes); // the taker's tx sits in the mempool
        uint256 atExecution = auction.costOf(id, take);
        assertLe(atExecution, quoted, "price never moves against a pending taker");

        vm.prank(taker);
        uint256 before = taker.balance;
        _fillViaRouter(id, take, take, quoted, taker);
        assertEq(before - taker.balance, atExecution, "billed the improved price, difference refunded");
        _assertSwapbolClean();
    }

    /// The listing-time anchor: derive startPrice/endPrice from a live zQuoter
    /// quote for the LOT SIZE, so the decay brackets the price the maker would
    /// actually realise dumping this much into the AMMs — then fill at the moment
    /// the schedule crosses that market price.
    ///
    /// The anchor is computed here, off-chain, at listing time. It must NOT be read
    /// inside `fill`: zQuoter reports live pool state, so a fill-time anchor would
    /// let a filler displace the pool, buy the whole lot at the depressed quote,
    /// and restore it.
    /// @dev zQuoter 0x0000002d… was deployed between blocks 25,630,000 and 25,640,000,
    ///      well after this suite's pin, so this case forks forward and rebuilds its
    ///      fixtures there. That block is also past 25,623,201, where Uniswap's V4
    ///      protocol fees broke the base quoter — so this exercises the repointed
    ///      quoter's corrected path, not the bricked one.
    function testForkListingAnchorFromQuoter() public {
        vm.createSelectFork(
            vm.envOr("FOUNDRY_ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_640_000
        );
        require(_QUOTER.code.length != 0, "zQuoter missing at anchor block");
        auction = new DutchAuction();
        swapbol = new Swapbol(address(this), address(new DutchAuction()), address(auction));
        dust = address(swapbol).balance;
        vm.deal(taker, 1_000 ether);

        (uint128 startPrice, uint128 endPrice, uint256 market) = _anchoredPrices(LOT, 500, 300);
        assertGt(startPrice, market, "start sits above market");
        assertLt(endPrice, market, "floor sits below market");

        uint40 duration = 20 minutes;
        uint256 id = _list(startPrice, endPrice, duration);

        assertEq(auction.priceOf(id), startPrice, "opens at the premium");

        // Walk the schedule until it crosses the anchored market price, then fill.
        uint256 crossed;
        for (uint256 i; i < 20; ++i) {
            skip(1 minutes);
            if (auction.priceOf(id) <= market) {
                crossed = i + 1;
                break;
            }
        }
        assertGt(crossed, 0, "schedule crossed market inside its duration");
        assertLt(crossed, 20, "and crossed before the floor");

        uint128 take = LOT / 2;
        uint256 cost = auction.costOf(id, take);
        vm.prank(taker);
        uint256 out = _fillViaRouter(id, take, take, cost, taker);

        assertEq(out, take, "filled at the market crossing");
        // At the crossing the maker realises about what the AMM would have paid,
        // and any fill before the crossing beat it outright.
        assertLe(cost, _prorate(market, take), "maker did no worse than the AMM reference");
        _assertSwapbolClean();
    }

    /// @dev The helper a maker's UI would call. `premBps` above market to open,
    ///      `floorBps` below market to stop. Size-aware: getQuotes takes the swap
    ///      amount, so `market` already includes the AMM slippage of a lot this big
    ///      — the correct reference for a lot-sized order, not a marginal tick.
    function _anchoredPrices(uint128 lot, uint256 premBps, uint256 floorBps)
        internal
        view
        returns (uint128 startPrice, uint128 endPrice, uint256 market)
    {
        (QuoteView memory best,) = IQuoter(_QUOTER).getQuotes(false, _USDC, ETH, lot);
        market = best.amountOut;
        require(market != 0, "no quote");
        startPrice = uint128(market * (10_000 + premBps) / 10_000);
        endPrice = uint128(market * (10_000 - floorBps) / 10_000);
    }
}

struct QuoteView {
    uint8 source;
    uint256 feeBps;
    uint256 amountIn;
    uint256 amountOut;
}

interface IQuoter {
    function getQuotes(bool exactOut, address tokenIn, address tokenOut, uint256 swapAmount)
        external
        view
        returns (QuoteView memory best, QuoteView[] memory quotes);
}
