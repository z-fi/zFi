// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Swapboard} from "../src/Swapboard.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {Floorboard} from "../src/Floorboard.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev A WNS stand-in that answers reverse lookups with hostile display text:
///      markup, a name far longer than the renderer admits, and a head offset
///      a naive decoder would misread. None of it may reach an SVG.
contract HostileReverse {
    uint256 public mode;

    function set(uint256 m) external {
        mode = m;
    }

    function reverseResolve(address) external view returns (string memory) {
        if (mode == 0) return "</text><script>alert(1)</script>";
        if (mode == 1) return "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        return "ok.wei";
    }
}

/// @dev Anything at all at the WNS slot, answering every call with a word of
///      zeroes. Neither a name nor a well-formed refusal.
contract Garbage {
    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(0));
    }
}

/// @notice The three boards render a maker label into their position art, and
///         that label is the only outward call `tokenURI` makes: a reverse WNS
///         lookup at a mainnet address. WNS exists on Ethereum and nowhere
///         else, so on Base and on Robinhood that call lands on empty space -
///         and a position whose art cannot be read is a position no wallet or
///         marketplace will show.
///
///         These run against the LIVE deployed boards on both L2s rather than
///         local copies, because the addresses and the bytecode are what has
///         to survive the missing registry, and both are immutable.
contract BoardNamesL2Test is Test {
    address constant WNS = 0x0000000000696760E15f265e828DB644A0c242EB;

    address constant SWAPBOARD = 0x0000001330435808A906432449D233d482Bc9b60;
    address constant DUTCHBOARD = 0x000000fa42d555173395323b2956e9c42EFaEFf2;
    address constant FLOORBOARD = 0x000000AC7d32e802B003a31F790eb28Ed3294Bac;

    address constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    string constant BASE_RPC = "https://mainnet.base.org";
    string constant RH_RPC = "https://rpc.mainnet.chain.robinhood.com";

    address maker = address(0xA11CE);

    function _fork(string memory url) internal {
        vm.createSelectFork(url);
        vm.deal(maker, 100 ether);
    }

    // ------------------------------------------------------------- the setting

    function _assertNoWns() internal view {
        assertEq(WNS.code.length, 0, "WNS is a mainnet contract; an L2 copy would change this test");
        assertGt(SWAPBOARD.code.length, 0, "Swapboard");
        assertGt(DUTCHBOARD.code.length, 0, "Dutchboard");
        assertGt(FLOORBOARD.code.length, 0, "Floorboard");
    }

    // ------------------------------------------------------------ the renders

    uint256[3] internal ids;

    /// @dev One position on each board, opened once so the SAME three ids can
    ///      be rendered under different WNS states. Ids are part of the art, so
    ///      re-listing between renders would make every comparison trivially
    ///      unequal.
    function _open() internal {
        MockERC20 lot = new MockERC20("LOT", 18);
        MockERC20 quote = new MockERC20("QUOTE", 18);
        lot.mint(maker, 1_000e18);
        quote.mint(maker, 1_000e18);

        vm.startPrank(maker);
        lot.approve(SWAPBOARD, type(uint256).max);
        lot.approve(DUTCHBOARD, type(uint256).max);
        quote.approve(FLOORBOARD, type(uint256).max);

        ids[0] = Swapboard(payable(SWAPBOARD)).createOrder(
            address(lot), 10e18, address(quote), 20e18, false, 0, false, false, address(0)
        );
        ids[1] = Dutchboard(payable(DUTCHBOARD)).listERC20(
            address(lot), address(quote), 10e18, 20e18, 5e18, 0, 1 days, 0
        );
        ids[2] = Floorboard(payable(FLOORBOARD)).bid(
            Floorboard.Terms({
                token: address(lot),
                quote: address(quote),
                want: 10e18,
                startPrice: 1e18,
                endPrice: 2e18,
                startTime: 0,
                duration: 1 days,
                isNFT: false,
                ids: new uint256[](0)
            })
        );
        vm.stopPrank();
    }

    function _render() internal view returns (string[3] memory uris) {
        uris[0] = Swapboard(payable(SWAPBOARD)).tokenURI(ids[0]);
        uris[1] = Dutchboard(payable(DUTCHBOARD)).tokenURI(ids[1]);
        uris[2] = Floorboard(payable(FLOORBOARD)).tokenURI(ids[2]);
    }

    function _assertRendersWithoutWns() internal {
        _open();
        string[3] memory uris = _render();
        string[3] memory names = ["Swapboard", "Dutchboard", "Floorboard"];
        for (uint256 i; i < 3; ++i) {
            assertGt(bytes(uris[i]).length, 1_000, string.concat(names[i], " rendered nothing"));
        }
    }

    // ------------------------------------------------------------- the bodies

    /// @dev The WNS address is not reserved on an L2. Anyone can put code there,
    ///      and `makerLabel` is a staticcall into whatever answers - so what it
    ///      answers has to be treated as display text from a stranger.
    function _squattedRegistryCannotReachTheArt(string memory url) internal {
        _fork(url);
        _open();
        string[3] memory clean = _render();

        HostileReverse hostile = new HostileReverse();
        vm.etch(WNS, address(hostile).code);

        for (uint256 mode; mode < 2; ++mode) {
            HostileReverse(WNS).set(mode);
            string[3] memory dirty = _render();
            for (uint256 i; i < 3; ++i) {
                assertEq(
                    keccak256(bytes(dirty[i])),
                    keccak256(bytes(clean[i])),
                    "a squatted registry changed the art"
                );
            }
        }
    }

    /// @dev A contract that answers, but not with a string. The decode must not
    ///      run off the end of the returndata.
    function _garbageRegistryCannotBrickTokenURI(string memory url) internal {
        _fork(url);
        _open();
        string[3] memory clean = _render();
        vm.etch(WNS, address(new Garbage()).code);
        string[3] memory dirty = _render();
        for (uint256 i; i < 3; ++i) {
            assertEq(keccak256(bytes(dirty[i])), keccak256(bytes(clean[i])), "garbage changed the art");
        }
    }

    /// @dev And the control: a well-formed short name DOES reach the card, so
    ///      the assertions above are about the guard rather than about a label
    ///      that never renders.
    function _wellFormedNameStillReachesTheArt(string memory url) internal {
        _fork(url);
        _open();
        string[3] memory clean = _render();

        HostileReverse hostile = new HostileReverse();
        vm.etch(WNS, address(hostile).code);
        HostileReverse(WNS).set(2);

        string[3] memory named = _render();
        for (uint256 i; i < 3; ++i) {
            assertTrue(keccak256(bytes(named[i])) != keccak256(bytes(clean[i])), "a valid name never landed");
        }
    }

    // --------------------------------------------------------------- the cases
    //
    // Both chains carry byte-identical board code, so these could be argued to
    // be the same test twice. They are not: what differs is the CHAIN STATE the
    // renderer runs against, and that is the half no bytecode comparison can
    // speak to.

    function test_BaseRendersWithNoRegistry() public {
        _fork(BASE_RPC);
        _assertNoWns();
        _assertRendersWithoutWns();
    }

    function test_RobinhoodRendersWithNoRegistry() public {
        _fork(RH_RPC);
        _assertNoWns();
        _assertRendersWithoutWns();
    }

    function test_BaseSquattedRegistryCannotReachTheArt() public {
        _squattedRegistryCannotReachTheArt(BASE_RPC);
    }

    function test_RobinhoodSquattedRegistryCannotReachTheArt() public {
        _squattedRegistryCannotReachTheArt(RH_RPC);
    }

    function test_BaseGarbageRegistryCannotBrickTokenURI() public {
        _garbageRegistryCannotBrickTokenURI(BASE_RPC);
    }

    function test_RobinhoodGarbageRegistryCannotBrickTokenURI() public {
        _garbageRegistryCannotBrickTokenURI(RH_RPC);
    }

    function test_BaseWellFormedNameStillReachesTheArt() public {
        _wellFormedNameStillReachesTheArt(BASE_RPC);
    }

    function test_RobinhoodWellFormedNameStillReachesTheArt() public {
        _wellFormedNameStillReachesTheArt(RH_RPC);
    }

    function test_BaseWethIsWhatTheBoardsHold() public {
        _fork(BASE_RPC);
        // Not a name check: the boards were redeployed for these chains because
        // the mainnet WETH constant is wrong here, and a board bound to the
        // wrong WETH would fail long before any label was drawn.
        assertEq(Swapboard(payable(SWAPBOARD)).weth(), BASE_WETH);
    }
}
