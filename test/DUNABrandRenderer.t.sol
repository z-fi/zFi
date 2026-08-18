// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "../lib/forge-std/src/Test.sol";
import {DUNABrandRenderer, BASE_RENDERER} from "../src/dao/DUNABrandRenderer.sol";

/// The composed renderer has to hold two properties at once, and they pull against
/// each other: the covenant must survive (it is the whole point of not pinning
/// `orgURI`), and the branding fields the coin page routes on must survive too (or a
/// DAICO renders as a plain treasury). Both are checked here against the DEPLOYED
/// base renderer and a real summon, because both failure modes are invisible to a
/// unit test with a mock.
contract DUNABrandRendererTest is Test {
    address constant SAFE_SUMMONER = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant SUMMONER = 0x0000000000330B8df9E3bc5E553074DA58eE9138;
    address constant MOLOCH_IMPL = 0x643A45B599D81be3f3A68F37EB3De55fF10673C1;
    address constant SHARE_SALE = 0x0000000021ea5069B532CeE09058aB9e02EA60f9;

    // A live DAO at the pinned block, used to exercise the base renderer.
    address constant FWC = 0xE7Aa6cA3a9Ca3fe92a425dFeaD24900B9BF49853;

    DUNABrandRenderer r;
    address creator = address(0xCA05E);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")), 25_640_000);
        r = new DUNABrandRenderer();
        vm.deal(creator, 100 ether);
    }

    // ---- fallback ----

    /// Pointing a DAO's renderer here before its branding is set must not change what
    /// the DAO says about itself. Otherwise migrating an existing DAO is a two-step
    /// operation with a window where its metadata is broken.
    function test_unregisteredDAO_returnsBareCovenant() public view {
        assertEq(
            r.daoContractURI(FWC),
            _baseContractURI(FWC),
            "an unbranded DAO did not fall through to the bare covenant"
        );
    }

    function test_tokenURI_isPassthrough() public view {
        assertEq(r.daoTokenURI(FWC, 1), _baseTokenURI(FWC, 1), "proposal art diverged from the base renderer");
    }

    /// clearBranding has to actually restore the fallthrough, not leave a husk that
    /// composes an empty document.
    function test_clearBranding_restoresCovenant() public {
        vm.prank(FWC);
        r.setBranding("ipfs://QmBrand", "ipfs://QmLogo", "cause");
        assertTrue(_contains(r.daoContractURI(FWC), '"launchType":"cause"'), "branding did not take");

        vm.prank(FWC);
        r.clearBranding();
        assertEq(r.daoContractURI(FWC), _baseContractURI(FWC), "clearBranding did not restore the covenant");
    }

    // ---- composition ----

    function test_composed_carriesBrandingAndCovenantTogether() public {
        vm.prank(FWC);
        r.setBranding("ipfs://QmBrand", "ipfs://QmLogo", "cause");
        string memory uri = r.daoContractURI(FWC);

        // Branding half — what a marketplace row and the coin page's router need.
        assertTrue(_contains(uri, '"launchType":"cause"'), "launchType missing: the coin page would render a DAICO as a plain DAO");
        assertTrue(_contains(uri, '"image":"ipfs://QmLogo"'), "logo missing");
        assertTrue(_contains(uri, '"external_url":"ipfs://QmBrand"'), "pinned document not linked");

        // Covenant half — the live document, embedded whole.
        assertTrue(_contains(uri, '"charter":"duna"'), "charter tag missing");
        assertTrue(_contains(uri, _baseContractURI(FWC)), "the live covenant is not embedded in the composed document");
    }

    /// The covenant is regenerated per read; that is the entire advantage over a pin.
    /// If the embedded copy were snapshotted at setBranding time this would fail.
    function test_embeddedCovenantTracksLiveDAOState() public {
        vm.prank(FWC);
        r.setBranding("ipfs://QmBrand", "ipfs://QmLogo", "cause");

        string memory before = r.daoContractURI(FWC);
        assertTrue(_contains(before, _baseContractURI(FWC)));

        // The base renderer reads share supply into the covenant. Move it and the
        // composed document must move with it.
        address sharesToken = _sharesOf(FWC);
        vm.prank(FWC);
        (bool ok,) = sharesToken.call(abi.encodeWithSignature("mintFromMoloch(address,uint256)", creator, 1 ether));
        vm.assume(ok); // if the mint path changes, the premise of this test is gone

        string memory later = r.daoContractURI(FWC);
        assertTrue(_contains(later, _baseContractURI(FWC)), "composed document stopped tracking the live covenant");
        assertTrue(
            keccak256(bytes(before)) != keccak256(bytes(later)),
            "covenant did not change after supply moved: it is being snapshotted, not rendered"
        );
    }

    // ---- injection ----

    /// Every interpolated field is DAO-controlled. An unescaped quote would let a DAO
    /// forge keys in its own metadata that a consumer reads as authentic on-chain data
    /// — e.g. claiming a `charter` it does not have.
    function test_brandingCannotInjectJSONKeys() public {
        vm.prank(FWC);
        r.setBranding('ipfs://x","charter":"forged', 'ipfs://y","admin":"0xdead', "cause");
        string memory uri = r.daoContractURI(FWC);

        assertTrue(_contains(uri, '"charter":"duna"'), "real charter key vanished");
        assertFalse(_contains(uri, '"charter":"forged"'), "a DAO forged its own charter field");
        assertFalse(_contains(uri, '"admin":"0xdead"'), "a DAO injected an arbitrary key");
    }

    function test_emptyLaunchTypeRejected() public {
        vm.prank(FWC);
        vm.expectRevert(DUNABrandRenderer.EmptyLaunchType.selector);
        r.setBranding("ipfs://QmBrand", "ipfs://QmLogo", "");
    }

    /// Branding is keyed by msg.sender, so one DAO must not be able to set — or
    /// inherit — another's.
    function test_brandingIsPerDAO() public {
        vm.prank(address(0xD00D));
        r.setBranding("ipfs://QmOther", "ipfs://QmOtherLogo", "cause");

        assertEq(bytes(r.branding(FWC).launchType).length, 0, "an unrelated DAO's branding leaked");
        assertEq(r.branding(address(0xD00D)).metadata, "ipfs://QmOther", "caller's own branding did not stick");
        // FWC still resolves to the bare covenant.
        assertEq(r.daoContractURI(FWC), _baseContractURI(FWC), "FWC picked up another DAO's branding");
    }

    // ---- end to end ----

    /// The whole point: one summoning transaction produces a DAO that carries the
    /// covenant AND its branding, with no follow-up tx. Branding is seeded through
    /// `extraCalls`, which Moloch executes from the DAO's own context.
    function test_summonWithCovenantAndBranding() public {
        address[] memory holders = new address[](1);
        holders[0] = creator;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1 ether;
        bytes32 salt = keccak256("duna-daico");
        address predicted = _predictDAO(salt, holders, shares);

        uint256 price = uint256(10 ether) / 10_000_000;

        Call[] memory extra = new Call[](1);
        extra[0] = Call({
            target: address(r),
            value: 0,
            data: abi.encodeCall(DUNABrandRenderer.setBranding, ("ipfs://QmPinned", "ipfs://QmLogo", "cause"))
        });

        vm.prank(creator);
        (bool ok, bytes memory ret) = SAFE_SUMMONER.call{value: price}(
            abi.encodeWithSignature(
                "safeSummonDAICO(string,string,string,uint16,bool,address,bytes32,address[],uint256[],uint256[],(uint96,uint64,uint64,uint96,uint96,bool,bool,uint256,uint256,address,bool,address,uint256,uint256,bool,bool,address,uint256,address,address,uint40),(address,address,uint40,uint256,uint256,bool,bool),(address,address,uint256,address,uint128),(address,address,uint128,address,uint128,uint40,bool,uint128),(address,uint256,bytes)[])",
                "Save The Bees",
                "BEE",
                "", // <- EMPTY orgURI: this is what lets contractURI() reach the renderer
                uint16(1000),
                true,
                address(r), // <- the composing renderer, not the base one
                salt,
                holders,
                shares,
                new uint256[](0),
                _config(),
                SaleModule(SHARE_SALE, address(0), uint40(block.timestamp + 30 days), price, 9_999_999 ether, false, true),
                TapModule(address(0), address(0), 0, address(0), 0),
                SeedModule(address(0), address(0), 0, address(0), 0, 0, false, 0),
                extra
            )
        );
        require(ok, "safeSummonDAICO reverted");
        address dao = abi.decode(ret, (address));
        assertEq(dao, predicted, "prediction drifted");

        // contractURI() must reach the renderer rather than short-circuiting on _orgURI.
        (bool got, bytes memory cu) = dao.staticcall(abi.encodeWithSignature("contractURI()"));
        assertTrue(got, "contractURI reverted");
        string memory uri = abi.decode(cu, (string));

        assertTrue(_contains(uri, '"launchType":"cause"'), "summoned DAO lost its launch type");
        assertTrue(_contains(uri, '"external_url":"ipfs://QmPinned"'), "summoned DAO lost its pinned metadata");
        assertTrue(_contains(uri, '"charter":"duna"'), "summoned DAO is not under the covenant");
        assertTrue(_contains(uri, '"name":"Save The Bees"'), "composed document lost the DAO name");
    }

    /// A cause summoned the OLD way — metadata pinned into orgURI — must keep working
    /// untouched. The launch path stays selectable, so this is not a migration.
    function test_pinnedOrgURIStillShortCircuits() public {
        address[] memory holders = new address[](1);
        holders[0] = creator;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1 ether;
        uint256 price = uint256(10 ether) / 10_000_000;

        vm.prank(creator);
        (bool ok, bytes memory ret) = SAFE_SUMMONER.call{value: price}(
            abi.encodeWithSignature(
                "safeSummonDAICO(string,string,string,uint16,bool,address,bytes32,address[],uint256[],uint256[],(uint96,uint64,uint64,uint96,uint96,bool,bool,uint256,uint256,address,bool,address,uint256,uint256,bool,bool,address,uint256,address,address,uint40),(address,address,uint40,uint256,uint256,bool,bool),(address,address,uint256,address,uint128),(address,address,uint128,address,uint128,uint40,bool,uint128),(address,uint256,bytes)[])",
                "Legacy Cause",
                "LEG",
                "ipfs://QmLegacy",
                uint16(1000),
                true,
                address(r),
                keccak256("legacy"),
                holders,
                shares,
                new uint256[](0),
                _config(),
                SaleModule(SHARE_SALE, address(0), uint40(block.timestamp + 30 days), price, 9_999_999 ether, false, true),
                TapModule(address(0), address(0), 0, address(0), 0),
                SeedModule(address(0), address(0), 0, address(0), 0, 0, false, 0),
                new Call[](0)
            )
        );
        require(ok, "safeSummonDAICO reverted");
        address dao = abi.decode(ret, (address));

        (, bytes memory cu) = dao.staticcall(abi.encodeWithSignature("contractURI()"));
        assertEq(abi.decode(cu, (string)), "ipfs://QmLegacy", "a pinned orgURI no longer short-circuits");
    }

    // ---- helpers ----

    struct Config {
        uint96 proposalThreshold;
        uint64 proposalTTL;
        uint64 timelockDelay;
        uint96 quorumAbsolute;
        uint96 minYesVotes;
        bool lockShares;
        bool lockLoot;
        uint256 autoFutarchyParam;
        uint256 autoFutarchyCap;
        address futarchyRewardToken;
        bool saleActive;
        address salePayToken;
        uint256 salePricePerShare;
        uint256 saleCap;
        bool saleMinting;
        bool saleIsLoot;
        address burnSingleton;
        uint256 saleBurnDeadline;
        address rollbackGuardian;
        address rollbackSingleton;
        uint40 rollbackExpiry;
    }

    struct SaleModule {
        address singleton;
        address payToken;
        uint40 deadline;
        uint256 price;
        uint256 cap;
        bool sellLoot;
        bool minting;
    }

    struct TapModule {
        address singleton;
        address token;
        uint256 budget;
        address beneficiary;
        uint128 ratePerSec;
    }

    struct SeedModule {
        address singleton;
        address tokenA;
        uint128 amountA;
        address tokenB;
        uint128 amountB;
        uint40 deadline;
        bool gateBySale;
        uint128 minSupply;
    }

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    function _config() internal pure returns (Config memory c) {
        c.proposalThreshold = 1 ether;
        c.proposalTTL = 7 days;
        c.timelockDelay = 2 days;
        c.quorumAbsolute = 1 ether;
    }

    function _baseContractURI(address dao) internal view returns (string memory) {
        (bool ok, bytes memory d) =
            BASE_RENDERER.staticcall(abi.encodeWithSignature("daoContractURI(address)", dao));
        require(ok, "base daoContractURI failed");
        return abi.decode(d, (string));
    }

    function _baseTokenURI(address dao, uint256 id) internal view returns (string memory) {
        (bool ok, bytes memory d) =
            BASE_RENDERER.staticcall(abi.encodeWithSignature("daoTokenURI(address,uint256)", dao, id));
        require(ok, "base daoTokenURI failed");
        return abi.decode(d, (string));
    }

    function _sharesOf(address dao) internal view returns (address) {
        (bool ok, bytes memory d) = dao.staticcall(abi.encodeWithSignature("shares()"));
        require(ok, "shares() failed");
        return abi.decode(d, (address));
    }

    function _predictDAO(bytes32 salt, address[] memory holders, uint256[] memory shares)
        internal
        pure
        returns (address)
    {
        bytes memory code = abi.encodePacked(
            hex"602d5f8160095f39f35f5f365f5f37365f73", MOLOCH_IMPL, hex"5af43d5f5f3e6029573d5ffd5b3d5ff3"
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), SUMMONER, keccak256(abi.encode(holders, shares, salt)), keccak256(code)
                        )
                    )
                )
            )
        );
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool hit = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
