// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import "forge-std/Test.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {Floorboard} from "../src/Floorboard.sol";
import {MockERC20, MockWETH} from "./SwapboardMocks.sol";

/// @dev A wallet never sees `amount()` or `legLabel()`. It sees ONE string, and
/// either that string parses or the receipt is a broken image. The primitives
/// are covered in `PositionSVGAmount`; this file asserts the property that
/// actually matters at the boundary - that every card a board can produce is a
/// well-formed JSON document wrapping a well-formed SVG one - and it asserts it
/// across the whole state space rather than at the two or three states a
/// happy-path render test happens to visit.
///
/// The inputs are deliberately worst-case: a symbol at the reader's 12-byte
/// limit, a WNS name at the 28-byte limit, a 36-decimal token, dust and
/// enormous amounts, and token id `type(uint256).max`. Those are the values
/// that overrun a slot or exhaust a buffer if anything is going to.
contract BoardCardWellFormedTest is Test {
    address constant WNS = 0x0000000000696760E15f265e828DB644A0c242EB;

    MockWETH weth;
    Swapboard swap;
    Dutchboard dutch;
    Floorboard floor;
    WideToken lot; // 36 decimals, 12-char symbol
    MockERC20 quote;
    CardNFT nft;

    address maker = address(0xA11CE);
    address taker = address(0xB0B);

    function setUp() public {
        vm.warp(1_000_000);
        weth = new MockWETH();
        swap = new Swapboard(address(weth));
        dutch = new Dutchboard(address(weth));
        floor = new Floorboard(address(weth));
        lot = new WideToken();
        quote = new MockERC20("QUOTE", 18);
        nft = new CardNFT();

        // The longest name the reader will admit, so the footer is at its widest.
        vm.etch(WNS, address(new LongName()).code);

        lot.mint(maker, type(uint128).max);
        quote.mint(taker, type(uint128).max);
        quote.mint(maker, type(uint128).max);
        vm.startPrank(maker);
        lot.approve(address(swap), type(uint256).max);
        lot.approve(address(dutch), type(uint256).max);
        quote.approve(address(floor), type(uint256).max);
        nft.setApprovalForAll(address(swap), true);
        nft.setApprovalForAll(address(dutch), true);
        vm.stopPrank();
        vm.startPrank(taker);
        quote.approve(address(swap), type(uint256).max);
        quote.approve(address(dutch), type(uint256).max);
        vm.stopPrank();
    }

    // --------------------------------------------------------------- SWAPBOARD

    /// @dev Open, partly filled, fully filled, cancelled, expired, frozen,
    ///      bound, private, NFT on either leg, dust, and the widest amounts the
    ///      slot admits.
    function test_SwapboardCardsAreWellFormedInEveryState() public {
        vm.startPrank(maker);
        uint256 open = swap.createOrder(address(lot), 100e36, address(quote), 200e18, true, 0, false, false, address(0));
        uint256 dusty = swap.createOrder(address(lot), 1, address(quote), 12345, true, 0, false, false, address(0));
        uint256 huge =
            swap.createOrder(address(lot), type(uint96).max, address(quote), type(uint96).max, true, 0, false, false, address(0));
        uint256 expiring =
            swap.createOrder(address(lot), 5e36, address(quote), 5e18, false, uint64(block.timestamp + 1), false, false, address(0));
        uint256 privately =
            swap.createOrder(address(lot), 5e36, address(quote), 5e18, false, 0, false, false, taker);
        uint256 frozen = swap.createOrder(address(lot), 5e36, address(quote), 5e18, false, 0, false, false, address(0));
        swap.setFrozen(frozen, true);
        uint256 bound = swap.createOrder(address(lot), 5e36, address(quote), 5e18, false, 0, false, false, address(0));
        swap.commitFrozen(bound, uint64(block.timestamp + 30 days));
        uint256 cancelled = swap.createOrder(address(lot), 5e36, address(quote), 5e18, false, 0, false, false, address(0));
        swap.cancelOrder(cancelled);

        nft.mint(maker, type(uint256).max);
        uint256 nftOrder = swap.createOrder(
            address(nft), type(uint256).max, address(quote), 1e18, false, 0, true, false, address(0)
        );
        vm.stopPrank();

        _check(swap.tokenURI(open), "open");
        _check(swap.tokenURI(dusty), "dust amounts");
        _check(swap.tokenURI(huge), "widest amounts");
        _check(swap.tokenURI(privately), "private");
        _check(swap.tokenURI(frozen), "soft frozen");
        _check(swap.tokenURI(bound), "committed");
        _check(swap.tokenURI(cancelled), "cancelled");
        _check(swap.tokenURI(nftOrder), "nft escrow, max token id");

        // Partly filled, then filled out.
        vm.prank(taker);
        swap.fillOrder(open, 0, 50e18, 0, taker);
        _check(swap.tokenURI(open), "partly filled");
        vm.prank(taker);
        swap.fillOrder(open, 0, 150e18, 0, taker);
        _check(swap.tokenURI(open), "filled");

        vm.warp(block.timestamp + 2);
        _check(swap.tokenURI(expiring), "expired");
    }

    // -------------------------------------------------------------- DUTCHBOARD

    function test_DutchboardCardsAreWellFormedInEveryState() public {
        vm.startPrank(maker);
        uint256 live = dutch.listERC20(address(lot), address(quote), 100e36, 200e18, 100e18, 0, 1 days, 0);
        uint256 scheduled = dutch.listERC20(
            address(lot), address(quote), 10e36, 200e18, 100e18, uint40(block.timestamp + 1 days), 1 days, 0
        );
        // A floor of zero decays to FREE; a nonzero one RESTS.
        uint256 toFree = dutch.listERC20(address(lot), address(quote), 10e36, 200e18, 0, 0, 1 hours, 0);
        uint256 toFloor = dutch.listERC20(address(lot), address(quote), 10e36, 200e18, 100e18, 0, 1 hours, 0);
        uint256 ethQuoted = dutch.listERC20(address(lot), address(0), 10e36, 200e18, 100e18, 0, 1 days, 0);
        uint256 cancelled = dutch.listERC20(address(lot), address(quote), 10e36, 200e18, 100e18, 0, 1 days, 0);
        dutch.cancel(cancelled);

        nft.mint(maker, 1);
        nft.mint(maker, type(uint256).max);
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (1, type(uint256).max);
        uint256 bundle = dutch.listNFT(address(nft), address(quote), ids, 200e18, 100e18, 0, 1 days);
        vm.stopPrank();

        _check(dutch.tokenURI(live), "live");
        _check(dutch.tokenURI(scheduled), "scheduled");
        _check(dutch.tokenURI(ethQuoted), "eth quote");
        _check(dutch.tokenURI(cancelled), "cancelled");
        _check(dutch.tokenURI(bundle), "nft bundle, max token id");

        vm.prank(taker);
        dutch.fill(live, 40e36, taker, type(uint256).max);
        _check(dutch.tokenURI(live), "partly filled");

        vm.warp(block.timestamp + 2 hours);
        _check(dutch.tokenURI(toFree), "decayed to free");
        _check(dutch.tokenURI(toFloor), "resting at floor");
    }

    // -------------------------------------------------------------- FLOORBOARD

    function test_FloorboardCardsAreWellFormedInEveryState() public {
        uint256 live = _bid(100e36, 100e18, 200e18, 0, 1 days, false);
        uint256 scheduled = _bid(10e36, 100e18, 200e18, uint40(block.timestamp + 1 days), 1 days, false);
        uint256 expiring = _bid(10e36, 100e18, 200e18, 0, 1 hours, false);
        uint256 nftBid = _bid(2, 100e18, 200e18, 0, 1 days, true);
        uint256 cancelled = _bid(10e36, 100e18, 200e18, 0, 1 days, false);
        vm.prank(maker);
        floor.cancel(cancelled);

        _check(floor.tokenURI(live), "live");
        _check(floor.tokenURI(scheduled), "scheduled");
        _check(floor.tokenURI(nftBid), "nft wanted");
        _check(floor.tokenURI(cancelled), "cancelled");

        vm.warp(block.timestamp + 2 hours);
        _check(floor.tokenURI(expiring), "expired");
    }

    function _bid(uint128 want, uint256 sp, uint256 ep, uint40 start, uint40 dur, bool isNFT)
        internal
        returns (uint256 id)
    {
        Floorboard.Terms memory t = Floorboard.Terms({
            token: isNFT ? address(nft) : address(lot),
            quote: address(quote),
            want: want,
            startPrice: sp,
            endPrice: ep,
            startTime: start,
            duration: dur,
            isNFT: isNFT,
            ids: new uint256[](0)
        });
        vm.prank(maker);
        id = floor.bid(t);
    }

    // ------------------------------------------------------------ THE ASSERTION

    /// @dev One card, checked as the two nested documents it actually is.
    function _check(string memory uri, string memory what) internal pure {
        bytes memory json = Base64.decode(_strip(uri, "data:application/json;base64,", what));
        _assertTextIsClean(json, what, "json");
        _assertBalanced(json, "{", "}", what, "json braces");
        _assertBalanced(json, "[", "]", what, "json brackets");
        _assertEven(json, '"', what, "json quotes");

        bytes memory svg = Base64.decode(_svgPayload(json, what));
        _assertTextIsClean(svg, what, "svg");
        // Angle brackets never nest: a `<` while a tag is open, or a `>` with
        // none open, is a document no parser will take.
        bool inTag;
        uint256 opened;
        for (uint256 i; i < svg.length; ++i) {
            if (svg[i] == "<") {
                assertFalse(inTag, string.concat(what, ": nested < in svg"));
                inTag = true;
                ++opened;
            } else if (svg[i] == ">") {
                assertTrue(inTag, string.concat(what, ": stray > in svg"));
                inTag = false;
            }
        }
        assertFalse(inTag, string.concat(what, ": unterminated tag"));
        assertTrue(opened != 0, string.concat(what, ": no markup at all"));
        _assertEven(svg, "'", what, "svg attribute quotes");
        // Every element this family opens, it closes.
        _assertTagBalance(svg, "<svg", "</svg>", what);
        _assertTagBalance(svg, "<text", "</text>", what);
        _assertTagBalance(svg, "<tspan", "</tspan>", what);
        _assertTagBalance(svg, "<g ", "</g>", what);
        // `&` starts an entity reference, and this family emits none - the
        // sanitiser drops it precisely so no card ever has to.
        assertEq(_count(svg, "&"), 0, string.concat(what, ": bare & in svg"));

        // No DRAWN string may be wider than the slot it sits in. Only element
        // text counts - the runs inside a tag are attributes, which have no
        // width on the card. The widest legitimate run is a leg label at its
        // maximum: a 12-byte symbol, ` / `, a shortened address, ` / `, and
        // `36 DEC` - 37 characters, which at 12px lands inside the 304px the
        // narrower of the two columns has.
        uint256 run;
        bool tagOpen;
        for (uint256 i; i < svg.length; ++i) {
            if (svg[i] == "<") {
                tagOpen = true;
                run = 0;
            } else if (svg[i] == ">") {
                tagOpen = false;
                run = 0;
            } else if (!tagOpen) {
                ++run;
                assertTrue(run <= 38, string.concat(what, ": a drawn string overruns its slot"));
            }
        }
    }

    function _assertTextIsClean(bytes memory doc, string memory what, string memory which) internal pure {
        assertTrue(doc.length != 0, string.concat(what, ": empty ", which));
        for (uint256 i; i < doc.length; ++i) {
            // XML 1.0 admits no C0 control character except tab, LF and CR, and
            // these documents are emitted without any of the three.
            assertTrue(uint8(doc[i]) >= 0x20, string.concat(what, ": control byte in ", which));
            assertTrue(uint8(doc[i]) < 0x7f, string.concat(what, ": non-ascii byte in ", which));
        }
    }

    function _assertBalanced(bytes memory doc, bytes1 open, bytes1 close, string memory what, string memory which)
        internal
        pure
    {
        int256 depth;
        for (uint256 i; i < doc.length; ++i) {
            if (doc[i] == open) ++depth;
            else if (doc[i] == close) --depth;
            assertTrue(depth >= 0, string.concat(what, ": unbalanced ", which));
        }
        assertEq(depth, int256(0), string.concat(what, ": unbalanced ", which));
    }

    function _assertEven(bytes memory doc, bytes1 c, string memory what, string memory which) internal pure {
        assertEq(_count(doc, c) % 2, 0, string.concat(what, ": odd ", which));
    }

    function _assertTagBalance(bytes memory doc, bytes memory open, bytes memory close, string memory what)
        internal
        pure
    {
        assertEq(
            _countBytes(doc, open),
            _countBytes(doc, close),
            string.concat(what, ": unclosed ", string(open))
        );
    }

    function _count(bytes memory doc, bytes1 c) internal pure returns (uint256 n) {
        for (uint256 i; i < doc.length; ++i) if (doc[i] == c) ++n;
    }

    function _countBytes(bytes memory doc, bytes memory needle) internal pure returns (uint256 n) {
        if (needle.length > doc.length) return 0;
        for (uint256 i; i + needle.length <= doc.length; ++i) if (_at(doc, i, needle)) ++n;
    }

    function _at(bytes memory doc, uint256 offset, bytes memory needle) internal pure returns (bool) {
        for (uint256 i; i < needle.length; ++i) if (doc[offset + i] != needle[i]) return false;
        return true;
    }

    function _strip(string memory uri, string memory prefix, string memory what)
        internal
        pure
        returns (string memory)
    {
        bytes memory u = bytes(uri);
        bytes memory p = bytes(prefix);
        assertTrue(u.length > p.length, string.concat(what, ": uri too short"));
        assertTrue(_at(u, 0, p), string.concat(what, ": wrong data uri prefix"));
        bytes memory out = new bytes(u.length - p.length);
        for (uint256 i; i < out.length; ++i) out[i] = u[p.length + i];
        return string(out);
    }

    function _svgPayload(bytes memory json, string memory what) internal pure returns (string memory) {
        bytes memory prefix = bytes("data:image/svg+xml;base64,");
        uint256 start;
        while (start + prefix.length <= json.length && !_at(json, start, prefix)) ++start;
        assertTrue(start + prefix.length <= json.length, string.concat(what, ": no svg in metadata"));
        uint256 end = start + prefix.length;
        while (end < json.length && json[end] != '"') ++end;
        bytes memory out = new bytes(end - start - prefix.length);
        for (uint256 i; i < out.length; ++i) out[i] = json[start + prefix.length + i];
        return string(out);
    }
}

/// @dev 36 decimals - the widest scale the reader admits - and a symbol at the
///      12-byte limit, so the leg label is as wide as a board can ever draw it.
contract WideToken {
    string public symbol = "WIDEST-TICKR";
    uint8 public constant decimals = 36;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address sp, uint256 amt) external returns (bool) {
        allowance[msg.sender][sp] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address f, address t, uint256 amt) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= amt;
        balanceOf[f] -= amt;
        balanceOf[t] += amt;
        return true;
    }
}

contract CardNFT {
    string public symbol = "COLLECTIBLES";
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function transferFrom(address f, address t, uint256 id) external {
        require(ownerOf[id] == f, "owner");
        require(msg.sender == f || isApprovedForAll[f][msg.sender], "approval");
        ownerOf[id] = t;
    }
}

/// @dev A reverse resolver answering at the reader's 28-byte ceiling.
contract LongName {
    function reverseResolve(address) external pure returns (string memory) {
        return "twenty-eight-chars-exactly.x";
    }
}
