// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";

interface IE20 {
    function transfer(address,uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function owner() external view returns (address);
}

contract FwaTransferTest is Test {
    IE20 constant FWA = IE20(0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845);

    function setUp() public { vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io"))); }

    /// @dev Can an ordinary holder send FWA to another wallet?
    function test_HolderToHolderTransfer() public {
        address alice = address(0xA11CE); address bob = address(0xB0B);
        deal(address(FWA), alice, 1e18);
        assertEq(FWA.balanceOf(alice), 1e18, "deal failed");
        vm.prank(alice);
        try FWA.transfer(bob, 1e17) {
            emit log("RESULT: holder->holder transfer SUCCEEDED (freely transferable)");
        } catch (bytes memory err) {
            emit log("RESULT: holder->holder transfer REVERTED (transfer-locked)");
            emit log_bytes(err);
        }
    }

    /// @dev The owner is exempt per the guard. Confirm the asymmetry is real.
    function test_OwnerTransfer() public {
        address o = FWA.owner();
        deal(address(FWA), o, 1e18);
        vm.prank(o);
        try FWA.transfer(address(0xB0B), 1e17) { emit log("RESULT: owner transfer SUCCEEDED"); }
        catch { emit log("RESULT: owner transfer REVERTED"); }
    }
}
