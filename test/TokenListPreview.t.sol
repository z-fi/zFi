// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListRenderer} from "../src/utils/TokenListRenderer.sol";
import {PostDeployListings} from "./PostDeployListings.sol";

/// @notice Dumps the seeded listing cards to `dapp/tokenlist-preview.html`.
/// @dev The page embeds each `tokenURI` verbatim and decodes it in the browser the
///      same way a marketplace does — base64 -> JSON -> `image` -> `<img>`. Nothing
///      about the card is re-implemented in JavaScript, so what the gallery shows is
///      what OpenSea and Etherscan will show; if the contract's SVG breaks, so does
///      this page. Run with:
///        forge test --match-contract TokenListPreview
contract TokenListPreviewTest is Test, PostDeployListings {
    using LibString for string;

    TokenList list;
    address owner = address(0xA11CE);

    /// @dev Every test in this repo runs against the mainnet fork pinned in
    ///      `foundry.toml`, which is what makes the seeded set exist: seeding is
    ///      chain-id-1 only and each seed is skipped where the address has no
    ///      code. On a bare local chain the registry deploys empty and every
    ///      seed-dependent assertion here fails for a reason that has nothing to
    ///      do with the contract.
    ///      The constructor now seeds four of the eleven; the preview applies the
    ///      other seven exactly as the owner will after deployment, so the gallery
    ///      still shows the full set and still proves every card renders.
    function setUp() public {
        list = new TokenList(owner, new TokenListRenderer());
        Listing[] memory l = _postDeployListings();
        vm.startPrank(owner);
        for (uint256 i; i < l.length; ++i) {
            uint256 id = list.list(l[i].token, l[i].color, l[i].rank, "", l[i].url, l[i].description);
            list.setLogoSVG(id, l[i].logo);
            if (l[i].onchainSvg) list.setOnchainSvg(id, true);
        }
        vm.stopPrank();
    }

    function testWritePreview() public {
        // Give one listing an audit link and one a full-length description, so the
        // page shows both the optional line present and the wrapping at its limit.
        vm.startPrank(owner);
        list.setAudit(list.idOf(WSTETH), "https://github.com/lidofinance/audits");
        list.setArt(
            list.idOf(BOLD),
            0x63D77D,
            993_000,
            list.logoOf(list.idOf(BOLD)),
            "https://liquity.org",
            "Liquity v2 stablecoin, borrowed against staked Ether at a user-set rate,"
            " redeemable one to one against the collateral backing it at all times."
        );
        vm.stopPrank();

        uint256[] memory ids = list.rankedIds();

        string memory rows = "";
        for (uint256 i; i < ids.length; ++i) {
            TokenList.Token memory t = list.get(ids[i]);
            rows = string.concat(
                rows,
                i == 0 ? "" : ",",
                '{"id":"',
                LibString.toString(ids[i]),
                '","asset":"',
                LibString.toHexString(uint256(t.account), 20),
                '","holder":"',
                LibString.toHexString(list.ownerOf(ids[i])),
                '","rank":',
                LibString.toString(t.rank),
                ',"synced":',
                t.synced ? "true" : "false",
                ',"logo":"',
                t.logo,
                '","uri":"',
                list.tokenURI(ids[i]),
                '"}'
            );
        }

        vm.writeFile("./dapp/tokenlist-preview.html", string.concat(_head(), "const TOKENS=[", rows, "];", _tail()));
    }

    function _head() internal pure returns (string memory) {
        return "<!doctype html><html lang='en'><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<title>TokenList - listing cards</title><style>"
            ":root{color-scheme:dark;--bg:#0b0b0d;--panel:#141417;--line:#2a2a30;--dim:#8b8b95;--fg:#f2f2f5}"
            "*{box-sizing:border-box}"
            "body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}"
            ".wrap{max-width:1180px;margin:0 auto;padding:32px 20px 64px}" "h1{font-size:20px;margin:0 0 4px}"
            ".sub{color:var(--dim);margin:0 0 28px}" ".sub code{color:var(--fg)}"
            "h2{font-size:13px;letter-spacing:.14em;text-transform:uppercase;color:var(--dim);"
            "margin:36px 0 14px;padding-bottom:8px;border-bottom:1px solid var(--line)}"
            ".grid{display:grid;gap:20px;grid-template-columns:repeat(auto-fill,minmax(320px,1fr))}"
            ".card{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}"
            ".card img.art{display:block;width:100%;height:auto;background:#000}" ".meta{padding:14px 16px}"
            ".meta .nm{font-weight:700;margin-bottom:2px}" ".meta .ds{color:var(--dim);font-size:12px;min-height:32px}"
            ".traits{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}"
            ".tr{border:1px solid var(--line);border-radius:6px;padding:3px 7px;font-size:11px;color:var(--dim)}"
            ".tr b{color:var(--fg);font-weight:600}" "a{color:#7aa2ff}" "table{width:100%;border-collapse:collapse}"
            "td,th{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line);font-size:13px}"
            "th{color:var(--dim);font-weight:400;font-size:11px;letter-spacing:.1em;text-transform:uppercase}"
            ".tk{display:flex;align-items:center;gap:10px}" ".tk img{width:22px;height:22px;border-radius:50%}"
            ".addr{color:var(--dim);font-size:12px}"
            ".pill{font-size:11px;border-radius:999px;padding:2px 8px;border:1px solid var(--line);color:var(--dim)}"
            ".ok{color:#63d77d;border-color:#2c5c38}" "</style></head><body><div class='wrap'>"
            "<h1>TokenList &mdash; listing cards</h1>"
            "<p class='sub'>Rendered from live <code>tokenURI()</code> output on a mainnet fork. "
            "Each card below is decoded in the browser exactly as a marketplace does: "
            "base64 &rarr; JSON &rarr; <code>image</code>.</p><script>";
    }

    function _tail() internal pure returns (string memory) {
        return "\n" "const dec=u=>JSON.parse(atob(u.slice('data:application/json;base64,'.length)));\n"
            "const esc=s=>String(s).replace(/[&<>\"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c]));\n"
            "const short=a=>a.slice(0,6)+'\\u2026'+a.slice(-4);\n"
            "const ZERO='0x0000000000000000000000000000000000000000';\n"
            "const parsed=TOKENS.map(t=>({...t,json:dec(t.uri)}));\n"
            "document.write(\"<h2>As a gallery shows it (OpenSea)</h2><div class='grid'>\"+parsed.map(t=>{\n"
            "  const j=t.json;\n"
            "  const traits=(j.attributes||[]).map(a=>`<span class='tr'>${esc(a.trait_type)} <b>${esc(a.value)}</b></span>`).join('');\n"
            "  const link=j.external_url?` &middot; <a href='${esc(j.external_url)}'>site</a>`:'';\n"
            "  return `<div class='card'><img class='art' src='${j.image}' alt='${esc(j.name)}'>`+\n"
            "    `<div class='meta'><div class='nm'>${esc(j.name)}</div>`+\n"
            "    `<div class='ds'>${esc(j.description||'')}</div>`+\n" "    `<div class='traits'>${traits}</div>`+\n"
            "    `<div class='addr' style='margin-top:10px'>asset ${t.asset==ZERO?'0x0 (native ETH)':short(t.asset)}`+\n"
            "    ` &middot; card held by ${short(t.holder)}${link}</div>`+\n" "    `</div></div>`;\n"
            "}).join('')+\"</div>\");\n" "document.write(\"<h2>As an explorer shows it (Etherscan token row)</h2>\"+\n"
            "  \"<table><tr><th>Token</th><th>Asset address</th><th>Card held by</th><th>Rank</th><th>Source</th></tr>\"+\n"
            "  parsed.map(t=>{\n" "    const j=t.json, sym=(j.attributes.find(a=>a.trait_type=='Symbol')||{}).value;\n"
            "    const dec_=(j.attributes.find(a=>a.trait_type=='Decimals')||{}).value;\n"
            "    const standard=(j.attributes.find(a=>a.trait_type=='Token Standard')||{}).value||'Unknown';\n"
            "    return `<tr><td><div class='tk'><img src='${t.logo}' alt=''>`+\n"
            "      `<div><div>${esc(sym)}</div><div class='addr'>${esc(standard)}${standard=='ERC-20'||standard=='Native'?` &middot; ${esc(dec_)} decimals`:''}</div></div></div></td>`+\n"
            "      `<td class='addr'>${t.asset==ZERO?'0x0 (native)':short(t.asset)}</td>`+\n"
            "      `<td class='addr'>${short(t.holder)}</td><td>${t.rank}</td>`+\n"
            "      `<td><span class='pill ${t.synced?'ok':''}'>${t.synced?'onchain':'attested'}</span></td></tr>`;\n"
            "  }).join('')+\"</table>\");\n" "</script></div></body></html>";
    }
}
