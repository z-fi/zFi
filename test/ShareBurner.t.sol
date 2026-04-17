// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {ShareBurner, IMoloch, IShares} from "../src/dao/ShareBurner.sol";

/*//////////////////////////////////////////////////////////////
                        MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

/// @dev Mock Moloch that records spendPermit calls and delegatecalls the target
contract MockMolochBurner {
    struct PermitSetup {
        uint8 op;
        address target;
        uint256 value;
        bytes data;
        bytes32 nonce;
        address spender;
        uint256 count;
    }
    PermitSetup public storedPermit;
    bool public permitSet;
    bool public permitCalled;

    function setPermit(
        uint8 op,
        address target,
        uint256 value,
        bytes calldata data,
        bytes32 nonce,
        address spender,
        uint256 count
    ) external {
        storedPermit = PermitSetup(op, target, value, data, nonce, spender, count);
        permitSet = true;
    }

    function spendPermit(uint8 op, address to, uint256 value, bytes calldata data, bytes32 nonce) external {
        require(permitSet, "no permit");
        require(storedPermit.count > 0, "permit exhausted");
        require(storedPermit.op == op, "op mismatch");
        require(storedPermit.target == to, "target mismatch");
        require(storedPermit.value == value, "value mismatch");
        require(keccak256(storedPermit.data) == keccak256(data), "data mismatch");
        require(storedPermit.nonce == nonce, "nonce mismatch");
        require(storedPermit.spender == msg.sender, "spender mismatch");

        storedPermit.count--;
        permitCalled = true;

        if (op == 1) {
            (bool ok,) = to.delegatecall(data);
            require(ok, "delegatecall failed");
        }
    }

    receive() external payable {}
}

/// @dev Mock shares token
contract MockSharesBurner {
    mapping(address => uint256) public balanceOf;
    uint256 public lastBurnAmount;
    bool public burned;

    function setBalance(address who, uint256 amount) external {
        balanceOf[who] = amount;
    }

    function burnFromMoloch(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "insufficient");
        balanceOf[from] -= amount;
        lastBurnAmount = amount;
        burned = true;
    }
}

/*//////////////////////////////////////////////////////////////
                           TESTS
//////////////////////////////////////////////////////////////*/

contract ShareBurnerTest is Test {
    ShareBurner burner;
    MockMolochBurner moloch;
    MockSharesBurner shares;

    address alice = address(0xA11CE);

    function setUp() public {
        burner = new ShareBurner();
        moloch = new MockMolochBurner();
        shares = new MockSharesBurner();
    }

    /*//////////////////////////////////////////////////////////////
                       DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function test_deploy() public view {
        assertTrue(address(burner) != address(0));
        assertTrue(address(burner).code.length > 0);
    }

    /*//////////////////////////////////////////////////////////////
                     PERMIT CALL HELPER
    //////////////////////////////////////////////////////////////*/

    function test_permitCall_structure() public view {
        uint256 deadline = block.timestamp + 30 days;
        bytes32 salt = bytes32(uint256(42));

        (address target, uint256 value, bytes memory data) =
            burner.permitCall(address(0xDA0), address(shares), deadline, salt);

        assertEq(target, address(0xDA0));
        assertEq(value, 0);

        bytes4 sel;
        assembly { sel := mload(add(data, 32)) }
        assertEq(sel, bytes4(keccak256("setPermit(uint8,address,uint256,bytes,bytes32,address,uint256)")));
    }

    function test_permitCall_self_spending() public view {
        uint256 deadline = block.timestamp + 30 days;
        bytes32 salt = bytes32(uint256(42));

        (,, bytes memory data) = burner.permitCall(address(moloch), address(shares), deadline, salt);
        bytes memory inner = _sliceBytes(data, 4);

        // Decode in two steps to avoid stack-too-deep
        (uint8 op, address target, uint256 val) = abi.decode(inner, (uint8, address, uint256));
        assertEq(op, 1);
        assertEq(target, address(burner)); // delegatecall target = burner
        assertEq(val, 0);

        // Decode remaining fields via assembly offset
        (,,,, bytes32 nonce, address spender, uint256 count) =
            abi.decode(inner, (uint8, address, uint256, bytes, bytes32, address, uint256));
        assertEq(spender, address(burner)); // spender = burner (self)
        assertEq(nonce, salt);
        assertEq(count, 1);
    }

    function test_different_deadlines_different_permits() public view {
        bytes32 salt = bytes32(uint256(1));

        (,, bytes memory d1) = burner.permitCall(address(moloch), address(shares), block.timestamp + 30 days, salt);
        (,, bytes memory d2) = burner.permitCall(address(moloch), address(shares), block.timestamp + 60 days, salt);

        assertTrue(keccak256(d1) != keccak256(d2));
    }

    /*//////////////////////////////////////////////////////////////
                     CLOSE SALE
    //////////////////////////////////////////////////////////////*/

    function test_closeSale_basic() public {
        uint256 deadline = block.timestamp + 30 days;
        bytes32 salt = bytes32(uint256(42));

        _setupPermit(address(moloch), address(shares), deadline, salt);
        shares.setBalance(address(moloch), 500_000e18);

        vm.warp(deadline + 1);
        burner.closeSale(address(moloch), address(shares), deadline, salt);

        assertTrue(moloch.permitCalled());
        assertTrue(shares.burned());
        assertEq(shares.balanceOf(address(moloch)), 0);
    }

    function test_closeSale_reverts_before_deadline() public {
        uint256 deadline = block.timestamp + 30 days;
        bytes32 salt = bytes32(uint256(42));

        _setupPermit(address(moloch), address(shares), deadline, salt);
        shares.setBalance(address(moloch), 100e18);

        vm.expectRevert();
        burner.closeSale(address(moloch), address(shares), deadline, salt);
    }

    function test_closeSale_reverts_at_deadline() public {
        uint256 deadline = block.timestamp + 30 days;
        bytes32 salt = bytes32(uint256(42));

        _setupPermit(address(moloch), address(shares), deadline, salt);
        shares.setBalance(address(moloch), 100e18);

        vm.warp(deadline);
        vm.expectRevert();
        burner.closeSale(address(moloch), address(shares), deadline, salt);
    }

    function test_closeSale_permissionless() public {
        uint256 deadline = block.timestamp + 30 days;
        bytes32 salt = bytes32(uint256(42));

        _setupPermit(address(moloch), address(shares), deadline, salt);
        shares.setBalance(address(moloch), 100e18);

        vm.warp(deadline + 1);
        vm.prank(alice);
        burner.closeSale(address(moloch), address(shares), deadline, salt);
        assertTrue(shares.burned());
    }

    function test_closeSale_one_shot() public {
        uint256 deadline = block.timestamp + 30 days;
        bytes32 salt = bytes32(uint256(42));

        _setupPermit(address(moloch), address(shares), deadline, salt);
        shares.setBalance(address(moloch), 100e18);

        vm.warp(deadline + 1);
        burner.closeSale(address(moloch), address(shares), deadline, salt);

        shares.setBalance(address(moloch), 50e18);
        vm.expectRevert();
        burner.closeSale(address(moloch), address(shares), deadline, salt);
    }

    function test_closeSale_emitsEvent() public {
        uint256 deadline = block.timestamp + 30 days;
        bytes32 salt = bytes32(uint256(42));

        _setupPermit(address(moloch), address(shares), deadline, salt);
        shares.setBalance(address(moloch), 250_000e18);

        vm.warp(deadline + 1);

        vm.expectEmit(true, false, false, true);
        emit ShareBurner.SaleClosed(address(moloch), 250_000e18);
        burner.closeSale(address(moloch), address(shares), deadline, salt);
    }

    function test_closeSale_zero_balance() public {
        uint256 deadline = block.timestamp + 30 days;
        bytes32 salt = bytes32(uint256(42));

        _setupPermit(address(moloch), address(shares), deadline, salt);

        vm.warp(deadline + 1);
        burner.closeSale(address(moloch), address(shares), deadline, salt);

        assertFalse(shares.burned());
    }

    function test_closeSale_wrong_deadline_reverts() public {
        uint256 deadline = block.timestamp + 30 days;
        bytes32 salt = bytes32(uint256(42));

        _setupPermit(address(moloch), address(shares), deadline, salt);
        shares.setBalance(address(moloch), 100e18);

        vm.warp(deadline + 8 days);
        vm.expectRevert();
        burner.closeSale(address(moloch), address(shares), deadline + 1, salt);
    }

    function test_closeSale_wrong_salt_reverts() public {
        uint256 deadline = block.timestamp + 30 days;
        bytes32 salt = bytes32(uint256(42));

        _setupPermit(address(moloch), address(shares), deadline, salt);
        shares.setBalance(address(moloch), 100e18);

        vm.warp(deadline + 1);
        vm.expectRevert();
        burner.closeSale(address(moloch), address(shares), deadline, bytes32(uint256(999)));
    }

    /*//////////////////////////////////////////////////////////////
                          HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setupPermit(address dao, address shr, uint256 deadline, bytes32 salt) internal {
        bytes memory burnData = abi.encodeWithSelector(burner.burnUnsold.selector, shr, deadline);

        MockMolochBurner(payable(dao))
            .setPermit(
                1, // op = delegatecall
                address(burner), // target = ShareBurner
                0, // value = 0
                burnData, // encoded burnUnsold
                salt, // nonce
                address(burner), // spender = ShareBurner (self)
                1 // count = 1
            );
    }

    function _sliceBytes(bytes memory b, uint256 start) internal pure returns (bytes memory) {
        require(b.length >= start);
        bytes memory result = new bytes(b.length - start);
        for (uint256 i; i < result.length; i++) {
            result[i] = b[i + start];
        }
        return result;
    }
}
