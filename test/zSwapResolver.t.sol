// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {zSwap} from "../src/zSwap.sol";
import {zSwapResolver, IzSwap} from "../src/utils/zSwapResolver.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";

/// @notice The name follows the chain, without a second transaction.
///
/// The property under test is not "addr() returns an address". It is that
/// there is NO MOMENT at which the chain and the name disagree: the resolver
/// stores nothing, so the DAO's `deployNext` is the only write, and the name's
/// answer changes with it. Every test here is written against that.
contract zSwapResolverTest is Test {
    /// The DAO is a constant in the resolver, so the tests speak as it.
    address dao = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;
    address stranger = makeAddr("stranger");

    uint256 constant CHUNKS = 16;
    address[CHUNKS] chunks;

    zSwapResolver resolver;
    zSwap rootV1;

    function setUp() public {
        for (uint256 i; i != CHUNKS; ++i) {
            bytes memory code = abi.encodePacked(hex"60", uint8(i + 1), hex"60005360016000f3");
            address a;
            assembly {
                a := create(0, add(code, 0x20), mload(code))
            }
            chunks[i] = a;
        }
        rootV1 = new zSwap(dao, address(0), chunks);
        resolver = new zSwapResolver(IzSwap(address(rootV1)));
    }

    /// The root this resolver was constructed against. Tests that want a
    /// SECOND, unrelated root build one explicitly.
    function _root() internal view returns (zSwap) {
        return rootV1;
    }

    function _initcode(address previous) internal view returns (bytes memory) {
        return abi.encodePacked(type(zSwap).creationCode, abi.encode(dao, previous, chunks));
    }

    bytes32 constant NODE = keccak256("zswap.eth");

    // ------------------------------------------------------ construction

    /// `ROOT` is a constructor argument, so the lineage this name follows is
    /// fixed by the bytes anyone can read - not by a later transaction that
    /// could name a different one.
    function test_theRootIsFixedAtConstruction() public view {
        assertEq(address(resolver.ROOT()), address(rootV1));
        assertEq(resolver.current(), address(rootV1));
        assertEq(resolver.addr(NODE), payable(address(rootV1)));
    }

    /// Starting mid-chain would serve the tip of a lineage whose earlier links
    /// this name never named, and would hide them from anyone walking back.
    function test_refusesToBeBuiltAnywhereButTheRoot() public {
        zSwap v1 = _root();
        vm.prank(dao);
        address v2 = v1.deployNext(_initcode(address(v1)), bytes32(uint256(1)));

        vm.expectRevert(zSwapResolver.NotTheRoot.selector);
        new zSwapResolver(IzSwap(v2));
    }

    /// A contract that answers `PREVIOUS()` but not `successor()` cannot be
    /// walked forward, so every resolution it backed would be useless.
    function test_refusesToBeBuiltOnSomethingThatIsNotAzSwap() public {
        address notAzSwap;
        bytes memory code = hex"600b80600a3d393df360006000f3";
        assembly {
            notAzSwap := create(0, add(code, 0x20), mload(code))
        }
        vm.expectRevert();
        new zSwapResolver(IzSwap(notAzSwap));

        // Answers PREVIOUS() with zero and nothing else: passes the root check,
        // fails the forward one.
        address halfAzSwap;
        bytes memory half = hex"600d80600a3d393df3600060005260206000f3";
        assembly {
            halfAzSwap := create(0, add(half, 0x20), mload(half))
        }
        vm.expectRevert();
        new zSwapResolver(IzSwap(halfAzSwap));
    }

    /// A resolver that throws does not fail politely - the name stops
    /// resolving and every gateway serving it goes dark.
    function test_theReadPathNeverReverts() public view {
        resolver.addr(NODE);
        resolver.addr(NODE, 60);
        resolver.text(NODE, "avatar");
        resolver.current();
    }

    // ------------------------------------------------- the name follows along

    /// THE TEST THIS CONTRACT EXISTS FOR. The DAO's upgrade is the ONLY write:
    /// no `setAddr`, no second proposal, and nothing anyone has to remember.
    /// The name changes on its own once the new version has stood for
    /// `MATURITY` - see the maturity section for why it is not instant.
    function test_theUpgradeIsTheNameUpdate() public {
        zSwap v1 = _root();
        assertEq(resolver.addr(NODE), payable(address(v1)), "before: the name is v0.1");

        vm.prank(dao);
        address v2 = v1.deployNext(_initcode(address(v1)), bytes32(uint256(2)));
        vm.warp(block.timestamp + resolver.MATURITY());

        assertEq(resolver.addr(NODE), payable(v2), "after: the name is v0.2, with no further write");
        assertEq(address(resolver.ROOT()), address(v1), "and the root never moved");
    }

    function test_followsTheChainAcrossSeveralVersions() public {
        zSwap v1 = _root();
        vm.startPrank(dao);
        address v2 = v1.deployNext(_initcode(address(v1)), bytes32(uint256(3)));
        address v3 = zSwap(v2).deployNext(_initcode(v2), bytes32(uint256(4)));
        address v4 = zSwap(v3).deployNext(_initcode(v3), bytes32(uint256(5)));
        vm.stopPrank();
        vm.warp(block.timestamp + resolver.MATURITY());

        assertEq(resolver.addr(NODE), payable(v4));
        assertEq(zSwap(v4).generation(), 4);
        // And every predecessor still serves its own page at its own address.
        assertEq(zSwap(v2).html(), v1.html());
        assertEq(v1.successor(), v2);
    }

    // ---------------------------------------------------------- the records

    /// ERC-6821: what a `web3://` gateway reads to learn it should render a
    /// CONTRACT. Same walk as `addr`, so the two can never point apart.
    function test_contentcontractNamesTheTipInErc3770Form() public {
        zSwap v1 = _root();
        vm.startPrank(dao);
        address v2 = v1.deployNext(_initcode(address(v1)), bytes32(uint256(6)));
        vm.stopPrank();
        vm.warp(block.timestamp + resolver.MATURITY());

        string memory got = resolver.text(NODE, "contentcontract");
        assertEq(got, string.concat("eip155:1:", vm.toString(v2)));
        assertEq(bytes(resolver.text(NODE, "url")).length, 0, "no other text record is invented");
    }

    function test_coinTypeSixtyOnly() public {
        zSwap v1 = _root();

        assertEq(resolver.addr(NODE, 60), abi.encodePacked(address(v1)));
        assertEq(resolver.addr(NODE, 0).length, 0, "bitcoin has no zSwap");
    }

    function test_declaresTheInterfacesItServes() public view {
        assertTrue(resolver.supportsInterface(0x3b3b57de), "addr(bytes32)");
        assertTrue(resolver.supportsInterface(0xf1cb7e06), "addr(bytes32,uint256)");
        assertTrue(resolver.supportsInterface(0x59d1d43c), "text(bytes32,string)");
        assertTrue(resolver.supportsInterface(0x01ffc9a7), "ERC-165");
        assertFalse(resolver.supportsInterface(0xbc1c58d1), "contenthash: deliberately absent");
    }

    /// The node is ignored on purpose - one resolver, one name - and saying so
    /// in a test is cheaper than someone discovering it by setting it on two.
    function test_theNodeIsIgnored() public {
        zSwap v1 = _root();
        assertEq(resolver.addr(keccak256("something.else.eth")), resolver.addr(NODE));
    }

    // ------------------------------------------------------- the live page

    /// The name resolves to an address, so something at that address has to
    /// serve a page. This one does - the CURRENT version's, whichever that is.
    function test_servesTheCurrentVersionsPage() public {
        zSwap v1 = _root();
        assertEq(resolver.html(), v1.html(), "before: the root's page");

        vm.prank(dao);
        address v2 = v1.deployNext(_initcode(address(v1)), bytes32(uint256(7)));

        assertEq(resolver.html(), zSwap(v2).html(), "after: v0.2's page, same address");
        assertEq(v1.html(), zSwap(v2).html(), "(identical chunks in this fixture)");
        assertEq(v1.successor(), v2);
    }

    /// THE HEADER THAT MATTERS. A version says `immutable` because it is one.
    /// This address is not: cached as permanent, it would serve a stale version
    /// long after the chain moved on - the exact failure it exists to prevent.
    function test_theLivePageIsNeverCachedAsImmutable() public {
        zSwap v1 = _root();

        (uint16 code, string memory body, zSwapResolver.KeyValue[] memory headers) =
            resolver.request(new string[](0), new zSwapResolver.KeyValue[](0));

        assertEq(code, 200);
        assertEq(body, v1.html());
        assertEq(headers[0].value, "text/html");
        assertEq(headers[1].value, "public, max-age=300");
        assertFalse(LibString.contains(headers[1].value, "immutable"), "never immutable, unlike a version");
        // The version it relays says the opposite, and is right to.
        (,, zSwap.KeyValue[] memory vh) = v1.request(new string[](0), new zSwap.KeyValue[](0));
        assertTrue(LibString.contains(vh[1].value, "immutable"));
        assertEq(resolver.resolveMode(), "5219");
    }

    /// Relaying a 200 KB page is the operation a gateway performs on every
    /// request. If it costs more than a node's `eth_call` cap, the name is
    /// unusable no matter how correct the walk is.
    function test_relayingTheRealPageStaysWithinAnEthCallBudget() public {
        bytes memory page = vm.readFileBinary("zSwap.html");
        uint256 per = (page.length + CHUNKS - 1) / CHUNKS;
        address[CHUNKS] memory real;
        for (uint256 k; k < CHUNKS; ++k) {
            uint256 start = k * per;
            uint256 end = start + per > page.length ? page.length : start + per;
            bytes memory part = new bytes(end - start);
            for (uint256 i; i < end - start; ++i) part[i] = page[start + i];
            bytes memory initcode = bytes.concat(hex"61", bytes2(uint16(part.length)), hex"80600a5f395ff3", part);
            address p;
            assembly { p := create(0, add(initcode, 0x20), mload(initcode)) }
            real[k] = p;
        }
        zSwap v1 = new zSwap(dao, address(0), real);
        // Its own resolver: `ROOT` is immutable, so a resolver for a different
        // root is a different resolver - which is the property under test
        // everywhere else in this file.
        zSwapResolver live = new zSwapResolver(IzSwap(address(v1)));

        uint256 before = gasleft();
        string memory served = live.html();
        uint256 used = before - gasleft();
        emit log_named_uint("bytes served", bytes(served).length);
        emit log_named_uint("gas to relay", used);
        assertEq(keccak256(bytes(served)), keccak256(page), "byte-identical to the repo file");
        assertLt(used, 30_000_000, "must fit a public node's eth_call budget");
    }

    // ---------------------------------------------------------- holding a name

    /// A `safeTransferFrom` of the name to a contract that does not accept
    /// ERC-721 reverts. The whole plan would fail at its last step.
    function test_acceptsTheNameNft() public {
        MockNameNFT nft = new MockNameNFT();
        nft.mint(dao, 1);
        vm.prank(dao);
        nft.safeTransferFrom(dao, address(resolver), 1);
        assertEq(nft.ownerOf(1), address(resolver), "the resolver holds the name");
    }

    /// A name held by a contract that cannot renew or re-point it is buried,
    /// not safe. The DAO keeps a registrant's reach - and only into WNS.
    function test_theDaoCanStillManageTheNameButOnlyAtTheRegistry() public {
        vm.prank(stranger);
        vm.expectRevert(zSwapResolver.NotDAO.selector);
        resolver.manage(hex"deadbeef");

        // The call goes to WNS and nowhere else: proven by etching code at the
        // registry address and watching it be the thing that answers.
        vm.etch(resolver.WNS(), hex"600160005260206000f3");
        vm.prank(dao);
        bytes memory ret = resolver.manage(hex"12345678");
        assertEq(abi.decode(ret, (uint256)), 1, "the registry answered");
    }

    /// A revert inside WNS must surface as WNS's revert, not a bare failure:
    /// a renewal that fails for lack of payment should say so.
    function test_manageBubblesTheRegistrysRevert() public {
        vm.etch(resolver.WNS(), hex"60006000fd");
        vm.prank(dao);
        vm.expectRevert();
        resolver.manage(hex"12345678");
    }

    /// `manage` reaches one contract, so it cannot reach the two things that
    /// would matter: which lineage this resolver follows, and what it serves.
    function test_manageCannotTouchTheRoot() public {
        zSwap v1 = _root();
        vm.startPrank(dao);
        vm.etch(resolver.WNS(), hex"600160005260206000f3");
        resolver.manage(abi.encodeWithSignature("setRoot(address)", address(0xdead)));
        vm.stopPrank();
        assertEq(address(resolver.ROOT()), address(v1), "immutable, and unreachable from manage");
        assertEq(resolver.current(), address(v1));
    }

    /// `latest()` stops at 32 hops, so a name that asked once would freeze on
    /// version 32 and serve it forever - silent staleness, which is the one
    /// failure this contract exists to rule out. It asks again from where the
    /// last answer landed.
    function test_followsTheChainPastLatestsOwnBound() public {
        zSwap v1 = _root();
        vm.startPrank(dao);
        address cur = address(v1);
        for (uint256 i; i != 40; ++i) {
            cur = zSwap(cur).deployNext(_initcode(cur), bytes32(i + 100));
        }
        vm.stopPrank();
        vm.warp(block.timestamp + resolver.MATURITY());

        assertEq(v1.latest(), address(0) == cur ? cur : v1.latest(), "sanity");
        assertTrue(v1.latest() != cur, "one walk cannot reach the tip past 32 hops");
        assertEq(resolver.current(), cur, "the resolver reaches it anyway");
        assertEq(resolver.addr(NODE), payable(cur));
    }

    // ------------------------------------------------------------- maturity

    /// A compromised DAO can name a successor in one transaction. Without a
    /// delay the name would carry every reader there in the same block; with
    /// one, the chain records it instantly and the NAME waits.
    function test_theNameDoesNotFollowAFreshSuccessorImmediately() public {
        zSwap v1 = _root();
        vm.startPrank(dao);
        address v2 = v1.deployNext(_initcode(address(v1)), bytes32(uint256(20)));
        vm.stopPrank();

        assertEq(v1.successor(), v2, "the chain records it at once");
        assertEq(v1.latest(), v2, "and says so to anyone who asks");
        assertEq(resolver.current(), address(v1), "but the name still serves v0.1");
        assertEq(resolver.html(), v1.html());
    }

    function test_theNameFollowsOnceTheDelayHasPassed() public {
        zSwap v1 = _root();
        vm.startPrank(dao);
        address v2 = v1.deployNext(_initcode(address(v1)), bytes32(uint256(21)));
        vm.stopPrank();

        vm.warp(block.timestamp + resolver.MATURITY() - 1);
        assertEq(resolver.current(), address(v1), "one second short is still short");

        vm.warp(block.timestamp + 1);
        assertEq(resolver.current(), v2, "and then the name moves, with no transaction");
        assertEq(resolver.addr(NODE), payable(v2));
    }

    /// The timestamp is written by the predecessor, in the same transaction
    /// that sets the pointer, so it cannot be backdated by whoever deployed it.
    function test_theClockIsTheChainsNotTheDeployers() public {
        zSwap v1 = _root();
        vm.warp(1_700_000_000);
        vm.prank(dao);
        v1.deployNext(_initcode(address(v1)), bytes32(uint256(22)));
        assertEq(v1.succeededAt(), 1_700_000_000);
        assertEq(v1.succeededAt(), uint96(block.timestamp));
    }

    /// Shipping twice in a week must not strand the name on the older of two
    /// young versions - it walks back to the newest one that has stood long.
    function test_walksBackThroughABurstOfYoungVersions() public {
        zSwap v1 = _root();
        vm.startPrank(dao);
        address v2 = v1.deployNext(_initcode(address(v1)), bytes32(uint256(23)));
        vm.warp(block.timestamp + 4 days);
        address v3 = zSwap(v2).deployNext(_initcode(v2), bytes32(uint256(24)));
        address v4 = zSwap(v3).deployNext(_initcode(v3), bytes32(uint256(25)));
        vm.stopPrank();

        assertEq(zSwap(v3).latest(), v4, "the chain is at v0.4");
        assertEq(resolver.current(), v2, "the name is at the newest MATURE version");

        vm.warp(block.timestamp + 3 days);
        assertEq(resolver.current(), v4, "and catches up to the tip together");
    }

    /// A chain that predates the field reports zero, and must still resolve.
    /// Refusing to serve those would break the name rather than protect it.
    function test_aChainThatDoesNotDateItsLinksIsTreatedAsMature() public {
        zSwap v1 = _root();
        vm.prank(dao);
        address v2 = v1.deployNext(_initcode(address(v1)), bytes32(uint256(26)));

        // Force the predecessor's clock to zero, as a pre-field chain reports.
        vm.store(address(v1), bytes32(uint256(0)), bytes32(uint256(uint160(v2))));
        assertEq(v1.succeededAt(), 0);
        assertEq(resolver.current(), v2, "no clock means no delay, not no service");
    }

    // -------------------------------------------------------- the version list

    /// A page served through the NAME cannot tell which version it is, so it
    /// has to ask - and asking hop by hop is a round trip per version.
    function test_versionsListsTheWholeChainOldestFirst() public {
        zSwap v1 = _root();
        vm.startPrank(dao);
        address v2 = v1.deployNext(_initcode(address(v1)), bytes32(uint256(30)));
        address v3 = zSwap(v2).deployNext(_initcode(v2), bytes32(uint256(31)));
        vm.stopPrank();

        address[] memory list = resolver.versions();
        assertEq(list.length, 3);
        assertEq(list[0], address(v1), "oldest first: the root is version one");
        assertEq(list[1], v2);
        assertEq(list[2], v3);
    }

    function test_versionsIsJustTheRootBeforeAnyUpgrade() public view {
        address[] memory list = resolver.versions();
        assertEq(list.length, 1);
        assertEq(list[0], address(rootV1));
    }

    /// The list shows what EXISTS; `current()` says what is SERVED. A picker
    /// needs both, and hiding a version the name is still waiting on would be
    /// the same silence this contract was built to remove.
    function test_versionsShowsTheTipEvenWhileTheNameStillWaits() public {
        zSwap v1 = _root();
        vm.prank(dao);
        address v2 = v1.deployNext(_initcode(address(v1)), bytes32(uint256(32)));

        address[] memory list = resolver.versions();
        assertEq(list.length, 2, "the fresh version is listed");
        assertEq(list[1], v2);
        assertEq(resolver.current(), address(v1), "but not yet served");
    }
}

/// Minimal ERC-721 with a real `safeTransferFrom` acceptance check - the only
/// behaviour this suite needs from a NameNFT.
contract MockNameNFT {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "not owner");
        require(msg.sender == from, "not sender");
        ownerOf[id] = to;
        if (to.code.length != 0) {
            bytes4 ret = IERC721Receiver(to).onERC721Received(msg.sender, from, id, "");
            require(ret == IERC721Receiver.onERC721Received.selector, "unsafe recipient");
        }
    }
}

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}



/// A zSwap-SHAPED root, so a chain can be pointed somewhere `deployNext` would
/// never allow. Not a zSwap: the point is a chain this resolver was not built
/// against, which is the only kind that can be malformed.
contract MalformedRoot {
    address public latest;
    address public constant PREVIOUS = address(0);

    function successor() external view returns (address) {
        return latest;
    }

    function succeededAt() external pure returns (uint96) {
        return 1;
    }

    function html() external pure returns (string memory) {
        return "";
    }

    function point(address a) external {
        latest = a;
    }
}

/// @notice The read path never reverts - INCLUDING on a link with no code.
///
/// `try/catch` does not catch a call to a codeless address: the compiler's
/// `extcodesize` check reverts before the call, so the `catch` never runs. Both
/// tests here fail without the explicit code checks in the walk, and the
/// failure is the one the resolver exists to prevent - the name stops
/// resolving. `deployNext` will not build such a chain, but that check is in
/// another contract; these assert the resolver does not depend on it.
contract zSwapResolverCodelessLinkTest is Test {
    MalformedRoot root;
    zSwapResolver resolver;
    address codeless = makeAddr("an EOA, not a contract");

    function setUp() public {
        root = new MalformedRoot();
        root.point(address(root)); // a valid one-link chain, so construction passes
        resolver = new zSwapResolver(IzSwap(address(root)));
        root.point(codeless);
    }

    function test_aCodelessLinkIsTheEndOfTheChainNotTheEndOfTheName() public view {
        assertEq(resolver.current(), address(root));
        assertEq(resolver.addr(keccak256("zswap.eth")), payable(address(root)));
    }

    function test_versionsStopsAtACodelessLinkInsteadOfReverting() public view {
        address[] memory list = resolver.versions();
        assertEq(list.length, 1);
        assertEq(list[0], address(root));
    }
}
