// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {LibString} from "../../lib/solady/src/utils/LibString.sol";
import {PositionSVG} from "./PositionSVG.sol";

/// @notice Immutable renderer deployed by each Swapboard instance.
/// @dev Keeping presentation code separate lets the position board remain
///      deployable under EIP-170 without making metadata upgradeable.
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
        bool active;
        bool partialFill;
        bool nftA;
        bool nftB;
        bool frozen;
        bool restricted;
    }

    function tokenURI(RenderParams calldata p) external view returns (string memory) {
        (string memory status, string memory accent) = _state(p);
        uint256 progress = _progress(p);
        // No width or height: the card scales to whatever box a wallet or
        // marketplace gives it, from a list thumbnail up to a full screen.
        string memory svg = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 600 320'><rect width='600' height='320' fill='#0b0e13'/><g fill='#fff' font-family='Helvetica,Arial,sans-serif'><text x='24' y='42' font-size='20' font-weight='700'>SWAPBOARD / #",
            LibString.toString(p.id), "</text><text x='24' y='64' font-size='12' fill='", accent, "'>", status,
            "</text><text x='24' y='84' font-size='11' fill='#8b94a3'>", _tags(p),
            "</text><text x='24' y='120' font-size='12' fill='#8b94a3'>ESCROW</text><text x='24' y='148' font-size='20'>",
            PositionSVG.amount(p.amountA, p.decimalsA, p.nftA), "</text><text x='24' y='168' font-size='11' fill='#8b94a3'>",
            PositionSVG.shortAddress(p.tokenA), _leg(p.nftA, p.symbolA),
            "</text><text x='322' y='120' font-size='12' fill='#8b94a3'>REQUEST</text><text x='322' y='148' font-size='20'>",
            PositionSVG.amount(p.amountB, p.decimalsB, p.nftB), "</text><text x='322' y='168' font-size='11' fill='#8b94a3'>",
            PositionSVG.shortAddress(p.tokenB), _leg(p.nftB, p.symbolB),
            "</text><text x='24' y='212' font-size='12' fill='#8b94a3'>FILL ", _percent(progress),
            "</text><rect x='24' y='222' width='552' height='10' fill='#232833'/><rect x='24' y='222' width='",
            LibString.toString((552 * progress) / 10_000), "' height='10' fill='", accent,
            "'/><text x='24' y='270' font-size='12'>MAKER ", PositionSVG.makerLabel(p.maker),
            "</text><text x='24' y='292' font-size='12' fill='#8b94a3'>EXP ", p.expiry == 0 ? "NEVER" : string.concat("UNIX ", LibString.toString(p.expiry)),
            "</text></g></svg>"
        );
        return PositionSVG.dataURI(
            "application/json",
            string.concat(
                '{"name":"Swapboard Position #',
                LibString.toString(p.id),
                '","description":"A live escrowed order on Swapboard. The holder of this receipt is the maker: they own the escrow, its proceeds, and the right to reprice or cancel.","image":"',
                PositionSVG.dataURI("image/svg+xml", svg),
                '","attributes":[{"trait_type":"Status","value":"',
                status,
                '"},{"trait_type":"Escrow","value":"',
                p.nftA ? "ERC721" : "ERC20",
                '"},{"trait_type":"Request","value":"',
                p.nftB ? "ERC721" : "ERC20",
                '"},{"trait_type":"Fill","value":"',
                p.partialFill ? "Partial" : "All or nothing",
                '"},{"trait_type":"Access","value":"',
                p.restricted ? "Private" : "Public",
                '"}]}'
            )
        );
    }

    /// @dev The one headline state. Everything a state can coincide with -
    ///      private, frozen, divisible - is a tag rather than a status, so no
    ///      combination of them can hide another.
    function _state(RenderParams calldata p) private view returns (string memory, string memory) {
        // A full fill zeroes both legs; every other close keeps the last live
        // terms. Checking only `amountB` would misreport a cancelled order
        // whose ask was NFT token id 0.
        if (!p.active) return (p.amountA | p.amountB) == 0 ? ("FILLED", "#6fa8ff") : ("CLOSED", "#969da7");
        if (p.expiry != 0 && p.expiry < block.timestamp) return ("EXPIRED", "#ffb55b");
        if (p.frozen) return ("FROZEN", "#c69cff");
        return ("OPEN", "#43d69b");
    }

    /// @dev The order's remaining terms, in the space a status line cannot
    ///      carry: divisibility, whether it is reserved for one taker, and
    ///      whether the claim is merely soft-frozen or bound until a timestamp
    ///      nobody - the owner included - can shorten.
    function _tags(RenderParams calldata p) private view returns (string memory tags) {
        tags = p.partialFill ? "PARTIAL FILL" : "ALL OR NOTHING";
        if (p.restricted) tags = string.concat(tags, " / PRIVATE");
        if (p.frozenUntil > block.timestamp) {
            tags = string.concat(tags, " / BOUND UNIX ", LibString.toString(p.frozenUntil));
        } else if (p.frozen) {
            tags = string.concat(tags, " / FROZEN");
        }
    }

    /// @dev The captured symbol when there is one, otherwise the leg's kind.
    ///      Symbols are only snapshotted for NFT legs, where the collection is
    ///      the identity; a fungible leg is identified by its amount instead.
    function _leg(bool isNFT, string calldata symbol) private pure returns (string memory) {
        if (!isNFT) return " / ERC20";
        return bytes(symbol).length == 0 ? " / NFT" : string.concat(" / ", symbol);
    }

    /// @dev Basis points as a percentage, with the hundredths padded: 1005 is
    ///      10.05%, not 10.5%.
    function _percent(uint256 bps) private pure returns (string memory) {
        uint256 fraction = bps % 100;
        return string.concat(
            LibString.toString(bps / 100), ".", fraction < 10 ? "0" : "", LibString.toString(fraction), "%"
        );
    }

    /// @dev How much of the current ask has been paid, in basis points.
    function _progress(RenderParams calldata p) private pure returns (uint256) {
        // An NFT leg has no ratio to measure - and its amount is a token id
        // rather than a quantity - so it reads as untouched or settled in full.
        if (p.nftA || p.nftB) return !p.active && (p.amountA | p.amountB) == 0 ? 10_000 : 0;
        if (p.initialAmountB == 0) return 0;
        return ((p.initialAmountB - p.amountB) * 10_000) / p.initialAmountB;
    }
}
