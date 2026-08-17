// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {PrecisionLauncher, LaunchToken} from "../src/pools/PrecisionLauncher.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";

/// @notice What "creator keeps 10%" actually means the moment the launch lands.
contract LaunchAllocationTest is Test {
    address constant FACTORY = 0x000000Eb27B557aB426d9E99cFd54EC455799e81;
    address constant TREASURY = 0x000000aA142133107c7D2664F900f80e28BbfFbd;
    uint256 constant SUPPLY = 1_000_000_000e18;

    PrecisionLauncher L;
    address creator = address(0xC0FFEE);
    address buyer = address(0xB0B);

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_745_140
        );
        L = new PrecisionLauncher(PrecisionPoolFactory(payable(FACTORY)), TREASURY);
        vm.deal(buyer, 1000 ether);
    }

    /// Immediately, in the launch transaction, fully unlocked.
    function test_theAllocationIsPaidInTheLaunchTransaction() public {
        (address t,) = L.launch("C", "C", "", SUPPLY, 1000, 30 ether, creator);
        assertEq(LaunchToken(t).balanceOf(creator), SUPPLY / 10, "not paid at launch");

        // No lock, no cliff, no vesting: transferable in the very next call.
        vm.prank(creator);
        LaunchToken(t).transfer(address(0xDEAD), 1e18);
        assertEq(LaunchToken(t).balanceOf(address(0xDEAD)), 1e18, "the allocation is locked");
    }

    /// And only 90% is seeded - the pool never holds the creator's share.
    /// @dev NOT an exact 90%: seeding is bounded by the band's resolution, so a
    ///      remainder of a few hundred thousand raw units (about 2e-13 of one
    ///      token) cannot go in. The launcher BURNS it rather than keeping it,
    ///      which is why nothing rests here and why total supply is a hair
    ///      under what was asked for. Asserting the round number instead of the
    ///      behaviour is how this test first "failed" against correct code.
    function test_onlyTheRestIsSeeded() public {
        (address t, address p) = L.launch("C", "C", "", SUPPLY, 1000, 30 ether, creator);
        uint256 pooled = LaunchToken(t).balanceOf(p);
        assertApproxEqAbs(pooled, SUPPLY * 9 / 10, 1e9, "pool holds the wrong amount");
        assertLe(pooled, SUPPLY * 9 / 10, "the pool cannot hold more than was allotted");
        assertEq(LaunchToken(t).balanceOf(address(L)), 0, "nothing rests in the launcher");
        assertEq(
            LaunchToken(t).totalSupply(),
            LaunchToken(t).balanceOf(creator) + pooled,
            "the unseedable remainder must be burned, not held"
        );
    }

    /// ONE TRANSACTION, ART INCLUDED.
    ///
    /// The image lives on the token, and the token does not exist until this
    /// call runs - so a page could not call `setImage` until the launch had
    /// already confirmed, making every launch with a logo two prompts. The
    /// second was declinable, which left coins with no art and no explanation.
    function test_aLaunchCanCarryItsArtInOneCall() public {
        bytes memory png = hex"89504e470d0a1a0a0000000d49484452";
        (address t,) = L.launchWithArt("C", "C", "", SUPPLY, 0, 30 ether, creator, png, 1);

        assertTrue(LaunchToken(t).imagePointer() != address(0), "no art was stored");
        assertEq(LaunchToken(t).imageMime(), 1, "mime did not survive");
        assertEq(LaunchToken(t).imagePointer().code.length, png.length + 1, "SSTORE2 keeps the STOP byte");
        // And it renders as a document rather than the bare stored string.
        assertTrue(bytes(LaunchToken(t).contractURI()).length > 100, "contractURI did not assemble");
    }

    /// The plain path is unchanged: same body, no art, no wasted calldata.
    function test_aPlainLaunchStoresNoArt() public {
        (address t,) = L.launch("C", "C", "ipfs://x", SUPPLY, 0, 30 ether, creator);
        assertEq(LaunchToken(t).imagePointer(), address(0), "art appeared from nowhere");
        assertEq(LaunchToken(t).contractURI(), "ipfs://x", "the stored string must still serve");
    }

    /// An unknown mime is refused here too, not just through `setImage`.
    function test_anUnknownMimeIsRefusedAtLaunch() public {
        vm.expectRevert(LaunchToken.BadMime.selector);
        L.launchWithArt("C", "C", "", SUPPLY, 0, 30 ether, creator, hex"00", 9);
    }

    /// The part worth knowing before choosing the number: it is immediately
    /// sellable into the market the same transaction created, and the whole
    /// 10% is far more than that market can absorb.
    function test_whatDumpingTheAllocationWouldDo() public {
        (address t, address p) = L.launch("C", "C", "", SUPPLY, 1000, 30 ether, creator);

        // Someone buys 5 ETH first, so there is ether in the pool to take.
        vm.prank(buyer);
        PrecisionPool(payable(p)).swapExactIn{value: 5 ether}(address(0), 5 ether, 0, buyer);
        emit log_named_uint("pool ether after a 5 ETH buy (wei)", p.balance);

        uint256 alloc = LaunchToken(t).balanceOf(creator);
        vm.startPrank(creator);
        LaunchToken(t).approve(p, alloc);
        uint256 before = creator.balance;
        PrecisionPool(payable(p)).swapExactIn(t, alloc, 0, creator);
        vm.stopPrank();

        emit log_named_uint("creator sold (tokens)", alloc / 1e18);
        emit log_named_uint("creator received (wei)", creator.balance - before);
        emit log_named_uint("pool ether left (wei)", p.balance);
        assertGt(creator.balance, before, "the allocation is sellable");
    }
}
