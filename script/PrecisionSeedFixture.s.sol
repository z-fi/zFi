// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Script.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionLiquidityLens} from "../src/pools/PrecisionLiquidityLens.sol";
import {MockERC20} from "../test/SwapboardMocks.sol";

/// @notice Regenerates test/fixtures/seed-preview.json.
///
/// @dev The band-creation form in zSwap.html cannot call `previewSeed`: the
///      pool it is about to create has no code yet, and `_band` reverts
///      `NoPool` on an address that does not exist. So the page mirrors the
///      seed in BigInt, and this fixture is the contract between the two - the
///      lens is checked against it by test/PrecisionSeedPreviewFixture.t.sol,
///      the page by test/ui/liquidity.test.mjs. Neither can drift without the
///      other noticing, which a fixture written by only one side would allow.
///
///      Run: forge script script/PrecisionSeedFixture.s.sol --ffi
contract PrecisionSeedFixture is Script {
    PrecisionPoolFactory factory;
    PrecisionLiquidityLens lens;
    MockERC20 t18;
    MockERC20 t6;

    struct Case {
        string desc;
        address token1;
        uint256 sl;
        uint256 sh;
        uint256 s;
        uint256 a0;
        uint256 a1;
    }

    function run() external {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        lens = new PrecisionLiquidityLens(factory);
        t18 = new MockERC20("T18", 18);
        t6 = new MockERC20("T6", 6);

        Case[] memory cs = _cases();
        string memory out = "[";
        for (uint256 i; i < cs.length; ++i) {
            if (i != 0) out = string.concat(out, ",");
            out = string.concat(out, _row(cs[i]));
        }
        vm.writeFile("test/fixtures/seed-preview.json", string.concat(out, "\n]\n"));
    }

    function _cases() internal view returns (Case[] memory cs) {
        address a18 = address(t18);
        address a6 = address(t6);
        cs = new Case[](14);
        // A plain 1:1 band, seeded mid, low and high.
        cs[0] = Case("mid seed, both sides", a18, 0.5e18, 2e18, 1e18, 100 ether, 100 ether);
        cs[1] = Case("token0 only at the lower bound", a18, 0.5e18, 2e18, 0.5e18, 100 ether, 0);
        cs[2] = Case("token1 only at the upper bound", a18, 0.5e18, 2e18, 2e18, 0, 100 ether);
        // Lopsided amounts: one side binds and the other is refunded.
        cs[3] = Case("token1 binds, token0 refunded", a18, 0.5e18, 2e18, 1e18, 100 ether, 1 ether);
        cs[4] = Case("token0 binds, token1 refunded", a18, 0.5e18, 2e18, 1e18, 1 ether, 100 ether);
        // Too little to clear MIN_RESOLUTION / MIN_LIQUIDITY.
        cs[5] = Case("dust refused", a18, 0.5e18, 2e18, 1e18, 1000, 1000);
        cs[6] = Case("nothing at all", a18, 0.5e18, 2e18, 1e18, 0, 0);
        // A price outside its own band, which the lens refuses outright.
        cs[7] = Case("price below the band", a18, 0.5e18, 2e18, 0.4e18, 100 ether, 100 ether);
        cs[8] = Case("price above the band", a18, 0.5e18, 2e18, 2.1e18, 100 ether, 100 ether);
        // A wide band, the shape the "full range" option picks.
        cs[9] = Case("millionfold band", a18, 1e15, 1e21, 1e18, 100 ether, 100 ether);
        cs[10] = Case("tight band", a18, 0.99e18, 1.01e18, 1e18, 100 ether, 100 ether);
        // Mixed decimals: a raw sqrt price the way the page builds one for an
        // 18/6 pair around 3000, where sqrt(3000 * 1e-12) * 1e18 is ~5.4e13.
        cs[11] = Case("18/6 decimals around 3000", a6, 44721359549995, 63245553203367, 54772255750516, 100 ether, 300000e6);
        cs[12] = Case("18/6 decimals, token0 only", a6, 54772255750516, 63245553203367, 54772255750516, 10 ether, 0);
        cs[13] = Case("18/6 decimals, tiny token1", a6, 44721359549995, 63245553203367, 54772255750516, 100 ether, 1);
    }

    function _mkt(Case memory c) internal pure returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market(address(0), c.token1, c.sl, c.sh, 3000, address(0), address(0), 0);
    }

    function _row(Case memory c) internal returns (string memory) {
        address pool = factory.poolFor(_mkt(c));
        if (!factory.isPool(pool)) factory.createPool(_mkt(c));
        (bool ok, uint256 lp, uint256 used0, uint256 used1) = lens.previewSeed(pool, c.s, c.a0, c.a1);
        return string.concat(
            '\n  {"desc": "',
            c.desc,
            '", "dec1": ',
            vm.toString(uint256(MockERC20(c.token1).decimals())),
            ', "sl": "',
            vm.toString(c.sl),
            '", "sh": "',
            vm.toString(c.sh),
            '", "s": "',
            vm.toString(c.s),
            '", "a0": "',
            vm.toString(c.a0),
            '", "a1": "',
            vm.toString(c.a1),
            '", "ok": ',
            ok ? "true" : "false",
            ', "lp": "',
            vm.toString(lp),
            '", "used0": "',
            vm.toString(used0),
            '", "used1": "',
            vm.toString(used1),
            '"}'
        );
    }
}
