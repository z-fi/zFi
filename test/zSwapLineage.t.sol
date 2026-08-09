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

    address[6] chunks;

    function setUp() public {
        for (uint256 i; i != 6; ++i) {
            // Six distinct, NON-EMPTY data contracts. The content is irrelevant
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
        return abi.encodePacked(
            type(zSwap).creationCode,
            abi.encode(dao, previous, chunks[0], chunks[1], chunks[2], chunks[3], chunks[4], chunks[5])
        );
    }

    function _root() internal returns (zSwap) {
        return new zSwap(dao, address(0), chunks[0], chunks[1], chunks[2], chunks[3], chunks[4], chunks[5]);
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
        new zSwap(dao, address(v1), chunks[0], chunks[1], chunks[2], chunks[3], chunks[4], chunks[5]);
    }

    function test_deployNextRevertsRatherThanRecordingAFailedDeploy() public {
        zSwap v1 = _root();
        // Initcode that reverts on construction: CREATE2 yields address(0).
        vm.prank(dao);
        vm.expectRevert(zSwap.DeployFailed.selector);
        v1.deployNext(hex"60006000fd", bytes32(uint256(9)));
        assertEq(v1.successor(), address(0), "a failed deploy leaves no successor");
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

    function test_versionStringIsZeroPointOne() public {
        assertEq(_root().VERSION(), "0.1");
    }
}
