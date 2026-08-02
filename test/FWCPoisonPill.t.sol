// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {FWCPoisonPill, FWCPoisonPillProposer} from "../src/dao/FWCPoisonPill.sol";

interface IMolochT {
    function setPermit(uint8, address, uint256, bytes calldata, bytes32, address, uint256) external payable;
    function spendPermit(uint8, address, uint256, bytes calldata, bytes32) external payable returns (bool, bytes memory);
    function balanceOf(address, uint256) external view returns (uint256);
    function shares() external view returns (address);
    function badges() external view returns (address);
    function getMessageCount() external view returns (uint256);
    function messages(uint256) external view returns (string memory);
    function state(uint256) external view returns (uint8);
    function castVote(uint256, uint8) external;
    function timelockDelay() external view returns (uint64);
    function executeByVotes(uint8, address, uint256, bytes calldata, bytes32)
        external
        payable
        returns (bool, bytes memory);
}

interface ISharesT {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function getVotes(address) external view returns (uint256);
    function delegate(address) external;
}

interface IFWT {
    function ownerOf(uint256) external view returns (address);
    function balanceOf(address) external view returns (uint256);
}

contract FWCPoisonPillTest is Test {
    address constant DAO = 0xE7Aa6cA3a9Ca3fe92a425dFeaD24900B9BF49853;
    address constant VAULT = 0xB3B3f4f1535305c5f40F9c0d6bCaf38032bF7F8e;
    address constant FW = 0xb33d806a94B6770C9d309E0842a75f8E6edCd5A6;
    address constant GUARDIAN = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;
    address constant WHALE = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;

    FWCPoisonPillProposer proposer;
    FWCPoisonPill pill;

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
        proposer = new FWCPoisonPillProposer();
        pill = proposer.PILL();
    }

    /// The pill must find the passes the vault never registered in `nftIds`. Only the
    /// primary-mint path records ids, and that closed with the mint period; the two
    /// remints acquired via `execute(FW, 1 ether, remint())` are absent from the index.
    /// Trusting the vault's bookkeeping would strand them.
    function test_ScanFindsAllHeldPasses() public view {
        uint256[] memory ids = pill.heldIds();
        assertEq(ids.length, IFWT(FW).balanceOf(VAULT), "missed a held pass");
        for (uint256 i; i < ids.length; ++i) {
            assertEq(IFWT(FW).ownerOf(ids[i]), VAULT, "scanned a pass the vault does not own");
        }
    }

    /// The whole point of the delegatecall body: one spend moves every held pass'
    /// unvested refund plus the vault's idle ETH into the treasury, and leaves the vault
    /// empty. No amount and no id list appears anywhere in the permit.
    function test_GrantThenPull() public {
        uint256[] memory idsBefore = pill.heldIds();
        assertGt(idsBefore.length, 0, "nothing to redeem on this fork");
        uint256 expected = pill.recoverable();
        uint256 treasuryBefore = DAO.balance;

        _grant();
        assertTrue(proposer.armed(), "permit not minted to guardian");

        // Resolve every argument first: a call inside a pranked expression consumes the
        // prank, and the spend would then come from the test contract, which holds no permit.
        bytes memory payload = proposer.pullPayload();
        bytes32 nonce = proposer.PILL_NONCE();
        address pillAddr = address(pill);

        vm.prank(GUARDIAN);
        (bool ok, bytes memory ret) = IMolochT(DAO).spendPermit(1, pillAddr, 0, payload, nonce);
        assertTrue(ok);
        (uint256 burned, uint256 skipped,, uint256 recovered) = abi.decode(ret, (uint256, uint256, uint256, uint256));

        assertEq(burned, idsBefore.length, "did not redeem every pass");
        assertEq(skipped, 0, "a redemption was skipped inside the window");
        assertEq(IFWT(FW).balanceOf(VAULT), 0, "vault still holds passes");
        assertEq(VAULT.balance, 0, "vault not swept");
        assertEq(DAO.balance - treasuryBefore, recovered, "treasury did not receive the proceeds");
        assertApproxEqAbs(recovered, expected, 1e15, "recovered far off the quoted amount");

        // One use, and it is gone.
        assertFalse(proposer.armed(), "permit survived its single use");
    }

    /// Single-use, single-spender: nobody but the guardian holds the permit, and a second
    /// pull has nothing left to burn.
    function test_OnlyGuardianCanSpend() public {
        _grant();
        bytes memory payload = proposer.pullPayload();
        bytes32 nonce = proposer.PILL_NONCE();
        address pillAddr = address(pill);

        vm.prank(WHALE);
        vm.expectRevert();
        IMolochT(DAO).spendPermit(1, pillAddr, 0, payload, nonce);
    }

    /// Directly calling the body does nothing — it is a delegatecall payload, not a
    /// contract with powers of its own.
    function test_DirectCallReverts() public {
        vm.expectRevert(FWCPoisonPill.NotDelegated.selector);
        pill.pull();
    }

    /// The permit id the proposer advertises is the id the DAO actually mints, and the
    /// preview is the proposal that gets built.
    function test_IdsAreDeterministic() public {
        (uint256 id, bytes32 nonce, bytes memory data) = proposer.previewProposal();
        assertEq(data, proposer.permitData(), "preview drifted from the payload");
        assertTrue(id != 0 && nonce != bytes32(0));
        _grant();
        assertEq(IMolochT(DAO).balanceOf(GUARDIAN, proposer.permitId()), 1, "permit id mismatch");
    }

    /// The scan ceiling is the fund's exact high-water id, not a guess: supply plus
    /// everything ever burnt is `currentTokenId - 1`.
    function test_ScanCeilingIsExact() public {
        uint256 top = pill.scanCeiling();
        // Every pass the vault holds falls inside the range...
        uint256[] memory ids = pill.heldIds();
        for (uint256 i; i < ids.length; ++i) {
            assertLe(ids[i], top, "a held pass sits past the scan ceiling");
        }
        // ...and one id past it has never been minted, so the range is not merely
        // sufficient but tight.
        vm.expectRevert();
        IFWT(FW).ownerOf(top + 1);
    }

    /// The failure that would have bricked the pill: once S02's vesting window shuts,
    /// `burn` reverts for every pass. A pull must degrade to the sweep instead of
    /// reverting wholesale and leaving the guardian with a permit that can never act.
    function test_ClosedWindowStillSweeps() public {
        _grant();
        bytes memory payload = proposer.pullPayload();
        bytes32 nonce = proposer.PILL_NONCE();
        address pillAddr = address(pill);
        uint256 held = pill.heldIds().length;

        // Past the end of the vesting period: refunds are zero and `burn` reverts.
        vm.warp(block.timestamp + 365 days + 1);
        assertFalse(pill.burnWindowOpen(), "window should be shut");
        assertEq(pill.pullWindowRemaining(), 0);

        // Give the vault ETH so there is still something to sweep.
        vm.deal(VAULT, 3 ether);
        uint256 treasuryBefore = DAO.balance;

        vm.prank(GUARDIAN);
        (bool ok, bytes memory ret) = IMolochT(DAO).spendPermit(1, pillAddr, 0, payload, nonce);
        assertTrue(ok, "pull reverted instead of degrading to a sweep");
        (uint256 burned, uint256 skipped, uint256 swept,) = abi.decode(ret, (uint256, uint256, uint256, uint256));

        assertEq(burned, 0, "burnt outside the window");
        assertEq(skipped, held, "did not skip the unburnable passes");
        assertEq(swept, 3 ether, "sweep did not run");
        assertEq(DAO.balance - treasuryBefore, 3 ether, "treasury did not receive the sweep");
        assertEq(VAULT.balance, 0, "vault not emptied");
    }

    /// A pull that would move nothing reverts, which rolls the permit burn back with it —
    /// the guardian's single use survives a mistimed pull.
    function test_NoOpPullPreservesTheSingleUse() public {
        _grant();
        bytes memory payload = proposer.pullPayload();
        bytes32 nonce = proposer.PILL_NONCE();
        address pillAddr = address(pill);

        vm.warp(block.timestamp + 365 days + 1); // no refunds
        vm.deal(VAULT, 0); // and nothing to sweep

        vm.prank(GUARDIAN);
        vm.expectRevert();
        IMolochT(DAO).spendPermit(1, pillAddr, 0, payload, nonce);

        assertTrue(proposer.armed(), "a no-op pull consumed the permit");
    }

    /// The pill is deployed by the proposer's constructor via plain CREATE, so its
    /// address is fixed by (proposer, nonce 1). That is what lets the mainnet pill
    /// address be predicted from the mined proposer address before either exists.
    function test_PillAddressIsPredictable() public view {
        assertEq(address(pill), vm.computeCreateAddress(address(proposer), 1), "pill is not at nonce 1");
    }

    /// A member (or the guardian) can author the proposal; a stranger cannot spam it.
    function test_ProposeIsMemberGated() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(FWCPoisonPillProposer.NotMember.selector);
        proposer.propose();
    }

    /// The proposer can write its own proposal once it is funded and delegated: the
    /// tagged message lands in the chatroom and the proposal is open.
    function test_SelfProposes() public {
        ISharesT shares = ISharesT(IMolochT(DAO).shares());
        address to = address(proposer);
        vm.prank(WHALE);
        shares.transfer(to, 10_000 ether);
        proposer.selfDelegate();
        vm.roll(block.number + 1);
        assertTrue(proposer.canPropose(), "not enough delegated weight");
        assertTrue(proposer.canChat(), "no badge seat");

        (uint256 expectedId,,) = proposer.previewProposal();
        uint256 msgsBefore = IMolochT(DAO).getMessageCount();

        vm.prank(GUARDIAN);
        uint256 id = proposer.propose();

        assertEq(id, expectedId, "proposal id drifted from preview");
        assertEq(IMolochT(DAO).getMessageCount(), msgsBefore + 1, "no message posted");
        string memory m = IMolochT(DAO).messages(msgsBefore);
        assertTrue(bytes(m).length > 0);
        assertTrue(IMolochT(DAO).state(id) != 0, "proposal not open");
    }

    /// FULL GOVERNANCE SIMULATION. No prank of the DAO and no shortcut: the proposer
    /// authors the proposal, a real holder votes it through, it queues and clears the
    /// timelock, the DAO executes it into a permit, and only then does the guardian pull
    /// the pill. This is the exact sequence that would run on mainnet.
    function test_EndToEndGovernance() public {
        // 1. Arm the proposer with voting power and a seat, as the deploy notes describe.
        ISharesT shares = ISharesT(IMolochT(DAO).shares());
        address to = address(proposer);
        vm.prank(WHALE);
        shares.transfer(to, 10_000 ether);
        proposer.selfDelegate();
        vm.roll(block.number + 1);

        uint256[] memory idsBefore = pill.heldIds();
        uint256 expected = pill.recoverable();
        uint256 treasuryBefore = DAO.balance;

        // 2. Author the proposal. Nothing about it is chosen by the caller.
        (uint256 pid, bytes32 pnonce, bytes memory pdata) = proposer.previewProposal();
        vm.prank(GUARDIAN);
        assertEq(proposer.propose(), pid, "proposal id drifted from preview");
        assertFalse(proposer.armed(), "permit exists before the vote passed");

        // 3. A real holder carries it. The whale delegates to itself first, since votes
        //    follow delegation rather than balance.
        vm.prank(WHALE);
        shares.delegate(WHALE);
        vm.roll(block.number + 1);
        vm.prank(WHALE);
        IMolochT(DAO).castVote(pid, 1);
        emit log_named_uint("state after whale vote (3 = Succeeded)", IMolochT(DAO).state(pid));

        // 4. Queue, clear the timelock, execute. Anyone may push these.
        IMolochT(DAO).executeByVotes(0, DAO, 0, pdata, pnonce);
        vm.warp(block.timestamp + IMolochT(DAO).timelockDelay() + 1);
        IMolochT(DAO).executeByVotes(0, DAO, 0, pdata, pnonce);

        assertTrue(proposer.armed(), "governance did not mint the permit");
        assertEq(IMolochT(DAO).balanceOf(GUARDIAN, proposer.permitId()), 1, "wrong count minted");

        // 5. The guardian pulls it. One call, and the collection is liquidated.
        bytes memory payload = proposer.pullPayload();
        bytes32 nonce = proposer.PILL_NONCE();
        address pillAddr = address(pill);
        assertTrue(pill.burnWindowOpen(), "S02 refund window shut on this fork");

        // The refunds have decayed while the proposal sat in the timelock. That is the
        // whole reason the amount is not written into the permit: what the guardian pulls
        // is what is there now, not what was quoted at proposal time.
        uint256 atPullTime = pill.recoverable();
        assertLt(atPullTime, expected, "refunds should decay across the timelock");
        assertApproxEqRel(atPullTime, expected, 0.01e18, "decay far larger than one timelock's worth");

        vm.prank(GUARDIAN);
        (bool ok, bytes memory ret) = IMolochT(DAO).spendPermit(1, pillAddr, 0, payload, nonce);
        assertTrue(ok);
        (uint256 burned, uint256 skipped,, uint256 recovered) = abi.decode(ret, (uint256, uint256, uint256, uint256));

        assertEq(burned, idsBefore.length, "did not redeem every pass");
        assertEq(skipped, 0, "a redemption was skipped");
        assertEq(IFWT(FW).balanceOf(VAULT), 0, "vault still holds passes");
        assertEq(VAULT.balance, 0, "vault not swept");
        assertEq(DAO.balance - treasuryBefore, recovered, "treasury did not receive the proceeds");
        assertApproxEqAbs(recovered, atPullTime, 1e15, "recovered far off the amount quoted at pull time");
        assertFalse(proposer.armed(), "permit survived its single use");

        emit log_named_decimal_uint("ETH liquidated into the treasury", recovered, 18);
        emit log_named_uint("passes redeemed", burned);
    }

    /// @dev Skip the vote and mint the permit as the DAO would, so the spend path is
    /// tested against the real permit id rather than a mock.
    function _grant() internal {
        bytes memory payload = proposer.pullPayload();
        bytes32 nonce = proposer.PILL_NONCE();
        address pillAddr = address(pill);

        vm.prank(DAO);
        IMolochT(DAO).setPermit(1, pillAddr, 0, payload, nonce, GUARDIAN, 1);
    }
}
