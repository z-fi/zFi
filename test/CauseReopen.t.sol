// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test, console} from "../lib/forge-std/src/Test.sol";

interface IMolochR {
    function proposalId(uint8,address,uint256,bytes calldata,bytes32) external view returns (uint256);
    function castVote(uint256,uint8) external;
    function state(uint256) external view returns (uint8);
    function executeByVotes(uint8,address,uint256,bytes calldata,bytes32) external payable returns (bool,bytes memory);
    function allowance(address,address) external view returns (uint256);
}
interface IERC20R { function totalSupply() external view returns (uint256); function balanceOf(address) external view returns (uint256); }
interface IOffer {
    function remaining(address) external view returns (uint256);
    function buy(address,uint256) external payable;
}

/// The two proposals the reopen panel builds, voted and executed, then a real buy.
contract ReopenTest is Test {
    address constant DAO = 0xD5dcE9BEE03e69362981afE48323A657fCceB8bE;
    address constant OFF = 0x000000A4Ad929C9E108aD2B1D2fBeDe0C2Ae57e1;
    address constant SHARES = 0xf142CfA6Ca3DFa4A131f12aACEF4890e390d70D6;
    address constant WHALE = 0x18DB005428492F8Bc154c50ad0A4Bd23DE2750fF; // clears quorum alone
    uint256 constant PRICE = 333_000_000_000;
    uint40  constant DEADLINE = 1788203204;

    // Needs a fork at head; foundry.toml pins earlier, so this skips by default:
    //   forge test --match-path test/CauseReopen.t.sol \
    //     --fork-url <rpc> --fork-block-number $(cast block-number --rpc-url <rpc>)
    function setUp() public { if (DAO.code.length == 0) vm.skip(true); }

    function _pass(address to, bytes memory data, bytes32 nonce) internal {
        uint256 id = IMolochR(DAO).proposalId(0, to, 0, data, nonce);
        vm.prank(WHALE); IMolochR(DAO).castVote(id, 1);
        assertEq(IMolochR(DAO).state(id), 3, "did not reach Succeeded");
        vm.prank(WHALE); IMolochR(DAO).executeByVotes(0, to, 0, data, nonce);  // queues
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(WHALE); IMolochR(DAO).executeByVotes(0, to, 0, data, nonce);  // executes
    }

    function test_reopenSaleEndToEnd() public {
        uint256 supply0 = IERC20R(SHARES).totalSupply();
        uint256 authorise = 2_000_000e18;
        uint256 cap = supply0 + authorise;
        console.log("supply now      :", supply0 / 1e18);
        console.log("remaining before:", IOffer(OFF).remaining(DAO));

        // exactly the bytes/nonces causeReopenSteps() produces
        _pass(DAO,
            abi.encodeWithSignature("setAllowance(address,address,uint256)", OFF, DAO, type(uint256).max),
            keccak256("zfi.cause.reopen.allow.0x000000a4ad929c9e108ad2b1d2fbede0c2ae57e1"));
        console.log("allowance to OFF:", IMolochR(DAO).allowance(DAO, OFF) == type(uint256).max ? "max" : "wrong");

        _pass(OFF,
            abi.encodeWithSignature("configure(address,address,uint256,uint40,uint256)",
                DAO, address(0), PRICE, DEADLINE, cap),
            keccak256(bytes(string.concat("zfi.cause.reopen.cfg.", vm.toString(cap)))));

        uint256 rem = IOffer(OFF).remaining(DAO);
        console.log("remaining after :", rem / 1e18, "shares");
        assertEq(rem, authorise, "capacity not opened");

        // and it actually sells
        address buyer = address(0xB0B);
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        IOffer(OFF).buy{value: 1_000_000 * PRICE}(DAO, 1_000_000e18);
        console.log("buyer got       :", IERC20R(SHARES).balanceOf(buyer) / 1e18, "shares");
        assertEq(IERC20R(SHARES).balanceOf(buyer), 1_000_000e18, "buy did not land");
        console.log("remaining now   :", IOffer(OFF).remaining(DAO) / 1e18);
    }
}
