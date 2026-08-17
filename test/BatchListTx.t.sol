// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListPage} from "../src/utils/TokenListPage.sol";

/// @notice Builds, executes and previews ONE multicall listing stETH, LUSD and ZAMM
///         for the src_co multisig. Run against live mainnet state:
///           forge test --match-contract BatchListTx -vv
/// @dev Same shape as `DaiTx`: the calldata that gets broadcast is produced by the
///      test that proves what it does, and the preview is rendered by the LIVE
///      renderer at the live registry rather than by a local build.
///
///      One transaction rather than three so the three listings land together and no
///      intermediate state — a listing without its art — is ever visible on chain.
contract BatchListTxTest is Test {
    using LibString for string;

    address constant REG = 0x0000006013dF75A31678B786061C2B54bf531524;
    address constant PAGE = 0x000000B06Bc63Ef8830645D4524cd0d0Ae824b3d;
    address constant SAFE = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;

    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant LUSD = 0x5f98805A4E8be255a32880FDeC7F6728C6568bA0;
    address constant ZAMM = 0xE9b1cFEA55BAA219e34301f2F31b9FD0921664ED;

    struct Item {
        address token;
        uint24 color;
        uint32 rank;
        string mark; // file under dapp/tokenlist/marks
        string url;
        string description;
        string name; // expected, read from the token by `list`
        string symbol;
        uint8 decimals;
    }

    function _items() internal pure returns (Item[] memory items) {
        items = new Item[](3);
        // Directly after wstETH (998000), before rETH (997000). The Lido mark is the
        // same art wstETH already carries, which is correct: it is one brand.
        items[0] = Item({
            token: STETH,
            color: 0x00A3FF,
            rank: 997_500,
            mark: "steth",
            url: "https://lido.fi",
            description: "Liquid staking token from Lido. Balances rebase as Ethereum staking rewards accrue, so"
                " one stETH tracks one staked Ether. Wrap to wstETH for the non-rebasing balance most DeFi"
                " integrations expect.",
            name: "Liquid staked Ether 2.0",
            symbol: "stETH",
            decimals: 18
        });
        // After BOLD (993000), before ZORG (992000). Liquity v1 sits below its own v2
        // stablecoin, which is the order the protocol itself puts them in.
        items[1] = Item({
            token: LUSD,
            color: 0x7B6AD6,
            rank: 992_500,
            mark: "lusd",
            url: "https://www.liquity.org",
            description: "Stablecoin of Liquity v1, borrowed against Ether at zero interest and redeemable one"
                " to one for the collateral behind it. The system is immutable: no governance, no admin keys, no"
                " upgrade path.",
            name: "LUSD Stablecoin",
            symbol: "LUSD",
            decimals: 18
        });
        // After ZORG (992000), before zOrgz (991000).
        items[2] = Item({
            token: ZAMM,
            color: 0xFFFFFF,
            rank: 991_500,
            mark: "zamm",
            url: "https://www.zamm.finance",
            description: "Community token for zAMM, first launched on v0 of the exchange.",
            name: "ZAMM",
            symbol: "ZAMM",
            decimals: 18
        });
    }

    function test_BatchListing() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")));

        // Only the ones still MISSING. This builds calldata to `list` three
        // tokens, and listing is not idempotent - the registry rejects an id it
        // already holds. Two of the three have since been listed for real, so the
        // multicall reverted and the suite reported "multicall reverted", which
        // reads like broken registry code and is actually the broadcast having
        // succeeded. A one-shot deploy artifact has to notice its own work
        // landing, or it turns into permanent red the moment it does its job.
        Item[] memory all = _items();
        TokenList regView = TokenList(payable(REG));
        uint256 pending;
        for (uint256 i; i < all.length; ++i) {
            if (!regView.isListed(uint256(uint160(all[i].token)))) ++pending;
        }
        if (pending == 0) {
            emit log("SKIP: every token in this batch is already listed - nothing left to broadcast");
            vm.skip(true);
        }
        Item[] memory items = new Item[](pending);
        uint256 k;
        for (uint256 i; i < all.length; ++i) {
            if (!regView.isListed(uint256(uint160(all[i].token)))) items[k++] = all[i];
        }
        emit log_named_uint("tokens still to list", items.length);

        bytes[] memory calls = new bytes[](items.length * 2);
        for (uint256 i; i < items.length; ++i) {
            Item memory it = items[i];
            string memory svg =
                vm.readFile(string.concat("./dapp/tokenlist/marks/", it.mark, ".svg")).replace("\n", "");
            calls[i * 2] = abi.encodeCall(TokenList.list, (it.token, it.color, it.rank, "", it.url, it.description));
            calls[i * 2 + 1] = abi.encodeCall(TokenList.setLogoSVG, (uint256(uint160(it.token)), svg));
        }
        bytes memory cd = abi.encodeWithSignature("multicall(bytes[])", calls);

        vm.writeFile("./deploy/BATCH-stETH-LUSD-ZAMM.calldata.txt", vm.toString(cd));
        emit log_named_uint("calldata bytes", cd.length);
        emit log_named_bytes32("calldata sha256", sha256(cd));

        TokenList reg = TokenList(payable(REG));
        uint256 jsonBefore = _count(TokenListPage(PAGE).tokenListJson());
        uint256 before_ = reg.total();

        uint256 g = gasleft();
        vm.prank(SAFE);
        (bool ok,) = REG.call(cd);
        emit log_named_uint("gas used", g - gasleft());
        assertTrue(ok, "multicall reverted");
        assertEq(reg.total(), before_ + items.length, "not all listed");

        for (uint256 i; i < items.length; ++i) {
            Item memory it = items[i];
            uint256 id = uint256(uint160(it.token));
            TokenList.Token memory t = reg.get(id);
            // Canonical text is READ FROM THE TOKEN by `list`, not supplied here; these
            // assertions check that what the token says is what the card will show.
            assertEq(t.name, it.name, "name");
            assertEq(t.symbol, it.symbol, "symbol");
            assertEq(t.decimals, it.decimals, "decimals");
            assertEq(t.account, bytes32(uint256(uint160(it.token))), "account");
            assertEq(t.chainId, 1, "chainId");
            assertTrue(t.kind == TokenList.Kind.EVM, "kind not EVM");
            assertTrue(t.standard == TokenList.Standard.ERC20, "standard not ERC20");
            assertTrue(t.synced, "must claim onchain sync");
            assertEq(t.color, it.color, "color");
            assertEq(t.rank, it.rank, "rank");
            assertEq(t.url, it.url, "url");
            assertTrue(t.logo.startsWith("data:image/svg+xml;base64,"), "logo not an inline data SVG");
            assertEq(bytes(t.description).length, bytes(it.description).length, "description clipped or filtered");
            assertEq(reg.ownerOf(id), it.token, "card must be held by the token");
            assertGt(bytes(reg.tokenURI(id)).length, 0, "tokenURI empty");
        }

        // Ranks are the whole point of a batch like this: check the SEATING, not just
        // that the listings exist. A rank that collides or lands in the wrong gap is
        // invisible in per-listing assertions and obvious here.
        string[] memory order = _symbols(reg);
        assertEq(order[2], "wstETH");
        assertEq(order[3], "stETH");
        assertEq(order[4], "rETH");
        assertEq(order[8], "DAI");
        assertEq(order[9], "BOLD");
        assertEq(order[10], "LUSD");
        assertEq(order[11], "ZORG");
        assertEq(order[12], "ZAMM");
        assertEq(order[13], "zzz"); // zOrgz
        for (uint256 i; i < order.length; ++i) {
            emit log_named_string(string.concat("rank ", LibString.toString(i + 1)), order[i]);
        }
        _assertRanksDistinct(reg);

        // All three are EVM ERC-20s, so all three SHOULD reach the integrator feed.
        assertEq(_count(TokenListPage(PAGE).tokenListJson()), jsonBefore + items.length, "missing from tokenlist.json");

        vm.prank(address(0xBAD));
        (bool ok2,) = REG.call(cd);
        assertFalse(ok2, "non-owner could list");
        emit log("guard: non-owner reverts");

        _writePreview(reg);
    }

    function _symbols(TokenList reg) internal view returns (string[] memory out) {
        uint256[] memory ids = reg.rankedIds();
        out = new string[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            out[i] = reg.get(ids[i]).symbol;
        }
    }

    /// @dev Ties are legal but break by array position, which `delist` can reshuffle.
    ///      Distinct ranks are what make the order above a promise.
    function _assertRanksDistinct(TokenList reg) internal {
        uint256[] memory ids = reg.rankedIds();
        for (uint256 i = 1; i < ids.length; ++i) {
            assertLt(reg.get(ids[i]).rank, reg.get(ids[i - 1]).rank, "rank collision");
        }
    }

    function _isNew(uint256 id) internal pure returns (bool) {
        return id == uint256(uint160(STETH)) || id == uint256(uint160(LUSD)) || id == uint256(uint160(ZAMM));
    }

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
                _isNew(ids[i]) ? "true" : "false",
                ',"logo":"',
                t.logo,
                '","uri":"',
                reg.tokenURI(ids[i]),
                '"}'
            );
        }
        vm.writeFile(
            "./dapp/tokenlist/batch-preview.html", string.concat(_head(), "const TOKENS=[", rows, "];", _tail())
        );
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
            "<title>TokenList - stETH / LUSD / ZAMM listing preview</title><style>"
            ":root{color-scheme:dark;--bg:#0b0b0d;--panel:#141417;--line:#2a2a30;--dim:#8b8b95;--fg:#f2f2f5}"
            "*{box-sizing:border-box}"
            "body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}"
            ".wrap{max-width:1180px;margin:0 auto;padding:32px 20px 64px}" "h1{font-size:20px;margin:0 0 4px}"
            ".sub{color:var(--dim);margin:0 0 28px}" ".sub code{color:var(--fg)}"
            "h2{font-size:13px;letter-spacing:.14em;text-transform:uppercase;color:var(--dim);"
            "margin:36px 0 14px;padding-bottom:8px;border-bottom:1px solid var(--line)}"
            ".grid{display:grid;gap:20px;grid-template-columns:repeat(auto-fill,minmax(320px,1fr))}"
            ".card{background:var(--panel);border:1px solid var(--line);border-radius:12px;overflow:hidden}"
            ".card.new{border-color:#7B6AD6;box-shadow:0 0 0 1px #7B6AD6}"
            ".card img.art{display:block;width:100%;height:auto;background:#000}" ".meta{padding:14px 16px}"
            ".meta .nm{font-weight:700;margin-bottom:2px}" ".meta .ds{color:var(--dim);font-size:12px;min-height:32px}"
            ".traits{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}"
            ".tr{border:1px solid var(--line);border-radius:6px;padding:3px 7px;font-size:11px;color:var(--dim)}"
            ".tr b{color:var(--fg);font-weight:600}" "a{color:#7aa2ff}" "table{width:100%;border-collapse:collapse}"
            "td,th{text-align:left;padding:10px 12px;border-bottom:1px solid var(--line);font-size:13px}"
            "th{color:var(--dim);font-weight:400;font-size:11px;letter-spacing:.1em;text-transform:uppercase}"
            "tr.new td{background:#17141d}" ".tk{display:flex;align-items:center;gap:10px}"
            ".tk img{width:22px;height:22px;border-radius:50%}" ".addr{color:var(--dim);font-size:12px}"
            ".pill{font-size:11px;border-radius:999px;padding:2px 8px;border:1px solid var(--line);color:var(--dim)}"
            ".ok{color:#63d77d;border-color:#2c5c38}" ".tag{color:#7B6AD6;font-size:11px;margin-left:6px}"
            "</style></head><body><div class='wrap'>" "<h1>TokenList &mdash; stETH / LUSD / ZAMM</h1>"
            "<p class='sub'>Live registry state on a mainnet fork with the multisig calldata applied. "
            "Cards come from the deployed renderer and are decoded here the way a marketplace does: "
            "base64 &rarr; JSON &rarr; <code>image</code>. The three new rows are highlighted, and the "
            "full list below shows where each one seats.</p><script>";
    }

    function _tail() internal pure returns (string memory) {
        return "\n" "const dec=u=>JSON.parse(atob(u.slice('data:application/json;base64,'.length)));\n"
            "const esc=s=>String(s).replace(/[&<>\"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;'}[c]));\n"
            "const short=a=>a.slice(0,6)+'\\u2026'+a.slice(-4);\n"
            "const ZERO='0x0000000000000000000000000000000000000000';\n"
            "const parsed=TOKENS.map(t=>({...t,json:dec(t.uri)}));\n"
            "document.write(\"<h2>The new listings</h2><div class='grid'>\"+parsed.filter(t=>t.isNew).map(card).join('')+\"</div>\");\n"
            "document.write(\"<h2>The full list as a gallery shows it</h2><div class='grid'>\"+parsed.map(card).join('')+\"</div>\");\n"
            "function card(t){\n" "  const j=t.json;\n"
            "  const traits=(j.attributes||[]).map(a=>`<span class='tr'>${esc(a.trait_type)} <b>${esc(a.value)}</b></span>`).join('');\n"
            "  const link=j.external_url?` &middot; <a href='${esc(j.external_url)}'>site</a>`:'';\n"
            "  return `<div class='card${t.isNew?' new':''}'><img class='art' src='${j.image}' alt='${esc(j.name)}'>`+\n"
            "    `<div class='meta'><div class='nm'>${esc(j.name)}${t.isNew?\"<span class='tag'>new</span>\":''}</div>`+\n"
            "    `<div class='ds'>${esc(j.description||'')}</div>`+\n" "    `<div class='traits'>${traits}</div>`+\n"
            "    `<div class='addr' style='margin-top:10px'>asset ${t.asset==ZERO?'0x0 (native ETH)':short(t.asset)}`+\n"
            "    ` &middot; card held by ${short(t.holder)}${link}</div>`+\n" "    `</div></div>`;\n" "}\n"
            "document.write(\"<h2>Curation order</h2>\"+\n"
            "  \"<table><tr><th>#</th><th>Token</th><th>Asset address</th><th>Rank</th><th>Source</th></tr>\"+\n"
            "  parsed.map((t,i)=>{\n"
            "    const j=t.json, sym=(j.attributes.find(a=>a.trait_type=='Symbol')||{}).value;\n"
            "    const dec_=(j.attributes.find(a=>a.trait_type=='Decimals')||{}).value;\n"
            "    const standard=(j.attributes.find(a=>a.trait_type=='Token Standard')||{}).value||'Unknown';\n"
            "    return `<tr class='${t.isNew?'new':''}'><td class='addr'>${i+1}</td><td><div class='tk'><img src='${t.logo}' alt=''>`+\n"
            "      `<div><div>${esc(sym)}${t.isNew?\"<span class='tag'>new</span>\":''}</div><div class='addr'>${esc(standard)}${standard=='ERC-20'||standard=='Native'?` &middot; ${esc(dec_)} decimals`:''}</div></div></div></td>`+\n"
            "      `<td class='addr'>${t.asset==ZERO?'0x0 (native)':short(t.asset)}</td>`+\n"
            "      `<td>${t.rank}</td>`+\n"
            "      `<td><span class='pill ${t.synced?'ok':''}'>${t.synced?'onchain':'attested'}</span></td></tr>`;\n"
            "  }).join('')+\"</table>\");\n" "</script></div></body></html>";
    }
}
