// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListPage} from "../src/utils/TokenListPage.sol";

/// @notice Builds, executes and previews the DAI listing multicall for the src_co
///         multisig. Run against live mainnet state:
///           forge test --match-contract DaiTx -vv
/// @dev Two artifacts come out of one run, which is the point: the calldata that gets
///      broadcast is produced by the same test that proves what it does, and the
///      preview page is rendered by the LIVE renderer at the live registry rather than
///      by a local build that might differ.
contract DaiTxTest is Test {
    using LibString for string;

    address constant REG = 0x0000006013dF75A31678B786061C2B54bf531524;
    address constant PAGE = 0x000000B06Bc63Ef8830645D4524cd0d0Ae824b3d;
    address constant SAFE = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // Local listings are keyed by the address itself.
    uint256 constant ID = uint256(uint160(DAI));

    uint24 constant COLOR = 0xF4B731; // canonical Dai yellow
    // Sparse by 1,000. USDT holds 994000 and BOLD 993000, so 993500 seats DAI inside
    // the stablecoin cluster rather than at the tail of the list.
    uint32 constant RANK = 993_500;
    string constant URL = "https://sky.money";
    string constant DESC = "Decentralized stablecoin soft-pegged to the US dollar and issued by the Maker"
        " Protocol against onchain collateral. Anyone can mint Dai by locking collateral in a vault and"
        " burn it to redeem, with no issuer able to freeze a balance.";

    function test_DaiListing() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")));

        string memory svg = vm.readFile("./dapp/tokenlist/marks/dai.svg").replace("\n", "");

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(TokenList.list, (DAI, COLOR, RANK, "", URL, DESC));
        calls[1] = abi.encodeCall(TokenList.setLogoSVG, (ID, svg));
        bytes memory cd = abi.encodeWithSignature("multicall(bytes[])", calls);

        vm.writeFile("./deploy/DAI-list.calldata.txt", vm.toString(cd));
        emit log_named_uint("calldata bytes", cd.length);
        emit log_named_bytes32("calldata sha256", sha256(cd));

        TokenList reg = TokenList(payable(REG));
        if (reg.isListed(ID)) {
            emit log("already listed - simulation skipped");
            return;
        }

        uint256 jsonBefore = _count(TokenListPage(PAGE).tokenListJson());
        uint256 before_ = reg.total();

        uint256 g = gasleft();
        vm.prank(SAFE);
        (bool ok,) = REG.call(cd);
        emit log_named_uint("gas used", g - gasleft());
        assertTrue(ok, "multicall reverted");

        // Canonical facts, all read from the token by `list` itself rather than
        // supplied by the curator: this is what earns the card's onchain chip.
        TokenList.Token memory t = reg.get(ID);
        assertEq(reg.total(), before_ + 1, "not listed");
        assertEq(t.name, "Dai Stablecoin");
        assertEq(t.symbol, "DAI");
        assertEq(t.decimals, 18);
        assertEq(t.account, bytes32(uint256(uint160(DAI))));
        assertEq(t.chainId, 1);
        assertTrue(t.kind == TokenList.Kind.EVM, "kind not EVM");
        assertTrue(t.standard == TokenList.Standard.ERC20, "standard not ERC20");
        assertTrue(t.synced, "must claim onchain sync");
        assertEq(t.color, COLOR);
        assertEq(t.rank, RANK);
        assertEq(t.url, URL);
        assertTrue(t.logo.startsWith("data:image/svg+xml;base64,"), "logo not an inline data SVG");
        assertEq(bytes(t.description).length, bytes(DESC).length, "description was clipped or filtered");

        // Soulbound to its subject.
        assertEq(reg.ownerOf(ID), DAI, "card must be held by the token");

        // Position: directly after USDT, before BOLD.
        uint256[] memory ids = reg.rankedIds();
        uint256 pos;
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == ID) pos = i + 1;
        }
        assertEq(pos, 8, "not seated after USDT");
        emit log_named_uint("position", pos);

        // DAI is an EVM ERC-20, so unlike TAC it SHOULD reach the integrator feed.
        assertEq(_count(TokenListPage(PAGE).tokenListJson()), jsonBefore + 1, "missing from tokenlist.json");

        assertGt(bytes(reg.tokenURI(ID)).length, 0, "tokenURI empty");

        vm.prank(address(0xBAD));
        (bool ok2,) = REG.call(cd);
        assertFalse(ok2, "non-owner could list");
        emit log("guard: non-owner reverts");

        _writePreview(reg);
    }

    /// @dev Full ranked set, so the DAI card can be checked in the company it will
    ///      keep. Every card is the live renderer's own output, decoded in the browser
    ///      exactly as a marketplace decodes it.
    function _writePreview(TokenList reg) internal {
        uint256[] memory ids = reg.rankedIds();
        string memory rows = "";
        for (uint256 i; i < ids.length; ++i) {
            TokenList.Token memory t = reg.get(ids[i]);
            rows = string.concat(
                rows,
                i == 0 ? "" : ",",
                '{"id":"',
                LibString.toString(ids[i]),
                '","asset":"',
                // A non-EVM account fills the whole word, so 20 bytes would truncate it.
                LibString.toHexString(uint256(t.account), t.kind == TokenList.Kind.EVM ? 20 : 32),
                '","holder":"',
                LibString.toHexString(reg.ownerOf(ids[i])),
                '","rank":',
                LibString.toString(t.rank),
                ',"synced":',
                t.synced ? "true" : "false",
                ',"isNew":',
                ids[i] == ID ? "true" : "false",
                ',"logo":"',
                t.logo,
                '","uri":"',
                reg.tokenURI(ids[i]),
                '"}'
            );
        }
        vm.writeFile("./dapp/tokenlist/dai-preview.html", string.concat(_head(), "const TOKENS=[", rows, "];", _tail()));
    }

    function _count(string memory j) internal pure returns (uint256 n) {
        bytes memory b = bytes(j);
        for (uint256 i; i + 8 < b.length; ++i) {
            if (
                b[i] == '"' && b[i + 1] == 'c' && b[i + 2] == 'h' && b[i + 3] == 'a' && b[i + 4] == 'i'
                    && b[i + 5] == 'n' && b[i + 6] == 'I' && b[i + 7] == 'd'
            ) ++n;
        }
    }

    function _head() internal pure returns (string memory) {
        return "<!doctype html><html lang='en'><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<title>TokenList - DAI listing preview</title><style>"
            ":root{color-scheme:dark;--bg:#0b0b0d;--panel:#141417;--line:#2a2a30;--dim:#8b8b95;--fg:#f2f2f5}"
            "*{box-sizing:border-box}"
            "body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}"
            ".wrap{max-width:1180px;margin:0 auto;padding:32px 20px 64px}" "h1{font-size:20px;margin:0 0 4px}"
            ".sub{color:var(--dim);margin:0 0 28px}" ".sub code{color:var(--fg)}"
            "h2{font-size:13px;letter-spacing:.14em;text-transform:uppercase;color:var(--dim);"
            "margin:36px 0 14px;padding-bottom:8px;border-bottom:1px solid var(--line)}"
            ".grid{display:grid;gap:20px;grid-template-columns:repeat(auto-fill,minmax(320px,1fr))}"
            ".card{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}"
            ".card.new{border-color:#F4B731;box-shadow:0 0 0 1px #F4B731}"
            ".card img.art{display:block;width:100%;height:auto;background:#000}" ".meta{padding:14px 16px}"
            ".meta .nm{font-weight:700;margin-bottom:2px}" ".meta .ds{color:var(--dim);font-size:12px;min-height:32px}"
            ".traits{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}"
            ".tr{border:1px solid var(--line);border-radius:6px;padding:3px 7px;font-size:11px;color:var(--dim)}"
            ".tr b{color:var(--fg);font-weight:600}" "a{color:#7aa2ff}" "table{width:100%;border-collapse:collapse}"
            "td,th{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line);font-size:13px}"
            "th{color:var(--dim);font-weight:400;font-size:11px;letter-spacing:.1em;text-transform:uppercase}"
            "tr.new td{background:#1d1a10}" ".tk{display:flex;align-items:center;gap:10px}"
            ".tk img{width:22px;height:22px;border-radius:50%}" ".addr{color:var(--dim);font-size:12px}"
            ".pill{font-size:11px;border-radius:999px;padding:2px 8px;border:1px solid var(--line);color:var(--dim)}"
            ".ok{color:#63d77d;border-color:#2c5c38}" ".tag{color:#F4B731;font-size:11px;margin-left:6px}"
            "</style></head><body><div class='wrap'>" "<h1>TokenList &mdash; DAI listing preview</h1>"
            "<p class='sub'>Live registry state on a mainnet fork with the multisig calldata applied. "
            "Cards come from the deployed renderer and are decoded here the way a marketplace does: "
            "base64 &rarr; JSON &rarr; <code>image</code>. The DAI row is highlighted.</p><script>";
    }

    function _tail() internal pure returns (string memory) {
        return "\n" "const dec=u=>JSON.parse(atob(u.slice('data:application/json;base64,'.length)));\n"
            "const esc=s=>String(s).replace(/[&<>\"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c]));\n"
            "const short=a=>a.slice(0,6)+'\\u2026'+a.slice(-4);\n"
            "const ZERO='0x0000000000000000000000000000000000000000';\n"
            "const parsed=TOKENS.map(t=>({...t,json:dec(t.uri)}));\n"
            "document.write(\"<h2>The new listing</h2><div class='grid'>\"+parsed.filter(t=>t.isNew).map(card).join('')+\"</div>\");\n"
            "document.write(\"<h2>The full list as a gallery shows it</h2><div class='grid'>\"+parsed.map(card).join('')+\"</div>\");\n"
            "function card(t){\n" "  const j=t.json;\n"
            "  const traits=(j.attributes||[]).map(a=>`<span class='tr'>${esc(a.trait_type)} <b>${esc(a.value)}</b></span>`).join('');\n"
            "  const link=j.external_url?` &middot; <a href='${esc(j.external_url)}'>site</a>`:'';\n"
            "  return `<div class='card${t.isNew?' new':''}'><img class='art' src='${j.image}' alt='${esc(j.name)}'>`+\n"
            "    `<div class='meta'><div class='nm'>${esc(j.name)}${t.isNew?\"<span class='tag'>new</span>\":''}</div>`+\n"
            "    `<div class='ds'>${esc(j.description||'')}</div>`+\n" "    `<div class='traits'>${traits}</div>`+\n"
            "    `<div class='addr' style='margin-top:10px'>asset ${t.asset==ZERO?'0x0 (native ETH)':short(t.asset)}`+\n"
            "    ` &middot; card held by ${short(t.holder)}${link}</div>`+\n" "    `</div></div>`;\n" "}\n"
            "document.write(\"<h2>As an explorer shows it (token row)</h2>\"+\n"
            "  \"<table><tr><th>Token</th><th>Asset address</th><th>Card held by</th><th>Rank</th><th>Source</th></tr>\"+\n"
            "  parsed.map(t=>{\n" "    const j=t.json, sym=(j.attributes.find(a=>a.trait_type=='Symbol')||{}).value;\n"
            "    const dec_=(j.attributes.find(a=>a.trait_type=='Decimals')||{}).value;\n"
            "    const standard=(j.attributes.find(a=>a.trait_type=='Token Standard')||{}).value||'Unknown';\n"
            "    return `<tr class='${t.isNew?'new':''}'><td><div class='tk'><img src='${t.logo}' alt=''>`+\n"
            "      `<div><div>${esc(sym)}</div><div class='addr'>${esc(standard)}${standard=='ERC-20'||standard=='Native'?` &middot; ${esc(dec_)} decimals`:''}</div></div></div></td>`+\n"
            "      `<td class='addr'>${t.asset==ZERO?'0x0 (native)':short(t.asset)}</td>`+\n"
            "      `<td class='addr'>${short(t.holder)}</td><td>${t.rank}</td>`+\n"
            "      `<td><span class='pill ${t.synced?'ok':''}'>${t.synced?'onchain':'attested'}</span></td></tr>`;\n"
            "  }).join('')+\"</table>\");\n" "</script></div></body></html>";
    }
}
