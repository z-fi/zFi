// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSwap} from "../src/zSwap.sol";

/// @notice What the DAO's proposal actually produces, read out and written to
///         disk so it can be diffed against the source it claims to be.
///
///         The succession test asserts a hash, which is proof but not evidence:
///         it says the bytes match without ever showing them. This deploys the
///         successor from the SAME initcode the proposal carries, asks it for
///         the page over the ABI exactly as a gateway would, and writes the
///         result to out/. Whether that file is the dapp is then a question
///         anyone can answer with `cmp`, not one they have to take on trust.
contract zSwapNextServesTest is Test {
    address constant ROOT = 0x00000095643CFfA7D9fae407a84dfCB6406456c6;
    address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;

    address[12] CHUNKS = [
        0xe8A6E96efa3A5E8b06F072936A5b7dC1278944Ab,
        0x67F406e883Bc9cD05D7B618B5ec16BA83ee09F5B,
        0x6cFC5f0539A986eB640E9Db074cd3DAa0474382b,
        0x3905E01f67035D16d02Eb0f3344fAb4f55a35d75,
        0x6aFb20DEa71EAE05Dc7193A98b7C0e4dF10141e0,
        0xf71757E2e2dA6fCCcD5fcfc5D4C415668b491EaF,
        0x8fDF890D97F3E1a6d85991e08f22e0b9080f1048,
        0x6E4403120FEC9b37a19D6ae5815b45eFBffCBd5c,
        0x88360aAAd9E9fA9986AbFF5Aec17f39393Bf222D,
        0xbD41F78D316615d7aAabCfaB50071BEFE9a7Cb7c,
        0xc346949a9C150BE962Ac073e3883878078d9981A,
        0xEbDD95e957D383b148c6589338Ed39E681D29064
    ];

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum.publicnode.com")));
    }

    function test_theSuccessorServesTheDappAndWritesItOut() public {
        bytes memory initcode = bytes.concat(type(zSwap).creationCode, abi.encode(DAO, ROOT, CHUNKS));

        vm.prank(DAO);
        address next = zSwap(ROOT).deployNext(initcode, bytes32(0));

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
