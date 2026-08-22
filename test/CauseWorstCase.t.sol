// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "../lib/forge-std/src/Test.sol";

interface IMoloch {
    function shares() external view returns (address);
    function ragequit(address[] calldata tokens, uint256 sharesToBurn, uint256 lootToBurn) external;
    function proposalId(uint8 op, address to, uint256 value, bytes calldata data, bytes32 nonce)
        external view returns (uint256);
    function castVote(uint256 id, uint8 support) external;
    function state(uint256 id) external view returns (uint8);
    function executeByVotes(uint8 op, address to, uint256 value, bytes calldata data, bytes32 nonce)
        external payable returns (bool, bytes memory);
    function allowance(address token, address spender) external view returns (uint256);
    function ragequittable() external view returns (bool);
}
interface IERC20 { function balanceOf(address) external view returns (uint256); function totalSupply() external view returns (uint256); }
interface ITapVest { function claimable(address) external view returns (uint256); function claim(address) external returns (uint256); }

contract CauseWorstCaseTest is Test {
    address constant DAO = 0xD5dcE9BEE03e69362981afE48323A657fCceB8bE;
    address constant TAP_VEST = 0x0000000060cdD33cbE020fAE696E70E7507bF56D;
    address constant CREATOR = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;
    address constant WHALE = 0xd15031D0942634CCAC10274E68945a23D2720922; // 150,150 = majority
    uint256 constant PRICE = 333_000_000_000;
    IERC20 sh;

    function setUp() public {
        if (DAO.code.length == 0) { vm.skip(true); return; }
        sh = IERC20(IMoloch(DAO).shares());
    }

    function _tokens() internal pure returns (address[] memory t) {
        t = new address[](1); t[0] = address(0);
    }

    /// Burn every share the creator holds. What comes back?
    function test_creatorRagequitsEverything() public {
        uint256 bal = sh.balanceOf(CREATOR);
        uint256 supply = sh.totalSupply();
        uint256 treasury = DAO.balance;
        uint256 paid = 33_000 * PRICE; // creator's 1 founder share was minted free

        console.log("creator shares   :", bal / 1e18);
        console.log("supply           :", supply / 1e18);
        console.log("treasury (wei)   :", treasury);
        console.log("tap claimable    :", ITapVest(TAP_VEST).claimable(DAO));

        uint256 before = CREATOR.balance;
        vm.prank(CREATOR);
        IMoloch(DAO).ragequit(_tokens(), bal, 0);
        uint256 got = CREATOR.balance - before;

        console.log("--- ragequit all ---");
        console.log("ETH returned     :", got);
        console.log("ETH paid in      :", paid);
        console.log("shares left      :", sh.balanceOf(CREATOR));
        console.log("treasury after   :", DAO.balance);
        assertEq(sh.balanceOf(CREATOR), 0, "shares not burned");
        assertGe(got, paid, "creator got back less than they paid");
    }

    /// Same burn, but after the multisig claims everything the tap has vested.
    function test_ragequitAfterTapDrains() public {
        vm.prank(address(0xDEAD));
        ITapVest(TAP_VEST).claim(DAO);
        console.log("treasury post-tap:", DAO.balance);

        uint256 bal = sh.balanceOf(CREATOR);
        uint256 before = CREATOR.balance;
        vm.prank(CREATOR);
        IMoloch(DAO).ragequit(_tokens(), bal, 0);
        console.log("ETH returned     :", CREATOR.balance - before);
        console.log("ETH paid in      :", 33_000 * PRICE);
    }

    /// The majority holder alone votes the treasury to themselves.
    function test_majorityHolderCanDrainTreasury() public {
        console.log("whale shares     :", sh.balanceOf(WHALE) / 1e18);
        console.log("supply           :", sh.totalSupply() / 1e18);
        console.log("treasury         :", DAO.balance);

        // setAllowance(spender = whale, token = ETH, amount = whole treasury)
        bytes memory data = abi.encodeWithSignature(
            "setAllowance(address,address,uint256)", WHALE, address(0), DAO.balance);
        bytes32 nonce = keccak256("drain");
        uint256 id = IMoloch(DAO).proposalId(0, DAO, 0, data, nonce);

        vm.prank(WHALE);
        IMoloch(DAO).castVote(id, 1);
        console.log("state on whale's vote alone:", IMoloch(DAO).state(id), "(3 = Succeeded)");

        vm.prank(WHALE);
        IMoloch(DAO).executeByVotes(0, DAO, 0, data, nonce);
        vm.warp(block.timestamp + 2 days);
        vm.prank(WHALE);
        IMoloch(DAO).executeByVotes(0, DAO, 0, data, nonce);

        uint256 granted = IMoloch(DAO).allowance(address(0), WHALE);
        console.log("allowance granted to whale:", granted);

        uint256 before = WHALE.balance;
        vm.prank(WHALE);
        (bool ok,) = DAO.call(abi.encodeWithSignature("spendAllowance(address,uint256)", address(0), granted));
        console.log("drained?         :", ok);
        console.log("whale took (wei) :", WHALE.balance - before);
        console.log("treasury after   :", DAO.balance);
    }

    /// Can the majority switch ragequit off, trapping everyone else?
    function test_majorityCanDisableRagequit() public {
        bytes memory data = abi.encodeWithSignature("setRagequittable(bool)", false);
        bytes32 nonce = keccak256("no-exit");
        uint256 id = IMoloch(DAO).proposalId(0, DAO, 0, data, nonce);

        vm.prank(WHALE);
        IMoloch(DAO).castVote(id, 1);
        vm.prank(WHALE);
        IMoloch(DAO).executeByVotes(0, DAO, 0, data, nonce);
        vm.warp(block.timestamp + 2 days);
        vm.prank(WHALE);
        IMoloch(DAO).executeByVotes(0, DAO, 0, data, nonce);

        console.log("ragequittable now:", IMoloch(DAO).ragequittable());

        uint256 cb = sh.balanceOf(CREATOR);
        vm.prank(CREATOR);
        (bool ok,) = DAO.call(abi.encodeWithSignature(
            "ragequit(address[],uint256,uint256)", _tokens(), cb, uint256(0)));
        console.log("creator can exit :", ok);
    }
}

/// The question that matters: when the majority moves against everyone else, does the
/// two-day timelock actually let the minority get out with their money?
contract RagequitProtectionTest is Test {
    address constant DAO = 0xD5dcE9BEE03e69362981afE48323A657fCceB8bE;
    address constant CREATOR = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;
    address constant HOLDER2 = 0x035C84E918E9FBbDEd9D4Cc57c91a76716fc38FC;
    address constant WHALE = 0xd15031D0942634CCAC10274E68945a23D2720922;
    IERC20 sh;

    function setUp() public {
        if (DAO.code.length == 0) { vm.skip(true); return; }
        sh = IERC20(IMoloch(DAO).shares());
    }
    function _tokens() internal pure returns (address[] memory t) { t = new address[](1); t[0] = address(0); }

    /// Whale queues an atomic "disable ragequit AND take the treasury" proposal.
    /// The minority sees it queued and leaves before it can execute.
    function test_minorityEscapesDuringTimelock() public {
        bytes[] memory batch = new bytes[](2);
        batch[0] = abi.encodeWithSignature("setRagequittable(bool)", false);
        batch[1] = abi.encodeWithSignature(
            "setAllowance(address,address,uint256)", WHALE, address(0), type(uint256).max);
        bytes memory data = abi.encodeWithSignature("multicall(bytes[])", batch);
        bytes32 nonce = keccak256("hostile-takeover");
        uint256 id = IMoloch(DAO).proposalId(0, DAO, 0, data, nonce);

        vm.prank(WHALE);
        IMoloch(DAO).castVote(id, 1);
        console.log("hostile proposal state:", IMoloch(DAO).state(id), "(3 = Succeeded)");

        // Whale starts the clock. This only QUEUES — it cannot execute yet.
        vm.prank(WHALE);
        IMoloch(DAO).executeByVotes(0, DAO, 0, data, nonce);
        console.log("state after queue     :", IMoloch(DAO).state(id), "(2 = Queued)");
        console.log("ragequit still on?    :", IMoloch(DAO).ragequittable());

        // The minority notices and leaves, one day into the two-day window.
        vm.warp(block.timestamp + 1 days);
        uint256 c0 = CREATOR.balance;
        uint256 cBal = sh.balanceOf(CREATOR);
        vm.prank(CREATOR);
        IMoloch(DAO).ragequit(_tokens(), cBal, 0);
        uint256 h0 = HOLDER2.balance;
        uint256 hBal = sh.balanceOf(HOLDER2);
        vm.prank(HOLDER2);
        IMoloch(DAO).ragequit(_tokens(), hBal, 0);

        console.log("--- minority exits during timelock ---");
        console.log("creator recovered     :", CREATOR.balance - c0);
        console.log("creator had paid      :", uint256(33_000) * 333_000_000_000);
        console.log("holder2 recovered     :", HOLDER2.balance - h0);
        console.log("holder2 had paid      :", uint256(100_000) * 333_000_000_000);
        console.log("treasury left to take :", DAO.balance);

        // Now the whale executes. Everything they can still reach is only their own share.
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(WHALE);
        IMoloch(DAO).executeByVotes(0, DAO, 0, data, nonce);
        console.log("ragequit now off?     :", IMoloch(DAO).ragequittable());
        uint256 w0 = WHALE.balance;
        vm.prank(WHALE);
        DAO.call(abi.encodeWithSignature("spendAllowance(address,uint256)", address(0), DAO.balance));
        console.log("whale seized          :", WHALE.balance - w0);
        console.log("whale had paid        :", uint256(150_150) * 333_000_000_000);

        assertGe(CREATOR.balance - c0, uint256(33_000) * 333_000_000_000 * 99 / 100, "creator lost money escaping");
        assertGe(HOLDER2.balance - h0, uint256(100_000) * 333_000_000_000 * 99 / 100, "holder2 lost money escaping");
    }

    /// And if nobody is watching?
    function test_inattentiveHolderIsTrapped() public {
        bytes[] memory batch = new bytes[](2);
        batch[0] = abi.encodeWithSignature("setRagequittable(bool)", false);
        batch[1] = abi.encodeWithSignature(
            "setAllowance(address,address,uint256)", WHALE, address(0), type(uint256).max);
        bytes memory data = abi.encodeWithSignature("multicall(bytes[])", batch);
        bytes32 nonce = keccak256("hostile-2");
        uint256 id = IMoloch(DAO).proposalId(0, DAO, 0, data, nonce);

        vm.prank(WHALE);
        IMoloch(DAO).castVote(id, 1);
        vm.prank(WHALE);
        IMoloch(DAO).executeByVotes(0, DAO, 0, data, nonce);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(WHALE);
        IMoloch(DAO).executeByVotes(0, DAO, 0, data, nonce);

        vm.prank(WHALE);
        DAO.call(abi.encodeWithSignature("spendAllowance(address,uint256)", address(0), DAO.balance));

        uint256 cBal2 = sh.balanceOf(CREATOR);
        vm.prank(CREATOR);
        (bool ok,) = DAO.call(abi.encodeWithSignature(
            "ragequit(address[],uint256,uint256)", _tokens(), cBal2, uint256(0)));
        console.log("treasury left    :", DAO.balance);
        console.log("creator can exit :", ok, "(false = trapped, lost everything)");
    }
}
