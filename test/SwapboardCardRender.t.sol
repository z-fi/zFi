// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PositionSVG} from "../src/utils/PositionSVG.sol";

/// The card's number formatting, at the edges that actually reach it: an
/// emptied leg on a settled order, a token with no `decimals()`, a 256-bit
/// token id, and denominations at both ends of the supported range.
contract SwapboardCardRenderTest is Test {
    /// `snapshot` is `decimals + 1`, so 19 is an 18-decimals token.
    uint8 constant DEC18 = 19;
    uint8 constant RAW = 0;

    function test_ZeroIsZeroAtEveryScale() public pure {
        assertEq(PositionSVG.amount(0, DEC18, false), "0");
        assertEq(PositionSVG.amount(0, RAW, false), "0");
        assertEq(PositionSVG.amount(0, 7, false), "0");
    }

    function test_OrdinaryDenominations() public pure {
        assertEq(PositionSVG.amount(1e18, DEC18, false), "1");
        assertEq(PositionSVG.amount(1.5e18, DEC18, false), "1.5");
        assertEq(PositionSVG.amount(100e18, DEC18, false), "100");
        assertEq(PositionSVG.amount(1_000_000e6, 7, false), "1000000");
        assertEq(PositionSVG.amount(1, DEC18, false), "1e-18");
        assertEq(PositionSVG.amount(15, DEC18, false), "1.5e-17");
    }

    /// Nothing may run off the edge of the card, whatever the token.
    function test_NothingExceedsTheSlot() public pure {
        assertLe(bytes(PositionSVG.amount(type(uint256).max, RAW, false)).length, 18);
        assertLe(bytes(PositionSVG.amount(type(uint256).max, DEC18, false)).length, 18);
        assertLe(bytes(PositionSVG.amount(type(uint256).max, 37, false)).length, 18);
        assertLe(bytes(PositionSVG.amount(1, 37, false)).length, 18);
        assertLe(bytes(PositionSVG.amount(type(uint256).max, DEC18, true)).length, 26);
    }

    /// A number too wide for the slot loses precision, never magnitude.
    function test_WideNumbersKeepTheirMagnitude() public pure {
        assertEq(PositionSVG.amount(type(uint256).max, RAW, false), "1.1579e+77");
        assertEq(PositionSVG.amount(1e30, DEC18, false), "1000000000000");
    }

    /// Token ids are routinely hashes; they are elided, not truncated.
    function test_LongTokenIdsAreElided() public pure {
        assertEq(PositionSVG.amount(7, DEC18, true), "TOKEN #7");
        assertEq(PositionSVG.amount(0, DEC18, true), "TOKEN #0");
        assertEq(PositionSVG.amount(type(uint256).max, DEC18, true), "TOKEN #115792..9935");
    }
}
