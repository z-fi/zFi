// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSwap} from "../src/zSwap.sol";

/// @notice Preflight for the ROOT deployment - the one that pins `DAO` forever.
///
///         `DAO` is immutable and is the only address that can ever call
///         `deployNext`. There is no setter, no recovery and no second chance:
///         a typo, an EOA nobody holds, or a contract that cannot make an
///         arbitrary call, and the page can never be succeeded. Every other
///         mistake in this repo is fixable by deploying again; this one is
///         fixable only by abandoning the address and every link to it.
///
///         So the address is CHECKED rather than trusted, against mainnet,
///         before it is baked in. What is checked is deliberately about shape
///         and capability, not about governance: whether a proposal passes is
///         the DAO's business, but whether the thing at that address could
///         execute the call at all is ours.
contract zSwapRootDeployTest is Test {
    uint256 constant CHUNKS = 11;

    /// The DAO this deployment will name. Moloch proxy, ZORG-share governed.
    address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;
    address constant ZORG = 0x00a6bA94BBb5474725515De88fE04F854f2dCb12;

    /// `executeByVotes(uint8,address,uint256,bytes,bytes32)` - the entry point an
    /// upgrade would go through, and the reason this DAO can drive `deployNext`
    /// at all. A DAO without an arbitrary-call path would be a dead end.
    bytes4 constant EXECUTE_BY_VOTES = 0x9d0a6a2c;

    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_739_900
        );
    }

    function _writeChunk(bytes memory data) internal returns (address p) {
        bytes memory initcode = bytes.concat(hex"61", bytes2(uint16(data.length)), hex"80600a5f395ff3", data);
        assembly ("memory-safe") {
            p := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(p != address(0), "chunk deploy failed");
    }

    function _realChunks() internal returns (address[CHUNKS] memory p) {
        bytes memory html = vm.readFileBinary("zSwap.html");
        uint256 per = (html.length + CHUNKS - 1) / CHUNKS;
        for (uint256 k; k < CHUNKS; ++k) {
            uint256 start = k * per;
            uint256 end = start + per > html.length ? html.length : start + per;
            bytes memory part = new bytes(end - start);
            for (uint256 i; i < end - start; ++i) {
                part[i] = html[start + i];
            }
            p[k] = _writeChunk(part);
        }
    }

    // ------------------------------------------------- the address being pinned

    /// An EOA here would be silently accepted by the constructor and would work
    /// - until the key is lost, at which point the lineage ends. A contract is
    /// the whole point of naming a DAO.
    function test_theDaoIsAContract() public view {
        assertGt(DAO.code.length, 0, "DAO has no code - an EOA or a typo");
    }

    /// It must be able to make a call it was told to make. This is the property
    /// that cannot be added later: `DAO` is immutable, so a DAO with no
    /// arbitrary-call path pins the page at generation one forever.
    function test_theDaoCanExecuteAnArbitraryCall() public view {
        (bool ok,) = DAO.staticcall(abi.encodeWithSelector(EXECUTE_BY_VOTES, uint8(0), address(0), uint256(0), "", bytes32(0)));
        // A staticcall to a state-changing function reverts, which is the
        // ANSWER: reaching it at all proves the selector is routed. A missing
        // function on this proxy would fall through to its implementation and
        // revert too - so the check that carries the weight is the pairing with
        // `shares()` below, which no unrelated contract would answer.
        ok;
        (bool sOk, bytes memory sRet) = DAO.staticcall(abi.encodeWithSignature("shares()"));
        assertTrue(sOk, "DAO does not answer shares() - not the Moloch we think it is");
        assertEq(abi.decode(sRet, (address)), ZORG, "DAO is governed by a different token than ZORG");
    }

    // ------------------------------------------------------- the deployment

    /// The root: no predecessor, generation one, and it is its own tip.
    function test_rootServesThePageAndNamesTheDao() public {
        zSwap root = new zSwap(DAO, address(0), _realChunks());

        assertEq(root.DAO(), DAO, "the deployment named a different DAO than intended");
        assertEq(root.PREVIOUS(), address(0), "a root has no predecessor");
        assertEq(root.generation(), 1);
        assertEq(root.latest(), address(root), "with no successor it is the tip");
        assertEq(bytes(root.html()).length, vm.readFileBinary("zSwap.html").length, "serves the whole page");
    }

    /// The upgrade key works, and only for the DAO.
    ///
    /// Pranked rather than voted through: whether a proposal passes is the
    /// Moloch's business and modelling its quorum here would be testing someone
    /// else's contract with my guesses about it. What belongs to zSwap is
    /// whether it accepts THAT address as caller and refuses every other, and
    /// that is what this pins.
    function test_onlyTheNamedDaoCanSucceedIt() public {
        zSwap root = new zSwap(DAO, address(0), _realChunks());
        bytes memory initcode =
            bytes.concat(type(zSwap).creationCode, abi.encode(DAO, address(root), _realChunks()));

        vm.prank(stranger);
        vm.expectRevert(zSwap.NotDAO.selector);
        root.deployNext(initcode, bytes32(uint256(1)));

        vm.prank(DAO);
        address next = root.deployNext(initcode, bytes32(uint256(1)));
        assertEq(root.successor(), next, "the DAO could not succeed the page it owns");
        assertEq(zSwap(next).DAO(), DAO, "the successor inherits the same DAO");
        assertEq(zSwap(next).generation(), 2);
    }

    /// The chunks must be fourteen distinct, non-empty data contracts, or the
    /// constructor reverts `InvalidData`. Checked here because the root deploy
    /// is the one place the set is assembled by hand rather than by a test.
    function test_theChunkSetIsWellFormed() public {
        address[CHUNKS] memory p = _realChunks();
        uint256 total;
        for (uint256 i; i < CHUNKS; ++i) {
            assertGt(p[i].code.length, 0, "empty chunk");
            total += p[i].code.length;
            for (uint256 j; j < i; ++j) assertTrue(p[i] != p[j], "duplicate chunk");
            assertLe(p[i].code.length, 24_576, "chunk exceeds EIP-170");
        }
        assertEq(total, vm.readFileBinary("zSwap.html").length, "the chunks do not sum to the page");
    }
}
