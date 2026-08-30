// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {zSwap} from "../src/zSwap.sol";

/// @notice The DAO-gated successor chain.
///
/// The property worth defending is that `html()` NEVER moves. A pointer to a
/// newer version is a claim about lineage, not a redirect, and these tests pin
/// that: after a successor exists, the predecessor still serves its own bytes.
///
/// The second property is that lineage cannot be forged. A successor is only
/// ever created by `deployNext`, so at construction time the deployer IS the
/// predecessor - which is what lets the constructor refuse any `previous` that
/// is not `msg.sender`, and what makes the backward pointer worth trusting.
contract zSwapLineageTest is Test {
    address dao = makeAddr("dao");
    address stranger = makeAddr("stranger");

    uint256 constant CHUNKS = 16;

    address[CHUNKS] chunks;

    function setUp() public {
        for (uint256 i; i != CHUNKS; ++i) {
            // CHUNKS distinct, NON-EMPTY data contracts. The content is irrelevant
            // but the length is not: `6001` is valid initcode that returns
            // nothing, so the chunk deploys with zero code and the constructor
            // rejects it. This stub writes one byte and returns it.
            //   PUSH1 n  PUSH1 0  MSTORE8  PUSH1 1  PUSH1 0  RETURN
            bytes memory code =
                abi.encodePacked(hex"60", uint8(i + 1), hex"60005360016000f3");
            address a;
            assembly {
                a := create(0, add(code, 0x20), mload(code))
            }
            chunks[i] = a;
        }
    }

    function _initcode(address previous) internal view returns (bytes memory) {
        return _initcodeFor(dao, previous);
    }

    /// @dev The same initcode with the DAO chosen by the caller - which is the
    ///      exact shape of the allegiance attack `deployNext` must refuse: a
    ///      succession payload whose constructor args look right in every way
    ///      the walk can see, but whose version answers to a different admin.
    function _initcodeFor(address g, address previous) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(zSwap).creationCode,
            abi.encode(g, previous, chunks)
        );
    }

    function _root() internal returns (zSwap) {
        return new zSwap(dao, address(0), chunks);
    }

    // ------------------------------------------------------------- THE ROOT

    function test_rootHasNoPredecessorAndIsGenerationOne() public {
        zSwap v1 = _root();
        assertEq(v1.PREVIOUS(), address(0));
        assertEq(v1.successor(), address(0));
        assertEq(v1.generation(), 1);
        assertEq(v1.latest(), address(v1), "with no successor, this IS the tip");
    }

    // ------------------------------------------------------------ THE CHAIN

    function test_daoDeploysTheSuccessorAndTheChainLinksBothWays() public {
        zSwap v1 = _root();
        vm.prank(dao);
        address v2 = v1.deployNext(_initcode(address(v1)), bytes32(uint256(1)));

        assertEq(v1.successor(), v2, "forward");
        assertEq(zSwap(v2).PREVIOUS(), address(v1), "backward");
        assertEq(zSwap(v2).generation(), 2);
        assertEq(v1.latest(), v2, "the root resolves to the tip");
        assertEq(zSwap(v2).latest(), v2);
    }

    function test_generationCountsAlongAThreeLinkChain() public {
        zSwap v1 = _root();
        vm.prank(dao);
        address v2 = v1.deployNext(_initcode(address(v1)), bytes32(uint256(1)));
        vm.prank(dao);
        address v3 = zSwap(v2).deployNext(_initcode(v2), bytes32(uint256(2)));

        assertEq(zSwap(v3).generation(), 3);
        assertEq(v1.latest(), v3, "the root still finds the newest");
        assertEq(zSwap(v3).PREVIOUS(), v2);
        assertEq(zSwap(v2).PREVIOUS(), address(v1));
    }

    /// The whole point: a successor does not move the predecessor's bytes.
    function test_predecessorStillServesItsOwnPageAfterBeingSucceeded() public {
        zSwap v1 = _root();
        string memory before = v1.html();
        vm.prank(dao);
        v1.deployNext(_initcode(address(v1)), bytes32(uint256(1)));
        assertEq(v1.html(), before, "html() is not a redirect");
    }

    // ------------------------------------------------------------ THE GUARDS

    function test_onlyTheDaoMayDeployTheSuccessor() public {
        zSwap v1 = _root();
        vm.prank(stranger);
        vm.expectRevert(zSwap.NotDAO.selector);
        v1.deployNext(_initcode(address(v1)), bytes32(uint256(1)));
    }

    function test_successorIsWriteOnce() public {
        zSwap v1 = _root();
        vm.prank(dao);
        v1.deployNext(_initcode(address(v1)), bytes32(uint256(1)));
        vm.prank(dao);
        vm.expectRevert(zSwap.AlreadySucceeded.selector);
        v1.deployNext(_initcode(address(v1)), bytes32(uint256(2)));
    }

    /// Lineage is unforgeable, not merely recorded: naming a predecessor you
    /// were not deployed by must fail, or the backward pointer means nothing.
    function test_cannotClaimAPredecessorThatDidNotDeployYou() public {
        zSwap v1 = _root();
        vm.expectRevert(zSwap.InvalidData.selector);
        new zSwap(dao, address(v1), chunks);
    }

    function test_deployNextRevertsRatherThanRecordingAFailedDeploy() public {
        zSwap v1 = _root();
        // Initcode that reverts on construction: CREATE2 yields address(0).
        vm.prank(dao);
        vm.expectRevert(zSwap.DeployFailed.selector);
        v1.deployNext(hex"60006000fd", bytes32(uint256(9)));
        assertEq(v1.successor(), address(0), "a failed deploy leaves no successor");
    }

    /// A CREATE2 that "succeeds" onto zero runtime code is the sharpest way to
    /// lose the chain: the address is non-zero, so the write-once pointer would
    /// be spent, and every subsequent `latest()` walk - from this contract AND
    /// from every predecessor - would revert decoding empty returndata, with
    /// `AlreadySucceeded` refusing the repair. It must not be recordable.
    function test_deployNextRefusesACodelessSuccessor() public {
        zSwap v1 = _root();
        // PUSH1 0 PUSH1 0 RETURN: constructs fine, returns no runtime code.
        vm.prank(dao);
        vm.expectRevert(zSwap.NotASuccessor.selector);
        v1.deployNext(hex"60006000f3", bytes32(uint256(11)));
        assertEq(v1.successor(), address(0));
        assertEq(v1.latest(), address(v1), "the walk still terminates");
    }

    /// The constructor's `previous` check is skipped when `previous` is zero,
    /// so a successor CAN be built that declares no predecessor. Recording one
    /// would fork the record: `v1.successor()` says v2, `v2.PREVIOUS()` says
    /// nothing, and `v2.generation()` restarts at 1. Two accounts of one fact.
    function test_deployNextRefusesASuccessorThatDisownsThisContract() public {
        zSwap v1 = _root();
        vm.prank(dao);
        vm.expectRevert(zSwap.NotASuccessor.selector);
        v1.deployNext(_initcode(address(0)), bytes32(uint256(12)));
        assertEq(v1.successor(), address(0));
    }

    /// Not every contract answers `PREVIOUS()`. One that does not - or that
    /// answers with someone else's address - is not this contract's successor.
    function test_deployNextRefusesAContractThatIsNotAzSwap() public {
        zSwap v1 = _root();
        // Runtime code that returns nothing for any call: valid contract, no ABI.
        vm.prank(dao);
        vm.expectRevert(zSwap.NotASuccessor.selector);
        v1.deployNext(hex"600b80600a3d393df360006000f3", bytes32(uint256(13)));
        assertEq(v1.successor(), address(0));
    }

    /// `latest()` walks FORWARD by calling `successor()` on each link, so a
    /// successor that cannot answer it breaks the walk for this contract and
    /// every predecessor - the same permanent failure as a codeless deploy,
    /// reached from the other side.
    function test_deployNextRefusesASuccessorThatCannotBeWalkedForward() public {
        zSwap v1 = _root();
        // Answers PREVIOUS() with this contract's address and everything else
        // with empty returndata: passes the backward check, fails the forward.
        bytes memory runtime = abi.encodePacked(hex"73", address(v1), hex"60005260206000f3");
        bytes memory initcode = abi.encodePacked(
            hex"61", bytes2(uint16(runtime.length)), hex"80600a5f395ff3", runtime
        );
        vm.prank(dao);
        vm.expectRevert(zSwap.NotASuccessor.selector);
        v1.deployNext(initcode, bytes32(uint256(14)));
        assertEq(v1.successor(), address(0));
        assertEq(v1.latest(), address(v1), "the walk still terminates");
    }

    /// The two probes above verify the successor's shape; this one verifies
    /// its allegiance. A real zSwap whose constructor was handed a DIFFERENT
    /// DAO answers `PREVIOUS()` and `successor()` perfectly - the walk would
    /// love it - but its admin is a governance this lineage never chose. One
    /// DAO address, for the life of the lineage, or there is no lineage.
    function test_deployNextRefusesASuccessorThatAnswersToAnotherDAO() public {
        zSwap v1 = _root();
        bytes memory init = _initcodeFor(stranger, address(v1));
        vm.prank(dao);
        vm.expectRevert(zSwap.NotASuccessor.selector);
        v1.deployNext(init, bytes32(uint256(15)));
        assertEq(v1.successor(), address(0));
    }

    /// The salt is the point of CREATE2 here: the DAO can publish the next
    /// address before the code exists.
    function test_successorAddressIsKnownBeforeItIsDeployed() public {
        zSwap v1 = _root();
        bytes memory init = _initcode(address(v1));
        bytes32 salt = bytes32(uint256(7));
        address predicted = vm.computeCreate2Address(salt, keccak256(init), address(v1));

        vm.prank(dao);
        address actual = v1.deployNext(init, salt);
        assertEq(actual, predicted, "CREATE2 landed where it was said it would");
    }

    /// Hand-written and immutable, like every other version marker here. It is
    /// not read for behaviour, which is exactly why it drifts: v0.2 was built
    /// still calling itself "0.1" and nothing failed until this was checked.
    function test_versionStringMatchesTheBuild() public {
        assertEq(_root().VERSION(), "0.3");
    }
}
