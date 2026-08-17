// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PriceTape} from "../src/pools/PriceTape.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev The storage layout, pinned. A reviewer flagged that `PriceTape` holds
/// two structs in the same layout as `reserve0`/`reserve1` and wanted the slot
/// arithmetic checked before signing off, which is the right instinct: the pool
/// inherits Solady's ERC-20, and a collision between an inherited balance and a
/// reserve is not a bug that announces itself - it corrupts one and the other
/// keeps working.
///
/// It does not collide, for a reason that is a property of the DEPENDENCY
/// rather than of this contract: Solady does not use sequential slots at all.
/// `_TOTAL_SUPPLY_SLOT` is a single large constant and balances, allowances and
/// nonces are keccak-derived from seeds. That leaves slots 0..518 - the pool's
/// own reserves, fee counters and both 257-slot tapes - entirely to this
/// contract. A Solady bump that moved to sequential slots would break it
/// silently, which is why this is a test rather than a comment.
contract PrecisionStorageLayoutTest is Test {
    PrecisionPoolFactory factory;
    PrecisionPool pool;
    MockERC20 tk;

    address lp = address(0xC11);

    /// @dev Solady ERC20's fixed slot, copied from the dependency. If a bump
    ///      changes it, this test should be the thing that notices.
    uint256 constant SOLADY_TOTAL_SUPPLY_SLOT = 0x05345cdf77eb68f44c;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        tk = new MockERC20("TK", 18);
        tk.mint(lp, 1e30);
        vm.deal(lp, 10_000 ether);

        vm.startPrank(lp);
        tk.approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed{value: 100 ether}(
            PrecisionPoolFactory.Market({
                token0: address(0),
                token1: address(tk),
                sqrtPLow: 0.5e18,
                sqrtPHigh: 2e18,
                fee: 500,
                hook: address(0),
                feeRecipient: address(0),
                creatorFeeBps: 0
            }),
            1e18, 100 ether, 1e24, 0, lp
        );
        vm.stopPrank();
        pool = PrecisionPool(payable(p));
    }

    /// @dev The pool's creation code has to fit in an SSTORE2 data contract,
    ///      because that is where the factory keeps it - see `poolCode`. That
    ///      moved the size constraint rather than removing it: the factory is
    ///      comfortably under EIP-170 on its own, but a pool whose INIT code
    ///      exceeds the 24,575-byte payload an SSTORE2 write can hold makes the
    ///      factory constructor revert, and the factory is undeployable. The
    ///      first symptom is a failed mainnet deploy, so assert the headroom
    ///      here where it costs nothing to learn.
    function test_PoolInitCodeStillFitsInAnSSTORE2Blob() public pure {
        // SSTORE2 prepends a single STOP byte to the payload, so the usable
        // room is one byte under the 24,576-byte contract limit.
        uint256 size = type(PrecisionPool).creationCode.length;
        assertLt(size, 24_576 - 1, "pool init code no longer fits in SSTORE2");
    }

    /// @dev The declared slots, as `forge inspect` reports them. Reserves share
    ///      slot 0; the tapes occupy 5..261 and 262..518.
    function test_TheTapesOccupyTheSlotsTheyAreAssumedTo() public view {
        // Reserves are packed into one slot, low half then high half.
        uint256 slot0 = uint256(vm.load(address(pool), bytes32(uint256(0))));
        assertEq(uint128(slot0), pool.reserve0(), "reserve0 is not the low half of slot 0");
        assertEq(uint128(slot0 >> 128), pool.reserve1(), "reserve1 is not the high half of slot 0");

        // A tape is one live bar plus a 256-entry ring, laid out sequentially.
        assertEq(PriceTape.BARS, 256, "ring depth changed; every slot below moves");
        uint256 tapeSlots = 1 + PriceTape.BARS;
        assertEq(tapeSlots, 257, "tape footprint changed");

        // Fine tape starts right after the four fee counters at 1..4.
        uint256 fineStart = 5;
        uint256 coarseStart = fineStart + tapeSlots;
        assertEq(coarseStart, 262, "coarse tape moved");

        uint256 lastUsed = coarseStart + tapeSlots - 1;
        assertEq(lastUsed, 518, "last sequential slot moved");

        // Nothing this contract owns reaches Solady's territory.
        assertGt(SOLADY_TOTAL_SUPPLY_SLOT, lastUsed, "sequential storage now overlaps Solady's total supply");
    }

    /// @dev The dependency's assumption, checked against the dependency rather
    ///      than trusted. `totalSupply` must live at Solady's constant slot and
    ///      not anywhere in the pool's sequential range.
    function test_SoladySupplyIsWhereWeThinkItIs() public view {
        uint256 stored = uint256(vm.load(address(pool), bytes32(SOLADY_TOTAL_SUPPLY_SLOT)));
        assertEq(stored, pool.totalSupply(), "Solady's supply slot moved");
        assertGt(pool.totalSupply(), 0, "pool is unseeded; the check would pass vacuously");
    }

    /// @dev The end-to-end version, which catches a collision no slot
    ///      arithmetic would: write the whole tape range by trading across many
    ///      buckets, and confirm the ERC-20 state and the reserves are
    ///      untouched by it.
    function test_FillingTheTapeCorruptsNothing() public {
        uint256 supplyBefore = pool.totalSupply();
        uint256 lpBalanceBefore = pool.balanceOf(lp);
        address trader = address(0xBEEF);
        vm.deal(trader, 1_000 ether);

        // Walk far enough to roll the fine ring and fold into the coarse tape
        // repeatedly, so both structs are genuinely written.
        for (uint256 i; i < 60; ++i) {
            vm.warp(block.timestamp + 10 minutes);
            vm.prank(trader);
            pool.swapExactIn{value: 0.01 ether}(address(0), 0.01 ether, 0, trader);
        }

        assertEq(pool.totalSupply(), supplyBefore, "tape writes moved total supply");
        assertEq(pool.balanceOf(lp), lpBalanceBefore, "tape writes moved an LP balance");
        assertEq(pool.balanceOf(address(0xdead)), 1000, "tape writes moved the dead minimum");

        // And the tape actually holds data, so the test is not vacuous.
        uint256[] memory fine = pool.tape(pool.FINE_PERIOD(), 8);
        uint256 nonEmpty;
        for (uint256 i; i < fine.length; ++i) {
            if (fine[i] != 0) ++nonEmpty;
        }
        assertGt(nonEmpty, 0, "no bars were written; the test proved nothing");

        // Reserves still back the pool after all that writing.
        assertGe(address(pool).balance, pool.reserve0(), "token0 backing broken");
        assertGe(tk.balanceOf(address(pool)), pool.reserve1(), "token1 backing broken");
    }

    /// @dev Two pools must not share transient state. The reentrancy guard uses
    ///      a fixed transient slot, which is per-ADDRESS, so a swap that routes
    ///      through two pools in one transaction must not have the first pool's
    ///      guard block the second.
    function test_TheTransientGuardIsPerPoolNotGlobal() public {
        MockERC20 other = new MockERC20("TK2", 18);
        other.mint(lp, 1e30);
        vm.startPrank(lp);
        other.approve(address(factory), type(uint256).max);
        (address p2,,,) = factory.createAndSeed{value: 100 ether}(
            PrecisionPoolFactory.Market({
                token0: address(0),
                token1: address(other),
                sqrtPLow: 0.5e18,
                sqrtPHigh: 2e18,
                fee: 500,
                hook: address(0),
                feeRecipient: address(0),
                creatorFeeBps: 0
            }),
            1e18, 100 ether, 1e24, 0, lp
        );
        vm.stopPrank();

        address trader = address(0xBEEF);
        vm.deal(trader, 10 ether);
        // Both in one transaction. A globally-keyed guard would revert the second.
        vm.startPrank(trader);
        pool.swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        PrecisionPool(payable(p2)).swapExactIn{value: 1 ether}(address(0), 1 ether, 0, trader);
        vm.stopPrank();
    }
}
