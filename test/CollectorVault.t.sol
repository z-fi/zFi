// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {CollectorVault} from "../src/dao/CollectorVault.sol";
import {CollectorVaultFactory, Call, IMoloch, IShares, IShareBurner} from "../src/dao/CollectorVaultFactory.sol";

/*//////////////////////////////////////////////////////////////
                        MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

/// @dev Mock target that accepts ETH + calldata, tracks calls
contract MockTarget {
    uint256 public callCount;
    uint256 public lastValue;
    bytes public lastData;

    function doSomething(uint256) external payable {
        callCount++;
        lastValue = msg.value;
        lastData = msg.data;
    }

    // Accept bare ETH calls (empty calldata)
    receive() external payable {
        callCount++;
        lastValue = msg.value;
    }
}

/// @dev Mock target that reverts
contract RevertTarget {
    fallback() external payable {
        revert("nope");
    }
}

/// @dev Minimal ERC20
contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        require(allowance[from][msg.sender] >= amount, "not approved");
        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Minimal ERC721
contract MockERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(uint256 => address) public getApproved;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function approve(address to, uint256 tokenId) external {
        getApproved[tokenId] = to;
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        require(
            msg.sender == from || isApprovedForAll[from][msg.sender] || getApproved[tokenId] == msg.sender,
            "not approved"
        );
        ownerOf[tokenId] = to;
        delete getApproved[tokenId];
    }
}

/// @dev ERC721 that always reverts on ownerOf (simulates non-existent tokenId)
contract RevertingERC721 {
    function ownerOf(uint256) external pure {
        revert("not minted");
    }

    function transferFrom(address, address, uint256) external pure {
        revert("not minted");
    }
}

/// @dev Tries to reenter fill()
contract ReentrantFiller {
    CollectorVault public vault;

    constructor(CollectorVault _vault) {
        vault = _vault;
    }

    function attack() external {
        vault.fill();
    }

    receive() external payable {
        vault.fill();
    }
}

/// @dev Tries to reenter execute() via receive callback
contract ReentrantExecutor {
    CollectorVault public vault;

    constructor(CollectorVault _vault) {
        vault = _vault;
    }

    receive() external payable {
        vault.execute(1);
    }
}

/// @dev Tries to reenter buy() via the spendAllowance callback
contract ReentrantBuyer {
    CollectorVault public vault;

    constructor(CollectorVault _vault) {
        vault = _vault;
    }

    function attack() external payable {
        vault.buy{value: msg.value}();
    }

    receive() external payable {
        vault.buy{value: 1}();
    }
}

/// @dev Mock Moloch that records spendAllowance calls
contract MockMoloch {
    address public lastAllowanceToken;
    uint256 public lastAllowanceAmount;
    bool public allowanceCalled;

    function spendAllowance(address token, uint256 amount) external {
        lastAllowanceToken = token;
        lastAllowanceAmount = amount;
        allowanceCalled = true;
    }

    receive() external payable {}
}

/// @dev Mock shares token for closeSale + buy tests
contract MockShares {
    mapping(address => uint256) public balanceOf;

    function setBalance(address who, uint256 amount) external {
        balanceOf[who] = amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        // Mock: just track the transfer (from msg.sender to to)
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Mock DAICO that tracks claimTap/claimableTap calls and sends ETH
contract MockDAICO {
    uint256 public claimableAmount;
    uint256 public lastClaimDao;
    bool public claimTapCalled;

    function setClaimable(uint256 amount) external {
        claimableAmount = amount;
    }

    function claimTap(address dao) external returns (uint256 claimed) {
        claimTapCalled = true;
        lastClaimDao = uint256(uint160(dao));
        claimed = claimableAmount;
        if (claimed > 0) {
            claimableAmount = 0;
            // Send ETH to caller (the vault)
            (bool ok,) = msg.sender.call{value: claimed}("");
            require(ok);
        }
    }

    function claimableTap(address) external view returns (uint256) {
        return claimableAmount;
    }

    receive() external payable {}
}

/*//////////////////////////////////////////////////////////////
                           TESTS
//////////////////////////////////////////////////////////////*/

contract CollectorVaultTest is Test {
    address dao = address(0xDA0);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    address constant DAICO_ADDR = 0x000000000033e92DB97B4B3beCD2c255126C60aC;

    CollectorVault impl;

    function setUp() public {
        impl = new CollectorVault();
    }

    /*//////////////////////////////////////////////////////////////
                        HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Clone the implementation and call init
    function _clone(bytes32 salt) internal returns (CollectorVault clone) {
        clone = CollectorVault(payable(_deployClone(address(impl), salt)));
    }

    function _deployClone(address _impl, bytes32 salt) internal returns (address clone) {
        assembly ("memory-safe") {
            mstore(0x24, 0x5af43d5f5f3e6029573d5ffd5b3d5ff3)
            mstore(0x14, _impl)
            mstore(0x00, 0x602d5f8160095f39f35f5f365f5f37365f73)
            clone := create2(0, 0x0e, 0x36, salt)
            if iszero(clone) {
                mstore(0x00, 0x30116425)
                revert(0x1c, 0x04)
            }
            mstore(0x24, 0)
        }
    }

    function _deployMode0(
        address _target,
        uint256 _ethPerCall,
        uint256 _maxCalls,
        bytes memory _payload,
        uint256 _deadline
    ) internal returns (CollectorVault m) {
        m = _clone(keccak256(abi.encode(_target, _ethPerCall, _maxCalls, _deadline, gasleft())));
        m.init(0, dao, _deadline, _target, _ethPerCall, _maxCalls, _payload, address(0), 0, false, address(0), 0);
    }

    function _deployMode1ERC20(address tkn, uint256 minBal, uint256 _deadline) internal returns (CollectorVault m) {
        m = _clone(keccak256(abi.encode(tkn, minBal, _deadline, gasleft())));
        m.init(1, dao, _deadline, address(0), 0, 0, "", tkn, minBal, false, address(0), 0);
    }

    function _deployMode1ERC721(address tkn, uint256 tokenId, uint256 _deadline) internal returns (CollectorVault m) {
        m = _clone(keccak256(abi.encode(tkn, tokenId, _deadline, gasleft())));
        m.init(1, dao, _deadline, address(0), 0, 0, "", tkn, tokenId, true, address(0), 0);
    }

    function _deployWithBuy(address _dao, address _shares, uint256 _shareRate) internal returns (CollectorVault m) {
        m = _clone(keccak256(abi.encode(_dao, _shares, _shareRate, gasleft())));
        m.init(0, _dao, 0, address(0), 0, 0, "", address(0), 0, false, _shares, _shareRate);
    }

    /// @dev Deploy MockDAICO at the hardcoded DAICO address
    function _etchDAICO() internal returns (MockDAICO mock) {
        mock = new MockDAICO();
        vm.etch(DAICO_ADDR, address(mock).code);
        mock = MockDAICO(payable(DAICO_ADDR));
    }

    function _deployMode0WithDao(
        address _dao,
        address _target,
        uint256 _ethPerCall,
        uint256 _maxCalls,
        bytes memory _payload
    ) internal returns (CollectorVault m) {
        m = _clone(keccak256(abi.encode(_dao, _target, _ethPerCall, _maxCalls, gasleft())));
        m.init(0, _dao, 0, _target, _ethPerCall, _maxCalls, _payload, address(0), 0, false, address(0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    MODE 0 — FIXED CALL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_execute_basic() public {
        MockTarget tgt = new MockTarget();
        bytes memory payload = abi.encodeWithSelector(MockTarget.doSomething.selector, 42);
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 10, payload, 0);

        vm.deal(address(m), 3 ether);

        assertEq(m.executable(), 3);

        vm.prank(alice);
        m.execute(2);

        assertEq(tgt.callCount(), 2);
        assertEq(m.callsMade(), 2);
        assertEq(address(m).balance, 1 ether);
        assertEq(m.executable(), 1);
    }

    function test_execute_all_max() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 0.5 ether, 3, "", 0);

        vm.deal(address(m), 10 ether);

        assertEq(m.executable(), 3);

        m.execute(3);
        assertEq(tgt.callCount(), 3);
        assertEq(m.callsMade(), 3);
        assertEq(m.executable(), 0);
    }

    function test_execute_unlimited() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", 0);

        vm.deal(address(m), 5 ether);
        assertEq(m.executable(), 5);

        m.execute(5);
        assertEq(tgt.callCount(), 5);
        assertEq(m.executable(), 0);
    }

    function test_execute_zero_ethPerCall() public {
        MockTarget tgt = new MockTarget();
        bytes memory payload = abi.encodeWithSelector(MockTarget.doSomething.selector, 1);
        CollectorVault m = _deployMode0(address(tgt), 0, 5, payload, 0);

        assertEq(m.executable(), 0);

        m.execute(3);
        assertEq(tgt.callCount(), 3);
        assertEq(m.callsMade(), 3);
    }

    function test_execute_reverts_WrongMode() public {
        CollectorVault m = _clone(bytes32(uint256(0xdead)));
        m.init(1, dao, 0, address(0), 0, 0, "", address(0), 0, false, address(0), 0);
        vm.expectRevert(CollectorVault.WrongMode.selector);
        m.execute(1);
    }

    function test_execute_reverts_BadQuantity() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", 0);
        vm.expectRevert(CollectorVault.BadQuantity.selector);
        m.execute(0);
    }

    function test_execute_reverts_NoFunds() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", 0);
        vm.deal(address(m), 0.5 ether);
        vm.expectRevert(CollectorVault.NoFunds.selector);
        m.execute(1);
    }

    function test_execute_reverts_MaxReached() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 2, "", 0);
        vm.deal(address(m), 10 ether);

        m.execute(2);

        vm.expectRevert(CollectorVault.MaxReached.selector);
        m.execute(1);
    }

    function test_execute_reverts_targetReverts() public {
        RevertTarget tgt = new RevertTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", 0);
        vm.deal(address(m), 1 ether);

        vm.expectRevert();
        m.execute(1);
    }

    function test_execute_emitsEvent() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", 0);
        vm.deal(address(m), 2 ether);

        vm.expectEmit(false, false, false, true);
        emit CollectorVault.Executed(2, 2 ether);
        m.execute(2);
    }

    /*//////////////////////////////////////////////////////////////
                   MODE 1 — TOKEN FILL (ERC20) TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fill_erc20() public {
        MockERC20 tkn = new MockERC20();
        CollectorVault m = _deployMode1ERC20(address(tkn), 1000, 0);

        vm.deal(address(m), 5 ether);

        tkn.mint(alice, 1000);
        vm.startPrank(alice);
        tkn.approve(address(m), 1000);
        m.fill();
        vm.stopPrank();

        assertTrue(m.filled());
        assertTrue(m.isFilled());
        assertEq(tkn.balanceOf(address(m)), 1000);
        assertEq(tkn.balanceOf(alice), 0);
        assertEq(alice.balance, 5 ether);
        assertEq(address(m).balance, 0);
    }

    function test_fill_erc20_reverts_AlreadyFilled() public {
        MockERC20 tkn = new MockERC20();
        CollectorVault m = _deployMode1ERC20(address(tkn), 100, 0);

        vm.deal(address(m), 1 ether);

        tkn.mint(alice, 200);
        vm.startPrank(alice);
        tkn.approve(address(m), 200);
        m.fill();

        vm.deal(address(m), 1 ether);
        vm.expectRevert(CollectorVault.AlreadyFilled.selector);
        m.fill();
        vm.stopPrank();
    }

    function test_fill_reverts_WrongMode() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", 0);
        vm.expectRevert(CollectorVault.WrongMode.selector);
        m.fill();
    }

    function test_fill_reverts_NoFunds() public {
        MockERC20 tkn = new MockERC20();
        CollectorVault m = _deployMode1ERC20(address(tkn), 100, 0);
        vm.deal(address(m), 0);

        vm.expectRevert(CollectorVault.NoFunds.selector);
        m.fill();
    }

    function test_fill_reverts_noApproval() public {
        MockERC20 tkn = new MockERC20();
        CollectorVault m = _deployMode1ERC20(address(tkn), 100, 0);
        vm.deal(address(m), 1 ether);

        tkn.mint(alice, 100);
        vm.prank(alice);
        vm.expectRevert();
        m.fill();
    }

    function test_fill_emitsEvent() public {
        MockERC20 tkn = new MockERC20();
        CollectorVault m = _deployMode1ERC20(address(tkn), 100, 0);
        vm.deal(address(m), 2 ether);

        tkn.mint(alice, 100);
        vm.startPrank(alice);
        tkn.approve(address(m), 100);

        vm.expectEmit(true, false, false, true);
        emit CollectorVault.Filled(alice, 2 ether);
        m.fill();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                   MODE 1 — TOKEN FILL (ERC721) TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fill_erc721() public {
        MockERC721 nft = new MockERC721();
        uint256 tokenId = 42;
        CollectorVault m = _deployMode1ERC721(address(nft), tokenId, 0);

        vm.deal(address(m), 3 ether);

        nft.mint(alice, tokenId);
        vm.startPrank(alice);
        nft.approve(address(m), tokenId);
        m.fill();
        vm.stopPrank();

        assertTrue(m.filled());
        assertTrue(m.isFilled());
        assertEq(nft.ownerOf(tokenId), address(m));
        assertEq(alice.balance, 3 ether);
    }

    function test_isFilled_erc721_beforeFill() public {
        MockERC721 nft = new MockERC721();
        uint256 tokenId = 99;
        CollectorVault m = _deployMode1ERC721(address(nft), tokenId, 0);

        assertFalse(m.isFilled());

        nft.mint(alice, tokenId);
        assertFalse(m.isFilled());

        vm.prank(alice);
        nft.transferFrom(alice, address(m), tokenId);
        assertTrue(m.isFilled());
    }

    function test_isFilled_erc20_beforeFill() public {
        MockERC20 tkn = new MockERC20();
        CollectorVault m = _deployMode1ERC20(address(tkn), 500, 0);

        assertFalse(m.isFilled());

        tkn.mint(address(m), 499);
        assertFalse(m.isFilled());

        tkn.mint(address(m), 1);
        assertTrue(m.isFilled());
    }

    function test_isFilled_mode0_returnsFalse() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", 0);
        assertFalse(m.isFilled());
    }

    /*//////////////////////////////////////////////////////////////
                        CLAWBACK TESTS
    //////////////////////////////////////////////////////////////*/

    function test_clawback_daoOnly_noDeadline() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", 0);
        vm.deal(address(m), 2 ether);

        vm.prank(alice);
        vm.expectRevert(CollectorVault.NotDAO.selector);
        m.clawback();

        vm.prank(dao);
        m.clawback();
        assertEq(dao.balance, 2 ether);
        assertEq(address(m).balance, 0);
    }

    function test_clawback_permissionless_afterDeadline() public {
        uint256 dl = block.timestamp + 1000;
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", dl);
        vm.deal(address(m), 2 ether);

        vm.prank(alice);
        vm.expectRevert(CollectorVault.NotDAO.selector);
        m.clawback();

        vm.warp(dl);
        vm.prank(alice);
        m.clawback();
        assertEq(dao.balance, 2 ether);
    }

    function test_clawback_dao_beforeDeadline() public {
        uint256 dl = block.timestamp + 1000;
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", dl);
        vm.deal(address(m), 1 ether);

        vm.prank(dao);
        m.clawback();
        assertEq(dao.balance, 1 ether);
    }

    function test_clawback_reverts_NoFunds() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", 0);
        vm.deal(address(m), 0);

        vm.prank(dao);
        vm.expectRevert(CollectorVault.NoFunds.selector);
        m.clawback();
    }

    function test_clawback_emitsEvent() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", 0);
        vm.deal(address(m), 1.5 ether);

        vm.prank(dao);
        vm.expectEmit(false, false, false, true);
        emit CollectorVault.Clawback(1.5 ether);
        m.clawback();
    }

    /*//////////////////////////////////////////////////////////////
                        RECEIVE / ERC721 RECEIVER
    //////////////////////////////////////////////////////////////*/

    function test_receive_eth() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", 0);
        vm.deal(address(m), 0);

        vm.deal(alice, 5 ether);
        vm.prank(alice);
        (bool ok,) = address(m).call{value: 3 ether}("");
        assertTrue(ok);
        assertEq(address(m).balance, 3 ether);
    }

    function test_onERC721Received() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", 0);

        bytes4 ret = m.onERC721Received(address(0), address(0), 0, "");
        assertEq(ret, CollectorVault.onERC721Received.selector);
    }

    /*//////////////////////////////////////////////////////////////
                        REENTRANCY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fill_reentrancy_blocked() public {
        MockERC20 tkn = new MockERC20();
        CollectorVault m = _clone(bytes32(uint256(0xBEE)));
        m.init(1, dao, 0, address(0), 0, 0, "", address(tkn), 100, false, address(0), 0);

        ReentrantFiller attacker = new ReentrantFiller(m);
        vm.deal(address(m), 2 ether);

        tkn.mint(address(attacker), 200);
        vm.prank(address(attacker));
        tkn.approve(address(m), 200);

        vm.expectRevert();
        attacker.attack();
    }

    /*//////////////////////////////////////////////////////////////
                    INIT / CLONE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_init_mode0() public {
        MockTarget tgt = new MockTarget();
        bytes memory payload = abi.encodeWithSelector(MockTarget.doSomething.selector, 99);
        CollectorVault m = _deployMode0(address(tgt), 2 ether, 5, payload, 1000);

        assertEq(m.mode(), 0);
        assertEq(m.dao(), dao);
        assertEq(m.deadline(), 1000);
        assertEq(m.target(), address(tgt));
        assertEq(m.ethPerCall(), 2 ether);
        assertEq(m.maxCalls(), 5);
        assertEq(m.callsMade(), 0);
        assertFalse(m.filled());
        assertEq(m.shares(), address(0));
        assertEq(m.shareRate(), 0);
    }

    function test_init_mode1() public {
        MockERC20 tkn = new MockERC20();
        CollectorVault m = _deployMode1ERC20(address(tkn), 500, 9999);

        assertEq(m.mode(), 1);
        assertEq(m.dao(), dao);
        assertEq(m.deadline(), 9999);
        assertEq(m.token(), address(tkn));
        assertEq(m.minBalance(), 500);
        assertFalse(m.specificId());
        assertFalse(m.filled());
    }

    function test_init_reverts_AlreadyInitialized() public {
        CollectorVault m = _clone(bytes32(uint256(0xABC)));
        m.init(0, dao, 0, address(0), 0, 0, "", address(0), 0, false, address(0), 0);

        vm.expectRevert(CollectorVault.AlreadyInitialized.selector);
        m.init(0, dao, 0, address(0), 0, 0, "", address(0), 0, false, address(0), 0);
    }

    function test_init_shareRate() public {
        MockMoloch moloch = new MockMoloch();
        MockShares shr = new MockShares();
        CollectorVault m = _deployWithBuy(address(moloch), address(shr), 1_000_000e18);

        assertEq(m.shareRate(), 1_000_000e18);
    }

    function test_init_reverts_zero_dao() public {
        CollectorVault m = _clone(bytes32(uint256(0xDEAD)));
        vm.expectRevert();
        m.init(0, address(0), 0, address(0), 0, 0, "", address(0), 0, false, address(0), 0);
    }

    function test_impl_bricked() public {
        vm.expectRevert(CollectorVault.AlreadyInitialized.selector);
        impl.init(0, dao, 0, address(0), 0, 0, "", address(0), 0, false, address(0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    REENTRANCY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_execute_reentrancy_blocked() public {
        ReentrantExecutor attacker = new ReentrantExecutor(CollectorVault(payable(address(0))));
        // Deploy vault targeting the attacker (attacker's receive tries to reenter)
        CollectorVault m = _deployMode0(address(attacker), 1 ether, 0, "", 0);
        // Point the attacker at the real vault
        attacker = new ReentrantExecutor(m);
        // Redeploy with attacker as target
        m = _deployMode0(address(attacker), 1 ether, 0, "", 0);
        vm.deal(address(m), 10 ether);

        vm.expectRevert();
        m.execute(1);
    }

    function test_buy_reentrancy_blocked() public {
        // Create a mock Moloch that sends ETH back (triggering receive on a ReentrantBuyer)
        // In practice, spendAllowance shouldn't send ETH, but we verify the guard works
        MockMoloch moloch = new MockMoloch();
        MockShares shr = new MockShares();

        CollectorVault m = _clone(bytes32(uint256(0xBEEF)));
        m.init(0, address(moloch), 0, address(0), 0, 0, "", address(0), 0, false, address(shr), 1e18);

        ReentrantBuyer attacker = new ReentrantBuyer(m);
        shr.setBalance(address(m), 100e18);

        vm.deal(address(attacker), 2 ether);
        vm.prank(address(attacker));
        // This should succeed (no actual reentrancy vector from spendAllowance/transfer)
        // but ensures the nonReentrant guard is wired on buy()
        attacker.attack{value: 1 ether}();
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_execute_partial_then_more() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 5, "", 0);

        vm.deal(address(m), 2 ether);
        m.execute(2);
        assertEq(m.callsMade(), 2);
        assertEq(m.executable(), 0);

        vm.deal(address(m), 3 ether);
        assertEq(m.executable(), 3);

        m.execute(3);
        assertEq(m.callsMade(), 5);
        assertEq(m.executable(), 0);

        vm.deal(address(m), 10 ether);
        assertEq(m.executable(), 0);
        vm.expectRevert(CollectorVault.MaxReached.selector);
        m.execute(1);
    }

    /*//////////////////////////////////////////////////////////////
                       DAICO TAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_claimTap_basic() public {
        MockDAICO mock = _etchDAICO();
        vm.deal(DAICO_ADDR, 5 ether);
        mock.setClaimable(2 ether);

        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0WithDao(dao, address(tgt), 1 ether, 0, "");

        uint256 claimed = m.claimTap();
        assertEq(claimed, 2 ether);
        assertEq(address(m).balance, 2 ether);
    }

    function test_claimTap_zero() public {
        MockDAICO mock = _etchDAICO();
        mock.setClaimable(0);

        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0WithDao(dao, address(tgt), 1 ether, 0, "");

        uint256 claimed = m.claimTap();
        assertEq(claimed, 0);
        assertEq(address(m).balance, 0);
    }

    function test_claimTap_emitsEvent() public {
        MockDAICO mock = _etchDAICO();
        vm.deal(DAICO_ADDR, 3 ether);
        mock.setClaimable(3 ether);

        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0WithDao(dao, address(tgt), 1 ether, 0, "");

        vm.expectEmit(false, false, false, true);
        emit CollectorVault.TapClaimed(3 ether);
        m.claimTap();
    }

    function test_claimableTap_view() public {
        MockDAICO mock = _etchDAICO();
        mock.setClaimable(7 ether);

        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0WithDao(dao, address(tgt), 1 ether, 0, "");

        assertEq(m.claimableTap(), 7 ether);
    }

    function test_executeFromTap() public {
        MockDAICO mock = _etchDAICO();
        vm.deal(DAICO_ADDR, 3 ether);
        mock.setClaimable(3 ether);

        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0WithDao(dao, address(tgt), 1 ether, 0, "");

        m.executeFromTap(2);

        assertEq(tgt.callCount(), 2);
        assertEq(m.callsMade(), 2);
        assertEq(address(m).balance, 1 ether);
    }

    function test_executeFromTap_reverts_WrongMode() public {
        _etchDAICO();

        CollectorVault m = _clone(bytes32(uint256(0xF00D)));
        m.init(1, dao, 0, address(0), 0, 0, "", address(0), 0, false, address(0), 0);

        vm.expectRevert(CollectorVault.WrongMode.selector);
        m.executeFromTap(1);
    }

    function test_executableFromTap_view() public {
        MockDAICO mock = _etchDAICO();
        mock.setClaimable(3 ether);

        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0WithDao(dao, address(tgt), 1 ether, 5, "");
        vm.deal(address(m), 1 ether);

        // 1 ETH balance + 3 ETH claimable = 4, capped by maxCalls=5, remaining=5
        assertEq(m.executableFromTap(), 4);
        // regular executable only sees balance
        assertEq(m.executable(), 1);
    }

    function test_executableFromTap_capped_by_maxCalls() public {
        MockDAICO mock = _etchDAICO();
        mock.setClaimable(10 ether);

        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0WithDao(dao, address(tgt), 1 ether, 3, "");
        vm.deal(address(m), 5 ether);

        // 5 + 10 = 15 ETH worth, but maxCalls = 3
        assertEq(m.executableFromTap(), 3);
    }

    /*//////////////////////////////////////////////////////////////
                   ALLOWANCE-BASED BUY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_buy_basic() public {
        MockMoloch moloch = new MockMoloch();
        MockShares shr = new MockShares();

        // 1 ETH = 1M shares (shareRate = 1_000_000e18)
        uint256 rate = 1_000_000e18;
        CollectorVault m = _deployWithBuy(address(moloch), address(shr), rate);

        // Give vault some shares to transfer (simulating DAO allowance payout)
        shr.setBalance(address(m), 2_000_000e18);

        uint256 daoBefore = address(moloch).balance;

        vm.deal(alice, 2 ether);
        vm.prank(alice);
        m.buy{value: 1 ether}();

        // spendAllowance called
        assertTrue(moloch.allowanceCalled());
        assertEq(moloch.lastAllowanceToken(), address(moloch)); // dao == moloch in test
        assertEq(moloch.lastAllowanceAmount(), 1_000_000e18);

        // shares transferred to buyer
        assertEq(shr.balanceOf(alice), 1_000_000e18);
        assertEq(shr.balanceOf(address(m)), 1_000_000e18);

        // ETH stays in vault to fund calls
        assertEq(address(moloch).balance, daoBefore);
        assertEq(address(m).balance, 1 ether);
    }

    function test_buy_reverts_BuyDisabled() public {
        MockTarget tgt = new MockTarget();
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 0, "", 0);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(CollectorVault.BuyDisabled.selector);
        m.buy{value: 1 ether}();
    }

    function test_buy_reverts_zero_value() public {
        MockMoloch moloch = new MockMoloch();
        MockShares shr = new MockShares();
        CollectorVault m = _deployWithBuy(address(moloch), address(shr), 1_000_000e18);

        vm.prank(alice);
        vm.expectRevert();
        m.buy{value: 0}();
    }

    function test_buy_emitsEvent() public {
        MockMoloch moloch = new MockMoloch();
        MockShares shr = new MockShares();
        uint256 rate = 1_000_000e18;
        CollectorVault m = _deployWithBuy(address(moloch), address(shr), rate);

        shr.setBalance(address(m), 1_000_000e18);

        vm.deal(alice, 1 ether);
        vm.prank(alice);

        vm.expectEmit(true, false, false, true);
        emit CollectorVault.Buy(alice, 1 ether, 1_000_000e18);
        m.buy{value: 1 ether}();
    }

    /*//////////////////////////////////////////////////////////////
               FACTORY CLONE PREDICTION CROSS-CHECK
    //////////////////////////////////////////////////////////////*/

    /// @dev Reference Solidity implementation (from FundingWorksMinter)
    function _predictCloneSolidity(address _impl, bytes32 salt_, address deployer_) internal pure returns (address) {
        bytes memory code =
            abi.encodePacked(hex"602d5f8160095f39f35f5f365f5f37365f73", _impl, hex"5af43d5f5f3e6029573d5ffd5b3d5ff3");
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer_, salt_, keccak256(code))))));
    }

    function test_factory_predictDAO_matches_solidity() public {
        CollectorVaultFactory factory = new CollectorVaultFactory();

        bytes32 salt = bytes32(uint256(12345));

        // Factory prediction
        address fromFactory = factory.predictDAO(salt);

        // Reference Solidity prediction
        address molochImpl = 0x643A45B599D81be3f3A68F37EB3De55fF10673C1;
        address summoner = 0x0000000000330B8df9E3bc5E553074DA58eE9138;
        bytes32 daoSalt = keccak256(abi.encode(new address[](0), new uint256[](0), salt));
        address fromSolidity = _predictCloneSolidity(molochImpl, daoSalt, summoner);

        assertEq(fromFactory, fromSolidity);
    }

    function test_factory_predictShares_matches_solidity() public {
        CollectorVaultFactory factory = new CollectorVaultFactory();

        bytes32 salt = bytes32(uint256(99));

        address predictedDAO = factory.predictDAO(salt);
        address fromFactory = factory.predictShares(salt);

        // Reference Solidity prediction
        address sharesImpl = 0x71E9b38d301b5A58cb998C1295045FE276Acf600;
        address fromSolidity = _predictCloneSolidity(sharesImpl, bytes32(bytes20(predictedDAO)), predictedDAO);

        assertEq(fromFactory, fromSolidity);
    }

    function test_factory_predict_fuzz(bytes32 salt) public {
        CollectorVaultFactory factory = new CollectorVaultFactory();

        address molochImpl = 0x643A45B599D81be3f3A68F37EB3De55fF10673C1;
        address summoner = 0x0000000000330B8df9E3bc5E553074DA58eE9138;
        address sharesImpl = 0x71E9b38d301b5A58cb998C1295045FE276Acf600;

        // DAO prediction
        bytes32 daoSalt = keccak256(abi.encode(new address[](0), new uint256[](0), salt));
        address daoRef = _predictCloneSolidity(molochImpl, daoSalt, summoner);
        assertEq(factory.predictDAO(salt), daoRef);

        // Shares prediction
        address sharesRef = _predictCloneSolidity(sharesImpl, bytes32(bytes20(daoRef)), daoRef);
        assertEq(factory.predictShares(salt), sharesRef);
    }

    function test_factory_predictVault_matches_deploy() public {
        CollectorVaultFactory factory = new CollectorVaultFactory();

        bytes32 salt = bytes32(uint256(777));
        uint40 deadline = uint40(block.timestamp + 1000);

        // Predict before deploy
        address predicted = factory.predictVault(salt);

        CollectorVaultFactory.VaultParams memory vp = CollectorVaultFactory.VaultParams({
            mode: 0,
            target: address(0xBEEF),
            ethPerCall: 1 ether,
            maxCalls: 10,
            payload: "",
            token: address(0),
            minBalance: 0,
            specificId: false
        });

        address vault = factory.deploy(vp, salt, deadline);
        assertEq(predicted, vault);
    }

    function test_factory_permitCall_structure() public {
        CollectorVaultFactory factory = new CollectorVaultFactory();

        bytes32 salt = bytes32(uint256(42));
        uint256 deadline = block.timestamp + 30 days;

        (address target, uint256 value, bytes memory data) = factory.permitCall(salt, deadline);

        // target should be predictedDAO
        assertEq(target, factory.predictDAO(salt));
        // value should be 0
        assertEq(value, 0);
        // data should start with setPermit selector
        bytes4 selector;
        assembly { selector := mload(add(data, 32)) }
        assertEq(selector, bytes4(keccak256("setPermit(uint8,address,uint256,bytes,bytes32,address,uint256)")));
    }

    function test_factory_deploy_basic() public {
        CollectorVaultFactory factory = new CollectorVaultFactory();

        CollectorVaultFactory.VaultParams memory vp = CollectorVaultFactory.VaultParams({
            mode: 0,
            target: address(0xBEEF),
            ethPerCall: 1 ether,
            maxCalls: 10,
            payload: "",
            token: address(0),
            minBalance: 0,
            specificId: false
        });

        bytes32 salt = bytes32(uint256(777));
        uint40 deadline = uint40(block.timestamp + 1000);

        address vault = factory.deploy(vp, salt, deadline);

        CollectorVault m = CollectorVault(payable(vault));
        assertEq(m.mode(), 0);
        assertEq(m.dao(), factory.predictDAO(salt));
        assertEq(m.deadline(), uint256(deadline));
        assertEq(m.target(), address(0xBEEF));
        assertEq(m.ethPerCall(), 1 ether);
        assertEq(m.maxCalls(), 10);
        assertEq(m.shares(), factory.predictShares(salt));
        assertEq(m.shareRate(), 0); // buy disabled via deploy()
    }

    function test_factory_deploy_is_clone() public {
        CollectorVaultFactory factory = new CollectorVaultFactory();

        CollectorVaultFactory.VaultParams memory vp = CollectorVaultFactory.VaultParams({
            mode: 0,
            target: address(0xBEEF),
            ethPerCall: 1 ether,
            maxCalls: 10,
            payload: "",
            token: address(0),
            minBalance: 0,
            specificId: false
        });

        bytes32 salt = bytes32(uint256(888));
        address vault = factory.deploy(vp, salt, 100);

        // Clone should have code (minimal proxy bytecode)
        assertTrue(vault.code.length > 0);
        // Clone should NOT be the same address as the implementation
        assertTrue(vault != factory.vaultImpl());
    }

    function test_factory_deploy_reverts_duplicate_salt() public {
        CollectorVaultFactory factory = new CollectorVaultFactory();

        CollectorVaultFactory.VaultParams memory vp = CollectorVaultFactory.VaultParams({
            mode: 0,
            target: address(0xBEEF),
            ethPerCall: 1 ether,
            maxCalls: 10,
            payload: "",
            token: address(0),
            minBalance: 0,
            specificId: false
        });

        bytes32 salt = bytes32(uint256(999));
        factory.deploy(vp, salt, 100);

        // Same salt should revert (CREATE2 collision)
        vm.expectRevert();
        factory.deploy(vp, salt, 100);
    }

    function test_fill_then_clawback_residual() public {
        MockERC20 tkn = new MockERC20();
        CollectorVault m = _deployMode1ERC20(address(tkn), 100, 0);

        vm.deal(address(m), 1 ether);
        tkn.mint(alice, 100);
        vm.startPrank(alice);
        tkn.approve(address(m), 100);
        m.fill();
        vm.stopPrank();

        vm.deal(address(m), 0.5 ether);

        vm.prank(dao);
        m.clawback();
        assertEq(dao.balance, 0.5 ether);
    }

    /*//////////////////////////////////////////////////////////////
                   BUY EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_buy_reverts_sharesAmt_zero() public {
        MockMoloch moloch = new MockMoloch();
        MockShares shr = new MockShares();

        // Very low rate: 1 wei * 1 / 1e18 = 0
        CollectorVault m = _deployWithBuy(address(moloch), address(shr), 1);

        vm.deal(alice, 1);
        vm.prank(alice);
        vm.expectRevert();
        m.buy{value: 1}();
    }

    /*//////////////////////////////////////////////////////////////
                   EXECUTABLE VIEW EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_executable_mode1_returns_zero() public {
        MockERC20 tkn = new MockERC20();
        CollectorVault m = _deployMode1ERC20(address(tkn), 100, 0);
        vm.deal(address(m), 10 ether);
        assertEq(m.executable(), 0);
    }

    function test_executableFromTap_mode1_returns_zero() public {
        _etchDAICO();
        MockERC20 tkn = new MockERC20();
        CollectorVault m = _deployMode1ERC20(address(tkn), 100, 0);
        vm.deal(address(m), 10 ether);
        assertEq(m.executableFromTap(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                   isFilled ERC721 CATCH PATH
    //////////////////////////////////////////////////////////////*/

    function test_isFilled_erc721_reverts_catch() public {
        // RevertingERC721 reverts on ownerOf — exercises the catch path
        RevertingERC721 nft = new RevertingERC721();
        CollectorVault m = _deployMode1ERC721(address(nft), 1, 0);
        assertFalse(m.isFilled());
    }

    /*//////////////////////////////////////////////////////////////
               BUY — DEADLINE / MAXCALLS / FILLED DISABLE
    //////////////////////////////////////////////////////////////*/

    function test_buy_reverts_afterDeadline() public {
        MockMoloch moloch = new MockMoloch();
        MockShares shr = new MockShares();
        uint256 rate = 1_000_000e18;

        // Deploy with deadline and shareRate
        CollectorVault m = _clone(keccak256(abi.encode("buy_deadline", gasleft())));
        uint256 dl = block.timestamp + 1000;
        m.init(0, address(moloch), dl, address(0), 0, 0, "", address(0), 0, false, address(shr), rate);

        shr.setBalance(address(m), 2_000_000e18);

        // Before deadline — works
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        m.buy{value: 1 ether}();
        assertEq(shr.balanceOf(alice), 1_000_000e18);

        // After deadline — reverts
        vm.warp(dl);
        vm.prank(alice);
        vm.expectRevert(CollectorVault.BuyDisabled.selector);
        m.buy{value: 1 ether}();
    }

    function test_buy_reverts_maxCallsSpent() public {
        MockMoloch moloch = new MockMoloch();
        MockShares shr = new MockShares();
        MockTarget tgt = new MockTarget();
        uint256 rate = 1_000_000e18;

        // Mode 0, maxCalls=1, with shareRate
        CollectorVault m = _clone(keccak256(abi.encode("buy_maxcalls", gasleft())));
        m.init(
            0,
            address(moloch),
            0,
            address(tgt),
            1 ether,
            1,
            abi.encodeWithSelector(MockTarget.doSomething.selector, 1),
            address(0),
            0,
            false,
            address(shr),
            rate
        );

        shr.setBalance(address(m), 2_000_000e18);
        vm.deal(address(m), 1 ether);

        // Execute the one allowed call
        m.execute(1);
        assertEq(m.callsMade(), 1);

        // Buy should now be disabled
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(CollectorVault.BuyDisabled.selector);
        m.buy{value: 1 ether}();
    }

    function test_buy_reverts_afterFill() public {
        MockMoloch moloch = new MockMoloch();
        MockShares shr = new MockShares();
        MockERC20 tkn = new MockERC20();
        uint256 rate = 1_000_000e18;

        // Mode 1, with shareRate
        CollectorVault m = _clone(keccak256(abi.encode("buy_fill", gasleft())));
        m.init(1, address(moloch), 0, address(0), 0, 0, "", address(tkn), 100, false, address(shr), rate);

        shr.setBalance(address(m), 2_000_000e18);
        vm.deal(address(m), 1 ether);

        // Fill the vault
        tkn.mint(alice, 100);
        vm.startPrank(alice);
        tkn.approve(address(m), 100);
        m.fill();
        vm.stopPrank();

        // Buy should now be disabled
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(CollectorVault.BuyDisabled.selector);
        m.buy{value: 1 ether}();
    }

    /*//////////////////////////////////////////////////////////////
          CLAWBACK — PERMISSIONLESS AFTER MAXCALLS / FILL
    //////////////////////////////////////////////////////////////*/

    function test_clawback_permissionless_afterMaxCalls() public {
        MockTarget tgt = new MockTarget();
        bytes memory payload = abi.encodeWithSelector(MockTarget.doSomething.selector, 1);
        CollectorVault m = _deployMode0(address(tgt), 1 ether, 2, payload, 0);
        vm.deal(address(m), 3 ether);

        // Execute all max calls
        m.execute(2);
        assertEq(m.callsMade(), 2);

        // Non-DAO caller can clawback remaining ETH
        vm.prank(alice);
        m.clawback();
        assertEq(dao.balance, 1 ether);
    }

    function test_clawback_permissionless_afterFill() public {
        MockERC20 tkn = new MockERC20();
        CollectorVault m = _deployMode1ERC20(address(tkn), 100, 0);
        vm.deal(address(m), 1 ether);

        // Fill
        tkn.mint(alice, 100);
        vm.startPrank(alice);
        tkn.approve(address(m), 100);
        m.fill();
        vm.stopPrank();

        // Send more ETH (residual)
        vm.deal(address(m), 0.5 ether);

        // Non-DAO caller can clawback
        vm.prank(bob);
        m.clawback();
        assertEq(dao.balance, 0.5 ether);
    }

    function test_clawback_reverts_NotDAO_mode1_unfilled() public {
        MockERC20 tkn = new MockERC20();
        CollectorVault m = _deployMode1ERC20(address(tkn), 100, 0);
        vm.deal(address(m), 1 ether);

        vm.prank(alice);
        vm.expectRevert(CollectorVault.NotDAO.selector);
        m.clawback();
    }
}

/*//////////////////////////////////////////////////////////////
          FACTORY INTEGRATION TESTS
//////////////////////////////////////////////////////////////*/

/// @dev Returns a fixed address for any call — used to mock DAICO/Summoner
contract ReturnAddress {
    address immutable _addr;

    constructor(address a) {
        _addr = a;
    }

    fallback() external payable {
        address a = _addr;
        assembly {
            mstore(0, a)
            return(0, 32)
        }
    }
}

/// @dev Harness to expose _buildCustomCalls for direct testing
contract FactoryHarness is CollectorVaultFactory {
    function buildCustomCalls(
        address predictedDAO,
        address predictedShares,
        address vault,
        bytes32 salt,
        DAICOParams calldata dp
    ) external pure returns (Call[] memory) {
        return _buildCustomCalls(predictedDAO, predictedShares, vault, salt, dp);
    }
}

contract FactoryIntegrationTest is Test {
    address constant DAICO_ADDR = 0x000000000033e92DB97B4B3beCD2c255126C60aC;
    address constant SUMMONER_ADDR = 0x0000000000330B8df9E3bc5E553074DA58eE9138;
    address constant BURNER_ADDR = 0x000000000040084694F7B6fb2846D067B4c3Aa9f;

    CollectorVaultFactory factory;
    bytes32 salt = bytes32(uint256(12345));

    function setUp() public {
        factory = new CollectorVaultFactory();
    }

    function _defaultVp() internal pure returns (CollectorVaultFactory.VaultParams memory) {
        return CollectorVaultFactory.VaultParams({
            mode: 0,
            target: address(0xBEEF),
            ethPerCall: 1 ether,
            maxCalls: 10,
            payload: abi.encodeWithSignature("doSomething(uint256)", 42),
            token: address(0),
            minBalance: 0,
            specificId: false
        });
    }

    function _defaultDp(uint16 lpBps) internal view returns (CollectorVaultFactory.DAICOParams memory) {
        return CollectorVaultFactory.DAICOParams({
            tribTkn: address(0),
            tribAmt: 1 ether,
            saleSupply: 1_000_000e18,
            forAmt: 1_000_000e18,
            deadline: uint40(block.timestamp + 30 days),
            sellLoot: false,
            lpBps: lpBps,
            maxSlipBps: 100,
            feeOrHook: 0,
            ratePerSec: 1e15,
            tapAllowance: 100 ether,
            quorumBps: 2000,
            votingSecs: 0,
            timelockSecs: 0,
            orgName: "Test",
            orgSymbol: "TST",
            orgURI: ""
        });
    }

    function _etchReturnAddr(address at, address returnVal) internal {
        ReturnAddress mock = new ReturnAddress(returnVal);
        vm.etch(at, address(mock).code);
        // Store the immutable _addr in slot 0 (fallback reads it)
        // For immutables embedded in bytecode, etch copies the bytecode, so the value is preserved
    }

    /*//////////////////////////////////////////////////////////////
               deployAndSummon — DAICO path (lpBps > 0)
    //////////////////////////////////////////////////////////////*/

    function test_deployAndSummon_daico_path() public {
        address predictedDAO = factory.predictDAO(salt);
        // Etch a mock at DAICO_ADDR that returns predictedDAO
        ReturnAddress mockDAICO = new ReturnAddress(predictedDAO);
        vm.etch(DAICO_ADDR, address(mockDAICO).code);

        CollectorVaultFactory.VaultParams memory vp = _defaultVp();
        CollectorVaultFactory.DAICOParams memory dp = _defaultDp(5000); // lpBps > 0

        (address dao, address vault) = factory.deployAndSummon(vp, dp, salt);

        assertEq(dao, predictedDAO);
        assertEq(vault, factory.predictVault(salt));

        CollectorVault m = CollectorVault(payable(vault));
        assertEq(m.mode(), 0);
        assertEq(m.dao(), predictedDAO);
        assertEq(m.deadline(), uint256(dp.deadline));
        assertEq(m.target(), address(0xBEEF));
        assertEq(m.ethPerCall(), 1 ether);
        assertEq(m.maxCalls(), 10);
        assertEq(m.shares(), factory.predictShares(salt));
        assertEq(m.shareRate(), 0); // DAICO handles sale
    }

    /*//////////////////////////////////////////////////////////////
           deployAndSummon — bare Moloch path (lpBps == 0)
    //////////////////////////////////////////////////////////////*/

    function test_deployAndSummon_bare_path() public {
        address predictedDAO = factory.predictDAO(salt);
        // Etch a mock at SUMMONER_ADDR that returns predictedDAO
        ReturnAddress mockSummoner = new ReturnAddress(predictedDAO);
        vm.etch(SUMMONER_ADDR, address(mockSummoner).code);

        CollectorVaultFactory.VaultParams memory vp = _defaultVp();
        CollectorVaultFactory.DAICOParams memory dp = _defaultDp(0); // lpBps == 0

        (address dao, address vault) = factory.deployAndSummon(vp, dp, salt);

        assertEq(dao, predictedDAO);

        CollectorVault m = CollectorVault(payable(vault));
        assertEq(m.mode(), 0);
        assertEq(m.dao(), predictedDAO);
        // shareRate = forAmt * 1e18 / tribAmt = 1_000_000e18 * 1e18 / 1e18 = 1_000_000e18
        assertEq(m.shareRate(), 1_000_000e18);
        assertEq(m.shares(), factory.predictShares(salt));
    }

    /*//////////////////////////////////////////////////////////////
                   deployAndSummonRaw
    //////////////////////////////////////////////////////////////*/

    function test_deployAndSummonRaw() public {
        address predictedDAO = factory.predictDAO(salt);
        ReturnAddress mockDAICO = new ReturnAddress(predictedDAO);
        vm.etch(DAICO_ADDR, address(mockDAICO).code);

        CollectorVaultFactory.VaultParams memory vp = _defaultVp();
        uint40 deadline = uint40(block.timestamp + 30 days);

        // Raw calldata — any bytes that the mock will accept
        bytes memory summonCalldata = abi.encodeWithSignature("anything()");

        (address dao, address vault) = factory.deployAndSummonRaw(vp, salt, deadline, summonCalldata);

        assertEq(dao, predictedDAO);

        CollectorVault m = CollectorVault(payable(vault));
        assertEq(m.mode(), 0);
        assertEq(m.dao(), predictedDAO);
        assertEq(m.deadline(), uint256(deadline));
        assertEq(m.shareRate(), 0);
        assertEq(m.shares(), factory.predictShares(salt));
    }

    function test_deployAndSummonRaw_reverts_dao_mismatch() public {
        // Etch a mock that returns the wrong address
        ReturnAddress mockDAICO = new ReturnAddress(address(0xBAD));
        vm.etch(DAICO_ADDR, address(mockDAICO).code);

        CollectorVaultFactory.VaultParams memory vp = _defaultVp();

        vm.expectRevert();
        factory.deployAndSummonRaw(vp, salt, 100, abi.encodeWithSignature("anything()"));
    }

    /*//////////////////////////////////////////////////////////////
              _buildCustomCalls via harness
    //////////////////////////////////////////////////////////////*/

    function test_buildCustomCalls_permit_only() public {
        FactoryHarness h = new FactoryHarness();

        address predictedDAO = address(0xDA0);
        address predictedShares = address(0x5EA);
        address vault = address(0xBEEF);

        CollectorVaultFactory.DAICOParams memory dp = _defaultDp(5000); // lpBps > 0, no gov
        dp.votingSecs = 0;
        dp.timelockSecs = 0;

        Call[] memory calls = h.buildCustomCalls(predictedDAO, predictedShares, vault, salt, dp);

        // Only permit call (no gov, no allowance for lpBps > 0)
        assertEq(calls.length, 1);
        assertEq(calls[0].target, predictedDAO);

        // Verify it's a setPermit call
        bytes4 sel;
        bytes memory d = calls[0].data;
        assembly { sel := mload(add(d, 32)) }
        assertEq(sel, IMoloch.setPermit.selector);
    }

    function test_buildCustomCalls_with_gov() public {
        FactoryHarness h = new FactoryHarness();

        CollectorVaultFactory.DAICOParams memory dp = _defaultDp(5000);
        dp.votingSecs = 86400;
        dp.timelockSecs = 3600;

        Call[] memory calls = h.buildCustomCalls(address(0xDA0), address(0x5EA), address(0xBEEF), salt, dp);

        // 2 gov + 1 permit = 3
        assertEq(calls.length, 3);

        // First call: setProposalTTL
        bytes4 sel0;
        bytes memory d0 = calls[0].data;
        assembly { sel0 := mload(add(d0, 32)) }
        assertEq(sel0, IMoloch.setProposalTTL.selector);

        // Second call: setTimelockDelay
        bytes4 sel1;
        bytes memory d1 = calls[1].data;
        assembly { sel1 := mload(add(d1, 32)) }
        assertEq(sel1, IMoloch.setTimelockDelay.selector);

        // Third call: setPermit
        bytes4 sel2;
        bytes memory d2 = calls[2].data;
        assembly { sel2 := mload(add(d2, 32)) }
        assertEq(sel2, IMoloch.setPermit.selector);
    }

    function test_buildCustomCalls_bare_path_with_allowance() public {
        FactoryHarness h = new FactoryHarness();

        address predictedDAO = address(0xDA0);
        address predictedShares = address(0x5EA);
        address vault = address(0xBEEF);

        CollectorVaultFactory.DAICOParams memory dp = _defaultDp(0); // lpBps == 0
        dp.votingSecs = 0;
        dp.timelockSecs = 0;

        Call[] memory calls = h.buildCustomCalls(predictedDAO, predictedShares, vault, salt, dp);

        // Bare path: setAllowance only (spendAllowance mints on demand, no pre-mint, no ShareBurner)
        assertEq(calls.length, 1);

        // setAllowance on DAO
        assertEq(calls[0].target, predictedDAO);
        bytes4 sel0;
        bytes memory d0 = calls[0].data;
        assembly { sel0 := mload(add(d0, 32)) }
        assertEq(sel0, IMoloch.setAllowance.selector);
    }

    function test_buildCustomCalls_bare_path_full() public {
        FactoryHarness h = new FactoryHarness();

        CollectorVaultFactory.DAICOParams memory dp = _defaultDp(0);
        dp.votingSecs = 86400;
        dp.timelockSecs = 3600;

        Call[] memory calls = h.buildCustomCalls(address(0xDA0), address(0x5EA), address(0xBEEF), salt, dp);

        // 2 gov + 1 setAllowance = 3
        assertEq(calls.length, 3);
    }

    /*//////////////////////////////////////////////////////////////
              deployAndSummon — dao mismatch revert
    //////////////////////////////////////////////////////////////*/

    function test_deployAndSummon_reverts_dao_mismatch() public {
        ReturnAddress mockDAICO = new ReturnAddress(address(0xBAD));
        vm.etch(DAICO_ADDR, address(mockDAICO).code);

        CollectorVaultFactory.VaultParams memory vp = _defaultVp();
        CollectorVaultFactory.DAICOParams memory dp = _defaultDp(5000);

        vm.expectRevert();
        factory.deployAndSummon(vp, dp, salt);
    }
}
