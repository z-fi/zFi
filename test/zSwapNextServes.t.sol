// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSwap} from "../src/zSwap.sol";

/// @notice What the DAO's proposal actually produces, read out and written to
///         disk so it can be diffed against the source it claims to be.
///
///         The succession test asserts a hash, which is proof but not evidence:
///         it says the bytes match without ever showing them. This deploys the
///         successor from the SAME shape of initcode the proposal carries,
///         asks it for the page over the ABI exactly as a gateway would, and
///         writes the result to out/. Whether that file is the dapp is then a
///         question anyone can answer with `cmp`, not one they have to take on
///         trust.
///
///         The chunks are deployed locally from zSwap.html - see
///         zSwapNextDeployTest for why, and for the repointing rule for TIP.
contract zSwapNextServesTest is Test {
    /// The current tip: zSwap v0.2, live since 2026-08-20.
    address constant TIP = 0xe686952842627A2cf81DF42CCaD54ef98046DB8D;
    address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;

    uint256 constant CHUNKS = 19;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum.publicnode.com")));
    }

    function _writeChunk(bytes memory data) internal returns (address p) {
        bytes memory initcode = bytes.concat(hex"61", bytes2(uint16(data.length)), hex"80600a5f395ff3", data);
        assembly ("memory-safe") {
            p := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(p != address(0), "chunk deploy failed");
    }

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

    function test_theSuccessorServesTheDappAndWritesItOut() public {
        bytes memory initcode = bytes.concat(type(zSwap).creationCode, abi.encode(DAO, TIP, _deployChunks()));

        vm.prank(DAO);
        address next = zSwap(TIP).deployNext(initcode, bytes32(0));

        // Over the same ABI a gateway calls, not by reading the chunks directly.
        string memory page = zSwap(next).html();
        vm.writeFile("out/zSwapNext.served.html", page);

        // ERC-5219 is how web3:// gateways fetch it; a 200 with the right
        // content type is what makes the address browsable at all.
        (uint16 code, string memory body,) = zSwap(next).request(new string[](0), new zSwap.KeyValue[](0));
        assertEq(code, 200, "the gateway path does not answer 200");
        assertEq(keccak256(bytes(body)), keccak256(bytes(page)), "request() and html() disagree");
    }
}
