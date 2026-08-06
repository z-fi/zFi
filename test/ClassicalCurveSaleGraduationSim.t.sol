// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {ClassicalCurveSale, IZAMM, ZAMM, ERC20} from "../src/dao/ClassicalCurveSale.sol";

/// @notice End-to-end graduation of the launcher's exact preset, driven the way the
///         dapp actually drives it, against the live sale contract and live ZAMM.
///
///         The existing lifecycle test buys with buy() (exact-out). The dapp's trade
///         panel calls buyExactIn -- a different code path with its own approximation
///         and binary-search fallback. This walks a real crowd of buyers through
///         buyExactIn to graduation, then checks the property that actually matters
///         to a holder at that moment: the price does not jump when trading moves
///         from the curve to the pool.
contract ClassicalCurveSaleGraduationSimTest is Test {
    ClassicalCurveSale constant SALE = ClassicalCurveSale(payable(0x000000005d9b18764E12E5aeefD6dA73110F85eb));

    // dapp/modules/coin.js launch() template, verbatim.
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CAP = 800_000_000e18;
    uint256 constant START_PRICE = 1_666_666_667;
    uint256 constant END_PRICE = 26_666_666_672;
    uint256 constant LP_TOKENS = 200_000_000e18;
    uint16 constant FEE_BPS = 100;
    uint16 constant POOL_FEE_BPS = 25;
    uint16 constant SNIPER_FEE_BPS = 500;
    uint16 constant SNIPER_DURATION = 300;
    uint16 constant MAX_BUY_BPS = 1000;

    address creator = makeAddr("creator");
    uint256 baseETH;

    function setUp() public {
        vm.createSelectFork(vm.envOr("FOUNDRY_ETH_RPC_URL", string("https://mainnet.gateway.tenderly.co")));
        vm.etch(creator, "");
        vm.deal(creator, 10 ether);
        baseETH = address(SALE).balance;
    }

    function _launchPreset() internal returns (address token) {
        vm.prank(creator);
        token = SALE.launch(
            creator,
            "Graduation Sim",
            "GRAD",
            "ipfs://preset",
            SUPPLY,
            bytes32(uint256(0xC0FFEE)),
            CAP,
            START_PRICE,
            END_PRICE,
            FEE_BPS,
            0, // graduationTarget: full cap sale
            LP_TOKENS,
            address(0), // burn LP
            POOL_FEE_BPS,
            SNIPER_FEE_BPS,
            SNIPER_DURATION,
            MAX_BUY_BPS,
            ClassicalCurveSale.CreatorFee(creator, 5, 5, true, false),
            0,
            0
        );
    }

    /// Marginal price on the curve: P(x) = P0 * T0^2 / (T0 - x)^2, 1e18 scaled.
    function _curveSpot(address token) internal view returns (uint256) {
        (,, uint256 sold, uint256 vr, uint256 sp,,,,,,,,,,,,,) = SALE.curves(token);
        uint256 rem = vr - sold;
        return (sp * vr * vr) / (rem * rem);
    }

    function test_preset_graduationViaBuyExactIn() public {
        address token = _launchPreset();
        uint256 creatorStart = creator.balance;

        // A crowd trades in through the sniper window and out the other side, using
        // the same entry point as the dapp's Buy button.
        uint256 buyers;
        uint256 ethIn;

        // Step the clock across the sniper window first, in the same 30s ticks a real
        // launch would see, so the decayed fee is exercised rather than a single
        // timestamp. Deadlines are absolute here: a relative one recomputed inside a
        // warping loop is its own moving target and has nothing to do with the curve.
        uint256 deadline = type(uint256).max;
        for (uint256 k; k < 12; ++k) {
            vm.warp(block.timestamp + 30);
            address early = address(uint160(0x4000 + k));
            vm.deal(early, 200 ether);
            uint256 earlyBefore = early.balance;
            vm.prank(early);
            SALE.buyExactIn{value: 0.3 ether}(token, 0, deadline);
            ethIn += earlyBefore - early.balance;
            ++buyers;
        }

        // Then run the crowd to graduation.
        for (uint256 i; i < 2000; ++i) {
            (,,,,,,,,,,,, bool grad,,,,,) = SALE.curves(token);
            if (grad) break;

            address buyer = address(uint160(0x5000 + i));
            vm.deal(buyer, 200 ether);
            uint256 send = 0.25 ether + (i % 7) * 0.05 ether; // uneven, realistic sizes
            uint256 before = buyer.balance;
            vm.prank(buyer);
            try SALE.buyExactIn{value: send}(token, 0, deadline) {
                ++buyers;
                ethIn += before - buyer.balance; // net of the contract's own refund
            } catch {
                break;
            }
        }

        (, uint256 cap, uint256 sold,,,,,, uint256 raised,,,, bool graduated, bool seeded,,,,) = SALE.curves(token);
        emit log_named_uint("buyers", buyers);
        emit log_named_decimal_uint("raised ETH", raised, 18);
        assertTrue(graduated, "curve graduated through buyExactIn");
        assertFalse(seeded, "not seeded until graduate()");
        assertEq(sold, cap, "full cap sold");

        // Price on the last tick of the curve, before any pool exists.
        uint256 curveFinal = _curveSpot(token);
        assertApproxEqRel(curveFinal, END_PRICE, 1e15, "curve ends at the preset end price");

        // Anyone can seed. Use a fresh address to prove it needs no privilege.
        address randomer = address(uint160(0x9999));
        vm.deal(randomer, 1 ether);
        vm.prank(randomer);
        uint256 liq = SALE.graduate(token);
        assertGt(liq, 0, "LP minted");

        (IZAMM.PoolKey memory key, uint256 poolId) = SALE.poolKeyOf(token);

        // ── the handoff property ──
        // Pool spot must match the curve's final price, or the first pool trade
        // reprices everyone who bought on the curve.
        (uint256 r0, uint256 r1) = _reserves(poolId);
        assertGt(r0, 0, "pool has ETH");
        assertGt(r1, 0, "pool has tokens");
        uint256 poolSpot = (r0 * 1e18) / r1;
        emit log_named_uint("curve final price", curveFinal);
        emit log_named_uint("pool spot  price", poolSpot);
        assertApproxEqRel(poolSpot, curveFinal, 1e15, "no price discontinuity at graduation");

        // Supply after graduation: 800M circulating, 200M in the pool, nothing else.
        assertEq(ERC20(token).balanceOf(address(SALE)), 0, "sale holds nothing");
        assertEq(ERC20(token).balanceOf(address(ZAMM)), r1, "pool holds the LP side");
        assertApproxEqRel(r1, LP_TOKENS, 1e15, "~200M seeded");

        // LP is burned, so the liquidity cannot be pulled.
        assertEq(_zammBal(address(0xdead), poolId), liq, "all LP burned");
        assertEq(_zammBal(creator, poolId), 0, "creator holds no LP");

        // The curve's ETH went into the pool, not to the creator. The creator's take
        // is the 1% trading fee stream only.
        assertApproxEqRel(r0, raised, 1e15, "raised ETH seeded as liquidity");
        uint256 creatorTake = creator.balance - creatorStart;
        emit log_named_decimal_uint("creator fees", creatorTake, 18);
        assertLt(creatorTake, raised / 3, "creator take is fees, not the raise");

        // Conservation: every wei the buyers parted with is either liquidity in the
        // pool or a fee the creator earned. Nothing evaporates and nothing is stranded.
        emit log_named_decimal_uint("buyers paid", ethIn, 18);
        assertApproxEqRel(ethIn, raised + creatorTake, 1e15, "buyer outlay = pool liquidity + creator fees");

        // No other curve's escrow was touched anywhere in this.
        assertEq(address(SALE).balance, baseETH, "shared ETH escrow untouched");

        // ── the pool is live and trades at the handoff price ──
        address trader = address(uint160(0xA1CE));
        vm.deal(trader, 10 ether);
        vm.prank(trader);
        uint256 out = SALE.swapExactIn{value: 0.1 ether}(key, 0.1 ether, 0, true, trader, block.timestamp + 1);
        assertGt(out, 0, "routed buy works post-graduation");
        uint256 execPrice = (0.1 ether * 1e18) / out;
        // Within fees + slippage of the handoff price, not a different regime.
        assertApproxEqRel(execPrice, poolSpot, 5e16, "first pool trade executes near the curve's last price");

        // And a holder from the curve can still sell into the pool.
        address seller = address(uint160(0x5000));
        uint256 bal = ERC20(token).balanceOf(seller);
        assertGt(bal, 0, "first buyer still holds tokens");
        uint256 ethBefore = seller.balance;
        vm.prank(seller);
        SALE.swapExactIn(key, bal, 0, false, seller, block.timestamp + 1);
        assertGt(seller.balance, ethBefore, "curve buyer can exit into the pool");

        assertEq(address(SALE).balance, baseETH, "escrow still untouched after pool trades");
    }

    function _reserves(uint256 poolId) internal view returns (uint256 r0, uint256 r1) {
        (bool ok, bytes memory ret) = address(ZAMM).staticcall(abi.encodeWithSignature("pools(uint256)", poolId));
        require(ok && ret.length >= 64, "pools() read failed");
        (r0, r1) = abi.decode(ret, (uint112, uint112)) ;
    }

    function _zammBal(address who, uint256 id) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) =
            address(ZAMM).staticcall(abi.encodeWithSignature("balanceOf(address,uint256)", who, id));
        if (ok && ret.length >= 32) bal = abi.decode(ret, (uint256));
    }
}
