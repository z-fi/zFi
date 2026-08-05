// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {LibString} from "../../lib/solady/src/utils/LibString.sol";
import {DateTimeLib} from "../../lib/solady/src/utils/DateTimeLib.sol";
import {TokenList} from "./TokenList.sol";

/// @title TokenListPage
/// @notice Permanently-deployed onchain HTML front end for the TokenList registry.
/// @dev Architecture mirrors zSwap: the page is the runtime bytecode of two data
///      contracts, deployed separately and passed to the constructor. html()
///      reassembles them via EXTCODECOPY, and request() implements ERC-5219 so
///      web3:// gateways (ERC-4804) serve it directly. Splitting across two data
///      contracts means EIP-170 caps each chunk, not the page (24576 B per chunk).
///
///      The page itself holds no registry address logic beyond a constant: it
///      reads TokenList over ordinary eth_call, so this contract stores markup
///      and nothing else. It is immutable — there is no owner and no setter.
///
/// HOW TO READ THE DAPP
///   cast call <addr> "html()(string)" --rpc-url <rpc> > page.html
///   # then open page.html in any browser
contract TokenListPage {
    string public constant NAME = "TokenListPage";
    string public constant VERSION = "0.1";

    /// @dev The registry this page reads. A constant rather than a constructor arg:
    ///      the page's own markup hardcodes the same address, and a wrapper pointed at
    ///      a different registry than the document it serves would be a liability, not
    ///      a feature.
    TokenList public constant REGISTRY = TokenList(0x0000006013dF75A31678B786061C2B54bf531524);

    /// @dev The markup lives in four data contracts whose runtime bytecode IS the
    /// page. They are deployed independently and passed in, so this wrapper's own
    /// creation bytecode stays small and cheap to deploy.
    address public immutable DATA1;
    address public immutable DATA2;
    address public immutable DATA3;
    address public immutable DATA4;

    /// @dev A missing or duplicated data chunk would permanently serve broken HTML.
    error InvalidData();

    struct KeyValue {
        string key;
        string value;
    }

    constructor(address data1, address data2, address data3, address data4) {
        address[4] memory d = [data1, data2, data3, data4];
        for (uint256 i; i != 4; ++i) {
            if (d[i].code.length == 0) revert InvalidData();
            for (uint256 j = i + 1; j != 4; ++j) {
                if (d[i] == d[j]) revert InvalidData();
            }
        }
        DATA1 = data1;
        DATA2 = data2;
        DATA3 = data3;
        DATA4 = data4;
    }

    function html() external view returns (string memory) {
        return _html();
    }

    /// @notice ERC-5219 request handler.
    /// @dev Two routes, because two audiences:
    ///
    ///        /                  the dapp, as HTML
    ///        /tokenlist.json    the Uniswap tokenlist.org schema, as JSON
    ///
    ///      The second is the point of a canonical list: a swap frontend can ingest
    ///      `https://<addr>.w4eth.io/tokenlist.json` directly, with no key, no
    ///      indexer and nobody's server in the path. Anything else falls through to
    ///      the page, so a gateway that appends a path still serves the dapp.
    ///
    ///      Cache hints differ on purpose. The HTML is the contract's own bytecode
    ///      and is byte-identical forever, so it is `immutable`. The JSON is composed
    ///      from live registry state and changes whenever a listing does — marking it
    ///      immutable would strand consumers on a stale list.
    function request(string[] memory resource, KeyValue[] memory /*params*/ )
        external
        view
        returns (uint16 statusCode, string memory body, KeyValue[] memory headers)
    {
        statusCode = 200;
        headers = new KeyValue[](2);
        if (resource.length != 0 && _eq(resource[0], "tokenlist.json")) {
            body = tokenListJson();
            headers[0] = KeyValue("Content-Type", "application/json");
            headers[1] = KeyValue("Cache-Control", "public, max-age=300");
        } else {
            body = _html();
            headers[0] = KeyValue("Content-Type", "text/html");
            headers[1] = KeyValue("Cache-Control", "public, max-age=31536000, immutable");
        }
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    /// @notice ERC-4804/5219 resolution mode. Returns bytes32("5219") to signal
    ///         that web3:// gateways should call request() per the ERC-5219
    ///         interface, rather than auto-mode URL-to-function resolution.
    function resolveMode() external pure returns (bytes32) {
        return "5219";
    }

    /// @dev Reassembles the page from all four chunks in one pass: each chunk is
    /// copied directly after the previous one at the string body, so no
    /// intermediate copy or concatenation is needed. An empty trailing chunk is
    /// harmless — it copies zero bytes — so the page may shrink below what three
    /// chunks need without this having to change.
    function _html() private view returns (string memory s) {
        address d1 = DATA1;
        address d2 = DATA2;
        address d3 = DATA3;
        address d4 = DATA4;
        assembly ("memory-safe") {
            let n1 := extcodesize(d1)
            let n2 := extcodesize(d2)
            let n3 := extcodesize(d3)
            let n12 := add(n1, n2)
            let n123 := add(n12, n3)
            let total := add(n123, extcodesize(d4))
            s := mload(0x40)
            mstore(s, total) // total string length
            let body := add(s, 0x20)
            extcodecopy(d1, body, 0, n1)
            extcodecopy(d2, add(body, n1), 0, n2)
            extcodecopy(d3, add(body, n12), 0, n3)
            extcodecopy(d4, add(body, n123), 0, extcodesize(d4))
            let padded := and(add(total, 0x1f), not(0x1f))
            mstore(0x40, add(body, padded)) // bump free memory pointer
        }
    }

    // TOKEN LIST -----------------------------------------------------------
    /// @notice The registry as a tokenlist.org-schema JSON document.
    /// @dev Filtered to what that schema actually means: deployed ERC-20s with an EVM
    ///      account. The native asset and the ERC-721/1155 collections are excluded on
    ///      purpose — a token list carrying address 0 or an NFT breaks consumers that
    ///      assume neither. Entries missing a name, a symbol, or an account are
    ///      dropped rather than emitted broken.
    ///
    ///      Intended for `eth_call`. It reads every listing, so it costs real gas in a
    ///      transaction and is not meant to be called from one.
    function tokenListJson() public view returns (string memory out) {
        uint256[] memory ids = REGISTRY.rankedIds();
        string memory toks;
        uint256 kept;
        for (uint256 i; i != ids.length; ++i) {
            TokenList.Token memory t = REGISTRY.get(ids[i]);
            if (!t.deployed) continue;
            if (t.kind != TokenList.Kind.EVM) continue;
            if (t.standard != TokenList.Standard.ERC20) continue;
            if (t.account == bytes32(0)) continue;
            if (bytes(t.name).length == 0 || bytes(t.symbol).length == 0) continue;
            toks = string.concat(
                toks,
                kept == 0 ? "" : ",",
                '{"chainId":',
                LibString.toString(t.chainId),
                ',"address":"',
                LibString.toHexStringChecksummed(address(uint160(uint256(t.account)))),
                '","name":"',
                t.name,
                '","symbol":"',
                t.symbol,
                '","decimals":',
                LibString.toString(t.decimals),
                _logo(t.logo),
                "}"
            );
            unchecked {
                ++kept;
            }
        }
        // tokenlist.org semver: minor moves when tokens are added. Deriving it from the
        // count makes the version track the registry instead of sitting at 1.0.0 and
        // telling a consumer nothing ever changed.
        out = string.concat(
            '{"name":"TokenList","timestamp":"',
            _iso8601(block.timestamp),
            '","version":{"major":1,"minor":',
            LibString.toString(kept),
            ',"patch":0},"keywords":["onchain","ethereum","erc20","tokenlist"],"tokens":[',
            toks,
            "]}"
        );
    }

    /// @dev A logo only ships if its scheme can actually be rendered by a consumer.
    ///      The registry does not constrain the scheme, and a `javascript:` logoURI
    ///      handed to somebody else's frontend is their problem to discover.
    function _logo(string memory logo) private pure returns (string memory) {
        if (bytes(logo).length == 0) return "";
        if (
            !LibString.startsWith(logo, "https://") && !LibString.startsWith(logo, "ipfs://")
                && !LibString.startsWith(logo, "data:image/")
        ) return "";
        return string.concat(',"logoURI":"', logo, '"');
    }

    /// @dev The schema requires an ISO-8601 timestamp, so build one rather than emit a
    ///      unix integer a validator will reject.
    function _iso8601(uint256 ts) private pure returns (string memory) {
        (uint256 y, uint256 mo, uint256 d, uint256 h, uint256 mi, uint256 sec) =
            DateTimeLib.timestampToDateTime(ts);
        return string.concat(
            LibString.toString(y),
            "-",
            _pad2(mo),
            "-",
            _pad2(d),
            "T",
            _pad2(h),
            ":",
            _pad2(mi),
            ":",
            _pad2(sec),
            "Z"
        );
    }

    function _pad2(uint256 v) private pure returns (string memory) {
        return v < 10 ? string.concat("0", LibString.toString(v)) : LibString.toString(v);
    }
}
