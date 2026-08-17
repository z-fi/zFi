// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSwap} from "../src/zSwap.sol";

/// @notice The launch operation itself: succeed a LIVE page with a LIVE page.
///
///         Two suites already cover the halves. `zSwapLineage.t.sol` proves the
///         pointer system - forward and backward links, generation, `latest()`,
///         write-once, DAO-only, a failed deploy recording nothing - but builds
///         its versions from fourteen stub data contracts, because for the
///         pointers the content is irrelevant. `zSwap.t.sol` proves a wrapper
///         built from the REAL fourteen chunks serves the real page.
///
///         Nothing composed them, and the composition is exactly what gets done
///         to ship a fix: deploy fourteen new chunks, call `deployNext` with the
///         successor's initcode, repoint the naming layer. Each half passing
///         does not by itself say the whole thing does - a stub successor cannot
///         show that a real one still serves 277KB through `html()`, and it
///         cannot show what that costs.
///
///         The property that matters most is the one an upgrade is most likely
///         to break by accident: succeeding a page must NOT change what the old
///         page serves. `html()` is immutable and the successor is a claim about
///         lineage, never a redirect - so a bookmark, an auditor and a gateway
///         cache that were told the answer is fixed must all keep getting the
///         same bytes afterwards.
contract zSwapLineageRealTest is Test {
    uint256 constant CHUNKS = 11;

    address dao = makeAddr("dao");

    function _writeChunk(bytes memory data) internal returns (address p) {
        bytes memory initcode = bytes.concat(hex"61", bytes2(uint16(data.length)), hex"80600a5f395ff3", data);
        assembly ("memory-safe") {
            p := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(p != address(0), "chunk deploy failed");
    }

    /// @dev The real page, split and deployed the way production does it.
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

    function _initcode(address previous, address[CHUNKS] memory p) internal view returns (bytes memory) {
        return bytes.concat(type(zSwap).creationCode, abi.encode(dao, previous, p));
    }

    /// The whole operation, once, with nothing stubbed.
    function test_aRealPageSucceedsARealPageAndBothStillServe() public {
        zSwap v1 = new zSwap(dao, address(0), _realChunks());
        string memory servedByV1 = v1.html();
        assertEq(bytes(servedByV1).length, vm.readFileBinary("zSwap.html").length, "v1 serves the whole page");

        // A successor built from its OWN fourteen chunks, as a real one would be.
        //
        // Built BEFORE the prank, deliberately. `vm.prank` applies to the next
        // call, and `_realChunks()` makes fourteen CREATEs of its own - so
        // inlining it as an argument spends the prank on a chunk deploy and
        // `deployNext` arrives as this contract, which is not the DAO. The
        // failure reads `NotDAO()`, which looks like an access-control bug in
        // the page and is a foot-gun in the test.
        address[CHUNKS] memory nextChunks = _realChunks();
        bytes memory initcode = _initcode(address(v1), nextChunks);
        vm.prank(dao);
        address v2 = v1.deployNext(initcode, bytes32(uint256(1)));

        assertEq(v1.successor(), v2, "forward link");
        assertEq(zSwap(v2).PREVIOUS(), address(v1), "backward link");
        assertEq(zSwap(v2).generation(), 2, "generation advanced");
        assertEq(v1.latest(), v2, "the old address resolves to the new one");

        // The successor serves the page in full, not a stub and not a redirect.
        assertEq(zSwap(v2).html(), servedByV1, "the successor serves the same bytes");

        // THE PROPERTY AN UPGRADE MUST NOT BREAK. Being succeeded changes what
        // `latest()` answers and nothing else: the predecessor keeps serving its
        // own bytes forever, which is the entire reason this design does not put
        // a redirect in `html()`.
        assertEq(v1.html(), servedByV1, "the predecessor still serves its own page, unchanged");
    }

    /// What the operation costs, so a launch is not the first time anyone finds out.
    function test_theCostOfSucceedingIsKnown() public {
        zSwap v1 = new zSwap(dao, address(0), _realChunks());
        address[CHUNKS] memory next = _realChunks();
        bytes memory initcode = _initcode(address(v1), next);

        vm.prank(dao);
        uint256 g = gasleft();
        v1.deployNext(initcode, bytes32(uint256(1)));
        uint256 used = g - gasleft();

        emit log_named_uint("deployNext gas (wrapper only)", used);
        emit log_named_uint("initcode bytes", initcode.length);
        // The chunks are deployed SEPARATELY and are the bulk of the cost; this
        // call only stores fourteen addresses. A figure in the millions would
        // mean the payload had ended up inside the wrapper.
        assertLt(used, 3_000_000, "the successor wrapper should be cheap; the chunks are the expense");
    }

    /// A successor whose chunks are wrong must fail at CONSTRUCTION, not serve a
    /// broken page. `deployNext` bubbles that as `DeployFailed` and records
    /// nothing, so a fumbled upgrade leaves the chain exactly as it was.
    function test_aSuccessorWithADuplicateChunkIsRefusedAndNothingIsRecorded() public {
        zSwap v1 = new zSwap(dao, address(0), _realChunks());
        address[CHUNKS] memory bad = _realChunks();
        bad[7] = bad[6]; // the constructor requires all fourteen distinct

        vm.prank(dao);
        vm.expectRevert(zSwap.DeployFailed.selector);
        v1.deployNext(_initcode(address(v1), bad), bytes32(uint256(1)));

        assertEq(v1.successor(), address(0), "a refused upgrade leaves no successor");
        assertEq(v1.latest(), address(v1), "and the old page is still the tip");
    }
}
