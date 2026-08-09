// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {Floorboard} from "../src/Floorboard.sol";
import {MockERC20, MockWETH, MockNFT} from "./SwapboardMocks.sol";

contract PreviewWns {
    mapping(address => string) public names;

    function set(address who, string calldata name) external {
        names[who] = name;
    }

    function reverseResolve(address who) external view returns (string memory) {
        return names[who];
    }
}

/// Builds the position card gallery out of REAL renderer output.
///
/// The previous preview was a hand-written JavaScript restatement of the SVG,
/// which is exactly the artefact that drifts: it had Swapboard on a layout the
/// contract never rendered. This deploys the three real boards, drives them
/// into every state a card can be in, and records the `tokenURI` each one
/// actually returns. The gallery replays those bytes, so what the page paints
/// is what a wallet paints.
contract BoardPreviewDumpTest is Test {
    using stdStorage for StdStorage;

    address constant WNS = 0x0000000000696760E15f265e828DB644A0c242EB;
    string constant OUT = "dapp/positions-preview.html";
    /// @dev Every timestamp in this file is an absolute constant. `block.timestamp`
    ///      is transaction-invariant as far as the optimizer is concerned, so a
    ///      read taken after a `vm.warp` can legally be hoisted above it and a
    ///      relative schedule silently comes out wrong.
    uint256 constant SWAP_T0 = 1_782_000_000;
    uint256 constant DUTCH_T0 = 1_790_000_000;
    uint256 constant FLOOR_T0 = 1_800_000_000;
    uint256 constant DAY = 1 days;

    MockWETH weth;
    MockERC20 tkn; // 18 decimals
    MockERC20 usdc; // 6 decimals
    MockNFT nft;
    Swapboard swapboard;
    Dutchboard dutchboard;
    Floorboard floorboard;

    address maker = address(0xA11CE);
    address taker = address(0xB0B);
    /// @dev A maker with no reverse WNS record. Most addresses have none, so the
    ///      short-address fallback is the COMMON footer, not the edge case, and
    ///      a gallery that only ever showed a resolved name never showed it.
    address plain = address(0xdeADbeef00000000000000000000000000c0Ffee);

    string cards;
    uint256 count;

    function setUp() public {
        vm.warp(SWAP_T0);
        weth = new MockWETH();
        tkn = new MockERC20("TKN", 18);
        usdc = new MockERC20("USDC", 6);
        nft = new MockNFT();
        swapboard = new Swapboard(address(weth));
        dutchboard = new Dutchboard(address(weth));
        floorboard = new Floorboard(address(weth));

        PreviewWns wns = new PreviewWns();
        vm.etch(WNS, address(wns).code);
        PreviewWns(WNS).set(maker, "terminal.wei");

        vm.deal(address(this), 100 ether);
        weth.deposit{value: 100 ether}();
        weth.transfer(plain, 100 ether);
        tkn.mint(maker, 10_000e18);
        tkn.mint(taker, 10_000e18);
        tkn.mint(plain, 10_000e18);
        usdc.mint(maker, 10_000_000e6);
        usdc.mint(taker, 10_000_000e6);
        usdc.mint(plain, 10_000_000e6);
        for (uint256 i = 1; i <= 8; ++i) nft.mint(maker, i);

        address[3] memory boards = [address(swapboard), address(dutchboard), address(floorboard)];
        address[3] memory parties = [maker, taker, plain];
        for (uint256 i; i < boards.length; ++i) {
            for (uint256 j; j < parties.length; ++j) {
                vm.startPrank(parties[j]);
                tkn.approve(boards[i], type(uint256).max);
                usdc.approve(boards[i], type(uint256).max);
                weth.approve(boards[i], type(uint256).max);
                nft.setApprovalForAll(boards[i], true);
                vm.stopPrank();
            }
        }
    }

    receive() external payable {}

    // ------------------------------------------------------------- SWAPBOARD

    function _swap(uint256 amountA, uint256 amountB, bool divisible, uint64 expiry, address counterparty)
        internal
        returns (uint256 id)
    {
        vm.prank(maker);
        id = swapboard.createOrder(
            address(tkn), amountA, address(usdc), amountB, divisible, expiry, false, false, counterparty
        );
    }

    function _swapCards() internal {
        uint64 future = uint64(SWAP_T0 + 30 * DAY);

        _card("Swapboard", "Open, divisible", swapboard.tokenURI(_swap(100e18, 250_000e6, true, future, address(0))));

        uint256 half = _swap(100e18, 250_000e6, true, future, address(0));
        vm.prank(taker);
        swapboard.fillOrder(half, SWAP_T0, 106_250e6, 0, taker);
        _card("Swapboard", "Partially filled", swapboard.tokenURI(half));

        _card(
            "Swapboard",
            "All or nothing, perpetual",
            swapboard.tokenURI(_swap(1e18, 2_500e6, false, 0, address(0)))
        );
        _card(
            "Swapboard",
            "Private counterparty",
            swapboard.tokenURI(_swap(50e18, 125_000e6, true, future, taker))
        );

        uint256 soft = _swap(75e18, 187_500e6, true, future, address(0));
        vm.prank(maker);
        swapboard.setFrozen(soft, true);
        _card("Swapboard", "Frozen by the maker", swapboard.tokenURI(soft));

        uint256 bound = _swap(75e18, 187_500e6, true, future, address(0));
        vm.prank(maker);
        swapboard.commitFrozen(bound, uint64(SWAP_T0 + 3 * DAY));
        _card("Swapboard", "Bound until a timestamp", swapboard.tokenURI(bound));

        uint256 dust = _swap(1, 1, true, future, address(0));
        _card("Swapboard", "One base unit each side", swapboard.tokenURI(dust));

        vm.prank(maker);
        uint256 nftLeg =
            swapboard.createOrder(address(nft), 1, address(usdc), 12_500e6, false, future, true, false, address(0));
        _card("Swapboard", "NFT for ERC-20", swapboard.tokenURI(nftLeg));

        uint256 filled = _swap(10e18, 25_000e6, false, future, address(0));
        vm.prank(taker);
        swapboard.fillOrder(filled, SWAP_T0, 25_000e6, 0, taker);
        _card("Swapboard", "Filled receipt", swapboard.tokenURI(filled));

        uint256 cancelled = _swap(10e18, 25_000e6, true, future, address(0));
        vm.prank(maker);
        swapboard.cancelOrder(cancelled);
        _card("Swapboard", "Cancelled receipt", swapboard.tokenURI(cancelled));

        // Half a WETH against USDC. An 18-decimal amount below one used to be
        // forced into scientific notation whatever its value, so the two slots
        // this card is mostly made of read "5e-1" and "1.25e+3".
        vm.prank(plain);
        uint256 fractional = swapboard.createOrder(
            address(weth), 5e17, address(usdc), 1_250e6, true, future, false, false, address(0)
        );
        _card("Swapboard", "Sub-unit WETH, unnamed maker", swapboard.tokenURI(fractional));

        vm.prank(plain);
        uint256 anon = swapboard.createOrder(
            address(tkn), 100e18, address(usdc), 250_000e6, true, future, false, false, address(0)
        );
        _card("Swapboard", "Open, maker has no WNS name", swapboard.tokenURI(anon));

        uint256 expired = _swap(10e18, 25_000e6, true, uint64(SWAP_T0 + DAY), address(0));
        // Both at once, to pin the precedence: FROZEN outranks EXPIRED here the
        // same way it does on Dutchboard.
        uint256 both = _swap(10e18, 25_000e6, true, uint64(SWAP_T0 + DAY), address(0));
        vm.prank(maker);
        swapboard.setFrozen(both, true);

        vm.warp(SWAP_T0 + 2 * DAY);
        _card("Swapboard", "Expired", swapboard.tokenURI(expired));
        _card("Swapboard", "Frozen and past expiry", swapboard.tokenURI(both));
    }

    // ------------------------------------------------------------ DUTCHBOARD

    /// @dev Time only ever moves forward here. Every listing is opened at `DUTCH_T0`
    ///      and the run then steps through the schedule once, so each card is
    ///      the board's genuine view at that instant rather than a rewind.
    function _dutchCards() internal {
        vm.warp(DUTCH_T0);

        vm.startPrank(maker);
        uint256 scheduled = dutchboard.listERC20(
            address(tkn), address(usdc), 1_000e18, 5_000e6, 1_000e6, uint40(DUTCH_T0 + DAY), 7 days, 0
        );
        uint256 live = dutchboard.listERC20(address(tkn), address(usdc), 1_000e18, 5_000e6, 1_000e6, 0, 7 days, 0);
        uint256 mid = dutchboard.listERC20(address(tkn), address(usdc), 1_000e18, 5_000e6, 1_000e6, 0, 7 days, 0);
        uint256 frozen = dutchboard.listERC20(address(tkn), address(usdc), 500e18, 2_000e6, 500e6, 0, 7 days, 0);
        uint256 floorLot = dutchboard.listERC20(address(tkn), address(usdc), 500e18, 2_000e6, 500e6, 0, 1 days, 0);
        uint256 freeLot = dutchboard.listERC20(address(tkn), address(usdc), 500e18, 2_000e6, 0, 0, 1 days, 0);
        uint256 expiring = dutchboard.listERC20(
            address(tkn), address(usdc), 500e18, 2_000e6, 500e6, 0, 1 days, uint40(DUTCH_T0 + 2 * DAY)
        );
        uint256 sold = dutchboard.listERC20(address(tkn), address(usdc), 100e18, 1_000e6, 100e6, 0, 7 days, 0);
        uint256 pulled = dutchboard.listERC20(address(tkn), address(usdc), 100e18, 1_000e6, 100e6, 0, 7 days, 0);
        uint256[] memory ids = new uint256[](3);
        (ids[0], ids[1], ids[2]) = (2, 3, 4);
        uint256 bundle = dutchboard.listNFT(address(nft), address(0), ids, 9e18, 1e18, 0, 7 days);
        dutchboard.cancel(pulled);
        vm.stopPrank();

        // FROZEN is only reachable through the nested-proceeds callback, which
        // needs a second board in the loop; the flag is what the card reads, so
        // it is set directly rather than staged.
        stdstore.target(address(dutchboard)).sig("frozen(uint256)").with_key(frozen).checked_write(true);

        _card("Dutchboard", "Scheduled, not yet open", dutchboard.tokenURI(scheduled));
        _card("Dutchboard", "Live at the start price", dutchboard.tokenURI(live));
        _card("Dutchboard", "Frozen by nested proceeds", dutchboard.tokenURI(frozen));
        _card("Dutchboard", "NFT bundle, ETH quote", dutchboard.tokenURI(bundle));
        _card("Dutchboard", "Cancelled receipt", dutchboard.tokenURI(pulled));

        vm.warp(DUTCH_T0 + 12 hours);
        vm.prank(taker);
        dutchboard.fill(sold, 100e18, taker, type(uint256).max);
        _card("Dutchboard", "Filled receipt", dutchboard.tokenURI(sold));

        vm.warp(DUTCH_T0 + 3 * DAY + 12 hours);
        vm.prank(taker);
        dutchboard.fill(mid, 425e18, taker, type(uint256).max);
        _card("Dutchboard", "Mid decay, partly filled", dutchboard.tokenURI(mid));
        _card("Dutchboard", "Resting on its floor", dutchboard.tokenURI(floorLot));
        _card("Dutchboard", "Decayed to free", dutchboard.tokenURI(freeLot));
        _card("Dutchboard", "Expired by hard deadline", dutchboard.tokenURI(expiring));

        // A seller with no reverse WNS record, quoting in ETH across a schedule
        // that decays below one whole unit.
        vm.prank(plain);
        uint256 anon = dutchboard.listERC20(address(tkn), address(0), 40e18, 2e18, 5e17, 0, 7 days, 0);
        _card("Dutchboard", "Sub-unit ETH floor, unnamed seller", dutchboard.tokenURI(anon));
    }

    // ------------------------------------------------------------ FLOORBOARD

    function _floorTerms(uint128 want, uint256 startPrice, uint256 endPrice, uint40 startTime, uint40 duration)
        internal
        view
        returns (Floorboard.Terms memory t)
    {
        t = Floorboard.Terms({
            token: address(tkn),
            quote: address(usdc),
            want: want,
            startPrice: startPrice,
            endPrice: endPrice,
            startTime: startTime,
            duration: duration,
            isNFT: false,
            ids: new uint256[](0)
        });
    }

    function _floorCards() internal {
        vm.warp(FLOOR_T0);

        Floorboard.Terms memory t = _floorTerms(1_000e18, 2_000e6, 5_000e6, uint40(FLOOR_T0 + DAY), 7 days);
        vm.startPrank(maker);
        uint256 scheduled = floorboard.bid(t);
        t = _floorTerms(1_000e18, 2_000e6, 5_000e6, 0, 7 days);
        uint256 live = floorboard.bid(t);
        uint256 mid = floorboard.bid(t);
        uint256 flat = floorboard.bid(_floorTerms(1_000e18, 2_000e6, 2_000e6, 0, 7 days));
        uint256 lapsed = floorboard.bid(_floorTerms(1_000e18, 2_000e6, 5_000e6, 0, 1 days));
        Floorboard.Terms memory n = _floorTerms(2, 5_000e6, 12_000e6, 0, 7 days);
        (n.token, n.isNFT) = (address(nft), true);
        uint256 nftBid = floorboard.bid(n);
        uint256 done = floorboard.bid(_floorTerms(100e18, 1_000e6, 2_000e6, 0, 7 days));
        uint256 pulled = floorboard.bid(_floorTerms(100e18, 1_000e6, 2_000e6, 0, 7 days));
        floorboard.cancel(pulled);
        vm.stopPrank();

        _card("Floorboard", "Scheduled, not yet open", floorboard.tokenURI(scheduled));
        _card("Floorboard", "Live at the start price", floorboard.tokenURI(live));
        _card("Floorboard", "Flat schedule, a limit bid", floorboard.tokenURI(flat));
        _card("Floorboard", "Standing NFT bid", floorboard.tokenURI(nftBid));
        _card("Floorboard", "Cancelled receipt", floorboard.tokenURI(pulled));

        vm.warp(FLOOR_T0 + 12 hours);
        vm.prank(taker);
        floorboard.hit(done, 100e18, 0, false);
        _card("Floorboard", "Filled receipt", floorboard.tokenURI(done));

        vm.warp(FLOOR_T0 + 3 * DAY + 12 hours);
        vm.prank(taker);
        floorboard.hit(mid, 425e18, 0, false);
        _card("Floorboard", "Mid climb, partly filled", floorboard.tokenURI(mid));
        _card("Floorboard", "Window closed", floorboard.tokenURI(lapsed));

        // A bidder with no reverse WNS record, escrowing sub-unit WETH.
        Floorboard.Terms memory w = _floorTerms(50e18, 25e16, 75e16, 0, 7 days);
        w.quote = address(weth);
        vm.prank(plain);
        uint256 anon = floorboard.bid(w);
        _card("Floorboard", "Sub-unit WETH bid, unnamed bidder", floorboard.tokenURI(anon));
    }

    // ----------------------------------------------------------------- DUMP

    function test_WritePreviewGallery() public {
        _swapCards();
        _dutchCards();
        _floorCards();
        assertGt(count, 25, "gallery covers every card state");
        vm.writeFile(OUT, string.concat(_head(), cards, _tail()));
    }

    /// @dev Every card is asserted to be a real metadata URI as it is recorded,
    ///      so a malformed renderer fails the run rather than shipping a blank
    ///      tile into the gallery.
    function _card(string memory board, string memory title, string memory uri) internal {
        assertTrue(bytes(uri).length > 256, title);
        cards = string.concat(
            cards,
            count == 0 ? "" : ",",
            '{"board":"',
            board,
            '","title":"',
            title,
            '","uri":"',
            uri,
            '"}'
        );
        ++count;
    }

    /// @dev The page is deliberately single-theme. The cards are white on #000
    ///      and that is how a wallet renders them; a light ground would
    ///      misrepresent the artwork it exists to show. The only chroma on the
    ///      page is the renderers' own state palette.
    function _head() internal pure returns (string memory) {
        return string.concat(
            "<!doctype html>\n<html lang='en'>\n<head>\n<meta charset='utf-8'>\n",
            "<meta name='viewport' content='width=device-width, initial-scale=1'>\n",
            "<title>Board position cards</title>\n<style>\n",
            ":root{color-scheme:dark;--ground:#08090a;--panel:#0e1013;--rule:#22262c;--ink:#e8eaed;",
            "--muted:#858c97;--mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;",
            "--ui:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif}\n",
            "*{box-sizing:border-box}\n",
            "body{margin:0;padding:0 clamp(16px,4vw,48px) 72px;background:var(--ground);color:var(--ink);",
            "font-family:var(--ui);-webkit-font-smoothing:antialiased}\n",
            "header{max-width:1500px;margin:0 auto;padding:56px 0 28px;border-bottom:1px solid var(--rule)}\n",
            "h1{margin:0;font-size:clamp(20px,2.4vw,29px);font-weight:650;letter-spacing:-.015em;text-wrap:balance}\n",
            ".sub{margin:12px 0 0;max-width:64ch;color:var(--muted);font-size:14px;line-height:1.6}\n",
            "code{font-family:var(--mono);font-size:.9em;color:var(--ink)}\n",
            "nav{position:sticky;top:0;z-index:2;display:flex;flex-wrap:wrap;gap:6px;max-width:1500px;",
            "margin:0 auto;padding:14px 0;background:var(--ground);border-bottom:1px solid var(--rule)}\n",
            "button{appearance:none;padding:7px 12px;border:1px solid var(--rule);border-radius:2px;",
            "background:var(--panel);color:var(--muted);cursor:pointer;font-family:var(--mono);",
            "font-size:11px;letter-spacing:.06em;text-transform:uppercase}\n",
            "button:hover{color:var(--ink);border-color:#3a4048}\n",
            "button.active{background:var(--ink);border-color:var(--ink);color:var(--ground)}\n",
            "button:focus-visible{outline:2px solid #6fa8ff;outline-offset:2px}\n",
            "section{max-width:1500px;margin:0 auto;padding-top:40px}\n",
            "h2{display:flex;align-items:baseline;gap:12px;margin:0 0 16px;font-family:var(--mono);",
            "font-size:11px;font-weight:600;letter-spacing:.16em;text-transform:uppercase;color:var(--muted)}\n",
            "h2 span{flex:1;height:1px;background:var(--rule)}\n",
            ".cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(360px,1fr));gap:20px}\n",
            "figure{margin:0;border:1px solid var(--rule);background:var(--panel);overflow:hidden}\n",
            "img{display:block;width:100%;height:auto;background:#000;border-bottom:1px solid var(--rule)}\n",
            "figcaption{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:12px 14px}\n",
            "figcaption b{font-weight:550;font-size:13px}\n",
            ".state{display:inline-flex;align-items:center;gap:6px;font-family:var(--mono);font-size:10px;",
            "letter-spacing:.08em;color:var(--muted);white-space:nowrap}\n",
            ".dot{width:7px;height:7px;border-radius:50%;background:currentColor}\n",
            ".traits{display:flex;flex-wrap:wrap;gap:4px 14px;padding:0 14px 13px;font-family:var(--mono);",
            "font-size:10.5px;color:var(--muted);font-variant-numeric:tabular-nums}\n",
            ".traits i{font-style:normal;color:#5c626c}\n",
            "</style>\n</head>\n<body>\n<header>\n",
            "<h1>Board position cards</h1>\n",
            "<p class='sub'>Every image below is the exact <code>tokenURI</code> a deployed Swapboard, ",
            "Dutchboard or Floorboard returned in a Foundry run &mdash; decoded and drawn as-is, nothing ",
            "restated by hand. The traits under each card come from the same metadata a wallet reads. ",
            "Regenerate with <code>forge test --match-path test/BoardPreviewDump.t.sol</code>.</p>\n",
            "</header>\n<nav id='filters'></nav>\n<main id='gallery'></main>\n",
            "<script type='application/json' id='data'>["
        );
    }

    function _tail() internal pure returns (string memory) {
        return string.concat(
            "]</script>\n<script>\n",
            // Must track `PositionSVG`'s constants. This map is hand-written and
            // had already drifted: it painted EXPIRED amber where the card draws
            // it red, and SCHEDULED in FILLED's blue, so the gallery misreported
            // the very palette it exists to show.
            "const ACCENT={OPEN:'#43d69b',LIVE:'#43d69b',SCHEDULED:'#8fa4c4',FILLED:'#6fa8ff',",
            "FROZEN:'#c69cff',EXPIRED:'#ff8f8f',FLOOR:'#ffb55b',FREE:'#5ee6d2',CLOSED:'#969da7'};\n",
            "const data=JSON.parse(document.getElementById('data').textContent);\n",
            "const decode=u=>JSON.parse(atob(u.slice('data:application/json;base64,'.length)));\n",
            "const esc=v=>String(v).replace(/[&<>\"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',\"'\":'&apos;'}[c]));\n",
            "const cards=data.map(d=>({...d,meta:decode(d.uri)}));\n",
            "const traits=m=>m.attributes||[];\n",
            "const status=m=>{const a=traits(m).find(t=>t.trait_type==='Status');return a?a.value:''};\n",
            "const boards=[...new Set(cards.map(c=>c.board))];\n",
            "let active='All';\n",
            "document.getElementById('filters').innerHTML=['All',...boards].map(b=>",
            "`<button data-board='${b}'>${b}</button>`).join('');\n",
            "function tile(c){\n",
            " const st=status(c.meta), colour=ACCENT[st]||'#858c97';\n",
            " const strip=traits(c.meta).filter(t=>t.trait_type!=='Board'&&t.trait_type!=='Status')\n",
            "  .map(t=>`<span><i>${esc(t.trait_type)}</i> ${esc(t.value)}</span>`).join('');\n",
            " return `<figure><img loading='lazy' alt='${esc(c.meta.name)}' src='${esc(c.meta.image)}'>`+\n",
            "  `<figcaption><b>${esc(c.title)}</b>`+\n",
            "  `<span class='state' style='color:${colour}'><span class='dot'></span>${esc(st)}</span>`+\n",
            "  `</figcaption><div class='traits'>${strip}</div></figure>`;\n",
            "}\n",
            "function render(){\n",
            " document.querySelectorAll('#filters button').forEach(b=>b.classList.toggle('active',b.dataset.board===active));\n",
            " document.getElementById('gallery').innerHTML=boards.filter(b=>active==='All'||active===b).map(b=>{\n",
            "  const own=cards.filter(c=>c.board===b);\n",
            "  return `<section><h2>${esc(b)}<span></span>${own.length} cards</h2>`+\n",
            "   `<div class='cards'>${own.map(tile).join('')}</div></section>`;\n",
            " }).join('');\n",
            "}\n",
            "document.getElementById('filters').addEventListener('click',e=>{\n",
            " if(!e.target.dataset.board)return; active=e.target.dataset.board; render();\n",
            "});\n",
            "render();\n",
            "</script>\n</body>\n</html>\n"
        );
    }
}
