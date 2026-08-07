// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";

interface IGov {
    function bondZorgz(uint256 receiptId, uint256 weight, uint8 tier) external payable;
    function allocate(uint256 receiptId, uint256 listingId, uint256 amount) external;
    function unbond(uint256 receiptId) external;
    function claimLoyalty(uint256 receiptId) external;
    function withdrawEthCredit(address payable to) external;
    function supportOf(uint256 listingId) external view returns (uint256);
    function listingState(uint256 listingId) external view returns (uint256, uint256);
    function bondedWeight(uint256 receiptId) external view returns (uint256);
    function loyaltyOf(uint256 receiptId) external view returns (uint256);
    function ethCredits(address who) external view returns (uint256);
    function loyaltyRewardReserve() external view returns (uint256);
    function totalEthPrincipal() external view returns (uint256);
    function treasuryEth() external view returns (uint256);
    function totalEthCredits() external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function ethBonds(uint256 id)
        external
        view
        returns (uint256, uint256, uint256, uint64, uint64, uint64, uint16, uint16);
    function halfLife() external view returns (uint64);
    function totalLoyaltyWeight() external view returns (uint256);
    function receiptLocks(uint256 id) external view returns (uint64, uint64, uint16, uint8);
    function shares() external view returns (address);
    function zorgz() external view returns (address);
}

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IERC721Like {
    function ownerOf(uint256 id) external view returns (address);
    function approve(address to, uint256 id) external;
    function transferFrom(address from, address to, uint256 id) external;
}

/// End-to-end exercise of the LIVE deployed governor, not a local redeploy.
///
/// Every other suite in this repo builds its own copy of ZorgConviction from
/// source. That proves the source is right; it does not prove the bytecode at
/// 0x0000006D93... behaves the way the source says, against the real zOrg share
/// token, the real zOrgz collection and the real TokenList. This drives one
/// complete lifecycle through the deployed contracts:
///
///   bond -> allocate -> conviction accrues -> someone exits early ->
///   loyalty accrues -> claim -> withdraw real ETH -> unbond at maturity
contract ZorgLiveMechanicsTest is Test {
    IGov constant GOV = IGov(0x0000006D936bA3653b8854490E16E782cd32a9a8);
    address constant TOKENLIST = 0x0000006013dF75A31678B786061C2B54bf531524;
    /// A listing that already exists on the live registry: WETH.
    uint256 constant LISTING_WETH = uint256(uint160(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    uint256 constant LISTING_RETH = uint256(uint160(0xae78736Cd615f374D3085123A210448E74Fc6393));

    IERC20Like zorg;
    IERC721Like zorgz;

    address alice = address(0xA11CE);   // stays bonded, earns
    address bob = address(0xB0B);       // exits early, pays

    uint256 aliceId;
    uint256 bobId;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://0xrpc.io/eth")));
        zorg = IERC20Like(GOV.shares());
        zorgz = IERC721Like(GOV.zorgz());

        // Take two real zOrgz from whoever currently holds them, and real zOrg
        // from a real holder. Nothing is minted or storage-poked, so the assets
        // behave exactly as they do in production.
        aliceId = _grabZorgz(alice, 0);
        bobId = _grabZorgz(bob, aliceId + 1);

        address whale = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;
        uint256 have = zorg.balanceOf(whale);
        require(have >= 40_000 ether, "whale short on zOrg");
        vm.startPrank(whale);
        zorg.transfer(alice, 20_000 ether);
        zorg.transfer(bob, 20_000 ether);
        vm.stopPrank();

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    /// Find a zOrgz that is NOT already escrowed in the governor and move it to
    /// `to`, by pranking its real owner.
    function _grabZorgz(address to, uint256 from) internal returns (uint256) {
        for (uint256 id = from + 1; id < from + 400; ++id) {
            address owner_;
            try zorgz.ownerOf(id) returns (address o) {
                owner_ = o;
            } catch {
                continue;
            }
            if (owner_ == address(0) || owner_ == address(GOV) || owner_.code.length != 0) continue;
            vm.prank(owner_);
            zorgz.transferFrom(owner_, to, id);
            return id;
        }
        revert("no free zOrgz found");
    }

    function _bond(address who, uint256 id, uint256 weight, uint256 eth, uint8 tier) internal {
        vm.startPrank(who);
        zorg.approve(address(GOV), type(uint256).max);
        zorgz.approve(address(GOV), id);
        GOV.bondZorgz{value: eth}(id, weight, tier);
        vm.stopPrank();
    }

    /// The whole thing, in order, against the deployed contracts.
    function testFullLifecycleAgainstDeployedContracts() public {
        // ---- 1. BOND -------------------------------------------------------
        _bond(alice, aliceId, 10_000 ether, 0.01 ether, 3);   // tier 3 = 1.50x
        assertEq(zorgz.ownerOf(aliceId), address(GOV), "zOrgz escrowed");
        assertEq(GOV.ownerOf(aliceId), alice, "receipt minted to alice");
        assertEq(GOV.bondedWeight(aliceId), 10_000 ether, "shares escrowed");

        // ---- 2. ALLOCATE ---------------------------------------------------
        (uint256 scoreBefore,) = GOV.listingState(LISTING_RETH);
        vm.prank(alice);
        GOV.allocate(aliceId, LISTING_RETH, 1_000 ether);
        (uint256 score0, uint256 weight0) = GOV.listingState(LISTING_RETH);
        assertEq(weight0 - 0, 1_500 ether, "1000 zOrg at 1.50x directs 1500 of live weight");
        assertApproxEqAbs(score0, scoreBefore + 1_500 ether, 1e15, "score starts at live weight");

        // ---- 3. CONVICTION ACCRUES ----------------------------------------
        uint64 hl = GOV.halfLife();
        vm.warp(block.timestamp + hl);                       // one half-life
        (uint256 score1,) = GOV.listingState(LISTING_RETH);
        assertApproxEqRel(score1, 1_500 ether * 3 / 2, 0.01e18, "1 half-life -> 1.5x live weight");

        vm.warp(block.timestamp + hl * 6);                   // six more
        (uint256 score2, uint256 weight2) = GOV.listingState(LISTING_RETH);
        assertEq(weight2, 1_500 ether, "live weight unchanged by time");
        assertApproxEqRel(score2, 2 * 1_500 ether, 0.02e18, "converges on the 2x ceiling");
        assertLt(score2, 2 * 1_500 ether, "and never exceeds it");

        // ---- 4. SOMEONE EXITS EARLY ---------------------------------------
        uint256 reserveBefore = GOV.loyaltyRewardReserve();
        uint256 aliceLoyaltyBefore = GOV.loyaltyOf(aliceId);
        _bond(bob, bobId, 5_000 ether, 0.01 ether, 0);
        // Bob's own weight leaves before the split, so the denominator is
        // everyone who REMAINS - captured here to prove exactly that.
        uint256 stayingWeight = GOV.totalLoyaltyWeight() - 5_000 ether;
        vm.prank(bob);
        GOV.unbond(bobId);                                    // immediate: fully taxed

        // 20% of 0.01 = 0.002 forfeited; half of that to bonded receipts.
        assertEq(GOV.ethCredits(bob), 0.008 ether, "leaver keeps 80% of principal");
        assertEq(zorgz.ownerOf(bobId), bob, "and gets the zOrgz back");
        assertEq(zorg.balanceOf(bob), 20_000 ether, "and every share back");
        assertEq(GOV.loyaltyRewardReserve() - reserveBefore, 0.001 ether, "0.001 to bonded receipts");

        // ---- 5. LOYALTY REACHES THE STAYER --------------------------------
        // NOT all of it: alice shares the pot with every other live bond, which
        // on mainnet today means the eternal receipt #9953. Compute the share
        // rather than assume, and assert the split is exactly pro-rata on RAW
        // weight - the 1.50x boost must not appear here.
        uint256 earned = GOV.loyaltyOf(aliceId) - aliceLoyaltyBefore;
        uint256 expected = 0.001 ether * 10_000 ether / stayingWeight;
        assertEq(earned, expected, "pro-rata on raw weight, boost excluded");
        assertLt(earned, 0.001 ether, "and diluted by the other live bonds");

        // ---- 6. CLAIM AND WITHDRAW REAL ETH -------------------------------
        vm.startPrank(alice);
        GOV.claimLoyalty(aliceId);
        assertEq(GOV.ethCredits(alice), earned, "settled to credit");
        assertEq(GOV.bondedWeight(aliceId), 10_000 ether, "claiming did not exit the bond");
        uint256 walletBefore = alice.balance;
        GOV.withdrawEthCredit(payable(alice));
        vm.stopPrank();
        assertEq(alice.balance - walletBefore, earned, "real ETH left the contract");

        // ---- 7. EXIT AT MATURITY, UNTAXED ---------------------------------
        // TWO clocks, and the later one governs: the 7-day ETH maturity decides
        // whether the exit is taxed, but the tier-3 hard lock decides whether it
        // is permitted at all. Warping only past maturity reverts ReceiptLocked,
        // which is the lock doing its job.
        (,,,, uint64 maturityAt,,,) = GOV.ethBonds(aliceId);
        (, uint64 unlockAt,,) = GOV.receiptLocks(aliceId);
        assertGt(unlockAt, maturityAt, "tier 3 outlasts the ETH maturity");
        vm.warp(uint256(maturityAt) + 1);
        vm.prank(alice);
        vm.expectRevert();
        GOV.unbond(aliceId);                                  // still hard locked
        vm.warp(uint256(unlockAt) + 1);
        vm.startPrank(alice);
        GOV.allocate(aliceId, LISTING_RETH, 0);               // must clear allocations first
        GOV.unbond(aliceId);
        vm.stopPrank();
        assertEq(zorg.balanceOf(alice), 20_000 ether, "every share returned");
        assertEq(zorgz.ownerOf(aliceId), alice, "zOrgz returned");
        assertEq(GOV.ethCredits(alice), 0.01 ether, "full principal, no tax at maturity");

        // Support falls back to where it started once the bond leaves.
        (, uint256 weightEnd) = GOV.listingState(LISTING_RETH);
        assertEq(weightEnd, 0, "live weight released");
    }

    /// The live contract must still be able to pay everyone at every step.
    function testDeployedContractStaysSolventThroughTheLifecycle() public {
        _bond(alice, aliceId, 10_000 ether, 0.05 ether, 0);
        _assertSolvent("after bond");

        vm.prank(alice);
        GOV.allocate(aliceId, LISTING_WETH, 4_000 ether);
        _assertSolvent("after allocate");

        _bond(bob, bobId, 5_000 ether, 0.05 ether, 0);
        vm.prank(bob);
        GOV.unbond(bobId);
        _assertSolvent("after a taxed exit");

        vm.prank(alice);
        GOV.claimLoyalty(aliceId);
        _assertSolvent("after a claim");

        vm.prank(alice);
        GOV.withdrawEthCredit(payable(alice));
        _assertSolvent("after a withdrawal");
    }

    function _assertSolvent(string memory at) internal view {
        uint256 owed =
            GOV.totalEthPrincipal() + GOV.loyaltyRewardReserve() + GOV.treasuryEth() + GOV.totalEthCredits();
        assertGe(address(GOV).balance, owed, string.concat("live contract underwater ", at));
    }
}
