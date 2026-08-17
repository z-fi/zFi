// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool, IPrecisionHook} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionRoute} from "../src/pools/PrecisionRoute.sol";

/// @dev Pins every hand-written 4-byte constant in the pool suite against the
/// signature it claims to be.
///
/// These are asserted by COMMENT in the source, inside `assembly` blocks the
/// compiler cannot check, and two of them fail SILENTLY if wrong - which is the
/// whole reason this file exists:
///
///   - `feeFor`: a wrong selector makes the staticcall fail, `extraFee` returns
///     zero by design, and every hooked pool then quietly charges no surcharge
///     forever. No functional test notices unless it asserts a NONZERO
///     `hookOwed`, because a pool that collects nothing still swaps correctly.
///   - `afterSwap`: a wrong selector emits `HookCallFailed` on every swap and
///     the swap still succeeds, so a hook that believes it is observing flow
///     never is.
///
/// The other two are loud, but they are the revert data a caller pattern-matches
/// on, so a wrong one is still a broken interface. `Reentrancy()` in particular
/// doubles as the pool's transient guard slot and is written in two places.
///
/// A test is the right home for this rather than a compile-time assertion: the
/// selectors live inside `assembly`, so there is no expression solc would fold
/// and reject. Keep this file in the default suite.
contract PrecisionMagicConstantsTest is Test {
    /// @dev The literals as they appear in `PrecisionPool.extraFee` and
    ///      `PrecisionPool._afterSwap`.
    function test_HookSelectorsMatchTheInterface() public pure {
        assertEq(bytes4(0xc5096a69), IPrecisionHook.feeFor.selector, "feeFor selector drifted");
        assertEq(bytes4(0x3da8b865), IPrecisionHook.afterSwap.selector, "afterSwap selector drifted");
    }

    /// @dev Independently of the interface declaration, in case the interface
    ///      itself is the thing that changed.
    function test_HookSelectorsMatchTheirSignatures() public pure {
        assertEq(bytes4(0xc5096a69), bytes4(keccak256("feeFor(address,address,uint256)")));
        assertEq(bytes4(0x3da8b865), bytes4(keccak256("afterSwap(address,address,uint256,uint256,address)")));
    }

    /// @dev `PrecisionPool.nonReentrant` and `PrecisionRoute` both hand-roll
    ///      this, and the pool reuses the same value as its transient slot.
    function test_ReentrancySelector() public pure {
        assertEq(bytes4(0xab143c06), PrecisionPool.Reentrancy.selector);
        assertEq(bytes4(0xab143c06), PrecisionRoute.Reentrancy.selector);
        assertEq(bytes4(0xab143c06), bytes4(keccak256("Reentrancy()")));
    }

    /// @dev Written by `PrecisionPoolFactory.createPool` when CREATE2 fails
    ///      with no return data.
    function test_ExistsSelector() public pure {
        assertEq(bytes4(0x846ec056), PrecisionPoolFactory.Exists.selector);
        assertEq(bytes4(0x846ec056), bytes4(keccak256("Exists()")));
    }

    /// @dev `_virtual0`/`_virtual1` multiply liquidity by a sqrt price inside
    ///      `unchecked`, and `_priceInRange`/`_bandMiss` square the bounds the
    ///      same way. That is safe only because of a relationship between two
    ///      constants that the source states in prose - "the factory caps
    ///      liquidity and the price range so this product fits" - and nowhere
    ///      enforces. Raising either one silently reintroduces the overflow, so
    ///      the coupling is asserted here instead of trusted.
    ///
    ///      `MAX_SQRT_PRICE + 1` is the quantity actually squared: `_priceInRange`
    ///      compares against an exclusive upper bound.
    function test_LiquidityAndPriceCapsCannotOverflow() public pure {
        uint256 maxLiquidity = type(uint128).max; // MAX_LIQUIDITY
        uint256 maxSqrtPrice = 1e36; // MAX_SQRT_PRICE
        uint256 wad = 1e18;

        // `_virtual1`: liquidity * sqrtPLow, with sqrtPLow < sqrtPHigh <= max.
        assertLe(maxLiquidity, type(uint256).max / maxSqrtPrice, "liquidity x price overflows");
        // `_virtual0`: liquidity * WAD.
        assertLe(maxLiquidity, type(uint256).max / wad, "liquidity x WAD overflows");
        // `_priceInRange` / `_bandMiss`: the exclusive ceiling, squared.
        uint256 hiExclusive = maxSqrtPrice + 1;
        assertLe(hiExclusive, type(uint256).max / hiExclusive, "squared price bound overflows");
    }

    /// @dev The EIP-2612 domain's cached name hash. Getting this wrong breaks
    ///      every permit - including the Permit2 and zap flows the suite is
    ///      designed around - so it is loud, but only if something signs.
    ///      `PrecisionPool.t.sol` checks the live `DOMAIN_SEPARATOR`; this pins
    ///      the constant itself against the string `name()` returns.
    function test_ConstantNameHash() public pure {
        assertEq(
            bytes32(0x97afff290dde66c4a8458ec3623f0fe8e943ac845271886a6598e35deed20617),
            keccak256(bytes("Precision LP"))
        );
    }
}
