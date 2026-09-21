// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {LaunchToken, PrecisionLauncher} from "../src/pools/PrecisionLauncher.sol";
import {PrecisionLauncherLens} from "../src/pools/PrecisionLauncherLens.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";

/// @dev The coin launcher on Base and Robinhood, deployed the way
/// `script/l2-mirror.mjs` deploys it: the mainnet SafeSummoner payloads in
/// `deploy/`, resent unchanged. FORKED, because what decides whether that is
/// sound lives on those chains and nowhere else:
///
///   - the three replays land at the mainnet addresses, bound to the factory
///     already mirrored there and to the FeeSplitter replayed beside them, and
///   - the tithe still leaves the launcher when the address it burns to holds
///     no BETH. On Base that address is a plain ERC-20 with no payable entry
///     point; on Robinhood it has no code at all. Either way the sweep must
///     succeed, the creator and the treasury must be paid in full, and the
///     tenth must arrive there with no receipt.
///
/// Each chain replays only what is not live yet, so the suite holds before and
/// after the broadcast.
contract PrecisionLauncherL2Test is Test {
    address constant SUMMONER = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant FACTORY = 0x000000Eb27B557aB426d9E99cFd54EC455799e81;
    address constant BURNER = 0x2cb662Ec360C34a45d7cA0126BCd53C9a1fd48F9;

    address creator = address(0xC0FFEE);
    address alice = address(0xA11CE);

    function testBase() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        assertGt(BURNER.code.length, 0, "Base has code at the burner address");
        _launchAndSweep();
    }

    function testRobinhood() public {
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        _launchAndSweep();
    }

    function testBaseArt() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")));
        _launchWithArt();
    }

    function testRobinhoodArt() public {
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        _launchWithArt();
    }

    /// The logo is stamped into contract code in the launch itself, served back
    /// from `contractURI`, and restampable by the coin's owner - as on mainnet.
    function _launchWithArt() internal {
        _replay("FeeSplitter");
        PrecisionLauncher launcher = PrecisionLauncher(payable(_replay("PrecisionLauncher")));
        bytes memory svg =
            bytes("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 8 8\"><circle cx=\"4\" cy=\"4\" r=\"4\"/></svg>");
        (address t,) = launcher.launchWithArt("Art", "ART", "", 1_000_000_000 ether, 0, 3 ether, creator, svg, 2);
        LaunchToken token = LaunchToken(t);

        address ptr = token.imagePointer();
        assertTrue(ptr != address(0), "no on-chain image");
        assertEq(keccak256(ptr.code), keccak256(abi.encodePacked(hex"00", svg)), "the stamped bytes are not the logo");
        assertTrue(LibString.contains(_json(token), Base64.encode(svg)), "contractURI does not serve the stamped logo");

        bytes memory png = hex"89504e470d0a1a0a0000000d49484452";
        vm.prank(creator);
        token.setImage(png, 0);
        assertTrue(LibString.contains(_json(token), Base64.encode(png)), "the owner's restamp is not served");
    }

    /// `contractURI` is the metadata JSON, itself base64-encoded behind a data URI.
    function _json(LaunchToken token) internal view returns (string memory) {
        string memory uri = token.contractURI();
        string memory head = "data:application/json;base64,";
        assertTrue(LibString.startsWith(uri, head), "contractURI is not a base64 JSON data URI");
        return string(Base64.decode(LibString.slice(uri, bytes(head).length)));
    }

    function _replay(string memory name) internal returns (address at) {
        at = vm.parseAddress(vm.trim(vm.readFile(string.concat("deploy/", name, ".address.txt"))));
        if (at.code.length == 0) {
            (bool ok,) =
                SUMMONER.call(vm.parseBytes(vm.trim(vm.readFile(string.concat("deploy/", name, ".deploy.calldata.txt")))));
            assertTrue(ok, string.concat(name, ": replay reverted"));
        }
        assertGt(at.code.length, 0, string.concat(name, ": not at its mainnet address"));
    }

    function _launchAndSweep() internal {
        address splitter = _replay("FeeSplitter");
        PrecisionLauncher launcher = PrecisionLauncher(payable(_replay("PrecisionLauncher")));
        PrecisionLauncherLens lens = PrecisionLauncherLens(_replay("PrecisionLauncherLens"));

        assertEq(address(launcher.factory()), FACTORY, "launcher factory");
        assertEq(launcher.treasury(), splitter, "launcher treasury");
        assertEq(address(lens.launcher()), address(launcher), "lens launcher");
        assertEq(LaunchToken(launcher.tokenImplementation()).owner(), address(0xdEaD), "template is locked");

        uint256 launchesBefore = lens.launchCount();
        (address t, address p) = launcher.launch("Layer", "LAYR", "", 1_000_000_000 ether, 0, 3 ether, creator);
        assertEq(lens.launchCount(), launchesBefore + 1, "lens counts the launch");

        // A buy and a sell, so fees accrue on both sides: the ether side is split,
        // the token side is burned.
        PrecisionPool pool = PrecisionPool(payable(p));
        vm.deal(alice, 20 ether);
        vm.startPrank(alice);
        pool.swapExactIn{value: 20 ether}(address(0), 20 ether, 0, alice);
        LaunchToken(t).approve(p, type(uint256).max);
        pool.swapExactIn(t, LaunchToken(t).balanceOf(alice) / 2, 0, alice);
        vm.stopPrank();

        uint256 accrued = PrecisionPool(payable(p)).creatorOwed0();
        uint256 burnerBefore = BURNER.balance;
        uint256 splitterBefore = splitter.balance;
        uint256 creatorBefore = creator.balance;
        uint256 launcherBefore = address(launcher).balance;

        (uint256 creatorEth, uint256 protocolEth, uint256 titheEth, uint256 tokensBurned, bool recorded) =
            launcher.collectFees(t);

        assertEq(creatorEth + protocolEth + titheEth, accrued, "the split lost or invented wei");
        assertEq(titheEth, accrued / 10, "tithe is not a tenth");
        assertEq(creator.balance - creatorBefore, creatorEth, "creator underpaid");
        assertEq(splitter.balance - splitterBefore, protocolEth, "treasury underpaid");
        assertEq(BURNER.balance - burnerBefore, titheEth, "the tenth did not reach the burner address");
        assertFalse(recorded, "no BETH here, so no receipt");
        assertEq(address(launcher).balance, launcherBefore, "launcher kept ether");
        assertGt(tokensBurned, 0, "token side did not burn");
    }
}
