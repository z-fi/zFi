// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolLens} from "../src/pools/PrecisionPoolLens.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {LaunchToken, PrecisionLauncher} from "../src/pools/PrecisionLauncher.sol";
import {PrecisionLauncherLens} from "../src/pools/PrecisionLauncherLens.sol";

/// @dev A lens is only worth anything if it AGREES with what settles. So this
/// suite mostly does not check that fields are populated - it checks each one
/// against the contract that would actually pay it out.
contract PrecisionLauncherLensTest is Test {
    PrecisionPoolFactory factory;
    PrecisionPoolLens poolLens;
    PrecisionLauncher launcher;
    PrecisionLauncherLens lens;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAC01);
    address treasury = address(0x7EA);

    uint256 constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        poolLens = new PrecisionPoolLens(factory);
        launcher = new PrecisionLauncher(factory, treasury);
        lens = new PrecisionLauncherLens(launcher);
        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
    }

    function _launch(address creator, uint256 allocBps) internal returns (LaunchToken token, PrecisionPool pool) {
        (address t, address p) = launcher.launch("Coin", "COIN", "ipfs://meta", SUPPLY, allocBps, 3 ether, creator);
        (token, pool) = (LaunchToken(t), PrecisionPool(payable(p)));
    }

    function _buy(address who, PrecisionPool pool, uint256 eth) internal returns (uint256) {
        vm.prank(who);
        return pool.swapExactIn{value: eth}(address(0), eth, 0, who);
    }

    // ------------------------------------------------------------ ENUMERATION

    /// The premise of the whole file: the launcher is already a registry,
    /// because it must be every launched pool's `feeRecipient`.
    function testEveryLaunchIsEnumerable() public {
        assertEq(lens.launchCount(), 0);

        (LaunchToken a,) = _launch(alice, 0);
        (LaunchToken b,) = _launch(bob, 1_000);
        (LaunchToken c,) = _launch(alice, 2_000);

        assertEq(lens.launchCount(), 3);

        PrecisionLauncherLens.LaunchInfo[] memory page = lens.launches(0, 10);
        assertEq(page.length, 3, "page truncated");
        assertEq(page[0].token, address(a), "out of launch order");
        assertEq(page[1].token, address(b));
        assertEq(page[2].token, address(c));

        // And it agrees with the generic pool lens reaching the same index.
        PrecisionPoolLens.PoolInfo[] memory viaPool = poolLens.marketsForCreator(address(launcher), alice, 0, 10, 0);
        assertEq(viaPool.length, 3, "factory index disagrees");
        for (uint256 i; i < 3; ++i) {
            assertEq(viaPool[i].pool, page[i].pool, "pool lens and launcher lens disagree");
        }
    }

    function testPaginationWalksTheWholeList() public {
        for (uint256 i; i < 5; ++i) {
            _launch(alice, 0);
        }

        uint256 seen;
        for (uint256 start; start < lens.launchCount(); start += 2) {
            PrecisionLauncherLens.LaunchInfo[] memory page = lens.launches(start, 2);
            for (uint256 i; i < page.length; ++i) {
                assertTrue(page[i].token != address(0), "hole in a page");
                ++seen;
            }
        }
        assertEq(seen, 5, "pagination lost entries");

        // Past the end is empty, not a revert.
        assertEq(lens.launches(99, 5).length, 0);
    }

    // ------------------------------------------------- CREATOR-KEYED LOOKUP

    /// THE GAP THIS LENS EXISTS FOR. The factory indexes launched pools under
    /// the LAUNCHER, so asking it for a real creator's markets returns nothing.
    /// That is not a missing convenience, it is a wrong answer, and it is why
    /// "show me my launches" cannot be served by `marketsForCreator`.
    function testFactoryIndexCannotAnswerForTheRealCreator() public {
        _launch(alice, 0);
        _launch(alice, 0);
        _launch(bob, 0);

        // The factory has never heard of alice.
        assertEq(factory.poolsForCreatorCount(alice), 0, "factory indexed the real creator");
        assertEq(poolLens.marketsForCreator(alice, alice, 0, 10, 0).length, 0);

        // This lens can answer.
        PrecisionLauncherLens.LaunchInfo[] memory mine = lens.launchesForCreator(alice, 0, 10);
        assertEq(mine.length, 2, "creator lookup failed");
        assertEq(mine[0].creator, alice);
        assertEq(mine[1].creator, alice);

        assertEq(lens.launchesForCreator(bob, 0, 10).length, 1);
        assertEq(lens.launchesForCreator(carol, 0, 10).length, 0);
    }

    /// Reassigning the fee stream must move the launch between creators, since
    /// `creatorOf` is the authority and it is mutable.
    function testCreatorLookupFollowsReassignment() public {
        (LaunchToken token,) = _launch(alice, 0);
        assertEq(lens.launchesForCreator(alice, 0, 10).length, 1);

        vm.prank(alice);
        launcher.setCreator(address(token), carol);
        vm.prank(carol);
        launcher.acceptCreator(address(token));

        assertEq(lens.launchesForCreator(alice, 0, 10).length, 0, "stale creator");
        assertEq(lens.launchesForCreator(carol, 0, 10).length, 1, "reassignment not reflected");
    }

    /// A filtered page may legitimately return fewer entries than asked for
    /// without the list having ended - the header says so, so prove it.
    function testFilteredPagesMayBeSparse() public {
        _launch(bob, 0);
        _launch(alice, 0);
        _launch(bob, 0);

        // Alice owns exactly one, and it is not in the first page of one.
        assertEq(lens.launchesForCreator(alice, 0, 1).length, 0, "expected a sparse page");
        assertEq(lens.launchesForCreator(alice, 1, 1).length, 1);
        assertEq(lens.launchesForCreator(alice, 0, 3).length, 1);
    }

    // ---------------------------------------------------------- AGREEMENT

    /// PAGES DO NOT ASSEMBLE `contractURI`, and the singular views do.
    ///
    /// Once a creator stores an image, `contractURI()` stops being the stored
    /// string and becomes an inline `data:` document: the image is read from
    /// SSTORE2 and base64'd, then the whole JSON is base64'd again - tens of
    /// kilobytes per token. Building that once per entry, with memory expansion
    /// quadratic in the page total, lets ONE creator make every page containing
    /// their token too expensive to `eth_call`, and a caller cannot page past
    /// it - only shrink `count` and step around it. Enumeration is the lens's
    /// whole purpose, so that is a griefing vector on the thing it exists for.
    ///
    /// This pins BOTH halves. The omission is not a saving to be optimised away
    /// later, and the singular path is not free to stop serving the document.
    function testPagesOmitTheContractUriAndSingularViewsServeIt() public {
        (LaunchToken token, PrecisionPool pool) = _launch(alice, 0);
        _buy(bob, pool, 10 ether);

        PrecisionLauncherLens.LaunchInfo[] memory page = lens.launches(0, 10);
        assertEq(page.length, 1, "launch did not enumerate");
        assertEq(bytes(page[0].contractURI).length, 0, "a page assembled the metadata document");

        // Everything else a page is for must still be there - the omission is
        // surgical, not a hollowed-out struct.
        assertEq(page[0].token, address(token));
        assertEq(page[0].name, token.name(), "page lost the name");
        assertEq(page[0].symbol, token.symbol(), "page lost the symbol");
        assertGt(page[0].floorPrice, 0, "page lost the floor");

        // And the singular views still serve it in full.
        assertEq(lens.infoFor(address(token)).contractURI, token.contractURI(), "infoFor dropped the document");
        assertEq(
            lens.infoForPool(address(pool)).contractURI, token.contractURI(), "infoForPool dropped the document"
        );

        // The filtered page takes the same route as the unfiltered one.
        PrecisionLauncherLens.LaunchInfo[] memory mine = lens.launchesForCreator(alice, 0, 10);
        assertEq(mine.length, 1, "creator filter lost the launch");
        assertEq(bytes(mine[0].contractURI).length, 0, "a filtered page assembled the document");
    }

    /// Every field must match the contract that would actually pay it.
    function testFieldsAgreeWithSettlement() public {
        (LaunchToken token, PrecisionPool pool) = _launch(alice, 1_000);
        _buy(bob, pool, 25 ether);

        PrecisionLauncherLens.LaunchInfo memory o = lens.infoFor(address(token));

        assertEq(o.token, address(token));
        assertEq(o.pool, address(pool));
        assertEq(o.creator, launcher.creatorOf(address(token)), "creator disagrees");
        assertEq(o.owner, token.owner(), "owner disagrees");
        assertEq(o.name, token.name());
        assertEq(o.symbol, token.symbol());
        assertEq(o.contractURI, token.contractURI());
        assertEq(o.totalSupply, token.totalSupply());
        assertEq(o.reserve0, pool.reserve0());
        assertEq(o.reserve1, pool.reserve1());
        assertEq(o.lpHeld, pool.balanceOf(address(launcher)));
        assertEq(o.pendingFeeEth, pool.creatorOwed0(), "pending ETH disagrees");
        assertEq(o.pendingBurn, pool.creatorOwed1());

        // The floor must be the launcher's own answer, not a re-derivation.
        assertEq(o.floorPrice, launcher.floorPrice(address(token)), "floor disagrees");
        assertGt(o.floorPrice, 0);

        // Backing must be what the position would actually release.
        uint256 expectBacking = uint256(pool.reserve0()) * o.lpHeld / pool.totalSupply();
        assertEq(o.backingEth, expectBacking, "backing disagrees");
    }

    /// `circulating` must be exactly the supply that can be redeemed, which is
    /// the strongest statement available: redeem all of it and the token empties.
    function testCirculatingIsWhatCanActuallyBeRedeemed() public {
        (LaunchToken token, PrecisionPool pool) = _launch(alice, 0);
        _buy(bob, pool, 40 ether);

        uint256 circulating = lens.infoFor(address(token)).circulating;
        assertApproxEqRel(circulating, token.balanceOf(bob), 0.001e18, "circulating is not the held supply");

        vm.startPrank(bob);
        token.approve(address(launcher), type(uint256).max);
        launcher.redeem(address(token), token.balanceOf(bob), 0, bob);
        vm.stopPrank();

        assertLt(lens.infoFor(address(token)).circulating, circulating / 100, "circulating survived a full exit");
    }

    /// The two prices must be comparable and correctly ordered - that ordering
    /// is the product's headline number.
    function testMarketPriceSitsAboveTheFloor() public {
        (LaunchToken token, PrecisionPool pool) = _launch(alice, 0);

        // Before trading: a market price exists, a floor does not.
        PrecisionLauncherLens.LaunchInfo memory o = lens.infoFor(address(token));
        assertGt(o.marketPrice, 0, "no opening price");
        assertEq(o.floorPrice, 0, "floor before any buy");

        // The opening price must match the requested valuation: 3 ETH over 1e9
        // tokens is 3e-9 ETH each.
        assertApproxEqRel(o.marketPrice, 3 ether / 1e9, 0.0001e18, "opening price off");

        for (uint256 i; i < 6; ++i) {
            _buy(bob, pool, 10 ether);
            o = lens.infoFor(address(token));
            assertGt(o.floorPrice, 0);
            assertLe(o.floorPrice, o.marketPrice, "floor above market");
        }
    }

    /// Pending fees must be readable BEFORE collection, so a UI need not
    /// simulate a sweep to show what is owed.
    function testPendingFeesMatchWhatCollectionPays() public {
        (LaunchToken token, PrecisionPool pool) = _launch(alice, 0);
        _buy(bob, pool, 30 ether);
        vm.startPrank(bob);
        token.approve(address(pool), type(uint256).max);
        pool.swapExactIn(address(token), token.balanceOf(bob) / 2, 0, bob);
        vm.stopPrank();

        PrecisionLauncherLens.LaunchInfo memory o = lens.infoFor(address(token));
        assertGt(o.pendingFeeEth, 0);
        assertGt(o.pendingBurn, 0);

        // The lens reports the WHOLE accrual, before it is split - so all three
        // legs plus nothing else must account for it.
        (uint256 cEth, uint256 pEth, uint256 tEth, uint256 burned,) = launcher.collectFees(address(token));
        assertEq(cEth + pEth + tEth, o.pendingFeeEth, "pending ETH mispredicted the sweep");
        assertEq(burned, o.pendingBurn, "pending burn mispredicted the sweep");

        PrecisionLauncherLens.LaunchInfo memory after_ = lens.infoFor(address(token));
        assertEq(after_.pendingFeeEth, 0, "pending survived collection");
        assertEq(after_.pendingBurn, 0);
    }

    /// Editable metadata must be reflected, since that is the point of it being
    /// editable.
    function testMetadataEditsAreReflected() public {
        (LaunchToken token,) = _launch(alice, 0);
        assertEq(lens.infoFor(address(token)).contractURI, "ipfs://meta");

        vm.prank(alice);
        token.setContractURI("ipfs://updated");
        assertEq(lens.infoFor(address(token)).contractURI, "ipfs://updated");

        vm.prank(alice);
        token.renounceOwnership();
        assertEq(lens.infoFor(address(token)).owner, address(0), "renouncement not reflected");
        // The fee stream is untouched by that, and the lens must not conflate them.
        assertEq(lens.infoFor(address(token)).creator, alice);
    }

    // ------------------------------------------------------------ PROBING

    /// Unknown addresses must probe cheaply rather than revert.
    function testUnknownAddressesReturnEmpty() public view {
        assertEq(lens.infoFor(address(0xDEAD)).token, address(0));
        assertEq(lens.infoForPool(address(0xDEAD)).token, address(0));
        assertEq(lens.infoFor(address(0)).token, address(0));
    }

    /// A pool this launcher did not open must not be described as a launch,
    /// even though it is a real PrecisionPool of the same factory.
    function testForeignPoolsAreNotDescribedAsLaunches() public {
        (LaunchToken token,) = _launch(alice, 0);

        // An unnamed market on the same token, opened by someone else.
        PrecisionPoolFactory.Market memory m = PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(token),
            sqrtPLow: 1e16,
            sqrtPHigh: 1e22,
            fee: 3_000,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
        vm.prank(carol);
        address foreign = factory.createPool(m);

        assertTrue(factory.isPool(foreign));
        assertEq(lens.infoForPool(foreign).token, address(0), "foreign pool described as a launch");

        // And it must not appear in enumeration, which keys on the launcher.
        assertEq(lens.launchCount(), 1, "foreign pool entered the registry");
    }

    /// Both entry points must describe the same launch identically.
    function testTokenAndPoolLookupsAgree() public {
        (LaunchToken token, PrecisionPool pool) = _launch(alice, 500);
        _buy(bob, pool, 15 ether);

        PrecisionLauncherLens.LaunchInfo memory byToken = lens.infoFor(address(token));
        PrecisionLauncherLens.LaunchInfo memory byPool = lens.infoForPool(address(pool));

        assertEq(keccak256(abi.encode(byToken)), keccak256(abi.encode(byPool)), "lookups disagree");
    }
}
