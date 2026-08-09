// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {V4Port, PoolKey} from "../src/forwarders/V4Port.sol";
import {Fwabol as FwabolV2} from "../src/forwarders/FwabolV2.sol";
import {V4QuoteLens} from "../src/V4QuoteLens.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice V4Port against real pools - the hooked one and an ordinary one.
///
/// The claim is that nothing here is FWA-specific. The way to show that is to
/// route the same contract through a pool that has no hook at all and get the
/// same guarantees, so both are exercised side by side below.
contract V4PortTest is Test {
    address constant PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant FWA = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address constant HOOK = 0x2C67ebA8A50AF0dB5Fba55F725247a75CbDA6444;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    V4Port port;
    V4QuoteLens lens;
    address user = makeAddr("user");

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com"));
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);

        port = new V4Port();
        vm.etch(makeAddr("port"), address(port).code);
        port = V4Port(payable(makeAddr("port")));
        assertEq(address(port).balance, 0, "the port starts empty");

        lens = new V4QuoteLens();
        vm.deal(user, 100 ether);
    }

    function _fwaKey() internal pure returns (PoolKey memory) {
        return PoolKey(address(0), FWA, 0, 60, HOOK);
    }

    function _buyFwa(uint256 amount) internal returns (uint256) {
        vm.prank(user);
        return port.swap{value: amount}(_fwaKey(), true, amount, 1, user, block.timestamp + 300);
    }

    // ---- the hooked pool -------------------------------------------------

    function test_buysThroughTheHookedPool() public {
        uint256 before = IERC20(FWA).balanceOf(user);
        uint256 out = _buyFwa(0.01 ether);

        assertGt(out, 0, "bought");
        assertEq(IERC20(FWA).balanceOf(user) - before, out, "and the user has it");
        assertEq(IERC20(FWA).balanceOf(address(port)), 0, "the port holds no FWA");
        assertEq(address(port).balance, 0, "and no ETH");
    }

    /// A restricted token can be sold because the seller pays the PoolManager
    /// in one hop. This is the property the whole design turns on.
    function test_sellsARestrictedTokenWithoutHoldingIt() public {
        uint256 held = _buyFwa(0.05 ether);

        vm.startPrank(user);
        IERC20(FWA).approve(address(port), type(uint256).max);
        uint256 ethBefore = user.balance;
        uint256 back = port.swap(_fwaKey(), false, held, 1, user, block.timestamp + 300);
        vm.stopPrank();

        assertGt(back, 0, "sold");
        assertEq(user.balance - ethBefore, back, "straight to the seller");
        assertEq(IERC20(FWA).balanceOf(user), 0, "the whole position went");
        assertEq(IERC20(FWA).balanceOf(address(port)), 0, "the port never held it");
    }

    /// The generic contract must not be worse than the specialised one. Same
    /// pool, same block, same amount - the outputs have to be identical, or
    /// one of them is doing something the other is not.
    function test_matchesFwabolWeiForWeiOnTheHookedPool() public {
        FwabolV2 fw = new FwabolV2();

        uint256 snap = vm.snapshotState();
        uint256 viaPort = _buyFwa(0.02 ether);
        vm.revertToState(snap);

        vm.prank(user);
        uint256 viaFwabol = fw.buy{value: 0.02 ether}(user, 1, block.timestamp + 300);

        assertEq(viaPort, viaFwabol, "the general route prices exactly like the specialised one");
    }

    // ---- an ordinary, hookless pool --------------------------------------

    /// Nothing here is about FWA. The same call, through a pool with no hook,
    /// behaves the same way - which is what makes this a venue rather than an
    /// adapter for one token.
    function test_worksOnAPoolWithNoHookAtAll() public {
        // ETH/USDC 0.05%, the deepest hookless v4 pool on mainnet.
        PoolKey memory key = PoolKey(address(0), USDC, 500, 10, address(0));
        (, uint256 quoted) = lens.quoteV4Hooked(false, address(0), USDC, 500, 10, address(0), 0.1 ether);
        vm.assume(quoted > 0);

        uint256 before = IERC20(USDC).balanceOf(user);
        vm.prank(user);
        uint256 out = port.swap{value: 0.1 ether}(key, true, 0.1 ether, quoted, user, block.timestamp + 300);

        assertEq(out, quoted, "quote == delivery on an unhooked pool too");
        assertEq(IERC20(USDC).balanceOf(user) - before, out, "the user was paid");
        assertEq(address(port).balance, 0, "nothing rests in the port");
        emit log_named_uint("USDC for 0.1 ETH", out);
    }

    /// And back the other way, an ERC20 input on an ordinary pool.
    function test_sellsAnOrdinaryErc20() public {
        PoolKey memory key = PoolKey(address(0), USDC, 500, 10, address(0));
        deal(USDC, user, 10_000e6);

        vm.startPrank(user);
        IERC20(USDC).approve(address(port), type(uint256).max);
        uint256 ethBefore = user.balance;
        uint256 out = port.swap(key, false, 1_000e6, 1, user, block.timestamp + 300);
        vm.stopPrank();

        assertGt(out, 0, "sold USDC for ETH");
        assertEq(user.balance - ethBefore, out, "paid to the seller");
        assertEq(IERC20(USDC).balanceOf(address(port)), 0, "no USDC rests in the port");
        assertEq(address(port).balance, 0, "no ETH either");
    }

    // ---- guards ----------------------------------------------------------

    /// The invariant that makes an arbitrary PoolKey safe: the input comes from
    /// `msg.sender` and nowhere else, so an allowance to this contract is not a
    /// standing option a stranger can exercise.
    function test_anApprovalCannotBeExercisedByAThirdParty() public {
        uint256 held = _buyFwa(0.05 ether);
        vm.prank(user);
        IERC20(FWA).approve(address(port), type(uint256).max);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        port.swap(_fwaKey(), false, held, 1, attacker, block.timestamp + 300);

        assertEq(IERC20(FWA).balanceOf(user), held, "the victim's position is intact");
    }

    /// Native input must be exactly `msg.value` - neither a silent leftover nor
    /// a chance to spend a previous caller's dust.
    function test_nativeInputMustMatchTheValueSent() public {
        vm.startPrank(user);
        vm.expectRevert(V4Port.ValueMismatch.selector);
        port.swap{value: 1 ether}(_fwaKey(), true, 0.5 ether, 1, user, block.timestamp + 300);

        // And ETH may not be attached when the input is an ERC20.
        vm.expectRevert(V4Port.ValueMismatch.selector);
        port.swap{value: 1 ether}(_fwaKey(), false, 1e18, 1, user, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_floorIsEnforcedAgainstTheActualDelta() public {
        V4QuoteLens l = lens;
        (, uint256 quoted) = l.quoteV4Hooked(false, address(0), FWA, 0, 60, HOOK, 0.01 ether);

        vm.prank(user);
        vm.expectRevert();
        port.swap{value: 0.01 ether}(_fwaKey(), true, 0.01 ether, quoted + 1, user, block.timestamp + 300);

        assertEq(_buyFwa(0.01 ether) >= quoted, true, "the exact floor clears");
    }

    function test_guardsOnRecipientDeadlineAndAmount() public {
        vm.startPrank(user);
        vm.expectRevert(V4Port.Deadline.selector);
        port.swap{value: 1e15}(_fwaKey(), true, 1e15, 1, user, block.timestamp - 1);
        vm.expectRevert(V4Port.BadRecipient.selector);
        port.swap{value: 1e15}(_fwaKey(), true, 1e15, 1, address(0), block.timestamp + 300);
        vm.expectRevert(V4Port.BadRecipient.selector);
        port.swap{value: 1e15}(_fwaKey(), true, 1e15, 1, address(port), block.timestamp + 300);
        vm.expectRevert(V4Port.NothingIn.selector);
        port.swap(_fwaKey(), true, 0, 1, user, block.timestamp + 300);
        vm.stopPrank();
    }

    function test_unlockCallbackIsPoolManagerOnly() public {
        vm.prank(user);
        vm.expectRevert(V4Port.NotPoolManager.selector);
        port.unlockCallback(abi.encode(_fwaKey(), true, uint256(1e15), uint256(0), user, user));
    }

    /// A pool that does not exist must revert rather than half-execute.
    function test_anUnknownPoolReverts() public {
        PoolKey memory bogus = PoolKey(address(0), USDC, 3000, 60, address(0x1234));
        vm.prank(user);
        vm.expectRevert();
        port.swap{value: 1e15}(bogus, true, 1e15, 1, user, block.timestamp + 300);
        assertEq(address(port).balance, 0, "and leaves nothing behind");
    }

    function testFuzz_portNeverAccumulates(uint96 amountIn) public {
        amountIn = uint96(bound(amountIn, 1e12, 5 ether));
        vm.deal(user, uint256(amountIn) + 10 ether);

        vm.prank(user);
        try port.swap{value: amountIn}(_fwaKey(), true, amountIn, 1, user, block.timestamp + 300)
        returns (uint256 got) {
            vm.startPrank(user);
            IERC20(FWA).approve(address(port), type(uint256).max);
            try port.swap(_fwaKey(), false, got, 1, user, block.timestamp + 300) {} catch {}
            vm.stopPrank();
        } catch {}

        assertEq(IERC20(FWA).balanceOf(address(port)), 0, "no token ever rests here");
        assertEq(address(port).balance, 0, "no ETH ever rests here");
    }
}
