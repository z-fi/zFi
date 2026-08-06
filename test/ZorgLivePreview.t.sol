// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {ZorgConviction, IERC721Zorgz, IWeiNames} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {IZorgConvictionRenderer} from "../src/dao/IZorgConvictionRenderer.sol";
import {IZorgReceiptArt} from "../src/dao/IZorgReceiptArt.sol";
import {MockShares, MockWeiNames} from "./ZorgConviction.t.sol";

/// @notice Renders the dashboard as it will exist — mined render stack at its real
///         CREATE2 addresses — and records the exact returndata each `eth_call`
///         yields, with the TokenList half coming from the LIVE deployed registry.
contract ZorgLivePreviewTest is Test {
    address constant SUMMONER = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant TOKENLIST = 0x0000006013dF75A31678B786061C2B54bf531524;
    address constant ZORGZ = 0x00000000008835ceF3E0D2333695f288Ee6b63A6;
    address constant PAGE_STYLE = 0x000000507b8F2DEE4893269De45652B960061941;
    address constant RECEIPT_ART = 0x0000007f4342bdddA2A951b9e181B42328DD1eD9;
    address constant RENDERER = 0x000000115B1B95b9e04128a2Bcd9eD9D24AB141c;
    address constant CONVICTION = 0x0000006D936bA3653b8854490E16E782cd32a9a8;

    uint256 constant RID = 9953;
    ZorgConviction sim;
    address holder;
    string dump;
    uint256 n;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_694_520);
        string[3] memory names = ["ZorgPageStyle", "ZorgReceiptArt", "ZorgConvictionRenderer"];
        for (uint256 i; i < names.length; ++i) {
            address at = [PAGE_STYLE, RECEIPT_ART, RENDERER][i];
            if (at.code.length != 0) continue; // already live on mainnet
            bytes memory ic = vm.readFileBinary(string.concat("deploy/", names[i], ".initcode.bin"));
            bytes32 salt = vm.parseBytes32(vm.trim(vm.readFile(string.concat("deploy/", names[i], ".salt.txt"))));
            (bool ok,) = SUMMONER.call(abi.encodeWithSignature("create2Deploy(bytes,bytes32)", ic, salt));
            require(ok, names[i]);
        }
        // A stand-in governor with mock shares (the real share token is a proxy with a
        // transfer gate). It points at the LIVE registry, so every listing figure the
        // page shows is real; only the conviction numbers are simulated.
        MockShares shares = new MockShares();
        MockWeiNames wn = new MockWeiNames();
        sim = new ZorgConviction(
            address(0xDA0), address(shares), IERC721Zorgz(ZORGZ), IWeiNames(address(wn)),
            TOKENLIST, IZorgConvictionRenderer(RENDERER), IZorgReceiptArt(RECEIPT_ART), 3 days
        );
        holder = IERC721Zorgz(ZORGZ).ownerOf(RID);
        shares.mint(holder, 1200 ether);
        vm.deal(holder, 1 ether);
        vm.startPrank(holder);
        shares.approve(address(sim), type(uint256).max);
        (bool k,) = ZORGZ.call(abi.encodeWithSignature("approve(address,uint256)", address(sim), RID));
        require(k, "zorgz approve");
        sim.bondZorgz{value: 0.1 ether}(RID, 1200 ether, 3);
        vm.stopPrank();
    }

    function _rec(address to, bytes memory data, address keyAs) internal {
        (bool ok, bytes memory out) = to.staticcall(data);
        require(ok, "call failed");
        dump = string.concat(dump, n++ == 0 ? "" : ",",
            '"', LibString.toHexString(keyAs), ":", vm.toString(data), '":"', vm.toString(out), '"');
    }

    function testRenderAndRecord() public {
        (, bytes memory r) = TOKENLIST.staticcall(abi.encodeWithSignature("rankedIds()"));
        uint256[] memory ids = abi.decode(r, (uint256[]));
        assertGe(ids.length, 11, "live registry seeded");

        vm.startPrank(holder);
        sim.allocate(RID, ids[2], 340 ether);  // wstETH
        sim.allocate(RID, ids[ids.length > 8 ? 8 : ids.length - 1], 260 ether);
        sim.allocate(RID, ids[0], 120 ether);  // ETH
        vm.stopPrank();
        skip(9 days); // three half-lives

        dump = "{";
        _rec(TOKENLIST, abi.encodeWithSignature("rankedIds()"), TOKENLIST);
        for (uint256 i; i < ids.length; ++i) {
            _rec(TOKENLIST, abi.encodeWithSignature("json(uint256)", ids[i]), TOKENLIST);
            _rec(address(sim), abi.encodeWithSignature("listingState(uint256)", ids[i]), CONVICTION);
            _rec(address(sim), abi.encodeWithSignature("allocationOf(uint256,uint256)", RID, ids[i]), CONVICTION);
        }
        for (uint8 t = 1; t <= 3; ++t) {
            _rec(address(sim), abi.encodeWithSignature("lockTiers(uint8)", t), CONVICTION);
        }
        _rec(address(sim), abi.encodeWithSignature("zorgz()"), CONVICTION);
        _rec(address(sim), abi.encodeWithSignature("bondedWeight(uint256)", RID), CONVICTION);
        _rec(address(sim), abi.encodeWithSignature("allocatedByBond(uint256)", RID), CONVICTION);
        _rec(address(sim), abi.encodeWithSignature("receiptLocks(uint256)", RID), CONVICTION);
        _rec(address(sim), abi.encodeWithSignature("eternalBonds(uint256)", RID), CONVICTION);
        _rec(address(sim), abi.encodeWithSignature("loyaltyOf(uint256)", RID), CONVICTION);
        _rec(address(sim), abi.encodeWithSignature("ethBonds(uint256)", RID), CONVICTION);
        _rec(address(sim), abi.encodeWithSignature("tokenURI(uint256)", RID), CONVICTION);
        _rec(address(sim), abi.encodeWithSignature("ownerOf(uint256)", RID), CONVICTION);
        _rec(ZORGZ, abi.encodeWithSignature("balanceOf(address)", holder), ZORGZ);
        _rec(ZORGZ, abi.encodeWithSignature("tokenURI(uint256)", RID), ZORGZ);
        dump = string.concat(dump, "}");
        vm.writeFile("./dapp/zlist/live-state.json", dump);

        string memory page = ZorgConvictionRenderer(RENDERER).html(CONVICTION, TOKENLIST);
        vm.writeFile("./dapp/zlist/live-preview.html", page);
        emit log_named_uint("page bytes", bytes(page).length);
        emit log_named_uint("recorded calls", n);
        emit log_named_address("wallet in preview", holder);
    }
}
