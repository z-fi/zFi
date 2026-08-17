// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";

interface ISwapboard {
    function createOrder(address,uint256,address,uint256,bool,uint64,bool,bool,address) external returns (uint256);
    function tokenURI(uint256) external view returns (string memory);
}
interface IDutchboard {
    function listERC20(address,address,uint128,uint256,uint256,uint40,uint40,uint40) external returns (uint256);
    function tokenURI(uint256) external view returns (string memory);
}
interface IFloorboard {
    struct Terms { address token; address quote; uint128 want; uint256 startPrice; uint256 endPrice;
        uint40 startTime; uint40 duration; bool isNFT; uint256[] ids; }
    function bid(Terms calldata) external payable returns (uint256);
    function tokenURI(uint256) external view returns (string memory);
}
interface IERC20 { function approve(address,uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }
interface IERC721 { function ownerOf(uint256) external view returns (address); function setApprovalForAll(address,bool) external; }
interface IDutchNFT {
    function listNFT(address,address,uint256[] calldata,uint256,uint256,uint40,uint40) external returns (uint256);
    function tokenURI(uint256) external view returns (string memory);
}

/// @notice Mints one order on each board against REAL tokens and writes the
///         SVG each renderer produces to disk.
///
///         The art is generated on chain by per-board immutable renderers, so
///         the only honest way to show it is to make real orders and read
///         `tokenURI` back. Mocking the cards would show a design nobody ships.
contract OrderbookArtTest is Test {
    address constant SWAPBOARD = 0x000000dA7bb4B2A9E3e80e9A4D4157E26CA6189b;
    address constant DUTCH     = 0x000000a213b430D14Bae6062c176289B05e04489;
    address constant FLOOR     = 0x00000080198137F790DA4C52bb902cf87c276748;

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant ZORG = 0x00a6bA94BBb5474725515De88fE04F854f2dCb12;
    address constant ZORG_WHALE = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;

    /// Milady, a real ERC-721 with real holders - so the NFT cards show a
    /// collection the renderer can actually name rather than a stub.
    address constant MILADY = 0x5Af0D9827E0c53E4799BB226655A1de152A425a5;
    uint256 constant MILADY_ID = 7;

    address maker = makeAddr("maker");

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_745_140
        );
        vm.deal(maker, 500 ether);
        deal(WETH, maker, 200 ether);
        deal(USDC, maker, 500_000e6);
        deal(WBTC, maker, 20e8);
        vm.prank(ZORG_WHALE);
        (bool ok,) = ZORG.call(abi.encodeWithSignature("transfer(address,uint256)", maker, 500_000e18));
        require(ok, "zorg");
    }

    /// @dev `tokenURI` is `data:application/json;base64,…`; the image inside is
    ///      `data:image/svg+xml;base64,…`. Peel both and write the raw SVG.
    function _writeSvg(string memory uri, string memory file) internal {
        string memory json = string(Base64.decode(LibString.slice(uri, 29)));
        uint256 at = LibString.indexOf(json, "image");
        string memory rest = LibString.slice(json, at);
        uint256 b64 = LibString.indexOf(rest, "base64,");
        string memory tail = LibString.slice(rest, b64 + 7);
        tail = LibString.slice(tail, 0, LibString.indexOf(tail, '"'));
        vm.writeFile(file, string(Base64.decode(tail)));
        emit log_named_uint(file, bytes(json).length);
    }

    function test_mintOneOfEachAndDumpTheArt() public {
        vm.startPrank(maker);

        // FIXED LIMIT — sell 1 WBTC for 95,000 USDC, all or nothing, 7 days.
        IERC20(WBTC).approve(SWAPBOARD, type(uint256).max);
        uint256 a = ISwapboard(SWAPBOARD).createOrder(
            WBTC, 1e8, USDC, 95_000e6, false, uint64(block.timestamp + 7 days), false, false, address(0));
        _writeSvg(ISwapboard(SWAPBOARD).tokenURI(a), "out/art-fixed.svg");

        // DUTCH DECAY — 250,000 ZORG, 0.40 -> 0.10 WETH over 24h.
        IERC20(ZORG).approve(DUTCH, type(uint256).max);
        uint256 b = IDutchboard(DUTCH).listERC20(
            ZORG, WETH, 250_000e18, 0.4 ether, 0.1 ether, 0, uint40(24 hours), 0);
        _writeSvg(IDutchboard(DUTCH).tokenURI(b), "out/art-dutch.svg");

        // CLIMBING BID — buy 100,000 USDC, 0.0245 -> 0.0262 WETH each over 12h.
        IFloorboard.Terms memory t = IFloorboard.Terms({
            token: USDC, quote: WETH, want: 100_000e6,
            startPrice: 245e11, endPrice: 262e11,
            startTime: 0, duration: uint40(12 hours), isNFT: false, ids: new uint256[](0)});
        IERC20(WETH).approve(FLOOR, type(uint256).max);
        uint256 c = IFloorboard(FLOOR).bid(t);
        _writeSvg(IFloorboard(FLOOR).tokenURI(c), "out/art-floor.svg");

        // A second fixed limit, the other direction, to fill the fourth card.
        IERC20(USDC).approve(SWAPBOARD, type(uint256).max);
        uint256 d = ISwapboard(SWAPBOARD).createOrder(
            USDC, 4_000e6, WETH, 1 ether, true, uint64(block.timestamp + 3 days), false, false, address(0));
        _writeSvg(ISwapboard(SWAPBOARD).tokenURI(d), "out/art-partial.svg");

        vm.stopPrank();

        // NFT SALE - a Dutch on one Milady, priced in ETH. Listed by the real
        // holder, so the renderer reads a collection that exists.
        address holder = IERC721(MILADY).ownerOf(MILADY_ID);
        uint256[] memory ids = new uint256[](1);
        ids[0] = MILADY_ID;
        vm.startPrank(holder);
        IERC721(MILADY).setApprovalForAll(DUTCH, true);
        uint256 e = IDutchNFT(DUTCH).listNFT(
            MILADY, WETH, ids, 6 ether, 3 ether, 0, uint40(48 hours));
        vm.stopPrank();
        _writeSvg(IDutchNFT(DUTCH).tokenURI(e), "out/art-nftsale.svg");

        // NFT FLOOR BID - any Milady, no id named. `ids` empty is what makes it
        // a floor bid rather than an offer on one token.
        vm.startPrank(maker);
        IFloorboard.Terms memory n = IFloorboard.Terms({
            token: MILADY, quote: WETH, want: 1,
            startPrice: 2.2 ether, endPrice: 3.4 ether,
            startTime: 0, duration: uint40(72 hours), isNFT: true, ids: new uint256[](0)});
        uint256 f = IFloorboard(FLOOR).bid(n);
        _writeSvg(IFloorboard(FLOOR).tokenURI(f), "out/art-nftbid.svg");
        vm.stopPrank();
    }
}
