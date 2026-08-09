// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {LibString} from "../../lib/solady/src/utils/LibString.sol";
import {PositionSVG} from "./PositionSVG.sol";

/// @notice Immutable renderer deployed by each Swapboard instance.
/// @dev Keeping presentation code separate lets the position board remain
///      deployable under EIP-170 without making metadata upgradeable. The card
///      shares `PositionSVG`'s 720x420 chrome with Dutchboard and Floorboard so
///      a wallet holding receipts from all three shows one family.
contract SwapboardMetadata {
    struct RenderParams {
        uint256 id;
        address maker;
        address tokenA;
        address tokenB;
        uint256 amountA;
        uint256 amountB;
        uint256 initialAmountB;
        uint64 expiry;
        uint8 decimalsA;
        uint8 decimalsB;
        string symbolA;
        string symbolB;
        uint64 frozenUntil;
        address counterparty; // zero when the order is open to anyone
        bool active;
        bool settled; // closed by a fill that took the whole order
        bool partialFill;
        bool nftA;
        bool nftB;
        bool frozen;
        bool restricted;
    }

    /// @notice Render the receipt for `id` on `board`.
    /// @dev The board used to assemble `RenderParams` itself and pass the whole
    ///      struct across. That cost it 1,242 bytes of runtime code - the
    ///      twenty-field build plus the encoder for two dynamic strings - on a
    ///      contract with no EIP-170 headroom left, to save this one, which has
    ///      thousands. So the reading moved here: the board exposes its
    ///      snapshots as getters and this contract does the assembly.
    ///
    ///      It is a view path reached through `eth_call`, so the extra
    ///      staticcalls cost nothing anyone pays for, and `RenderParams` stays
    ///      the shape every helper below is written against.
    function tokenURI(address board, uint256 id) external view returns (string memory) {
        ISwapboard b = ISwapboard(board);
        RenderParams memory q;
        q.id = id;
        (
            q.maker,
            q.active,
            q.partialFill,
            q.expiry,
            q.nftA,
            q.nftB,
            q.counterparty,
            q.tokenA,
            q.amountA,
            q.tokenB,
            q.amountB
        ) = b.orders(id);
        q.initialAmountB = b.initialAmountB(id);
        // An NFT leg's amount is a token id, not a quantity, so it carries no
        // scale - the same substitution the board made before this moved.
        if (!q.nftA) q.decimalsA = b.tokenDecimals(q.tokenA);
        if (!q.nftB) q.decimalsB = b.tokenDecimals(q.tokenB);
        q.symbolA = b.tokenSymbols(q.tokenA);
        q.symbolB = b.tokenSymbols(q.tokenB);
        q.frozenUntil = b.frozenUntil(id);
        q.settled = b.settled(id);
        q.frozen = b.frozen(id);
        q.restricted = q.counterparty != address(0);
        return _render(q);
    }

    function _render(RenderParams memory p) internal view returns (string memory) {
        (string memory status, string memory accent) = _state(p);
        uint256 progress = _progress(p);
        string memory svg = string.concat(
            PositionSVG.OPEN,
            PositionSVG.FRAME,
            // The divider between the two legs, and the fill bar, drawn in the
            // same stroked group as the frame. The divider stops at 230, clear
            // of the full-width rows below it: a long TERMS string used to run
            // straight through it.
            //
            // The bar sits in the 258-298 band, centred on the same 278 the
            // sibling boards' schedule curve is centred on. It used to float at
            // 272 with its caption immediately above and forty dead pixels
            // below, which made the one board without a curve read as the one
            // board that ran out of things to say.
            "M360 112v100'/><rect x='32' y='270' width='656' height='16'/><rect x='32' y='270' width='",
            LibString.toString((656 * progress) / 10_000),
            "' height='16' fill='",
            accent,
            "' stroke='none'/>",
            PositionSVG.TEXT,
            "<text x='32' y='55' font-size='25' font-weight='700'>SWAPBOARD / POSITION #",
            LibString.toString(p.id),
            "</text><text x='32' y='77' font-size='12'><tspan fill='#8b939e'>ESCROW RECEIPT //</tspan> <tspan fill='",
            accent,
            "' font-weight='700'>",
            status,
            "</tspan></text>",
            _legs(p),
            _unitPrice(p),
            _rows(p, accent, progress),
            _ledger(p),
            _footer(p),
            PositionSVG.CLOSE
        );
        return PositionSVG.dataURI(
            "application/json",
            string.concat(
                '{"name":"Swapboard Position #',
                LibString.toString(p.id),
                '","description":"A live escrowed order on Swapboard. The holder of this receipt is the maker: they own the escrow, its proceeds, and the right to reprice or cancel.","image":"',
                PositionSVG.dataURI("image/svg+xml", svg),
                '","attributes":[{"trait_type":"Board","value":"Swapboard"},{"trait_type":"Status","value":"',
                status,
                '"},{"trait_type":"Escrow","value":"',
                p.nftA ? "ERC721" : "ERC20",
                '"},{"trait_type":"Request","value":"',
                p.nftB ? "ERC721" : "ERC20",
                '"},{"trait_type":"Fill","value":"',
                p.partialFill ? "Partial" : "All or nothing",
                '"},{"trait_type":"Access","value":"',
                p.restricted ? "Private" : "Public",
                '"},{"display_type":"number","trait_type":"Filled %","value":',
                PositionSVG.percent(progress),
                "}",
                _expiryAttribute(p.expiry),
                "]}"
            )
        );
    }

    /// @dev Split out to keep `tokenURI`'s frame under the stack limit.
    /// @dev A closed order keeps its last live terms in storage, so the headings
    ///      say so. Reading "ESCROW 10" off a cancelled receipt whose escrow went
    ///      back to the maker is the one way these numbers can mislead.
    function _legs(RenderParams memory p) private pure returns (string memory) {
        return string.concat(
            PositionSVG.LABEL,
            "x='32' y='132'>",
            p.active ? "ESCROW" : "ESCROW AT CLOSE",
            "</text><text x='32' y='168' font-size='22'>",
            PositionSVG.amount(p.amountA, p.decimalsA, p.nftA),
            "</text><text x='32' y='192' font-size='12'>",
            PositionSVG.legLabel(p.tokenA, p.symbolA, p.decimalsA, p.nftA),
            "</text>",
            PositionSVG.LABEL,
            "x='384' y='132'>",
            p.active ? "REQUEST" : "REQUEST AT CLOSE",
            "</text><text x='384' y='168' font-size='22'>",
            PositionSVG.amount(p.amountB, p.decimalsB, p.nftB),
            "</text><text x='384' y='192' font-size='12'>",
            PositionSVG.legLabel(p.tokenB, p.symbolB, p.decimalsB, p.nftB),
            "</text>"
        );
    }

    /// @dev The terms row and the bar's caption. Split out with `_footer` to
    ///      keep `tokenURI`'s frame under the stack limit - it went one slot over
    ///      when the labels gained their tspans.
    function _rows(RenderParams memory p, string memory accent, uint256 progress)
        private
        view
        returns (string memory)
    {
        return string.concat(
            "<text x='32' y='230' font-size='12'>",
            PositionSVG.key("TERMS"),
            _tags(p),
            "</text>",
            "<text x='32' y='248' font-size='12'>",
            PositionSVG.key("FILL PROGRESS"),
            "<tspan fill='",
            accent,
            "' font-weight='700'>",
            PositionSVG.percent(progress),
            "%</tspan></text>"
        );
    }

    /// @dev The footer band runs 326-402 and held two lines hugging its top
    ///      edge. Centred, they read as belonging to the band rather than
    ///      hanging off the rule above it.
    function _footer(RenderParams memory p) private view returns (string memory) {
        return string.concat(
            "<text x='32' y='358' font-size='12'>",
            PositionSVG.key("MAKER"),
            PositionSVG.makerLabel(p.maker),
            "</text><text x='32' y='382' font-size='12'>",
            PositionSVG.key("EXPIRY"),
            PositionSVG.timestamp(p.expiry),
            "</text>",
            _reserved(p)
        );
    }

    /// @dev The fill bar in words, on the row the sibling boards close their
    ///      schedule band with. Swapboard is the one board with no curve, and
    ///      its lower half ended at the bar with the whole 286-326 strip empty
    ///      while Dutchboard and Floorboard carried captions down to 316.
    ///
    ///      PAID and the original ask are the two facts the bar is drawn from
    ///      that are NOT already on the card. What is left to pay is deliberately
    ///      absent: it is `amountB`, which is the REQUEST figure in the hero slot
    ///      directly above, so naming it here restated a number verbatim instead
    ///      of adding one.
    function _ledger(RenderParams memory p) private pure returns (string memory) {
        if (p.nftB || p.initialAmountB == 0 || p.amountB > p.initialAmountB) return "";
        return string.concat(
            PositionSVG.AXIS_L,
            "y='316'>",
            PositionSVG.key("PAID"),
            PositionSVG.amount(p.initialAmountB - p.amountB, p.decimalsB, false),
            "</text>",
            PositionSVG.AXIS_R,
            "y='316'>",
            PositionSVG.key("REQUESTED AT OPEN"),
            PositionSVG.amount(p.initialAmountB, p.decimalsB, false),
            "</text>"
        );
    }

    /// @dev What one whole unit of the escrowed asset is being asked for, in the
    ///      request asset. Both sibling boards put a price in their largest slot;
    ///      a swap order's price is the entire point of it, and until now it was
    ///      the one fact a reader had to work out for themselves - across two
    ///      different decimal bases, from two raw amounts. Sits under the request
    ///      leg because that is what it is denominated in.
    ///
    ///      A partial fill scales both legs together, so this holds for the life
    ///      of the order and only a reprice moves it.
    function _unitPrice(RenderParams memory p) private pure returns (string memory) {
        if (p.nftA || p.nftB || p.amountA == 0 || p.amountB == 0) return "";
        // `decimalsA` is a snapshot: decimals + 1, with zero meaning raw units.
        uint256 scale = 10 ** (p.decimalsA == 0 ? 0 : p.decimalsA - 1);
        // Checked rather than assumed. An immutable renderer must never be the
        // reason a receipt reverts instead of drawing, however odd the pair.
        if (p.amountB > type(uint256).max / scale) return "";
        uint256 rate = (p.amountB * scale) / p.amountA;
        // Below one base unit per whole unit there is no price left to show, and
        // "UNIT PRICE 0" would state something false about a live order.
        if (rate == 0) return "";
        return string.concat(
            "<text x='384' y='210' font-size='12'>", PositionSVG.key("UNIT PRICE"), "",
            PositionSVG.amount(rate, p.decimalsB, false),
            "</text>"
        );
    }

    /// @dev Who is allowed to take this order, stated on every card rather than
    ///      only on private ones. "PRIVATE" in the terms told the holder that
    ///      somebody else held the only right to fill without telling them who -
    ///      the one fact that decides what the position is worth to them - and a
    ///      public order said nothing at all, leaving the reader to infer it from
    ///      an absence. Sits beside MAKER: the two are the same kind of fact.
    function _reserved(RenderParams memory p) private pure returns (string memory) {
        return string.concat(
            "<text text-anchor='end' x='688' y='358' font-size='12'>",
            PositionSVG.key("TAKER"),
            p.counterparty == address(0) ? "ANYONE" : PositionSVG.shortAddress(p.counterparty),
            "</text>"
        );
    }

    /// @dev An ERC-721 expiry is a real terminal state, so a zero timestamp has
    ///      to read as "never" rather than as an epoch date. Emitted only when
    ///      set so a perpetual order carries no misleading date trait.
    function _expiryAttribute(uint64 expiry) private pure returns (string memory) {
        if (expiry == 0) return "";
        return string.concat(
            ',{"display_type":"date","trait_type":"Expiry","value":', LibString.toString(expiry), "}"
        );
    }

    /// @dev The one headline state. Everything a state can coincide with -
    ///      private, frozen, divisible - is a tag rather than a status, so no
    ///      combination of them can hide another.
    function _state(RenderParams memory p) private view returns (string memory, string memory) {
        // The board says whether the close was a settlement. It used to be
        // inferred from both legs reading zero, which is exactly what a
        // CANCELLED order escrowing NFT token id 0 against NFT token id 0 also
        // reads as - that receipt claimed FILLED, and its bar claimed 100%.
        if (!p.active) {
            return p.settled ? ("FILLED", PositionSVG.FILLED) : ("CLOSED", PositionSVG.CLOSED);
        }
        // FROZEN outranks EXPIRED, matching Dutchboard: an order that is both
        // used to draw a different headline and a different accent on the two
        // boards, which is exactly the family consistency the shared palette
        // exists to hold. A suspended claim is the fact the holder can act on.
        if (p.frozen) return ("FROZEN", PositionSVG.FROZEN);
        if (p.expiry != 0 && p.expiry < block.timestamp) return ("EXPIRED", PositionSVG.EXPIRED);
        return ("OPEN", PositionSVG.LIVE);
    }

    /// @dev The order's remaining terms, in the space a status line cannot
    ///      carry: divisibility, and whether the claim is merely soft-frozen or
    ///      bound until a timestamp nobody - the owner included - can shorten.
    ///
    ///      Access is deliberately NOT here. It used to append "/ PRIVATE", but
    ///      the footer now names the taker outright on every card, so the tag
    ///      said the same thing a second time and less precisely. This line is
    ///      about how the order fills; that one is about who may fill it.
    function _tags(RenderParams memory p) private view returns (string memory tags) {
        tags = p.partialFill ? "PARTIAL FILL" : "ALL OR NOTHING";
        if (p.frozenUntil > block.timestamp) {
            tags = string.concat(tags, " / BOUND UNIX ", LibString.toString(p.frozenUntil));
        } else if (p.frozen) {
            tags = string.concat(tags, " / FROZEN");
        }
    }

    /// @dev How much of the current ask has been paid, in basis points.
    function _progress(RenderParams memory p) private pure returns (uint256) {
        // A settled order is complete whatever its legs read. A cancelled one
        // keeps whatever it managed to fill first, which is the honest number.
        if (p.settled) return 10_000;
        // An NFT leg has no ratio to measure - and its amount is a token id
        // rather than a quantity - so it reads as untouched unless settled.
        if (p.nftA || p.nftB) return 0;
        // A reprice rebases `initialAmountB`, so `amountB` is never above it in
        // practice. Clamped anyway: an immutable renderer must not be the reason
        // a receipt becomes unreadable if the board ever writes them out of step.
        if (p.initialAmountB == 0 || p.amountB >= p.initialAmountB) return 0;
        return ((p.initialAmountB - p.amountB) * 10_000) / p.initialAmountB;
    }
}

interface ISwapboard {
    function orders(uint256)
        external
        view
        returns (address, bool, bool, uint64, bool, bool, address, address, uint256, address, uint256);
    function initialAmountB(uint256) external view returns (uint256);
    function tokenDecimals(address) external view returns (uint8);
    function tokenSymbols(address) external view returns (string memory);
    function settled(uint256) external view returns (bool);
    function frozenUntil(uint256) external view returns (uint64);
    function frozen(uint256) external view returns (bool);
}
