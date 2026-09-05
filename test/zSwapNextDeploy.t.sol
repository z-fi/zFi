// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSwap} from "../src/zSwap.sol";

/// @notice The NEXT succession, rehearsed against mainnet as it actually is.
///
///         An `eth_call` with a spoofed `from` proves the tip would ACCEPT the
///         call. It proves nothing about what the chain looks like afterwards,
///         because eth_call throws the state away - and "afterwards" is the
///         whole question: `successor` is write-once, so the only chance to see
///         whether it lands correctly is before it is sent for real.
///
///         So this forks mainnet, impersonates the DAO, executes `deployNext`
///         on the CURRENT TIP, and then reads the world back. What is asserted
///         is the interface the lineage is walked by - `PREVIOUS`, `successor`,
///         `generation`, `latest` - plus the thing all of it exists to serve:
///         the page itself.
///
///         The page the rehearsal carries is the working tree's: its chunks are
///         deployed locally exactly as script/deploy-zSwapNext.mjs deploys
///         them, and the served page is compared to the source byte-for-byte.
///         Once those chunks exist on mainnet, paste their addresses over
///         `_deployChunks` to rehearse the exact proposal payload - which is
///         what the v0.2 rehearsal did, with the twelve real addresses this
///         file carried until then (see git history).
///
///         NO VERSION ASSERTION ON THE SUCCESSOR: this file compiles today's
///         src, so the successor would report whatever the source says either
///         way, and asserting it here only restates the build. The pin that
///         catches a forgotten bump is test_versionStringMatchesTheBuild in
///         zSwapLineage.t.sol.
///
///         REPOINTING: TIP is a release constant. When the succession it
///         rehearses ships, the pre-state test goes red on purpose - it says
///         so in its message - and TIP moves to the version that just became
///         the tip.
contract zSwapNextDeployTest is Test {
    /// The current tip: zSwap v0.2, live since 2026-08-20.
    address constant TIP = 0xe686952842627A2cf81DF42CCaD54ef98046DB8D;
    address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;

    uint256 constant CHUNKS = 18;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum.publicnode.com")));
    }

    /// @dev Deploys `data` as a contract whose runtime bytecode IS that data,
    ///      mirroring how the chunks are deployed on-chain (PUSH2 len, DUP1,
    ///      PUSH1 0x0a, PUSH0, CODECOPY, PUSH0, RETURN | payload).
    function _writeChunk(bytes memory data) internal returns (address p) {
        bytes memory initcode = bytes.concat(hex"61", bytes2(uint16(data.length)), hex"80600a5f395ff3", data);
        assembly ("memory-safe") {
            p := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(p != address(0), "chunk deploy failed");
    }

    /// @dev Splits zSwap.html into CHUNKS parts and deploys each one - ceil
    ///      division, remainder in the last, the same slicing
    ///      script/build-zSwap-chunks.mjs does. Reassembly order is the chunk
    ///      order, which is what the page assertion downstream is really
    ///      checking.
    function _deployChunks() internal returns (address[CHUNKS] memory p) {
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

    /// @dev The successor's initcode: today's compiled zSwap, pointed at the
    ///      tip. `previous` MUST be TIP - the constructor refuses any other
    ///      value once the deploy comes from TIP's own `deployNext`.
    function _initcode(address[CHUNKS] memory chunks) internal view returns (bytes memory) {
        return bytes.concat(type(zSwap).creationCode, abi.encode(DAO, TIP, chunks));
    }

    /// The state that must be true BEFORE the vote, or the proposal is moot.
    /// Red here means the succession it rehearses has shipped: repoint TIP.
    function test_theTipIsStillUnsucceeded() public view {
        assertEq(zSwap(TIP).successor(), address(0), "the successor slot is already spent - repoint TIP to the new tip");
        assertEq(zSwap(TIP).DAO(), DAO, "the tip names a different DAO than the proposal targets");
        // The tip reports itself v0.2. This is a fork-identity check as much as
        // a lineage one: it fails if TIP ever stops being the address below.
        assertEq(zSwap(TIP).VERSION(), "0.2", "the tip is not the version this rehearsal was written for");
        address prev = zSwap(TIP).PREVIOUS();
        assertTrue(prev != address(0), "the tip is the root - there is no predecessor to point back at");
        assertEq(zSwap(TIP).generation(), zSwap(prev).generation() + 1, "the tip is not one generation past its predecessor");
    }

    /// The whole succession, executed, then read back.
    function test_theDaoSucceedsTheTipAndTheChainAgrees() public {
        address[CHUNKS] memory chunks = _deployChunks();
        bytes memory initcode = _initcode(chunks);
        bytes32 salt = bytes32(0);
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), TIP, salt, keccak256(initcode))))));

        vm.prank(DAO);
        address next = zSwap(TIP).deployNext(initcode, salt);

        assertEq(next, predicted, "the successor did not land where CREATE2 said it would");

        // Backward and forward halves of the pointer, which every reader walks.
        assertEq(zSwap(next).PREVIOUS(), TIP, "the successor does not name the tip");
        assertEq(zSwap(TIP).successor(), next, "the tip does not name the successor");
        assertEq(zSwap(next).successor(), address(0), "a new tip cannot already be succeeded");

        // The numbers the page and the resolver read - derived from the tip
        // rather than hardcoded, so the suite survives the chain growing.
        assertEq(zSwap(next).generation(), zSwap(TIP).generation() + 1, "generation did not advance by one");
        assertEq(zSwap(TIP).latest(), next, "the tip's tip did not move");
        assertEq(zSwap(next).latest(), next, "the new tip is not its own tip");

        // The DAO carries forward, or the succession after this one is impossible.
        assertEq(zSwap(next).DAO(), DAO, "the successor named a different DAO");

        // And the point of all of it: the page the successor serves is the
        // page in the tree, byte for byte, over the same ABI a gateway calls.
        string memory page = zSwap(next).html();
        string memory source = string(vm.readFileBinary("zSwap.html"));
        assertEq(bytes(page).length, bytes(source).length, "the successor serves a different page than the source");
        assertEq(keccak256(bytes(page)), keccak256(bytes(source)), "the reassembled page does not match zSwap.html");
    }

    /// The tip refuses anyone else, so a leaked deployer key cannot pre-empt
    /// the vote by burning the one successor slot.
    /// @dev The initcode is built OUTSIDE the prank/expectRevert window: its
    ///      argument evaluation deploys the twelve chunks, and `create` is a
    ///      call as far as those cheatcodes are concerned - evaluated inline,
    ///      it consumes the prank and the real call runs as the wrong sender.
    function test_nobodyButTheDaoCanSucceedIt() public {
        bytes memory initcode = _initcode(_deployChunks());
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        zSwap(TIP).deployNext(initcode, bytes32(0));
    }

    /// Write-once: a second succession is refused even from the DAO.
    function test_theSlotCannotBeSpentTwice() public {
        bytes memory initcode = _initcode(_deployChunks());
        vm.prank(DAO);
        zSwap(TIP).deployNext(initcode, bytes32(0));
        vm.prank(DAO);
        vm.expectRevert();
        zSwap(TIP).deployNext(initcode, bytes32(uint256(1)));
    }
}
