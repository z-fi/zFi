// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;
import "forge-std/Test.sol";
import "../src/zQuoter.sol";
import {zQuoterV4} from "../src/zQuoterV4.sol";
interface IERC20x { function balanceOf(address) external view returns (uint256); function approve(address,uint256) external returns (bool); }

contract TmpRepro is Test {
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant V4_HELPER = 0x00005d8a3675b7b00BA172Aa85485Fc5D23121B6;
    address constant ETH = address(0);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    zQuoter q;
    address user = address(0xB0B);

    function setUp() public {
        vm.createSelectFork("https://gateway.tenderly.co/public/mainnet", 25_640_000);
        vm.etch(V4_HELPER, address(new zQuoterV4()).code);
        q = new zQuoter();
    }

    function _build() internal returns (bytes memory cd, uint256 mv) {
        (,, , bytes memory mc, uint256 v) =
            q.buildBestSwapViaETHMulticall(user, user, false, ETH, USDC, 0.021 ether, 100, type(uint256).max);
        return (mc, v);
    }

    /// Exactly as the matrix does it: value comes from the test contract, which was never funded.
    function test_A_asMatrixDoesIt() public {
        (bytes memory cd, uint256 mv) = _build();
        vm.deal(user, 1 ether); // matrix funds the USER
        emit log_named_uint("msgValue", mv);
        emit log_named_uint("test contract balance", address(this).balance);
        vm.prank(user);
        (bool ok, bytes memory ret) = ZROUTER.call{value: mv}(cd);
        emit log_named_string("result", ok ? "OK" : "REVERTED");
        if (!ret_empty(ret)) emit log_named_bytes("revert data", ret);
        assertTrue(ok, "as-matrix reverted");
    }

    /// Same call, but the account actually supplying the value is funded.
    function test_B_withTestContractFunded() public {
        (bytes memory cd, uint256 mv) = _build();
        vm.deal(user, 1 ether);
        vm.deal(address(this), 10 ether);
        uint256 before = IERC20x(USDC).balanceOf(user);
        vm.prank(user);
        (bool ok, bytes memory ret) = ZROUTER.call{value: mv}(cd);
        emit log_named_string("result", ok ? "OK" : "REVERTED");
        if (!ret_empty(ret)) emit log_named_bytes("revert data", ret);
        emit log_named_uint("USDC delivered", IERC20x(USDC).balanceOf(user) - before);
        assertTrue(ok, "funded-caller reverted");
    }

    function ret_empty(bytes memory b) internal pure returns (bool) { return b.length == 0; }
    receive() external payable {}
}
