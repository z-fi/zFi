// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LibString} from "../../lib/solady/src/utils/LibString.sol";
import {PositionSVG} from "./PositionSVG.sol";

/// @title FloorboardMetadata
/// @notice Immutable renderer deployed by each Floorboard instance.
/// @dev The sibling of `DutchboardMetadata`, and for the same reason:
///      presentation code is most of the board's bytecode and none of its risk,
///      so it lives out here and the board stays deployable under EIP-170
///      without making metadata upgradeable. The board passes a fully resolved
///      snapshot — every untrusted read (decimals, symbol) already happened at
///      bid time — so this contract makes no call other than best-effort
///      reverse WNS.
contract FloorboardMetadata {
    struct RenderParams {
        uint256 id;
        address bidder; // holder when the bid has closed
        address token;
        address quote;
        uint128 remaining;
        uint128 initial; // units wanted at creation; the basis `price` is quoted on
        uint96 locked;
        uint256 price;
        uint96 startPrice;
        uint96 endPrice;
        uint40 startTime;
        uint40 duration;
        uint256 fillProgress; // basis points
        uint256 climbProgress; // basis points
        uint8 tokenDecimals;
        uint8 quoteDecimals;
        string tokenSymbol;
        string quoteSymbol;
        bool isNFT;
        bool live;
        bool settled;
    }

    function tokenURI(RenderParams calldata p) external view returns (string memory) {
        (string memory status, string memory accent) = _state(p);
        string memory svg = string.concat(
            PositionSVG.OPEN,
            PositionSVG.FRAME,
            "M360 112v100'/>",
            _curve(p, accent),
            PositionSVG.TEXT,
            "<text x='32' y='55' font-size='25' font-weight='700'>FLOORBOARD / POSITION #",
            LibString.toString(p.id),
            "</text><text x='32' y='77' font-size='12'><tspan fill='#8b939e'>RISING BID //</tspan> <tspan fill='",
            accent,
            "' font-weight='700'>",
            status,
            "</tspan></text>",
            _legs(p),
            _sellAll(p),
            _stats(p, accent),
            // The footer band runs 326-402 and held two lines hugging its top
            // edge. Centred, they read as belonging to the band rather than
            // hanging off the rule above it.
            "<text x='32' y='358' font-size='12'>",
            p.live ? PositionSVG.key("BIDDER") : PositionSVG.key("HOLDER"),
            PositionSVG.makerLabel(p.bidder),
            "</text><text x='32' y='382' font-size='12'>", PositionSVG.key("ESCROW"), "",
            PositionSVG.amount(p.locked, p.quoteDecimals, false),
            "</text>",
            _basis(p),
            PositionSVG.CLOSE
        );
        return PositionSVG.dataURI(
            "application/json",
            string.concat(
                '{"name":"Floorboard Position #',
                LibString.toString(p.id),
                '","description":"A live standing bid on Floorboard. The holder of this receipt owns the escrowed quote, its refund, and the right to cancel. The offered price climbs from the start price to the end price over the window shown on the card.","image":"',
                PositionSVG.dataURI("image/svg+xml", svg),
                '","attributes":[{"trait_type":"Board","value":"Floorboard"},{"trait_type":"Status","value":"',
                status,
                '"},{"trait_type":"Wanted","value":"',
                p.isNFT ? "ERC721" : "ERC20",
                '"},{"trait_type":"Quote","value":"',
                PositionSVG.quoteLabel(p.quote),
                '"},{"display_type":"number","trait_type":"Climbed %","value":',
                PositionSVG.percent(p.climbProgress),
                '},{"display_type":"number","trait_type":"Filled %","value":',
                PositionSVG.percent(p.fillProgress),
                // Emitted under both names on purpose. `Schedule ends` lines up
                // with Dutchboard's climb/decay window, and `Expiry` lines up
                // with the deadline trait every board carries - for a Floorboard
                // bid they are the same instant, because the window closing is
                // what makes the bid unfillable. One name would break one of the
                // two cross-board filters a marketplace can offer.
                '},{"display_type":"date","trait_type":"Schedule ends","value":',
                LibString.toString(uint256(p.startTime) + p.duration),
                '},{"display_type":"date","trait_type":"Expiry","value":',
                LibString.toString(uint256(p.startTime) + p.duration),
                "}]}"
            )
        );
    }

    /// @dev Mirror of Dutchboard's curve: same 258-298 band, entered from the
    ///      other end. A decaying lot falls from the top of the band, a rising
    ///      bid climbs from the bottom, so the two boards read as opposites at a
    ///      glance and neither one's line strays into the other rows' space.
    ///      `endPrice >= startPrice` and `startPrice != 0` are creation
    ///      invariants (`_checkPrices`) and closing a bid does not clear the
    ///      terms, so this neither underflows nor divides by zero for any id
    ///      that has ever existed.
    function _curve(RenderParams calldata p, string memory accent) private pure returns (string memory) {
        uint256 curveEnd = 298 - (40 * (uint256(p.endPrice) - p.startPrice)) / p.endPrice;
        string memory id = string.concat("c", LibString.toString(p.id));
        string memory baseline = PositionSVG.baseline("M32 298Q360 298 688 ", curveEnd, id);
        // A zero-length dash under `stroke-linecap='round'` renders as a DOT,
        // so tracing 0% drew a stray mark on the baseline rather than nothing.
        if (p.climbProgress == 0) return baseline;
        return string.concat(
            baseline,
            PositionSVG.use_(
                id,
                string.concat(
                    "stroke='",
                    accent,
                    "' stroke-linecap='round' stroke-dasharray='",
                    PositionSVG.percent(p.climbProgress),
                    " 100'"
                )
            ),
            // The mirror of Dutchboard's head, falling out of the same
            // `y0 + (y1 - y0)t²` - here `y1` is above `y0`, so it subtracts.
            PositionSVG.head(
                298 - ((298 - curveEnd) * p.climbProgress * p.climbProgress) / 100_000_000,
                p.climbProgress,
                accent
            )
        );
    }

    /// @dev Split out to keep `tokenURI`'s frame under the stack limit.
    /// @dev Both headings state which reading they are. A closed bid keeps its
    ///      last live size in storage, and a scheduled one quotes a price nobody
    ///      can hit yet; neither should read as a number you can act on.
    function _legs(RenderParams calldata p) private view returns (string memory) {
        return string.concat(
            PositionSVG.LABEL,
            "x='32' y='132'>",
            p.live ? "STILL WANTED" : "WANTED AT CLOSE",
            "</text><text x='32' y='168' font-size='22'>",
            p.isNFT
                ? string.concat("NFT x", LibString.toString(p.remaining))
                : PositionSVG.amount(p.remaining, p.tokenDecimals, false),
            "</text><text x='32' y='192' font-size='12'>",
            PositionSVG.legLabel(p.token, p.tokenSymbol, p.tokenDecimals, p.isNFT),
            "</text>",
            PositionSVG.LABEL,
            "x='384' y='132'>",
            // See the sibling note in `DutchboardMetadata`: a closed window
            // leaves a bid nobody can hit, so the heading must not say "NOW".
            !p.live
                ? "BID AT CLOSE"
                : block.timestamp >= uint256(p.startTime) + p.duration
                    ? "BID AT EXPIRY"
                    : block.timestamp < p.startTime ? "BID AT OPEN" : "BID NOW",
            "</text><text x='384' y='168' font-size='22'>",
            // The board now resolves the price the bid closed at, so a spent
            // receipt no longer spends its largest slot on "--" - which it did
            // on precisely the cards where the settlement price is the most
            // interesting fact left.
            PositionSVG.amount(p.price, p.quoteDecimals, false),
            "</text><text x='384' y='192' font-size='12'>",
            PositionSVG.quoteLine(p.quote, p.quoteSymbol, p.quoteDecimals),
            "</text>"
        );
    }

    /// @dev What delivering everything still wanted pays, right now.
    ///
    ///      The mirror of Dutchboard's `TAKE ALL`, and needed for the same
    ///      reason: `price` is the total for the FULL INITIAL lot, since
    ///      `_proceeds` divides by `initial`. On a partly filled bid the headline
    ///      is NOT what the remainder pays, and a seller reading it as such
    ///      expects more than the board will send.
    ///
    ///      Rounds down exactly as `Floorboard._proceeds` does - the opposite way
    ///      to Dutchboard, because each board rounds against the party the card
    ///      is quoting to.
    function _sellAll(RenderParams calldata p) private view returns (string memory) {
        if (!p.live || p.initial == 0 || p.remaining == 0) return "";
        // Only where the board would actually honour it - `hit` reverts before
        // the window opens and once it closes, and the board's own quote
        // returns `(false, 0)`. See the sibling note in `DutchboardMetadata`:
        // this row is what a seller acts on, so a bid that cannot be hit must
        // not carry one. Unlike a Dutch lot there is no resting state here; the
        // window closing ends the bid outright.
        if (block.timestamp < p.startTime) return "";
        if (block.timestamp >= uint256(p.startTime) + p.duration) return "";
        return string.concat(
            "<text x='384' y='210' font-size='12'>", PositionSVG.key("SELL ALL"), "",
            PositionSVG.amount((p.price * p.remaining) / p.initial, p.quoteDecimals, false),
            "</text>"
        );
    }

    /// @dev The quantity every price on this card is quoted against. `price`,
    ///      `startPrice` and `endPrice` are all totals for the FULL INITIAL
    ///      size, because `Floorboard._proceeds` divides by `initial` - and that
    ///      size appeared nowhere once the bid was partly filled. The quote line
    ///      used to end "/ FULL LOT", which named the basis without ever saying
    ///      what it was. Right-anchored into the footer, whose right half was
    ///      empty on every card the board can produce.
    function _basis(RenderParams calldata p) private pure returns (string memory) {
        if (p.initial == 0) return "";
        return string.concat(
            "<text text-anchor='end' x='688' y='358' font-size='12'>", PositionSVG.key("WANTED AT OPEN"), "",
            p.isNFT
                ? string.concat("NFT x", LibString.toString(p.initial))
                : PositionSVG.amount(p.initial, p.tokenDecimals, false),
            "</text>"
        );
    }

    /// @dev The terms the receipt was created under, set as the curve's own two
    ///      axes: price at the ends it climbs between, time at the ends it runs
    ///      between. The curve occupies y 258-298, so these sit clear of it at
    ///      244 and 316 rather than being drawn through it. See the sibling
    ///      note in `DutchboardMetadata`: 248 did not in fact clear the band.
    function _stats(RenderParams calldata p, string memory accent) private pure returns (string memory) {
        return string.concat(
            "<text x='32' y='230' font-size='12'>", PositionSVG.key("CLIMB"), "<tspan fill='",
            accent,
            "' font-weight='700'>",
            PositionSVG.percent(p.climbProgress),
            "%</tspan></text><text x='384' y='230' font-size='12'>", PositionSVG.key("BID FILLED"), "<tspan fill='",
            accent,
            "' font-weight='700'>",
            PositionSVG.percent(p.fillProgress),
            "%</tspan></text>",
            PositionSVG.AXIS_L,
            "y='244'>", PositionSVG.key("START"), "",
            PositionSVG.amount(p.startPrice, p.quoteDecimals, false),
            "</text>",
            PositionSVG.AXIS_R,
            "y='244'>", PositionSVG.key("END"), "",
            PositionSVG.amount(p.endPrice, p.quoteDecimals, false),
            "</text>",
            PositionSVG.AXIS_L,
            "y='316'>", PositionSVG.key("OPENS"), "",
            PositionSVG.timestamp(p.startTime),
            "</text>",
            PositionSVG.AXIS_R,
            "y='316'>", PositionSVG.key("EXPIRES"), "",
            PositionSVG.timestamp(uint256(p.startTime) + p.duration),
            "</text>"
        );
    }

    /// @dev EXPIRED is the state Dutchboard has no analogue for: a Floorboard bid
    ///      stops being takeable when its window closes rather than resting at
    ///      its terminal price, so a live-but-dead bid must read differently
    ///      from one that is still climbing.
    function _state(RenderParams calldata p) private view returns (string memory, string memory) {
        if (!p.live) return p.settled ? ("FILLED", PositionSVG.FILLED) : ("CLOSED", PositionSVG.CLOSED);
        if (block.timestamp < p.startTime) return ("SCHEDULED", PositionSVG.PENDING);
        if (block.timestamp >= uint256(p.startTime) + p.duration) return ("EXPIRED", PositionSVG.EXPIRED);
        return ("LIVE", PositionSVG.LIVE);
    }
}
