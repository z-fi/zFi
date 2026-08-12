// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";

/// Production dry run. Nothing is deployed here: this forks live mainnet and drives the
/// contracts that are already on it, through the proposal that is already queued. It
/// answers one question — if the timelock expires and the guardian pulls, does the DAO
/// actually get the money?
interface IMolochP {
    function state(uint256) external view returns (uint8);
    function queuedAt(uint256) external view returns (uint64);
    function timelockDelay() external view returns (uint64);
    function balanceOf(address, uint256) external view returns (uint256);
    function executeByVotes(uint8, address, uint256, bytes calldata, bytes32)
        external
        payable
        returns (bool, bytes memory);
    function spendPermit(uint8, address, uint256, bytes calldata, bytes32) external payable returns (bool, bytes memory);
}

interface IProposerP {
    function permitData() external view returns (bytes memory);
    function pullPayload() external view returns (bytes memory);
    function PILL_NONCE() external view returns (bytes32);
    function PERMIT_COUNT() external view returns (uint256);
    function permitId() external view returns (uint256);
    function armed() external view returns (bool);
    function proposalCount() external view returns (uint256);
}

interface IPillP {
    function heldIds() external view returns (uint256[] memory);
    function recoverable() external view returns (uint256);
    function burnWindowOpen() external view returns (bool);
}

interface IFWP {
    function balanceOf(address) external view returns (uint256);
}

contract FWCPoisonPillProdTest is Test {
    address constant DAO = 0xE7Aa6cA3a9Ca3fe92a425dFeaD24900B9BF49853;
    address constant VAULT = 0xB3B3f4f1535305c5f40F9c0d6bCaf38032bF7F8e;
    address constant FW = 0xb33d806a94B6770C9d309E0842a75f8E6edCd5A6;
    address constant GUARDIAN = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;

    // Live, verified, already deployed.
    address constant PROPOSER = 0x00001fE2ef7B69Fee2626afF8B8Cba2D18A9f888;
    address constant PILL = 0x55D2cF1fD3cb803c37340CDd4Fd8fC59d750d050;

    // The proposal that is queued right now.
    uint256 constant PROPOSAL_ID = 55511535566162768971693823684403719456643902004293396652267903071997430971244;

    IMolochP dao = IMolochP(DAO);
    IProposerP proposer = IProposerP(PROPOSER);
    IPillP pill = IPillP(PILL);

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
    }

    /// The nonce is not stored anywhere — it is derived from the sequence number, so a
    /// mismatch here would mean the queued proposal is not the one this contract wrote.
    function _proposalNonce() internal view returns (bytes32) {
        return keccak256(abi.encode(PROPOSER, proposer.PILL_NONCE(), proposer.PERMIT_COUNT(), uint256(1)));
    }

    /// Bring live state to "permit exists". The proposal may already be Executed on
    /// mainnet, in which case there is nothing left to push.
    function _arm() internal {
        uint8 st = dao.state(PROPOSAL_ID);
        emit log_named_uint("proposal state (2 = Queued, 6 = Executed)", st);
        if (st == 6) {
            assertTrue(proposer.armed(), "executed but no permit");
            return;
        }
        assertEq(st, 2, "proposal is neither queued nor executed on live state");
        assertFalse(proposer.armed(), "permit already exists before execution");

        // Clear the timelock. Anyone may push this; the test contract is a stranger.
        uint64 qAt = dao.queuedAt(PROPOSAL_ID);
        assertGt(qAt, 0, "not actually queued");
        vm.warp(uint256(qAt) + dao.timelockDelay() + 1);

        (bool exOk,) = dao.executeByVotes(0, DAO, 0, proposer.permitData(), _proposalNonce());
        assertTrue(exOk, "executeByVotes failed");
        assertEq(dao.state(PROPOSAL_ID), 6, "proposal not marked Executed");
    }

    /// The whole path, end to end, on live state.
    function test_ProductionDryRun() public {
        uint256[] memory idsBefore = pill.heldIds();
        emit log_named_uint("passes held by vault", idsBefore.length);
        assertGt(idsBefore.length, 0, "vault holds nothing to redeem");

        // --- 1/2. Queued -> Executed (a no-op if mainnet already got there) -----------
        _arm();

        // --- 3. The guardian now holds exactly one permit ------------------------------
        assertTrue(proposer.armed(), "permit was not minted");
        assertEq(dao.balanceOf(GUARDIAN, proposer.permitId()), 1, "wrong permit count");

        // --- 4. Pull -------------------------------------------------------------------
        assertTrue(pill.burnWindowOpen(), "S02 refund window shut");
        uint256 quoted = pill.recoverable();
        uint256 treasuryBefore = DAO.balance;

        bytes memory payload = proposer.pullPayload();
        bytes32 permitNonce = proposer.PILL_NONCE();

        vm.prank(GUARDIAN);
        (bool ok, bytes memory ret) = dao.spendPermit(1, PILL, 0, payload, permitNonce);
        assertTrue(ok, "pull reverted");
        (uint256 burned, uint256 skipped, uint256 swept, uint256 recovered) =
            abi.decode(ret, (uint256, uint256, uint256, uint256));

        // --- 5. What actually happened -------------------------------------------------
        assertEq(burned, idsBefore.length, "did not redeem every pass");
        assertEq(skipped, 0, "a redemption was skipped");
        assertEq(IFWP(FW).balanceOf(VAULT), 0, "vault still holds passes");
        assertEq(VAULT.balance, 0, "vault not swept");
        assertEq(DAO.balance - treasuryBefore, recovered, "treasury delta != reported");
        assertApproxEqAbs(recovered, quoted, 1e15, "recovered far off quote");
        assertFalse(proposer.armed(), "permit survived its single use");

        emit log_named_uint("passes redeemed", burned);
        emit log_named_decimal_uint("swept from vault", swept, 18);
        emit log_named_decimal_uint("ETH into treasury", recovered, 18);
        emit log_named_decimal_uint("treasury after", DAO.balance, 18);
    }

    /// Nobody but the guardian can spend it, even once it exists.
    function test_OnlyGuardianAfterExecution() public {
        _arm();
        assertTrue(proposer.armed());

        bytes memory payload = proposer.pullPayload();
        bytes32 permitNonce = proposer.PILL_NONCE();

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        dao.spendPermit(1, PILL, 0, payload, permitNonce);
    }

    /// The timelock is real: executing early must fail.
    function test_CannotExecuteBeforeTimelock() public {
        uint256 unlock = uint256(dao.queuedAt(PROPOSAL_ID)) + dao.timelockDelay();
        vm.warp(unlock - 60);
        bytes memory data = proposer.permitData();
        bytes32 nonce = _proposalNonce();
        vm.expectRevert();
        dao.executeByVotes(0, DAO, 0, data, nonce);
    }
}
