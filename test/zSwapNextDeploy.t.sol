// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSwap} from "../src/zSwap.sol";

/// @notice The v0.2 succession, run against mainnet as it actually is.
///
///         An `eth_call` with a spoofed `from` proves the root would ACCEPT the
///         call. It proves nothing about what the chain looks like afterwards,
///         because eth_call throws the state away - and "afterwards" is the
///         whole question: `successor` is write-once, so the only chance to see
///         whether it lands correctly is before it is sent for real.
///
///         So this forks mainnet, impersonates the DAO, executes `deployNext`
///         with the REAL initcode built from the REAL deployed chunks, and then
///         reads the world back. What is asserted is the interface the lineage
///         is walked by - `PREVIOUS`, `successor`, `generation`, `latest` - plus
///         the thing all of it exists to serve: the page itself.
contract zSwapNextDeployTest is Test {
    address constant ROOT = 0x00000095643CFfA7D9fae407a84dfCB6406456c6;
    address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;

    /// The twelve data contracts deployed for v0.2, in reassembly order.
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

    function _initcode() internal view returns (bytes memory) {
        return bytes.concat(type(zSwap).creationCode, abi.encode(DAO, ROOT, CHUNKS));
    }

    /// The state that must be true BEFORE the vote, or the proposal is moot.
    function test_theRootIsStillUnsucceeded() public view {
        assertEq(zSwap(ROOT).successor(), address(0), "the successor slot is already spent");
        assertEq(zSwap(ROOT).DAO(), DAO, "the root names a different DAO than the proposal targets");
        assertEq(zSwap(ROOT).generation(), 1, "the root is not generation one");
    }

    /// The whole succession, executed, then read back.
    function test_theDaoSucceedsTheRootAndTheChainAgrees() public {
        bytes32 salt = bytes32(0);
        address predicted =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), ROOT, salt, keccak256(_initcode()))))));

        vm.prank(DAO);
        address next = zSwap(ROOT).deployNext(_initcode(), salt);

        assertEq(next, predicted, "the successor did not land where CREATE2 said it would");

        // Backward and forward halves of the pointer, which every reader walks.
        assertEq(zSwap(next).PREVIOUS(), ROOT, "the successor does not name the root");
        assertEq(zSwap(ROOT).successor(), next, "the root does not name the successor");
        assertEq(zSwap(next).successor(), address(0), "a new tip cannot already be succeeded");

        // The numbers the page and the resolver read.
        assertEq(zSwap(next).generation(), 2, "v0.2 is not generation two");
        assertEq(zSwap(ROOT).latest(), next, "the root's tip did not move");
        assertEq(zSwap(next).latest(), next, "the tip is not its own tip");

        // The DAO carries forward, or generation three is impossible.
        assertEq(zSwap(next).DAO(), DAO, "the successor named a different DAO");

        // Hand-written and immutable. v0.2 was first built still reporting
        // "0.1" - the same string the root reports - which would have made the
        // two versions indistinguishable by the field that names them.
        assertEq(zSwap(next).VERSION(), "0.2", "the successor does not call itself v0.2");
        assertEq(zSwap(ROOT).VERSION(), "0.1", "the root's version changed under us");

        // And the point of all of it.
        string memory page = zSwap(next).html();
        assertEq(bytes(page).length, 287734, "the successor serves a different page than was deployed");
        assertEq(
            keccak256(bytes(page)),
            0x7fc0383637ec8fac47734e66b95a28e465f51dfb798e08fbfb8798bbd3885d14,
            "the reassembled page does not match zSwap.html"
        );
    }

    /// The root refuses anyone else, so a leaked deployer key cannot pre-empt
    /// the vote by burning the one successor slot.
    function test_nobodyButTheDaoCanSucceedIt() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        zSwap(ROOT).deployNext(_initcode(), bytes32(0));
    }

    /// Write-once: a second succession is refused even from the DAO.
    function test_theSlotCannotBeSpentTwice() public {
        vm.prank(DAO);
        zSwap(ROOT).deployNext(_initcode(), bytes32(0));
        vm.prank(DAO);
        vm.expectRevert();
        zSwap(ROOT).deployNext(_initcode(), bytes32(uint256(1)));
    }
}
