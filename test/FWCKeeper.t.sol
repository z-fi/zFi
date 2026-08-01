// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {FWCKeeper} from "../src/dao/FWCKeeper.sol";

interface IMolochT {
    function setPermit(uint8, address, uint256, bytes calldata, bytes32, address, uint256) external payable;
    function executeByVotes(uint8, address, uint256, bytes calldata, bytes32)
        external
        payable
        returns (bool, bytes memory);
    function castVote(uint256, uint8) external;
    function state(uint256) external view returns (uint8);
    function balanceOf(address, uint256) external view returns (uint256);
    function timelockDelay() external view returns (uint64);
    function getMessageCount() external view returns (uint256);
    function messages(uint256) external view returns (string memory);
    function badges() external view returns (address);
    function shares() external view returns (address);
}

interface IBadgesT {
    function mintSeat(address to, uint16 seat) external payable;
    function balanceOf(address) external view returns (uint256);
}

interface ISharesT {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function getVotes(address) external view returns (uint256);
}

interface INFTT {
    function balanceOf(address) external view returns (uint256);
}

contract FWCKeeperTest is Test {
    address constant DAO = 0xE7Aa6cA3a9Ca3fe92a425dFeaD24900B9BF49853;
    address constant VAULT = 0xB3B3f4f1535305c5f40F9c0d6bCaf38032bF7F8e;
    address constant PASS = 0xb33d806a94B6770C9d309E0842a75f8E6edCd5A6;
    address constant WHALE = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;
    address constant RANDOM = address(0xCAFE);

    // The claim payload governance has already been shown, byte for byte.
    bytes constant KNOWN_CLAIM_PAYLOAD =
        hex"b61d27f60000000000000000000000001c175b9f0e8c73ed3e677e1cbb1b5a2dd4373bfe0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000646ba4c13800000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000009c00000000000000000000000000000000000000000000000000000000";

    FWCKeeper keeper;
    IMolochT dao = IMolochT(DAO);

    function setUp() public {
        vm.createSelectFork("https://ethereum-rpc.publicnode.com");
        keeper = new FWCKeeper();
    }

    /// The contract must rebuild the exact bytes governance hashes, or the permit id
    /// it computes will not be the permit the DAO minted.
    function test_PayloadMatchesTheOneGovernanceApproved() public view {
        assertEq(keeper.claimPayload(), KNOWN_CLAIM_PAYLOAD, "claim payload drift");
    }

    function _equip() internal {
        // Resolve every address first: a call inside a pranked expression consumes the
        // prank, and the transfer would then come from the test contract, which is broke.
        ISharesT shares = ISharesT(dao.shares());
        vm.prank(WHALE);
        shares.transfer(address(keeper), 10_000 ether);
        // No badge proposal needed: Badges.onSharesChanged seats a holder automatically
        // when shares arrive, which is what makes chat() reachable from here.
        assertTrue(keeper.canChat(), "share transfer should have seated the keeper");
        keeper.selfDelegate();
        vm.roll(block.number + 1); // votes are read from the previous block
    }

    function test_KeeperProposesVotesAndThenRunsTheChore() public {
        _equip();
        assertTrue(keeper.canPropose(), "needs 10k delegated shares");
        assertTrue(keeper.canChat(), "needs a badge seat");

        uint256 msgsBefore = dao.getMessageCount();
        uint256 id = keeper.proposeClaimPermit(12);

        // the tagged message is on-chain for the dapps to parse
        assertEq(dao.getMessageCount(), msgsBefore + 1, "message posted");
        emit log_string(dao.messages(msgsBefore));
        emit log_named_uint("proposal state after self-vote (1=Active)", dao.state(id));

        // a real voter carries it past quorum
        vm.prank(WHALE);
        dao.castVote(id, 1);
        emit log_named_uint("state after whale vote (3=Succeeded)", dao.state(id));

        bytes memory data = _setPermitData(keeper.claimPayload(), keeper.CLAIM_NONCE(), 12);
        bytes32 nonce = _lastNonce(12);
        dao.executeByVotes(0, DAO, 0, data, nonce); // queue
        vm.warp(block.timestamp + dao.timelockDelay() + 1);
        dao.executeByVotes(0, DAO, 0, data, nonce); // execute

        assertEq(keeper.remainingClaims(), 12, "permits minted to the keeper");
        emit log_named_uint("claims available", keeper.remainingClaims());

        // ...and now anyone can run it
        uint256 vaultBefore = VAULT.balance;
        uint256 callerBefore = RANDOM.balance;
        vm.prank(RANDOM);
        uint256 claimed = keeper.claimFees();

        emit log_named_uint("claimed into vault", claimed);
        assertGt(claimed, 0, "fees swept");
        assertEq(VAULT.balance, vaultBefore + claimed, "proceeds go to the vault");
        assertEq(RANDOM.balance, callerBefore, "caller gains nothing");
        assertEq(keeper.remainingClaims(), 11, "one use burned");
    }

    function test_RemintBuysAPassWithVaultFunds() public {
        bytes memory payload = keeper.remintPayload();
        bytes32 nonce = keeper.REMINT_NONCE();
        vm.prank(DAO);
        dao.setPermit(0, VAULT, 0, payload, nonce, address(keeper), 3);

        assertFalse(keeper.canRemint(), "vault is short of a full pass price");
        emit log_named_uint("still needed for next pass", keeper.untilNextPass());

        vm.deal(VAULT, 1 ether);
        assertTrue(keeper.canRemint(), "funded");

        uint256 passesBefore = INFTT(PASS).balanceOf(VAULT);
        vm.prank(RANDOM);
        keeper.remint();

        assertEq(INFTT(PASS).balanceOf(VAULT), passesBefore + 1, "vault holds another pass");
        assertEq(VAULT.balance, 0, "exactly one ether spent");
        assertEq(keeper.remainingRemints(), 2, "one use burned");
        emit log_named_uint("passes held by vault", INFTT(PASS).balanceOf(VAULT));
    }

    function test_CannotSpendWithoutAPermit() public {
        vm.expectRevert(FWCKeeper.NoPermit.selector);
        keeper.claimFees();
    }

    function _setPermitData(bytes memory payload, bytes32 permitNonce, uint256 count)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeWithSignature(
            "setPermit(uint8,address,uint256,bytes,bytes32,address,uint256)",
            uint8(0),
            VAULT,
            uint256(0),
            payload,
            permitNonce,
            address(keeper),
            count
        );
    }

    function _lastNonce(uint256 count) internal view returns (bytes32) {
        return keccak256(abi.encode(address(keeper), keeper.CLAIM_NONCE(), count, keeper.proposalCount()));
    }

    /// Everything about a self-authored proposal is derived from inputs, so it can be
    /// checked before it is sent and audited after.
    function test_ProposalIsPrecomputable() public {
        _equip();
        (uint256 pid, bytes32 pnonce, bytes memory pdata) = keeper.previewClaimProposal(12);
        uint256 id = keeper.proposeClaimPermit(12);
        assertEq(id, pid, "id must match the preview");

        // and the preview's calldata/nonce are the ones the DAO will actually execute
        vm.prank(WHALE);
        dao.castVote(id, 1);
        dao.executeByVotes(0, DAO, 0, pdata, pnonce);
        vm.warp(block.timestamp + dao.timelockDelay() + 1);
        dao.executeByVotes(0, DAO, 0, pdata, pnonce);
        assertEq(keeper.remainingClaims(), 12, "preview data executed cleanly");
    }

    /// Two proposals for the same action must not collide on the same id.
    function test_SequentialProposalsAreDistinct() public {
        _equip();
        uint256 first = keeper.proposeClaimPermit(12);
        uint256 second = keeper.proposeClaimPermit(12);
        assertTrue(first != second, "sequence number must separate them");
        assertEq(keeper.proposalCount(), 2, "counter advanced");
    }

    /// An emergency config bump re-salts every permit id. The keeper's views must follow,
    /// so an operator can see that its permits need re-granting rather than silently failing.
    function test_ConfigBumpInvalidatesTheKeepersPermits() public {
        bytes memory payload = keeper.claimPayload();
        bytes32 nonce = keeper.CLAIM_NONCE();
        vm.prank(DAO);
        dao.setPermit(0, VAULT, 0, payload, nonce, address(keeper), 5);
        assertEq(keeper.remainingClaims(), 5, "granted");
        uint256 idBefore = keeper.claimPermitId();

        vm.prank(DAO);
        (bool ok,) = DAO.call(abi.encodeWithSignature("bumpConfig()"));
        assertTrue(ok);

        assertTrue(keeper.claimPermitId() != idBefore, "permit id moves with config");
        assertEq(keeper.remainingClaims(), 0, "keeper reports it can no longer act");
        vm.expectRevert(FWCKeeper.NoPermit.selector);
        keeper.claimFees();
    }

    /// The escape hatch runs a permit granted for a payload the contract does not hardcode.
    function test_GenericSpendRunsAnyGrantedPermit() public {
        // claim payload for a pass the contract has no constant for
        uint256[] memory ids = new uint256[](1);
        ids[0] = 156;
        bytes memory payload = abi.encodeWithSignature(
            "execute(address,uint256,bytes)",
            0x1C175b9F0e8C73eD3e677e1cBb1B5A2DD4373Bfe,
            uint256(0),
            abi.encodeWithSignature("claim(uint256[])", ids)
        );
        bytes32 nonce = keccak256("ADHOC");
        vm.prank(DAO);
        dao.setPermit(0, VAULT, 0, payload, nonce, address(keeper), 1);

        uint256 before = VAULT.balance;
        vm.prank(RANDOM);
        keeper.spend(payload, nonce);
        assertGt(VAULT.balance, before, "ad-hoc permit executed, proceeds to vault");
    }

    /// The guardian can halt the contract without a vote, and only the guardian can.
    function test_GuardianCanStopAndResume() public {
        address GUARDIAN = keeper.GUARDIAN();
        bytes memory payload = keeper.claimPayload();
        bytes32 nonce = keeper.CLAIM_NONCE();
        vm.prank(DAO);
        dao.setPermit(0, VAULT, 0, payload, nonce, address(keeper), 5);

        vm.prank(RANDOM);
        vm.expectRevert(FWCKeeper.NotGuardian.selector);
        keeper.setStopped(true);

        vm.prank(GUARDIAN);
        keeper.setStopped(true);
        assertTrue(keeper.stopped(), "stopped");
        assertFalse(keeper.canClaim(), "views reflect the stop");

        vm.expectRevert(FWCKeeper.Stopped.selector);
        keeper.claimFees();
        vm.expectRevert(FWCKeeper.Stopped.selector);
        keeper.spend(payload, nonce);

        // permits are untouched — a stop is a pause, not a burn
        assertEq(keeper.remainingClaims(), 5, "permits survive the stop");

        vm.prank(GUARDIAN);
        keeper.setStopped(false);
        vm.prank(RANDOM);
        uint256 claimed = keeper.claimFees();
        assertGt(claimed, 0, "resumes cleanly");
    }

    /// A stopped keeper must not be able to spam governance either.
    function test_StopAlsoBlocksProposing() public {
        _equip();
        vm.prank(keeper.GUARDIAN());
        keeper.setStopped(true);
        vm.expectRevert(FWCKeeper.Stopped.selector);
        keeper.proposeClaimPermit(12);
    }
}
