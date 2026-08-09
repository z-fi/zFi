// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "forge-std/Test.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {PositionSVG} from "../src/utils/PositionSVG.sol";

/// @dev Every amount on every card goes through `PositionSVG.amount`, and it is
/// the only place on these receipts where a number is CONSTRUCTED rather than
/// copied. A wrong digit here is worse than a missing one: the card still looks
/// right.
///
/// The case that motivated this file: a fresh `bytes` is zero-BYTES, not
/// zero-DIGITS, so the fraction's leading zeros were never written. 0.012345
/// USDC printed as "0.<NUL>12345" - ten times the real value, in a document XML
/// does not admit a NUL into at all.
contract PositionSVGAmountTest is Test {
    function _amount(uint256 value, uint8 decimals) internal pure returns (string memory) {
        return PositionSVG.amount(value, decimals + 1, false);
    }

    /// @dev No NUL, anywhere, for any scale or magnitude. This is the assertion
    ///      that would have caught the bug: the value could have been checked
    ///      and still read as plausible, but a NUL is never right.
    function _assertRenderable(string memory s) internal pure {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            // XML 1.0 admits no C0 control character except tab, LF and CR, and
            // an amount should contain none of those either.
            assertTrue(b[i] >= 0x20, "control byte in a rendered amount");
            assertTrue(b[i] != "<" && b[i] != "&", "markup byte in a rendered amount");
        }
    }

    // ------------------------------------------------- THE FRACTIONAL BRANCH

    /// @dev One leading zero: the common USDC dust case.
    function test_OneLeadingZero() public pure {
        assertEq(_amount(12345, 6), "0.012345");
        assertEq(_amount(5, 2), "0.05");
        assertEq(_amount(1, 2), "0.01");
    }

    /// @dev Two leading zeros - the widest gap this branch can produce before
    ///      `decimals - n >= 3` sends it to scientific notation.
    function test_TwoLeadingZeros() public pure {
        assertEq(_amount(1234, 6), "0.001234");
        assertEq(_amount(1, 3), "0.001");
    }

    /// @dev No gap at all: the case that always worked, kept so a fix to the
    ///      others cannot silently break it.
    function test_NoLeadingZeros() public pure {
        assertEq(_amount(123456, 6), "0.123456");
        assertEq(_amount(50, 2), "0.5", "trailing zeros are dropped, as in the whole branch");
        assertEq(_amount(10000, 6), "0.01", "and dropped without moving the leading ones");
    }

    /// @dev The widest fraction the slot admits. Below one whole unit the
    ///      written-out branch only runs while the gap is under three places,
    ///      so the widest case is a full-length mantissa at sixteen decimals.
    function test_WidestFractionalSlot() public pure {
        string memory widest = _amount(1234567890123456, 16); // sixteen digits, no gap
        assertEq(bytes(widest).length, 18, "0. plus sixteen places");
        assertEq(widest, "0.1234567890123456");
        // Three places of gap is scientific by design, however few decimals.
        assertEq(_amount(1, 16), "1e-16");
    }

    // -------------------------------------------------------- WHOLE NUMBERS

    function test_WholeAndMixed() public pure {
        assertEq(_amount(1e18, 18), "1");
        assertEq(_amount(1.5e18, 18), "1.5");
        assertEq(_amount(1e6, 6), "1");
        assertEq(_amount(1_000_000e6, 6), "1000000");
        assertEq(_amount(0, 18), "0", "zero is zero at every scale");
    }

    /// @dev Magnitude is never sacrificed to the slot width; precision is.
    function test_WideNumbersKeepTheirMagnitude() public pure {
        string memory wide = _amount(123456789012345678901234567890, 0);
        assertEq(wide, "1.2345e+29");
        assertTrue(bytes(_amount(type(uint256).max, 0)).length <= 18, "still fits the slot");
    }

    // ------------------------------------------------------------ SCIENTIFIC

    /// @dev The cutoff is the VALUE's leading zeros, not the token's scale. A
    ///      number keeps its written form while five significant places survive
    ///      them and switches to `d.ddddeK` once they do not - below that,
    ///      scientific carries strictly more of the number than a run of zeros
    ///      with two digits on the end.
    function test_TinyValuesGoScientific() public pure {
        assertEq(_amount(1, 6), "0.000001", "five places still fit at six decimals");
        assertEq(_amount(5, 18), "5e-18");
        assertEq(_amount(12345, 18), "1.2345e-14");
        assertEq(_amount(1, 12), "0.000000000001", "the last scale that fits");
        assertEq(_amount(1, 13), "1e-13", "one place further and it does not");
    }

    /// @dev The regression this cutoff exists for. `decimals + 2 > MAX_WIDTH`
    ///      never looked at the value, so on WETH - the default quote leg on two
    ///      of the three boards - EVERY sub-unit amount came out in scientific
    ///      notation, in the largest slot on the card.
    function test_SubUnitAmountsOnAnEighteenDecimalTokenAreWrittenOut() public pure {
        assertEq(_amount(5e17, 18), "0.5");
        assertEq(_amount(25e16, 18), "0.25");
        assertEq(_amount(999e15, 18), "0.999");
        assertEq(_amount(1e15, 18), "0.001");
    }

    // ------------------------------------------------------------------ NFTs

    function test_NFTAmountsAreTokenIds() public pure {
        assertEq(PositionSVG.amount(0, 0, true), "TOKEN #0", "token id zero is a real id");
        assertEq(PositionSVG.amount(7, 19, true), "TOKEN #7", "scale is ignored for an id");
        assertEq(
            PositionSVG.amount(type(uint256).max, 0, true),
            "TOKEN #115792..9935",
            "a hash-shaped id is elided, not overrun"
        );
    }

    // ------------------------------------------------------------- SWEEP

    /// @dev Every scale a token can declare, against magnitudes on both sides
    ///      of the decimal point. Nothing renders a control byte, nothing
    ///      exceeds the slot, and nothing comes back empty.
    function testFuzz_EveryRenderIsWellFormed(uint256 value, uint8 rawDecimals) public pure {
        uint8 decimals = uint8(bound(rawDecimals, 0, 36));
        string memory out = _amount(value, decimals);
        _assertRenderable(out);
        assertTrue(bytes(out).length != 0, "an amount always renders something");
        assertTrue(bytes(out).length <= 22, "and never runs off the card");
    }

    /// @dev A rendered fraction must round-trip: reading the digits back at the
    ///      stated scale has to give the value it was drawn from. This is the
    ///      property the NUL bug violated while still looking like a number.
    function testFuzz_FractionalRendersAreExact(uint256 value, uint8 rawDecimals) public pure {
        uint8 decimals = uint8(bound(rawDecimals, 1, 16));
        value = bound(value, 1, 10 ** decimals - 1); // strictly below one whole unit
        bytes memory digits = bytes(LibString.toString(value));
        // Only the written-out branch; the rest is scientific by design. This
        // must track `amount`'s cutoff or the fuzz silently stops covering the
        // cases the cutoff was widened to admit - it used to restate the old
        // rule, so every sub-unit value on a high-decimals token was skipped.
        if (decimals - digits.length + 7 > 18) return;

        bytes memory out = bytes(_amount(value, decimals));
        assertTrue(out.length <= uint256(decimals) + 2, "never wider than the scale");
        assertEq(out[0], bytes1("0"));
        assertEq(out[1], bytes1("."));

        uint256 parsed;
        for (uint256 i = 2; i < out.length; ++i) {
            assertTrue(out[i] >= 0x30 && out[i] <= 0x39, "every place is a digit");
            parsed = parsed * 10 + (uint8(out[i]) - 0x30);
        }
        // Trailing zeros are dropped, so scale the reading back up by however
        // many places were trimmed before comparing.
        parsed *= 10 ** (uint256(decimals) + 2 - out.length);
        assertEq(parsed, value, "the card states the value it was given");
    }
}
