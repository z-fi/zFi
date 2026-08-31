// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ScoreMinter, INameNFT} from "../src/ScoreMinter.sol";

/// @notice ScoreMinter against the live Wei Name Service, on a fork.
///
/// @dev The whole contract exists because of two registry rules that only bite
///      in the real thing: `setText` demands the caller BE the owner, and
///      `_register` uses `_safeMint`. A mock would let both pass and prove
///      nothing, so every test here runs against the deployed registry with a
///      parent this contract actually holds.
contract ScoreMinterTest is Test {
    INameNFT constant NAMES = INameNFT(0x0000000000696760E15f265e828DB644A0c242EB);

    /// `arcade.wei`, the parent the namespace is issued beneath.
    uint256 constant PARENT =
        50954229446721386169926547816206122353384135962146661543629559682287576011957;

    ScoreMinter minter;
    address player = address(0xB0B);
    address parentOwner;

    function setUp() public {
        // NOT pinned, unlike the other fork suites here, and deliberately so:
        // `arcade.wei` was registered recently enough that no free endpoint
        // still serves state from before it existed, and pinning to a block
        // that predates the name fails with TokenDoesNotExist. The head it is,
        // which means this suite needs a live RPC rather than an archive one.
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        minter = new ScoreMinter(PARENT);
        parentOwner = NAMES.ownerOf(PARENT);
    }

    /// Hand the parent over exactly as the deploy runbook will.
    function _giveParent() internal {
        vm.prank(parentOwner);
        NAMES.transferFrom(parentOwner, address(minter), PARENT);
    }

    /// @dev The parent arrives by `transferFrom`, not `safeTransferFrom`, so
    ///      this passes even without a receiver hook. The hook matters for the
    ///      SUBDOMAIN, which the registry mints with `_safeMint` - which is the
    ///      thing that makes every deployed forwarder unusable here.
    function test_acceptsTheParentAndReportsReady() public {
        assertFalse(minter.ready(), "cannot be ready before it holds the parent");
        _giveParent();
        assertTrue(minter.ready(), "should hold the parent");
        assertEq(NAMES.ownerOf(PARENT), address(minter));
    }

    /// The claim in one test: one call, name minted, record written, player owns it.
    function test_claimMintsRecordsAndHandsOver() public {
        _giveParent();

        uint256 id = minter.claim("zinv-4820-k3x9", "4820", player);

        assertEq(NAMES.ownerOf(id), player, "the player must end up owning it");
        assertTrue(NAMES.ownerOf(id) != address(minter), "the contract must not keep it");
    }

    /// @dev The reason the three steps cannot be split across transactions:
    ///      `setText` reverts for anyone who is not the current owner, so a
    ///      contract that minted straight to the player could never write the
    ///      record.
    function test_setTextIsOwnerOnly_whichIsWhyThisContractExists() public {
        _giveParent();
        uint256 id = minter.claim("zinv-100-aaaa", "100", player);

        vm.expectRevert();
        NAMES.setText(id, "score", "999999");

        // The owner may, of course.
        vm.prank(player);
        NAMES.setText(id, "score", "999999");
    }

    /// Nobody but this contract can issue under the parent. That exclusivity is
    /// the entire reason to spend a name on this rather than mint under an open
    /// parent like `id.wei`.
    function test_nobodyElseCanMintUnderTheParent() public {
        _giveParent();
        vm.prank(address(0xBAD));
        vm.expectRevert();
        NAMES.registerSubdomain("zinv-1-evil", PARENT);
    }

    function test_refusesAnEmptyLabelAndAnOverlongScore() public {
        _giveParent();
        vm.expectRevert(ScoreMinter.BadLabel.selector);
        minter.claim("", "1", player);

        vm.expectRevert(ScoreMinter.BadScore.selector);
        minter.claim("zinv-2-bbbb", "123456789012345678901", player);
    }

    function test_refusesToMintToNobody() public {
        _giveParent();
        vm.expectRevert(ScoreMinter.BadLabel.selector);
        minter.claim("zinv-3-cccc", "3", address(0));
    }

    /// @dev THE ONE THAT NEARLY SHIPPED. The registry lets a parent owner
    ///      OVERWRITE a live subdomain - it burns the existing token and
    ///      reissues it. This contract is the parent owner, so a second claim
    ///      on the same label would have destroyed the first player's name and
    ///      handed the label to whoever asked second. Name a rival's label and
    ///      their collectible is gone.
    ///
    ///      A mock registry would have minted twice and told us nothing. This
    ///      is the reason the suite forks.
    function test_aLabelCannotBeTakenFromItsOwner() public {
        _giveParent();
        uint256 id = minter.claim("zinv-500-dddd", "500", player);
        assertEq(NAMES.ownerOf(id), player);

        address thief = address(0xBAD);
        vm.prank(thief);
        vm.expectRevert(ScoreMinter.Taken.selector);
        minter.claim("zinv-500-dddd", "500", thief);

        assertEq(NAMES.ownerOf(id), player, "the first player must still own it");
    }

    function test_availableTracksTheRegistry() public {
        _giveParent();
        assertTrue(minter.available("zinv-777-eeee"));
        minter.claim("zinv-777-eeee", "777", player);
        assertFalse(minter.available("zinv-777-eeee"), "a minted label is no longer available");
    }

    /// @dev Load-bearing. The contract has no owner to notice an expiry, and a
    ///      lapsed parent takes the whole namespace with it - every name minted
    ///      beneath it stops resolving, and the parent becomes registrable by
    ///      somebody else. Anyone must be able to pay to extend it.
    function test_anyoneCanRenewTheParent() public {
        _giveParent();
        uint256 before = NAMES.ownerOf(PARENT) == address(minter) ? 1 : 0;
        assertEq(before, 1);

        address stranger = address(0xCAFE);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        // Overpaying on purpose: `renew` refunds the excess to its CALLER,
        // which is this contract. Without a `receive` that refund reverts and
        // no renewal is possible at all - which is exactly what happened the
        // first time this ran.
        minter.renewParent{value: 0.05 ether}();

        assertEq(NAMES.ownerOf(PARENT), address(minter), "renewing must not move the parent");
    }

    /// Whatever the refund left behind has a way out, and only one destination.
    function test_sweepSendsStrayEtherToRecovery() public {
        vm.deal(address(minter), 1 ether);
        uint256 before = minter.RECOVERY().balance;
        vm.prank(address(0xCAFE));
        minter.sweep();
        assertEq(address(minter).balance, 0, "nothing should rest here");
        assertEq(minter.RECOVERY().balance, before + 1 ether, "it can only pay RECOVERY");
    }

    /// The contract must not become a resting place for unrelated NFTs.
    function test_rejectsTokensThatAreNotNames() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert(ScoreMinter.NotHeld.selector);
        minter.onERC721Received(address(0), address(0), 1, "");
    }

    /// Before the parent is handed over the contract is inert rather than
    /// half-working, which is what `ready()` lets a frontend check.
    function test_claimFailsBeforeTheParentArrives() public {
        vm.expectRevert();
        minter.claim("zinv-9-ffff", "9", player);
    }
}
