// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "../lib/solady/src/auth/Ownable.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {IPrecisionPoolFactoryRegistry, PrecisionPoolPolicy} from "../src/pools/PrecisionPoolPolicy.sol";
import {MockERC20} from "./SwapboardMocks.sol";

contract PolicyHook {
    function feeFor(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function afterSwap(address, address, uint256, uint256, address) external {}
}

contract TogglePoolRegistry {
    mapping(address pool => bool) internal _isPool;
    bool internal _reverts;

    function setPool(address pool, bool exists) external {
        _isPool[pool] = exists;
    }

    function setReverts(bool reverts_) external {
        _reverts = reverts_;
    }

    function isPool(address pool) external view returns (bool) {
        if (_reverts) revert();
        return _isPool[pool];
    }
}

contract PrecisionPoolPolicyTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant NEXT_OWNER = address(0xB0B);
    address internal constant OUTSIDER = address(0xBAD);

    PrecisionPoolFactory internal factory;
    PrecisionPoolPolicy internal policy;
    MockERC20 internal token;
    PolicyHook internal hook;
    address internal unhookedPool;
    address internal hookedPool;

    event PoolPolicySet(
        address indexed pool, PrecisionPoolPolicy.Policy oldPolicy, PrecisionPoolPolicy.Policy newPolicy
    );

    function setUp() external {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        token = new MockERC20("TKN", 18);
        hook = new PolicyHook();

        unhookedPool = factory.createPool(_market(address(0)));
        hookedPool = factory.createPool(_market(address(hook)));
        policy = new PrecisionPoolPolicy(IPrecisionPoolFactoryRegistry(address(factory)), OWNER);
    }

    function _market(address hook_) internal view returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(token),
            sqrtPLow: 1e18,
            sqrtPHigh: 2e18,
            fee: 500,
            hook: hook_,
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    function testConstructorInitializesOwnerAndFactory() external view {
        assertEq(policy.owner(), OWNER);
        assertEq(address(policy.factory()), address(factory));
    }

    function testConstructorRejectsInvalidFactoryAndOwner() external {
        vm.expectRevert(PrecisionPoolPolicy.InvalidFactory.selector);
        new PrecisionPoolPolicy(IPrecisionPoolFactoryRegistry(address(0xBEEF)), OWNER);

        vm.expectRevert(PrecisionPoolPolicy.InvalidOwner.selector);
        new PrecisionPoolPolicy(IPrecisionPoolFactoryRegistry(address(factory)), address(0));
    }

    function testConstructorRejectsWrongInterfaceRegistry() external {
        // A contract that is not a pool registry: `isPool` is missing entirely.
        vm.expectRevert(PrecisionPoolPolicy.InvalidFactory.selector);
        new PrecisionPoolPolicy(IPrecisionPoolFactoryRegistry(address(token)), OWNER);

        // A registry that answers but reverts on the probe.
        TogglePoolRegistry registry = new TogglePoolRegistry();
        registry.setReverts(true);
        vm.expectRevert(PrecisionPoolPolicy.InvalidFactory.selector);
        new PrecisionPoolPolicy(IPrecisionPoolFactoryRegistry(address(registry)), OWNER);

        // A registry that claims the zero address is a pool is not credible.
        TogglePoolRegistry loose = new TogglePoolRegistry();
        loose.setPool(address(0), true);
        vm.expectRevert(PrecisionPoolPolicy.InvalidFactory.selector);
        new PrecisionPoolPolicy(IPrecisionPoolFactoryRegistry(address(loose)), OWNER);
    }

    function testIsRoutableBatchMatchesSingleReads() external {
        vm.prank(OWNER);
        policy.setPoolPolicy(hookedPool, PrecisionPoolPolicy.Policy.Approved);

        address[] memory pools = new address[](4);
        pools[0] = unhookedPool;
        pools[1] = hookedPool;
        pools[2] = address(0xCAFE);
        pools[3] = unhookedPool;

        bool[] memory out = policy.isRoutableBatch(pools);
        assertEq(out.length, pools.length);
        for (uint256 i; i < pools.length; ++i) {
            assertEq(out[i], policy.isRoutable(pools[i]));
        }
        assertTrue(out[0]);
        assertTrue(out[1]);
        assertFalse(out[2]);

        assertEq(policy.isRoutableBatch(new address[](0)).length, 0);
    }

    function testUnknownAddressFailsClosed() external {
        address unknown = address(0xCAFE);
        assertFalse(policy.isRoutable(unknown));

        vm.expectRevert(PrecisionPoolPolicy.PoolNotRoutable.selector);
        policy.requireRoutable(unknown);
    }

    function testBlockedPoolDoesNotDependOnFactoryLiveness() external {
        TogglePoolRegistry registry = new TogglePoolRegistry();
        registry.setPool(hookedPool, true);
        PrecisionPoolPolicy isolatedPolicy =
            new PrecisionPoolPolicy(IPrecisionPoolFactoryRegistry(address(registry)), OWNER);

        vm.prank(OWNER);
        isolatedPolicy.setPoolPolicy(hookedPool, PrecisionPoolPolicy.Policy.Blocked);
        registry.setReverts(true);

        assertFalse(isolatedPolicy.isRoutable(hookedPool));
        vm.expectRevert(PrecisionPoolPolicy.PoolNotRoutable.selector);
        isolatedPolicy.requireRoutable(hookedPool);
    }

    function testDefaultAllowsUnhookedPool() external view {
        assertEq(uint256(policy.policyOf(unhookedPool)), uint256(PrecisionPoolPolicy.Policy.Default));
        assertTrue(policy.isRoutable(unhookedPool));
        policy.requireRoutable(unhookedPool);
    }

    function testDefaultDeniesHookedPool() external {
        assertEq(uint256(policy.policyOf(hookedPool)), uint256(PrecisionPoolPolicy.Policy.Default));
        assertFalse(policy.isRoutable(hookedPool));

        vm.expectRevert(PrecisionPoolPolicy.PoolNotRoutable.selector);
        policy.requireRoutable(hookedPool);
    }

    function testOwnerCanApproveAndRevokeHookedPool() external {
        vm.expectEmit(true, false, false, true, address(policy));
        emit PoolPolicySet(hookedPool, PrecisionPoolPolicy.Policy.Default, PrecisionPoolPolicy.Policy.Approved);
        vm.prank(OWNER);
        policy.setPoolPolicy(hookedPool, PrecisionPoolPolicy.Policy.Approved);
        assertTrue(policy.isRoutable(hookedPool));
        policy.requireRoutable(hookedPool);

        vm.prank(OWNER);
        policy.setPoolPolicy(hookedPool, PrecisionPoolPolicy.Policy.Default);
        assertFalse(policy.isRoutable(hookedPool));
    }

    function testOwnerCanBlockAndRestoreUnhookedPool() external {
        vm.prank(OWNER);
        policy.setPoolPolicy(unhookedPool, PrecisionPoolPolicy.Policy.Blocked);
        assertFalse(policy.isRoutable(unhookedPool));

        vm.prank(OWNER);
        policy.setPoolPolicy(unhookedPool, PrecisionPoolPolicy.Policy.Default);
        assertTrue(policy.isRoutable(unhookedPool));
    }

    function testBlockingHookedPoolErasesPriorApproval() external {
        vm.startPrank(OWNER);
        policy.setPoolPolicy(hookedPool, PrecisionPoolPolicy.Policy.Approved);
        policy.setPoolPolicy(hookedPool, PrecisionPoolPolicy.Policy.Blocked);
        vm.stopPrank();
        assertFalse(policy.isRoutable(hookedPool));

        vm.prank(OWNER);
        policy.setPoolPolicy(hookedPool, PrecisionPoolPolicy.Policy.Default);
        assertFalse(policy.isRoutable(hookedPool));

        vm.prank(OWNER);
        policy.setPoolPolicy(hookedPool, PrecisionPoolPolicy.Policy.Approved);
        assertTrue(policy.isRoutable(hookedPool));
    }

    function testOnlyOwnerCanSetPolicy() external {
        vm.prank(OUTSIDER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        policy.setPoolPolicy(hookedPool, PrecisionPoolPolicy.Policy.Approved);
    }

    function testCannotApproveUnhookedPool() external {
        vm.prank(OWNER);
        vm.expectRevert(PrecisionPoolPolicy.UnhookedPool.selector);
        policy.setPoolPolicy(unhookedPool, PrecisionPoolPolicy.Policy.Approved);
    }

    function testCannotSetPolicyForUnknownAddress() external {
        vm.prank(OWNER);
        vm.expectRevert(PrecisionPoolPolicy.NotFactoryPool.selector);
        policy.setPoolPolicy(address(0xCAFE), PrecisionPoolPolicy.Policy.Blocked);
    }

    function testOwnershipTransferChangesAuthority() external {
        vm.prank(OWNER);
        policy.transferOwnership(NEXT_OWNER);
        assertEq(policy.owner(), NEXT_OWNER);

        vm.prank(OWNER);
        vm.expectRevert(Ownable.Unauthorized.selector);
        policy.setPoolPolicy(hookedPool, PrecisionPoolPolicy.Policy.Approved);

        vm.prank(NEXT_OWNER);
        policy.setPoolPolicy(hookedPool, PrecisionPoolPolicy.Policy.Approved);
        assertTrue(policy.isRoutable(hookedPool));
    }

    function testOwnershipHandoverChangesAuthority() external {
        vm.prank(NEXT_OWNER);
        policy.requestOwnershipHandover();

        vm.prank(OWNER);
        policy.completeOwnershipHandover(NEXT_OWNER);
        assertEq(policy.owner(), NEXT_OWNER);
    }

    function testOwnershipCannotBeRenounced() external {
        vm.prank(OWNER);
        vm.expectRevert(PrecisionPoolPolicy.RenounceDisabled.selector);
        policy.renounceOwnership();
        assertEq(policy.owner(), OWNER);
    }
}
