// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev Balances that move on their own, in either direction. A rebase is not
/// a transfer, so nothing the pool does is involved in the change - which is
/// exactly why it cannot be accounted for.
contract RebasingERC20 is MockERC20("REBASE", 18) {
    function rebaseDown(address holder, uint256 amount) external {
        balanceOf[holder] -= amount;
    }

    function rebaseUp(address holder, uint256 amount) external {
        balanceOf[holder] += amount;
    }
}

/// @dev Freezes an address after it is already holding or owed the token.
contract BlacklistERC20 is MockERC20("BLOCK", 18) {
    mapping(address => bool) public blocked;

    function block_(address who) external {
        blocked[who] = true;
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        require(!blocked[msg.sender] && !blocked[to], "blocked");
        return super.transfer(to, amt);
    }

    function transferFrom(address f, address t, uint256 amt) public override returns (bool) {
        require(!blocked[f] && !blocked[t], "blocked");
        return super.transferFrom(f, t, amt);
    }
}

/// @dev ERC-777-shaped: hands control to a recipient mid-transfer. The callback
/// swallows its own failure so the OUTER call still completes - otherwise a
/// reverting reentrancy would be indistinguishable from a token that simply
/// broke the swap.
contract CallbackERC20 is MockERC20("HOOKED", 18) {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public succeeded;

    function arm(address target_, bytes calldata payload_) external {
        (target, payload) = (target_, payload_);
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        bool ok = super.transfer(to, amt);
        if (target != address(0)) {
            attempted = true;
            (succeeded,) = target.call(payload);
        }
        return ok;
    }
}

/// @dev Reports success while delivering less than it was asked to move.
contract ShortPayERC20 is MockERC20("SHORT", 18) {
    bool public shorting;

    function startShorting() external {
        shorting = true;
    }

    function transfer(address to, uint256 amt) public override returns (bool) {
        uint256 sent = shorting ? amt - 1 : amt;
        balanceOf[msg.sender] -= sent;
        balanceOf[to] += sent;
        return true;
    }

    /// @dev Shorts the pull side too, so the pool is tested on the way in as
    /// well as on the way out. Both directions are opt-in after seeding.
    function transferFrom(address f, address t, uint256 amt) public override returns (bool) {
        uint256 sent = shorting ? amt - 1 : amt;
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= sent;
        balanceOf[t] += sent;
        return true;
    }
}

/// @dev The pool supports exact-transfer, non-rebasing ERC-20s and nothing
/// else. That claim was previously carried by argument - the balance-delta
/// checks look right - rather than by evidence. These pin what each hostile
/// class actually does to a funded pool, including the cases where the honest
/// answer is "the pool stops working", because a token that can freeze or
/// shrink its holders' balances can always do that and the pool's job is to
/// refuse rather than to mis-account.
contract PrecisionPoolHostileTokensTest is Test {
    PrecisionPoolFactory factory;

    address lp = address(0xC11);
    address trader = address(0x22);

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
    }

    /// @dev Seed a pool over `hostile` and a plain counterpart, whichever way
    /// the addresses happen to sort.
    function _seed(address hostile)
        internal
        returns (PrecisionPool pool, address token0, address token1, MockERC20 plain)
    {
        plain = new MockERC20("PLAIN", 18);
        (token0, token1) = hostile < address(plain) ? (hostile, address(plain)) : (address(plain), hostile);

        MockERC20(token0).mint(lp, 1e30);
        MockERC20(token1).mint(lp, 1e30);
        MockERC20(token0).mint(trader, 1e30);
        MockERC20(token1).mint(trader, 1e30);

        vm.startPrank(lp);
        MockERC20(token0).approve(address(factory), type(uint256).max);
        MockERC20(token1).approve(address(factory), type(uint256).max);
        (address p,,,) = factory.createAndSeed(
            PrecisionPoolFactory.Market({
                token0: token0,
                token1: token1,
                sqrtPLow: 1e18,
                sqrtPHigh: 3e18,
                fee: 3000,
                hook: address(0),
                feeRecipient: address(0),
                creatorFeeBps: 0
            }),
            2e18,
            1e24,
            1e24,
            0,
            lp
        );
        vm.stopPrank();
        pool = PrecisionPool(payable(p));
    }

    function _swap(PrecisionPool pool, address tokenIn, uint256 amount, address to) internal {
        vm.startPrank(trader);
        MockERC20(tokenIn).approve(address(pool), type(uint256).max);
        pool.swapExactIn(tokenIn, amount, 0, to);
        vm.stopPrank();
    }

    // ------------------------------------------------------------- REBASE

    /// @dev A negative rebase takes tokens the reserves still claim. Every
    /// value-moving path must refuse rather than pay out against a balance
    /// that is no longer there, and the refusal must name the real cause.
    function test_NegativeRebaseIsCaughtAsBalanceDeficit() public {
        RebasingERC20 hostile = new RebasingERC20();
        (PrecisionPool pool, address token0, address token1,) = _seed(address(hostile));

        hostile.rebaseDown(address(pool), 1e23);

        vm.startPrank(trader);
        MockERC20(token0).approve(address(pool), type(uint256).max);
        MockERC20(token1).approve(address(pool), type(uint256).max);
        vm.expectRevert(PrecisionPool.BalanceDeficit.selector);
        pool.swapExactIn(token0, 1e18, 0, trader);
        vm.expectRevert(PrecisionPool.BalanceDeficit.selector);
        pool.swapExactIn(token1, 1e18, 0, trader);
        vm.stopPrank();
    }

    /// @dev And the consequence integrators actually have to plan for: the exit
    /// is blocked too. There is no accounting trick that makes a pool solvent
    /// after its assets were taken from underneath it, so this is documented
    /// rather than defended against - it is why negative-rebasing tokens are
    /// outside the supported set instead of merely discouraged.
    function test_NegativeRebaseAlsoBlocksWithdrawal() public {
        RebasingERC20 hostile = new RebasingERC20();
        (PrecisionPool pool,,,) = _seed(address(hostile));

        uint256 shares = pool.balanceOf(lp);
        hostile.rebaseDown(address(pool), 1e23);

        vm.prank(lp);
        vm.expectRevert(PrecisionPool.BalanceDeficit.selector);
        pool.removeLiquidity(shares / 2, 0, 0, lp);
    }

    /// @dev A positive rebase is a donation, and donations are never credited
    /// to whoever shows up next. The reserves ignore it, so it cannot be swept
    /// by a swap or claimed by a deposit.
    function test_PositiveRebaseIsNotCreditedToTheNextCaller() public {
        RebasingERC20 hostile = new RebasingERC20();
        (PrecisionPool pool, address token0, address token1, MockERC20 plain) = _seed(address(hostile));

        (uint128 r0Before, uint128 r1Before) = (pool.reserve0(), pool.reserve1());
        hostile.rebaseUp(address(pool), 5e23);

        // Reserves are storage, not balances, so nothing moved.
        assertEq(pool.reserve0(), r0Before, "reserve0 absorbed a donation");
        assertEq(pool.reserve1(), r1Before, "reserve1 absorbed a donation");

        // And a swap prices against the reserves, so the surplus is not paid out.
        address inToken = address(hostile) == token0 ? token1 : token0;
        uint256 before = hostile.balanceOf(trader);
        _swap(pool, inToken, 1e18, trader);
        uint256 got = hostile.balanceOf(trader) - before;
        assertGt(got, 0, "swap delivered nothing");
        assertLt(got, 5e23, "swap paid out the donated surplus");
        plain;
    }

    // ---------------------------------------------------------- BLACKLIST

    /// @dev Freezing the POOL after it is funded strands the position. The pool
    /// cannot pay what the token will not move, so it reverts instead of
    /// updating reserves against a transfer that did not happen.
    function test_BlacklistedPoolCannotPayOutAndNothingIsMisAccounted() public {
        BlacklistERC20 hostile = new BlacklistERC20();
        (PrecisionPool pool, address token0, address token1,) = _seed(address(hostile));

        (uint128 r0, uint128 r1) = (pool.reserve0(), pool.reserve1());
        hostile.block_(address(pool));

        address inToken = address(hostile) == token0 ? token1 : token0;
        vm.startPrank(trader);
        MockERC20(inToken).approve(address(pool), type(uint256).max);
        vm.expectRevert();
        pool.swapExactIn(inToken, 1e18, 0, trader);
        vm.stopPrank();

        assertEq(pool.reserve0(), r0, "reserve0 moved on a failed payout");
        assertEq(pool.reserve1(), r1, "reserve1 moved on a failed payout");
    }

    /// @dev Freezing only the RECIPIENT fails that one swap and leaves the pool
    /// entirely usable for everyone else.
    function test_BlacklistedRecipientDoesNotBreakThePool() public {
        BlacklistERC20 hostile = new BlacklistERC20();
        (PrecisionPool pool, address token0, address token1,) = _seed(address(hostile));

        address pariah = address(0xDEAD);
        hostile.block_(pariah);
        address inToken = address(hostile) == token0 ? token1 : token0;

        vm.startPrank(trader);
        MockERC20(inToken).approve(address(pool), type(uint256).max);
        vm.expectRevert();
        pool.swapExactIn(inToken, 1e18, 0, pariah);
        vm.stopPrank();

        // Same trade, ordinary recipient.
        _swap(pool, inToken, 1e18, trader);
        assertGt(hostile.balanceOf(trader), 0, "pool was left unusable");
    }

    // ----------------------------------------------------------- CALLBACK

    /// @dev The ERC-777 case. Payout hands control to the token, which is
    /// inside the pool's guard, so a reentrant swap is refused. The outer swap
    /// still settles - the guard rejects the nested call, it does not poison
    /// the transaction.
    function test_TokenCallbackDuringPayoutCannotReenter() public {
        CallbackERC20 hostile = new CallbackERC20();
        (PrecisionPool pool, address token0, address token1,) = _seed(address(hostile));

        address inToken = address(hostile) == token0 ? token1 : token0;
        hostile.arm(
            address(pool),
            abi.encodeCall(PrecisionPool.swapExactIn, (inToken, 1e18, 0, address(hostile)))
        );

        _swap(pool, inToken, 1e18, trader);

        assertTrue(hostile.attempted(), "payout did not reach the callback");
        assertFalse(hostile.succeeded(), "a reentrant swap got through");
    }

    /// @dev The same callback aimed at the exit path, which moves both sides.
    function test_TokenCallbackDuringBurnCannotReenter() public {
        CallbackERC20 hostile = new CallbackERC20();
        (PrecisionPool pool,,,) = _seed(address(hostile));

        uint256 shares = pool.balanceOf(lp);
        hostile.arm(address(pool), abi.encodeCall(PrecisionPool.removeLiquidity, (1, 0, 0, address(hostile))));

        vm.prank(lp);
        pool.removeLiquidity(shares / 2, 0, 0, lp);

        assertTrue(hostile.attempted(), "burn did not reach the callback");
        assertFalse(hostile.succeeded(), "a reentrant burn got through");
    }

    // ---------------------------------------------------------- SHORT PAY

    /// @dev A token that reports success while delivering less is the case the
    /// balance-delta check on the PAYOUT side exists for: the swap is undone
    /// rather than settled against a delivery that never arrived.
    function test_ShortPayingTokenIsRejectedOnPayout() public {
        ShortPayERC20 hostile = new ShortPayERC20();
        (PrecisionPool pool, address token0, address token1,) = _seed(address(hostile));

        (uint128 r0, uint128 r1) = (pool.reserve0(), pool.reserve1());
        hostile.startShorting();

        address inToken = address(hostile) == token0 ? token1 : token0;
        vm.startPrank(trader);
        MockERC20(inToken).approve(address(pool), type(uint256).max);
        vm.expectRevert(PrecisionPool.UnsupportedToken.selector);
        pool.swapExactIn(inToken, 1e18, 0, trader);
        vm.stopPrank();

        assertEq(pool.reserve0(), r0, "reserve0 settled against a short payment");
        assertEq(pool.reserve1(), r1, "reserve1 settled against a short payment");
    }

    /// @dev And on the way in: a short-paying pull is refused before anything
    /// is credited, so the pool never prices an input it did not receive.
    function test_ShortPayingTokenIsRejectedOnPull() public {
        ShortPayERC20 hostile = new ShortPayERC20();
        (PrecisionPool pool, address token0, address token1,) = _seed(address(hostile));

        hostile.startShorting();
        address inToken = address(hostile) == token0 ? token0 : token1;
        assertEq(inToken, address(hostile), "test must push the hostile side in");

        vm.startPrank(trader);
        MockERC20(inToken).approve(address(pool), type(uint256).max);
        vm.expectRevert(PrecisionPool.UnsupportedToken.selector);
        pool.swapExactIn(inToken, 1e18, 0, trader);
        vm.stopPrank();
    }
}
