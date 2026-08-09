// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Fwabol} from "../src/forwarders/Fwabol.sol";
import {V4QuoteLens} from "../src/V4QuoteLens.sol";
import {Fwabol as FwabolV2} from "../src/forwarders/FwabolV2.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice The deployment itself, rehearsed against mainnet before it is paid for.
///
/// Everything upstream of this has been checked on artifacts: the three CREATE2
/// tables agree, the salt was mined against the pinned initcode, the checker is
/// green. None of that exercises the transaction that will actually be sent.
/// This does - the literal bytes from `deploy/<Name>.deploy.calldata.txt`, to
/// the real SafeSummoner, on a fork - and then swaps through what comes out.
///
/// @dev The calldata is READ FROM DISK rather than rebuilt here on purpose. A
///      test that re-encodes the call proves the encoder agrees with itself.
///      Reading the file proves the bytes that will be broadcast are the bytes
///      that were verified.
contract FwabolDeployTest is Test {
    address constant SUMMONER = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant UR = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address constant HOOK = 0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444;

    address deployer = makeAddr("deployer");
    address user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        vm.deal(deployer, 1 ether);
        vm.deal(user, 10 ether);
    }

    /// @dev Deploys if the address is still free, and otherwise checks the code
    ///      already there. The suite was written before the deploy and has to
    ///      keep working after it - a rehearsal that turns red the moment it
    ///      succeeds stops being run, and then stops being true.
    function _deploy(string memory name) internal returns (address deployed) {
        address expected = vm.parseAddress(vm.trim(vm.readFile(string.concat("deploy/", name, ".address.txt"))));
        bytes memory calldata_ =
            vm.parseBytes(vm.trim(vm.readFile(string.concat("deploy/", name, ".deploy.calldata.txt"))));

        if (expected.code.length != 0) {
            // Already live. Everything downstream still runs against it, which
            // is the stronger check anyway: it is the real deployed runtime.
            return expected;
        }

        vm.prank(deployer);
        (bool ok, bytes memory ret) = SUMMONER.call(calldata_);
        assertTrue(ok, "the summoner accepted the calldata");

        deployed = abi.decode(ret, (address));
        assertEq(deployed, expected, "and put it exactly where the tables say");
        assertGt(deployed.code.length, 0, "with code at it");
    }

    /// The address is vanity, so it is worth confirming it is the one that was
    /// mined rather than merely a valid one.
    function test_deployedAddressHasThreeLeadingZeroBytes() public {
        address fwabol = _deploy("Fwabol");
        assertEq(uint256(uint160(fwabol)) >> 136, 0, "three leading zero bytes");
        address lens = _deploy("V4QuoteLens");
        assertEq(uint256(uint160(lens)) >> 136, 0, "three leading zero bytes");
    }

    /// Constructor args survive the CREATE2 round trip. A wrong router here is
    /// not recoverable - it is immutable, and the contract would be dead on
    /// arrival at an address that can never be reused.
    function test_deployedFwabolIsBoundToTheRealRouter() public {
        Fwabol fwabol = Fwabol(payable(_deploy("Fwabol")));
        assertEq(fwabol.router(), UR, "bound to the mainnet Universal Router");
        assertGt(UR.code.length, 0, "which is a live contract");
    }

    /// The deployed runtime, not a locally constructed one, buys FWA for a user.
    /// This is the last thing that could differ: same source, same optimizer
    /// runs, but the bytes that will sit at that address forever.
    function test_theDeployedRuntimeActuallyBuys() public {
        Fwabol fwabol = Fwabol(payable(_deploy("Fwabol")));

        uint256 before = IERC20(FWA).balanceOf(user);
        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.001 ether}(user, 1, block.timestamp + 300);

        assertGt(IERC20(FWA).balanceOf(user) - before, 0, "the user was paid");
        assertEq(IERC20(FWA).balanceOf(address(fwabol)), 0, "and the adapter kept nothing");
        assertEq(address(fwabol).balance, 0, "of either asset");
    }

    /// And the deployed lens quotes what the deployed adapter delivers - the
    /// two halves that ship together, checked together, at their real addresses.
    function test_theDeployedLensQuotesTheDeployedAdapter() public {
        Fwabol fwabol = Fwabol(payable(_deploy("Fwabol")));
        V4QuoteLens lens = V4QuoteLens(_deploy("V4QuoteLens"));

        (, uint256 quoted) = lens.quoteV4Hooked(false, address(0), FWA, 0, 60, HOOK, 0.01 ether);
        assertGt(quoted, 0, "the lens quoted");

        uint256 before = IERC20(FWA).balanceOf(user);
        vm.prank(user);
        fwabol.swapEthForFwa{value: 0.01 ether}(user, uint128(quoted), block.timestamp + 300);

        assertEq(IERC20(FWA).balanceOf(user) - before, quoted, "quote == delivery, at production addresses");
    }

    /// The superseding Fwabol: deployed from its own calldata, then made to buy
    /// AND sell at its production address. The sell is the half the first one
    /// could not do, so it is the half most worth proving off a fresh deploy.
    function test_theSupersedingFwabolBuysAndSells() public {
        FwabolV2 fw = FwabolV2(payable(_deploy("FwabolV2")));

        uint256 fwaBefore = IERC20(FWA).balanceOf(user);
        vm.prank(user);
        uint256 got = fw.buy{value: 0.02 ether}(user, 1, block.timestamp + 300);
        assertEq(IERC20(FWA).balanceOf(user) - fwaBefore, got, "bought");

        vm.startPrank(user);
        IERC20(FWA).approve(address(fw), type(uint256).max);
        uint256 ethBefore = user.balance;
        uint256 back = fw.sell(uint128(got), user, 1, block.timestamp + 300);
        vm.stopPrank();

        assertEq(user.balance - ethBefore, back, "and sold, straight back to the seller");
        assertEq(IERC20(FWA).balanceOf(address(fw)), 0, "the adapter held no FWA");
        assertEq(address(fw).balance, 0, "and no ETH");
        emit log_named_decimal_uint("0.02 ETH round trip", back, 18);
    }

    /// Deploying twice must not be a way to get a different contract at the
    /// same address - and a re-run of the deploy script should fail loudly
    /// rather than appear to succeed.
    function test_redeployingTheSameSaltIsRefused() public {
        _deploy("Fwabol");
        bytes memory calldata_ = vm.parseBytes(vm.trim(vm.readFile("deploy/Fwabol.deploy.calldata.txt")));
        vm.prank(deployer);
        (bool ok,) = SUMMONER.call(calldata_);
        assertFalse(ok, "the second deploy fails instead of silently doing nothing");
    }
}
