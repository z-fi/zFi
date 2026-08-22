// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "../lib/forge-std/src/Test.sol";

interface IMoloch {
    function shares() external view returns (address);
    function allowance(address token, address spender) external view returns (uint256);
    function proposalId(uint8 op, address to, uint256 value, bytes calldata data, bytes32 nonce)
        external view returns (uint256);
    function castVote(uint256 id, uint8 support) external;
    function state(uint256 id) external view returns (uint8);
    function supplySnapshot(uint256 id) external view returns (uint256);
    function executeByVotes(uint8 op, address to, uint256 value, bytes calldata data, bytes32 nonce)
        external payable returns (bool, bytes memory);
}

interface IERC20 { function balanceOf(address) external view returns (uint256); function totalSupply() external view returns (uint256); }

interface IShareSale {
    function buy(address dao, uint256 amount) external payable;
    function sales(address dao) external view returns (address token, address payToken, uint40 deadline, uint256 price);
}

/// Can the DAO extend its own sale deadline by vote, and does an expired sale revive?
contract CauseExtendSaleTest is Test {
    address constant DAO = 0xD5dcE9BEE03e69362981afE48323A657fCceB8bE;
    IShareSale constant SALE = IShareSale(0x0000000021ea5069B532CeE09058aB9e02EA60f9);
    address constant CREATOR = 0x1C0Aa8cCD568d90d61659F060D1bFb1e6f855A20;
    address constant OTHER_HOLDER = 0x035C84E918E9FBbDEd9D4Cc57c91a76716fc38FC;
    uint256 constant PRICE = 333_000_000_000;
    uint40  constant OLD_DEADLINE = 1788203204;

    IERC20 sh;

    function setUp() public {
        if (DAO.code.length == 0) { vm.skip(true); return; }
        sh = IERC20(IMoloch(DAO).shares());
    }

    function _extendCalldata(uint40 newDeadline) internal pure returns (bytes memory) {
        // configure(token=DAO (mint-shares sentinel), payToken=ETH, price, deadline)
        return abi.encodeWithSignature(
            "configure(address,address,uint256,uint40)", DAO, address(0), PRICE, newDeadline
        );
    }

    /// The creator alone clears quorum today — and that stops being true as the sale mints.
    function test_creatorAloneCanPassItToday() public {
        uint40 newDeadline = OLD_DEADLINE + 30 days;
        bytes memory data = _extendCalldata(newDeadline);
        bytes32 nonce = keccak256("extend-sale-1");
        uint256 id = IMoloch(DAO).proposalId(0, address(SALE), 0, data, nonce);

        console.log("creator shares   :", sh.balanceOf(CREATOR) / 1e18);
        console.log("other holder     :", sh.balanceOf(OTHER_HOLDER) / 1e18);
        console.log("supply           :", sh.totalSupply() / 1e18);
        console.log("quorum needed    :", sh.totalSupply() / 1e18 / 10);

        vm.prank(CREATOR);
        IMoloch(DAO).castVote(id, 1); // 1 = for
        console.log("snapshot supply  :", IMoloch(DAO).supplySnapshot(id) / 1e18);
        console.log("state after vote :", IMoloch(DAO).state(id), "(3 = Succeeded)");
        assertEq(IMoloch(DAO).state(id), 3, "creator alone did not reach quorum");

        // First call queues, second executes after the timelock.
        vm.prank(CREATOR);
        IMoloch(DAO).executeByVotes(0, address(SALE), 0, data, nonce);
        console.log("state queued     :", IMoloch(DAO).state(id), "(2 = Queued)");

        vm.warp(block.timestamp + 2 days);
        vm.prank(CREATOR);
        IMoloch(DAO).executeByVotes(0, address(SALE), 0, data, nonce);

        (,, uint40 dl,) = SALE.sales(DAO);
        console.log("old deadline     :", OLD_DEADLINE);
        console.log("new deadline     :", dl);
        assertEq(dl, newDeadline, "deadline did not move");
    }

    /// The other holder can outvote the creator 100k to 33k.
    function test_otherHolderCanBlockIt() public {
        bytes memory data = _extendCalldata(OLD_DEADLINE + 30 days);
        bytes32 nonce = keccak256("extend-sale-2");
        uint256 id = IMoloch(DAO).proposalId(0, address(SALE), 0, data, nonce);

        vm.prank(CREATOR);
        IMoloch(DAO).castVote(id, 1);
        vm.prank(OTHER_HOLDER);
        IMoloch(DAO).castVote(id, 0); // 0 = against
        console.log("state            :", IMoloch(DAO).state(id), "(4 = Defeated)");
        assertEq(IMoloch(DAO).state(id), 4, "a 100k against vote did not defeat 33k for");
    }

    /// An already-expired sale can be revived — the deadline is not a one-way door.
    function test_expiredSaleCanBeRevived() public {
        vm.warp(uint256(OLD_DEADLINE) + 1 days);

        address buyer = address(0xB0B);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        (bool ok,) = address(SALE).call{value: 1000 * PRICE}(
            abi.encodeWithSignature("buy(address,uint256)", DAO, uint256(1000e18)));
        console.log("buy while expired:", ok, "(expected false)");
        assertFalse(ok, "expired sale still sold");

        uint40 revived = uint40(block.timestamp + 14 days);
        bytes memory data = _extendCalldata(revived);
        bytes32 nonce = keccak256("revive-sale");
        uint256 id = IMoloch(DAO).proposalId(0, address(SALE), 0, data, nonce);

        vm.prank(CREATOR);
        IMoloch(DAO).castVote(id, 1);
        vm.prank(CREATOR);
        IMoloch(DAO).executeByVotes(0, address(SALE), 0, data, nonce);
        vm.warp(block.timestamp + 2 days);
        vm.prank(CREATOR);
        IMoloch(DAO).executeByVotes(0, address(SALE), 0, data, nonce);

        vm.prank(buyer);
        (ok,) = address(SALE).call{value: 1000 * PRICE}(
            abi.encodeWithSignature("buy(address,uint256)", DAO, uint256(1000e18)));
        console.log("buy after revive :", ok, "(expected true)");
        assertTrue(ok, "revived sale still refuses buys");
        console.log("buyer shares     :", sh.balanceOf(buyer) / 1e18);
    }
}
