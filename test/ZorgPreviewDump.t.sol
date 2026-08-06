// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListRenderer} from "../src/utils/TokenListRenderer.sol";
import {PostDeployListings} from "./PostDeployListings.sol";
import {ZorgConviction, IERC721Zorgz, IWeiNames} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {MockShares, MockWeiNames} from "./ZorgConviction.t.sol";

/// Builds the zOrg dashboard preview out of REAL state rather than mock data.
///
/// The dapp is a thin client over `eth_call`, so a faithful preview does not
/// need a mock at all - it needs the genuine returndata. This deploys the real
/// `TokenList` and its renderer on the mainnet fork (seeding is chain-id-1 only,
/// which is what makes the canonical set exist), applies the same post-deploy
/// listings the owner will, points a real `ZorgConviction` at it, and bonds the
/// REAL zOrgz #9953 from its actual holder.
///
/// It then records the exact bytes each `eth_call` returns. The preview replays
/// those, so what it paints is what the deployed page paints - same ids, same
/// onchain logo SVGs, same ranking, same receipt art.
contract ZorgPreviewDumpTest is Test, PostDeployListings {
    TokenList list;
    ZorgConviction conviction;
    MockShares shares;

    uint256 constant RID = 9953;
    /// @dev Placeholder: ZorgConviction has no mined CREATE2 salt yet.
    address constant CREATE2_CONVICTION = 0x00000000000000000000000000000000c0117c71;
    address owner = address(0xA11CE);
    address holder;

    string dump;
    uint256 entries;

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

        shares = new MockShares();
        MockWeiNames names = new MockWeiNames();
        names.mint(address(0xD0A1), "zorg.wei");
        conviction = new ZorgConviction(
            address(0xDA0),
            address(shares),
            IERC721Zorgz(ZORGZ),
            IWeiNames(address(names)),
            address(list),
            new ZorgConvictionRenderer(new ZorgPageStyle()), new ZorgReceiptArt(),
            7 days
        );

        // Bond the real zOrgz from the address that actually holds it, so the
        // receipt art comes from the live collection rather than a stand-in.
        holder = IERC721Zorgz(ZORGZ).ownerOf(RID);
        shares.mint(holder, 1200 ether);
        vm.deal(holder, 1 ether);
        vm.startPrank(holder);
        shares.approve(address(conviction), type(uint256).max);
        (bool ok,) = ZORGZ.call(abi.encodeWithSignature("approve(address,uint256)", address(conviction), RID));
        require(ok, "approve");
        conviction.bondZorgz{value: 0.1 ether}(RID, 1200 ether, 3);
        vm.stopPrank();
    }

    function _rec(string memory key, address target, bytes memory data) internal {
        (bool ok, bytes memory out) = target.staticcall(data);
        require(ok, string.concat("call failed: ", key));
        dump = string.concat(dump, entries++ == 0 ? "" : ",", '"', key, '":"', vm.toString(out), '"');
    }

    function testDumpPreviewState() public {
        uint256[] memory ids = list.rankedIds();
        require(ids.length > 3, "empty registry");

        // A receipt with live support, so the preview shows allocation in place
        // rather than an untouched list.
        vm.startPrank(holder);
        conviction.allocate(RID, ids[2], 340 ether);
        conviction.allocate(RID, ids[0], 120 ether);
        vm.stopPrank();
        // Let conviction accrue so live and accrued components are both visible.
        skip(21 days);

        dump = "{";
        _rec("ids", address(list), abi.encodeWithSignature("rankedIds()"));
        for (uint256 i; i < ids.length; ++i) {
            string memory n = LibString.toString(ids[i]);
            _rec(string.concat("json:", n), address(list), abi.encodeWithSignature("json(uint256)", ids[i]));
            _rec(string.concat("state:", n), address(conviction), abi.encodeWithSignature("listingState(uint256)", ids[i]));
            _rec(
                string.concat("allocOf:", n),
                address(conviction),
                abi.encodeWithSignature("allocationOf(uint256,uint256)", RID, ids[i])
            );
        }
        for (uint8 t = 1; t <= 3; ++t) {
            _rec(
                string.concat("tiers:", LibString.toString(t)),
                address(conviction),
                abi.encodeWithSignature("lockTiers(uint8)", t)
            );
        }
        // The page now asks the zOrgz collection directly - does this wallet
        // hold one, and what does that id look like - so record those too.
        _rec("zorgzAddr", address(conviction), abi.encodeWithSignature("zorgz()"));
        _rec("zorgzBal", ZORGZ, abi.encodeWithSignature("balanceOf(address)", holder));
        _rec("zorgzUri", ZORGZ, abi.encodeWithSignature("tokenURI(uint256)", RID));
        _rec("weight", address(conviction), abi.encodeWithSignature("bondedWeight(uint256)", RID));
        _rec("used", address(conviction), abi.encodeWithSignature("allocatedByBond(uint256)", RID));
        _rec("locks", address(conviction), abi.encodeWithSignature("receiptLocks(uint256)", RID));
        _rec("isEternal", address(conviction), abi.encodeWithSignature("eternalBonds(uint256)", RID));
        _rec("loyalty", address(conviction), abi.encodeWithSignature("loyaltyOf(uint256)", RID));
        _rec("ethBond", address(conviction), abi.encodeWithSignature("ethBonds(uint256)", RID));
        _rec("uri", address(conviction), abi.encodeWithSignature("tokenURI(uint256)", RID));
        _rec("owner", address(conviction), abi.encodeWithSignature("ownerOf(uint256)", RID));
        dump = string.concat(dump, "}");

        vm.writeFile("./dapp/zlist/preview-state.json", dump);
        // Render the page against the DETERMINISTIC addresses rather than this
        // test's throwaway deploys, so the preview's OpenSea links and error
        // messages carry the addresses the contracts will actually occupy.
        // TokenList's is the mined CREATE2 target in deploy/TokenList.md; the
        // governor has no mined salt yet, so its placeholder is marked as one.
        string memory page = ZorgConvictionRenderer(address(conviction.renderer())).html(
            CREATE2_CONVICTION, 0x000000146057913eC6A42a961D2E6Cb179f16272
        );
        vm.writeFile("./dapp/zlist/renderer-output.html", page);
        emit log_named_uint("listings", ids.length);
        emit log_named_uint("state bytes", bytes(dump).length);
        emit log_named_uint("html bytes", bytes(page).length);
    }
}
