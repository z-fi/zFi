// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LibString} from "../../lib/solady/src/utils/LibString.sol";
import {PositionSVG} from "./PositionSVG.sol";

/// @notice Immutable renderer deployed by each Dutchboard instance.
/// @dev Same reasoning as `SwapboardMetadata`: presentation code is most of the
///      board's bytecode and none of its risk, so it lives out here and the
///      board stays deployable under EIP-170 without making metadata
///      upgradeable. The board passes a fully resolved snapshot — every
///      untrusted read (decimals, symbol) already happened at listing time — so
///      this contract makes no call other than best-effort reverse WNS.
contract DutchboardMetadata {
    struct RenderParams {
        uint256 id;
        address seller; // holder when the listing has closed
        address token;
        address quote;
        uint256 lotSize; // NFT bundle size, unused for ERC-20 lots
        uint128 remaining;
        uint128 initial; // units offered at creation; the basis `price` is quoted on
        uint256 price;
        uint96 startPrice;
        uint96 endPrice;
        uint40 startTime;
        uint40 duration;
        uint256 fillProgress; // basis points
        uint256 decayProgress; // basis points
        uint40 expiry; // 0 = never expires
        uint8 tokenDecimals;
        uint8 quoteDecimals;
        string tokenSymbol;
        string quoteSymbol;
        bool isNFT;
        bool live;
        bool settled;
        bool frozen;
    }

    function tokenURI(RenderParams calldata p) external view returns (string memory) {
        (string memory status, string memory accent) = _state(p);
        string memory svg = string.concat(
            PositionSVG.OPEN,
            PositionSVG.FRAME,
            "M360 112v100'/>",
            _curve(p, accent),
            PositionSVG.TEXT,
            "<text x='32' y='55' font-size='25' font-weight='700'>DUTCHBOARD / POSITION #",
            LibString.toString(p.id),
            "</text><text x='32' y='77' font-size='12'><tspan fill='#8b939e'>DECAYING LOT //</tspan> <tspan fill='",
            accent,
            "' font-weight='700'>",
            status,
            "</tspan></text>",
            _legs(p),
            _takeAll(p),
            _stats(p, accent),
            // The footer band runs 326-402 and held two lines hugging its top
            // edge. Centred, they read as belonging to the band rather than
            // hanging off the rule above it.
            "<text x='32' y='358' font-size='12'>",
            p.live ? PositionSVG.key("SELLER") : PositionSVG.key("HOLDER"),
            PositionSVG.makerLabel(p.seller),
            "</text><text x='32' y='382' font-size='12'>", PositionSVG.key("EXPIRY"), "",
            PositionSVG.timestamp(p.expiry),
            "</text>",
            _basis(p),
            PositionSVG.CLOSE
        );
        return PositionSVG.dataURI(
            "application/json",
            string.concat(
                '{"name":"Dutchboard Position #',
                LibString.toString(p.id),
                '","description":"A live Dutch auction listing on Dutchboard. The holder of this receipt owns the lot, its proceeds, and the right to withdraw or cancel. The asking price decays from the start price to the end price over the schedule shown on the card.","image":"',
                PositionSVG.dataURI("image/svg+xml", svg),
                '","attributes":[{"trait_type":"Board","value":"Dutchboard"},{"trait_type":"Status","value":"',
                status,
                '"},{"trait_type":"Lot","value":"',
                p.isNFT ? "ERC721" : "ERC20",
                '"},{"trait_type":"Quote","value":"',
                PositionSVG.quoteLabel(p.quote),
                '"},{"display_type":"number","trait_type":"Decayed %","value":',
                PositionSVG.percent(p.decayProgress),
                '},{"display_type":"number","trait_type":"Filled %","value":',
                PositionSVG.percent(p.fillProgress),
                '},{"display_type":"date","trait_type":"Schedule ends","value":',
                LibString.toString(uint256(p.startTime) + p.duration),
                "}",
                _expiryAttribute(p.expiry),
                "]}"
            )
        );
    }

    /// @dev The decay schedule drawn as a curve sinking below its baseline by an
    ///      amount proportional to the total drop, with the elapsed share of the
    ///      schedule traced over it. `startPrice != 0` is a creation invariant
    ///      (`_checkPrices`) and closing a listing does not clear the terms, so
    ///      the division is total for every id that has ever existed.
    function _curve(RenderParams calldata p, string memory accent) private pure returns (string memory) {
        uint256 curveEnd = 258 + (40 * (uint256(p.startPrice) - p.endPrice)) / p.startPrice;
        string memory id = string.concat("c", LibString.toString(p.id));
        string memory baseline = PositionSVG.baseline("M32 258Q360 258 688 ", curveEnd, id);
        // A zero-length dash under `stroke-linecap='round'` renders as a DOT,
        // so tracing 0% drew a stray mark on the baseline rather than nothing.
        if (p.decayProgress == 0) return baseline;
        return string.concat(
            baseline,
            PositionSVG.use_(
                id,
                string.concat(
                    "stroke='",
                    accent,
                    "' stroke-linecap='round' stroke-dasharray='",
                    PositionSVG.percent(p.decayProgress),
                    " 100'"
                )
            ),
            PositionSVG.head(_headY(curveEnd, 258, p.decayProgress), p.decayProgress, accent)
        );
    }

    /// @dev Where the traced curve currently ends, on the curve itself.
    ///      The control point sits at the midpoint's x, so `x(t)` is exactly
    ///      linear and `y(t)` collapses to `y0 + (y1 - y0)t²` - the head lands
    ///      on the line rather than near it, at any progress.
    function _headY(uint256 curveEnd, uint256 y0, uint256 progress) private pure returns (uint256) {
        return y0 + ((curveEnd - y0) * progress * progress) / 100_000_000;
    }

    /// @dev Split out to keep `tokenURI`'s frame under the stack limit.
    /// @dev Both headings state which reading they are. A closed listing keeps
    ///      its last live lot size in storage, and a scheduled one quotes a price
    ///      nobody can pay yet; neither should read as a number you can act on.
    function _legs(RenderParams calldata p) private view returns (string memory) {
        return string.concat(
            PositionSVG.LABEL,
            "x='32' y='132'>",
            p.live ? "LOT REMAINING" : "LOT AT CLOSE",
            "</text><text x='32' y='168' font-size='22'>",
            p.isNFT
                ? string.concat("BUNDLE ", LibString.toString(p.lotSize))
                : PositionSVG.amount(p.remaining, p.tokenDecimals, false),
            "</text><text x='32' y='192' font-size='12'>",
            PositionSVG.legLabel(p.token, p.tokenSymbol, p.tokenDecimals, p.isNFT),
            "</text>",
            PositionSVG.LABEL,
            "x='384' y='132'>",
            // "NOW" is a claim that the figure under it is transactable. On an
            // EXPIRED listing it is the schedule's price and nobody can pay it,
            // which is the same thing the TAKE ALL row was doing before it was
            // gated - the heading has to agree with the row it lost.
            !p.live
                ? "PRICE AT CLOSE"
                : p.expiry != 0 && block.timestamp > p.expiry
                    ? "PRICE AT EXPIRY"
                    : block.timestamp < p.startTime ? "PRICE AT OPEN" : "PRICE NOW",
            "</text><text x='384' y='168' font-size='22'>",
            // The board now resolves the price the listing closed at, so a
            // spent receipt no longer spends its largest slot on "--" - which
            // it did on precisely the cards where the settlement price is the
            // most interesting fact left.
            PositionSVG.amount(p.price, p.quoteDecimals, false),
            "</text><text x='384' y='192' font-size='12'>",
            PositionSVG.quoteLine(p.quote, p.quoteSymbol, p.quoteDecimals),
            "</text>"
        );
    }

    /// @dev What it costs to take everything still on offer, right now.
    ///
    ///      `price` is the total for the FULL INITIAL lot - that is the board's
    ///      own basis, since `_cost` divides by `initial` - so on a partly filled
    ///      listing the headline is NOT what the remainder costs. Reading
    ///      "LOT REMAINING 575 / PRICE NOW 3000" as "3000 buys the 575" misprices
    ///      by the fill ratio. The quote line now names the basis and this line
    ///      gives the number a taker can act on.
    ///
    ///      Rounds up exactly as `Dutchboard._cost` does. A card that rounded the
    ///      other way would quote a price the board refuses to honour.
    function _takeAll(RenderParams calldata p) private view returns (string memory) {
        // An NFT bundle is all-or-nothing and costs `price` outright, so the
        // headline already is the actionable number.
        if (!p.live || p.isNFT || p.initial == 0 || p.remaining == 0) return "";
        // Only where the board would actually honour it. `takeFor` returns
        // `(0, 0)` and `fill` reverts while a listing is frozen, before it
        // opens, or once it has expired - and this row is the one number on the
        // card a taker is invited to act on. A SCHEDULED or EXPIRED receipt was
        // quoting a cost nobody could pay, under a heading that reads as an
        // instruction. The schedule running out is NOT one of these: a lot
        // resting on its floor is still takeable, at the floor.
        if (p.frozen || block.timestamp < p.startTime) return "";
        if (p.expiry != 0 && block.timestamp > p.expiry) return "";
        return string.concat(
            "<text x='384' y='210' font-size='12'>", PositionSVG.key("TAKE ALL"), "",
            PositionSVG.amount((p.price * p.remaining + p.initial - 1) / p.initial, p.quoteDecimals, false),
            "</text>"
        );
    }

    /// @dev The quantity every price on this card is quoted against. `price`,
    ///      `startPrice` and `endPrice` are all totals for the FULL INITIAL lot,
    ///      because `Dutchboard._cost` divides by `initial` - and that lot size
    ///      appeared nowhere once the listing was partly filled. The quote line
    ///      used to end "/ FULL LOT", which named the basis without ever saying
    ///      what it was. Right-anchored into the footer, whose right half was
    ///      empty on every card the board can produce.
    function _basis(RenderParams calldata p) private pure returns (string memory) {
        if (p.isNFT || p.initial == 0) return "";
        return string.concat(
            "<text text-anchor='end' x='688' y='358' font-size='12'>", PositionSVG.key("LOT AT OPEN"), "",
            PositionSVG.amount(p.initial, p.tokenDecimals, false),
            "</text>"
        );
    }

    /// @dev The terms the receipt was created under, set as the curve's own two
    ///      axes: price at the ends it decays between, time at the ends it runs
    ///      between. The curve occupies y 258-298, so these sit clear of it at
    ///      244 and 316 rather than being drawn through it. The price axis was
    ///      at 248, whose descenders came within seven pixels of a curve the
    ///      comment already claimed they cleared - and within four of the head
    ///      marking a schedule that has only just started.
    function _stats(RenderParams calldata p, string memory accent) private pure returns (string memory) {
        return string.concat(
            "<text x='32' y='230' font-size='12'>", PositionSVG.key("DUTCH CURVE"), "<tspan fill='",
            accent,
            "' font-weight='700'>",
            PositionSVG.percent(p.decayProgress),
            "%</tspan></text><text x='384' y='230' font-size='12'>", PositionSVG.key("LOT FILLED"), "<tspan fill='",
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
            "y='316'>", PositionSVG.key("ENDS"), "",
            PositionSVG.timestamp(uint256(p.startTime) + p.duration),
            "</text>"
        );
    }

    function _expiryAttribute(uint40 expiry) private pure returns (string memory) {
        if (expiry == 0) return "";
        return string.concat(
            ',{"display_type":"date","trait_type":"Expiry","value":', LibString.toString(expiry), "}"
        );
    }

    /// @dev FROZEN outranks the schedule states: the underlying live position
    ///      settled, so the curve is no longer what a holder is looking at.
    function _state(RenderParams calldata p) private view returns (string memory, string memory) {
        if (!p.live) return p.settled ? ("FILLED", PositionSVG.FILLED) : ("CLOSED", PositionSVG.CLOSED);
        if (p.frozen) return ("FROZEN", PositionSVG.FROZEN);
        // A hard expiry outranks the curve: an expired listing is unfillable
        // whatever the schedule would otherwise be showing.
        if (p.expiry != 0 && block.timestamp > p.expiry) return ("EXPIRED", PositionSVG.EXPIRED);
        if (block.timestamp < p.startTime) return ("SCHEDULED", PositionSVG.PENDING);
        if (block.timestamp >= uint256(p.startTime) + p.duration) {
            return p.endPrice == 0 ? ("FREE", PositionSVG.FREE) : ("FLOOR", PositionSVG.RESTING);
        }
        return ("LIVE", PositionSVG.LIVE);
    }
}
