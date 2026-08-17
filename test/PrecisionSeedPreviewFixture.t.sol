// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionLiquidityLens} from "../src/pools/PrecisionLiquidityLens.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Half of a two-sided pin. zSwap.html's band-creation form cannot call
///      `previewSeed` at all - the pool it is about to create has no code, and
///      `_band` reverts `NoPool` on an address that does not exist - so the page
///      carries its own BigInt mirror of the seed. A mirror is only as good as
///      what holds it to the original, and neither side can be the reference for
///      the other: this suite asserts the LENS still produces
///      test/fixtures/seed-preview.json, and test/ui/liquidity.test.mjs asserts
///      the PAGE reproduces the same file. Change the seed math on either side
///      and exactly one of the two fails, which names the side that moved.
///
///      Regenerate with `forge script script/PrecisionSeedFixture.s.sol` - and
///      only after deciding that the lens, not the fixture, was wrong.
contract PrecisionSeedPreviewFixtureTest is Test {
    PrecisionPoolFactory factory;
    PrecisionLiquidityLens lens;
    MockERC20 t18;
    MockERC20 t6;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        lens = new PrecisionLiquidityLens(factory);
        t18 = new MockERC20("T18", 18);
        t6 = new MockERC20("T6", 6);
    }

    function test_LensStillMatchesTheSharedFixture() public {
        string memory j = vm.readFile("test/fixtures/seed-preview.json");
        uint256 n;
        for (uint256 i; i < 256; ++i) {
            if (!vm.keyExistsJson(j, string.concat("[", vm.toString(i), "].desc"))) break;
            _one(j, i);
            n = i + 1;
        }
        assertGt(n, 0, "empty fixture");
    }

    function _one(string memory j, uint256 i) internal {
        string memory at = string.concat("[", vm.toString(i), "].");
        string memory desc = vm.parseJsonString(j, string.concat(at, "desc"));
        PrecisionPoolFactory.Market memory m = PrecisionPoolFactory.Market({
            token0: address(0),
            token1: vm.parseJsonUint(j, string.concat(at, "dec1")) == 6 ? address(t6) : address(t18),
            sqrtPLow: _num(j, at, "sl"),
            sqrtPHigh: _num(j, at, "sh"),
            fee: 3000,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
        address pool = factory.poolFor(m);
        if (!factory.isPool(pool)) factory.createPool(m);

        (bool ok, uint256 lp, uint256 used0, uint256 used1) =
            lens.previewSeed(pool, _num(j, at, "s"), _num(j, at, "a0"), _num(j, at, "a1"));

        assertEq(ok, vm.parseJsonBool(j, string.concat(at, "ok")), string.concat("ok: ", desc));
        assertEq(lp, _num(j, at, "lp"), string.concat("lp: ", desc));
        assertEq(used0, _num(j, at, "used0"), string.concat("used0: ", desc));
        assertEq(used1, _num(j, at, "used1"), string.concat("used1: ", desc));
    }

    /// @dev Amounts are quoted decimal strings; a uint256 does not survive a
    /// JSON number.
    function _num(string memory j, string memory at, string memory key) internal view returns (uint256) {
        return vm.parseUint(vm.parseJsonString(j, string.concat(at, key)));
    }

    /// @dev The premise the mirror exists for, stated as a test rather than as
    /// a comment: the preview the page would rather call cannot be called.
    function test_PreviewSeedRevertsOnABandThatDoesNotExistYet() public {
        PrecisionPoolFactory.Market memory m = PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(t18),
            sqrtPLow: 0.5e18,
            sqrtPHigh: 2e18,
            fee: 3000,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
        address predicted = factory.poolFor(m);
        assertEq(predicted.code.length, 0, "already deployed");
        vm.expectRevert(PrecisionLiquidityLens.NoPool.selector);
        lens.previewSeed(predicted, 1e18, 100 ether, 100 ether);
    }
}
