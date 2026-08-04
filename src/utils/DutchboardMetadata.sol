// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {LibString} from "../../lib/solady/src/utils/LibString.sol";
import {PositionSVG} from "./PositionSVG.sol";

/// @notice Immutable renderer deployed by each Dutchboard instance.
/// @dev Same reasoning as `SwapboardMetadata`: presentation code is most of the
///      board's bytecode and none of its risk, so it lives out here and the
///      board stays deployable under EIP-170 without making metadata
///      upgradeable. The board passes a fully resolved snapshot — every
///      untrusted read (decimals, symbol) already happened at listing time — so
///      this contract calls nothing.
contract DutchboardMetadata {
    struct RenderParams {
        uint256 id;
        address seller; // holder when the listing has closed
        address token;
        address quote;
        uint256 lotSize; // NFT bundle size, unused for ERC-20 lots
        uint128 remaining;
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
        bool isNFT;
        bool live;
        bool settled;
        bool frozen;
    }

    function tokenURI(RenderParams calldata p) external view returns (string memory) {
        (string memory status, string memory accent) = _state(p);
        uint256 curveEnd = 258 + (46 * (uint256(p.startPrice) - p.endPrice)) / p.startPrice;
        string memory assetLabel = p.isNFT && bytes(p.tokenSymbol).length != 0
            ? string.concat("NFT / ", p.tokenSymbol)
            : PositionSVG.assetType(p.tokenDecimals, p.isNFT);
        string memory svg = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 720 420'><rect width='720' height='420' fill='#000'/><g fill='none' stroke='#fff' stroke-width='2'><rect x='18' y='18' width='684' height='384'/><path d='M18 88h684M18 326h684M360 112v118'/><path id='c' d='M32 258Q360 258 688 ",
            LibString.toString(curveEnd),
            "' pathLength='100' opacity='.3'/><use href='#c' stroke='",
            accent,
            "' opacity='1' stroke-linecap='round' stroke-dasharray='",
            LibString.toString(p.decayProgress / 100),
            ".",
            LibString.toString(p.decayProgress % 100),
            " 100'/></g><g fill='#fff' font-family='Helvetica,Arial,sans-serif'><text x='32' y='55' font-size='25' font-weight='700'>DUTCHBOARD / POSITION #",
            LibString.toString(p.id),
            "</text><text x='32' y='77' font-size='12'>DECAYING LOT // <tspan fill='",
            accent,
            "' font-weight='700'>",
            status,
            "</tspan></text><text x='32' y='132' font-size='12'>LOT REMAINING</text><text x='32' y='168' font-size='22'>",
            p.isNFT
                ? string.concat("BUNDLE ", LibString.toString(p.lotSize))
                : PositionSVG.amount(p.remaining, p.tokenDecimals, false),
            "</text><text x='32' y='190' font-size='13'>",
            PositionSVG.shortAddress(p.token),
            " / ",
            assetLabel,
            "</text><text x='384' y='132' font-size='12'>PRICE NOW</text><text x='384' y='168' font-size='22'>",
            p.live ? PositionSVG.amount(p.price, p.quoteDecimals, false) : "--",
            "</text><text x='384' y='190' font-size='13'>",
            p.quote == address(0) ? "ETH" : PositionSVG.shortAddress(p.quote),
            "</text><text x='32' y='238' font-size='12'>DUTCH CURVE  <tspan fill='",
            accent,
            "' font-weight='700'>",
            LibString.toString(p.decayProgress / 100),
            ".",
            LibString.toString(p.decayProgress % 100),
            "%</tspan></text><text x='384' y='238' font-size='12'>LOT FILLED  <tspan fill='",
            accent,
            "' font-weight='700'>",
            LibString.toString(p.fillProgress / 100),
            ".",
            LibString.toString(p.fillProgress % 100),
            "%</tspan></text><text x='32' y='350' font-size='12'>",
            p.live ? "SELLER  " : "HOLDER  ",
            PositionSVG.makerLabel(p.seller),
            "</text><text x='32' y='374' font-size='12'>END ",
            LibString.toString(uint256(p.startTime) + p.duration),
            "</text></g></svg>"
        );
        return PositionSVG.dataURI(
            "application/json",
            string.concat(
                '{"name":"Dutchboard Position #',
                LibString.toString(p.id),
                '","image":"',
                PositionSVG.dataURI("image/svg+xml", svg),
                '"}'
            )
        );
    }

    /// @dev FROZEN outranks the schedule states: the underlying live position
    ///      settled, so the curve is no longer what a holder is looking at.
    function _state(RenderParams calldata p) private view returns (string memory, string memory) {
        if (!p.live) return p.settled ? ("FILLED", "#6fa8ff") : ("CLOSED", "#969da7");
        if (p.frozen) return ("FROZEN", "#c69cff");
        // A hard expiry outranks the curve: an expired listing is unfillable
        // whatever the schedule would otherwise be showing.
        if (p.expiry != 0 && block.timestamp > p.expiry) return ("EXPIRED", "#ff8f8f");
        if (block.timestamp < p.startTime) return ("SCHEDULED", "#6fa8ff");
        if (block.timestamp >= uint256(p.startTime) + p.duration) {
            return p.endPrice == 0 ? ("FREE", "#5ee6d2") : ("FLOOR", "#ffb55b");
        }
        return ("LIVE", "#43d69b");
    }
}
