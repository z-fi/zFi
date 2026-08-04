// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {PriceTape} from "../src/pools/PriceTape.sol";

/// @dev Writes test/fixtures/tape.json: real packed bars from the Solidity
///      encoder, with the values they must decode back to. The dapp clients are
///      checked against this by script/check-zSwap.mjs, so a codec change in
///      either language fails the build instead of silently mispricing a chart.
///
///      Run with: forge test --match-path test/TapeFixture.t.sol --ffi
///      (or just read the emitted JSON from -vv output and paste it).
contract TapeFixtureTest is Test {
    using PriceTape for PriceTape.Tape;

    PriceTape.Tape internal tape;

    function test_WriteFixture() public {
        uint256 t = 1_700_000_000;
        vm.warp(t);

        // Prices spanning the range a real pair reaches, so an encoder that
        // drops the exponent cannot pass by accident.
        uint256[5] memory prices =
            [uint256(3_120_000_000), 1e18, 96_500_000_000_000, 846_000_000_000_000_000, 1_234_567];
        uint256[5] memory vols = [uint256(1e18), 25e18, 3e8, 7e17, 5e6];

        string memory rows = "";
        for (uint256 i; i < prices.length; ++i) {
            tape.print(prices[i], vols[i], 300);
            uint256 bar = tape.live;
            (uint32 b, uint256 o, uint256 h, uint256 l, uint256 c, uint256 v, uint16 n) =
                PriceTape.decode(bar);
            rows = string.concat(
                rows,
                i == 0 ? "" : ",",
                '{"word":"',
                vm.toString(bar),
                '","bucket":',
                vm.toString(uint256(b)),
                ',"open":',
                vm.toString(o),
                ',"high":',
                vm.toString(h),
                ',"low":',
                vm.toString(l),
                ',"close":',
                vm.toString(c),
                ',"volume":',
                vm.toString(v),
                ',"count":',
                vm.toString(uint256(n)),
                "}"
            );
            t += 300;
            vm.warp(t);
        }
        // Emitted rather than written: the repo restricts test filesystem
        // writes. script/capture-tape-fixture.sh pipes this into the fixture.
        emit log_string(string.concat('{"period":300,"bars":[', rows, "]}"));
    }
}
