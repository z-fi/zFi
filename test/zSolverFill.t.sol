// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSolverFill, zSolverExec} from "../src/utils/zSolverFill.sol";

contract MockERC20 {
    string public name = "Mock";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) public {
        balanceOf[to] += v;
    }

    function approve(address s, uint256 v) public returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) public virtual returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function transferFrom(address f, address t, uint256 v) public returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        balanceOf[f] -= v;
        balanceOf[t] += v;
        return true;
    }
}

/// @dev Takes 1% on every transfer, so what the adapter measures and what the
///      recipient receives are deliberately different numbers.
contract FeeToken is MockERC20 {
    function transfer(address to, uint256 v) public override returns (bool) {
        uint256 fee = v / 100;
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v - fee;
        return true;
    }
}

/// @dev An honest router: pulls the input, pays the output to whoever the
///      calldata names.
contract GoodRouter {
    function swap(address tIn, uint256 aIn, address tOut, uint256 aOut, address to) public payable {
        if (tIn != address(0)) MockERC20(tIn).transferFrom(msg.sender, address(this), aIn);
        if (tOut == address(0)) payable(to).transfer(aOut);
        else MockERC20(tOut).transfer(to, aOut);
    }
}

/// @dev Takes the input and pays nothing.
contract ThiefRouter {
    function swap(address tIn, uint256 aIn) public payable {
        if (tIn != address(0)) MockERC20(tIn).transferFrom(msg.sender, address(this), aIn);
    }
}

contract Reenterer {
    zSolverFill public fill;

    function set(zSolverFill f) public {
        fill = f;
    }

    function swap() public payable {
        fill.fill(address(1), address(1), address(0), 1, address(2), 1, address(this), "");
    }
}

/// @dev A `tokenOut` that REDUCES the recipient's balance during transfer -
///      the reflection / anti-whale shape. It is what turned an `unchecked`
///      subtraction into a bypass of the only bound this contract enforces.
contract ShrinkToken is MockERC20 {
    uint256 public constant CAP = 60 ether;

    function transfer(address to, uint256 v) public override returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        if (balanceOf[to] > CAP) balanceOf[to] /= 2;
        return true;
    }
}

/// @dev Grants an allowance on a token that has nothing to do with the fill -
///      the side effect an attacker wants out of a free arbitrary call.
contract Planter {
    function plant(address token, address to) public {
        MockERC20(token).approve(to, type(uint256).max);
    }
}

/// @dev A contract with no payable receive - the shape the ETH sweep used to
///      brick for one wei.
contract BlindCaller {
    function go(zSolverFill f, address router, address tIn, uint256 aIn, address tOut, uint256 min, bytes memory d)
        public
        returns (uint256)
    {
        MockERC20(tIn).approve(address(f), aIn);
        return f.fill(router, router, tIn, aIn, tOut, min, address(this), d);
    }
}

/// @notice The adapter's whole job is to make an untrusted solver's route safe
///         to execute. These tests are written from the attacker's side: the
///         route is hostile until proven otherwise, and the properties below
///         are the ones that have to survive that.
contract zSolverFillTest is Test {
    zSolverFill fill;
    zSolverExec exec;
    MockERC20 tokenIn;
    MockERC20 tokenOut;
    GoodRouter router;

    address user = address(0xF00D);
    address attacker = address(0xBAD);

    function setUp() public {
        fill = new zSolverFill();
        exec = zSolverExec(payable(fill.EXEC()));
        tokenIn = new MockERC20();
        tokenOut = new MockERC20();
        router = new GoodRouter();
        tokenIn.mint(user, 100 ether);
        tokenOut.mint(address(router), 1_000 ether);
        vm.deal(address(router), 100 ether);
        vm.deal(user, 100 ether);
    }

    function _route(uint256 aIn, uint256 aOut, address tOut) internal view returns (bytes memory) {
        // The route pays EXEC, which is where the page must point it.
        return abi.encodeCall(GoodRouter.swap, (address(tokenIn), aIn, tOut, aOut, address(exec)));
    }

    // ------------------------------------------------- THE HAPPY PATH

    function test_anHonestRouteFillsAndPaysTheUser() public {
        vm.startPrank(user);
        tokenIn.approve(address(fill), 1 ether);
        uint256 out = fill.fill(
            address(router),
            address(router),
            address(tokenIn),
            1 ether,
            address(tokenOut),
            3 ether,
            user,
            _route(1 ether, 3 ether, address(tokenOut))
        );
        vm.stopPrank();
        assertEq(out, 3 ether);
        assertEq(tokenOut.balanceOf(user), 3 ether);
        assertEq(tokenIn.balanceOf(user), 99 ether);
    }

    // ------------------------------------ THE HOLE THAT BROKE THE FIRST DRAFT
    //
    // The original adapter guarded `target` against tokenIn/tokenOut/itself -
    // but the caller chooses tokenIn and tokenOut, so the guard excluded
    // nothing. `tokenIn = ETH, amountIn = 0, minOut = 0` and a tokenOut whose
    // balance never moves made every check pass, the measurement compare zero
    // against zero, and the contract call anything for anyone. These are the
    // tests that exploit is now expected to fail.

    function test_theFreeArbitraryCallIsRefused() public {
        vm.prank(attacker);
        vm.expectRevert(zSolverFill.NothingToDo.selector);
        fill.fill(
            address(router),
            address(router),
            address(0), // ETH in
            0, // nothing in
            address(tokenOut),
            0, // no bound
            attacker,
            abi.encodeCall(MockERC20.transfer, (attacker, 1 ether))
        );
    }

    function test_aStandingAllowanceToTheAdapterIsNotSpendableByAnAttacker() public {
        // The user does the thing every front end teaches: an infinite approval.
        vm.prank(user);
        tokenIn.approve(address(fill), type(uint256).max);

        // The attacker tries to spend it through a funded fill, aiming the
        // route at the token itself.
        tokenIn.mint(attacker, 1 ether);
        vm.startPrank(attacker);
        tokenIn.approve(address(fill), 1 ether);
        vm.expectRevert(zSolverFill.BadTarget.selector);
        fill.fill(
            address(tokenIn), // the asset is not a router
            address(tokenIn),
            address(tokenIn),
            1 ether,
            address(tokenOut),
            1,
            attacker,
            abi.encodeCall(MockERC20.transferFrom, (user, attacker, 100 ether))
        );
        vm.stopPrank();
        assertEq(tokenIn.balanceOf(user), 100 ether, "the standing allowance was spent");
    }

    function test_theExecutorHoldsNoAllowanceAnAttackerCanPlant() public {
        // Even reaching EXEC's arbitrary call - which a funded fill can still
        // do - reaches a contract nobody has approved and which holds nothing.
        assertEq(tokenIn.allowance(address(exec), attacker), 0);
        assertEq(tokenIn.balanceOf(address(exec)), 0);
        assertEq(tokenOut.balanceOf(address(exec)), 0);
        assertEq(address(exec).balance, 0);
    }

    function test_nobodyButTheAdapterCanDriveTheExecutor() public {
        vm.prank(attacker);
        vm.expectRevert(zSolverExec.NotFill.selector);
        exec.run(
            address(tokenIn),
            address(tokenIn),
            address(tokenIn),
            0,
            address(tokenOut),
            abi.encodeCall(MockERC20.transfer, (attacker, 1 ether))
        );
    }

    // ------------------------------------------------------- THE BOUND

    function test_aRouteThatKeepsTheOutputReverts() public {
        ThiefRouter thief = new ThiefRouter();
        vm.startPrank(user);
        tokenIn.approve(address(fill), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(zSolverFill.Insufficient.selector, 0, 3 ether));
        fill.fill(
            address(thief),
            address(thief),
            address(tokenIn),
            1 ether,
            address(tokenOut),
            3 ether,
            user,
            abi.encodeCall(ThiefRouter.swap, (address(tokenIn), 1 ether))
        );
        vm.stopPrank();
        assertEq(tokenIn.balanceOf(user), 100 ether, "the user lost their input to a failed fill");
    }

    function test_aRouteThatUnderdeliversReverts() public {
        vm.startPrank(user);
        tokenIn.approve(address(fill), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(zSolverFill.Insufficient.selector, 2 ether, 3 ether));
        fill.fill(
            address(router),
            address(router),
            address(tokenIn),
            1 ether,
            address(tokenOut),
            3 ether,
            user,
            _route(1 ether, 2 ether, address(tokenOut))
        );
        vm.stopPrank();
    }

    function test_aRouteThatPaysTheUserDirectlyMeasuresNothingAndReverts() public {
        // A safe failure, and a loud one: the delta must be measured somewhere
        // an unrelated inbound transfer cannot forge it.
        bytes memory direct = abi.encodeCall(GoodRouter.swap, (address(tokenIn), 1 ether, address(tokenOut), 3 ether, user));
        vm.startPrank(user);
        tokenIn.approve(address(fill), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(zSolverFill.Insufficient.selector, 0, 3 ether));
        fill.fill(
            address(router), address(router), address(tokenIn), 1 ether, address(tokenOut), 3 ether, user, direct
        );
        vm.stopPrank();
    }

    /// The bound is what the RECIPIENT receives, not what the adapter caught.
    /// For a fee-on-transfer output those are different numbers, and it is the
    /// first one people are relying on.
    function test_theBoundIsCheckedAtTheRecipientNotTheAdapter() public {
        FeeToken fee = new FeeToken();
        fee.mint(address(router), 1_000 ether);
        vm.startPrank(user);
        tokenIn.approve(address(fill), 1 ether);
        // The adapter catches 3 ether (minus the router's fee leg); the user
        // receives 1% less again, so a bound of exactly 3 ether must fail.
        vm.expectRevert();
        fill.fill(
            address(router),
            address(router),
            address(tokenIn),
            1 ether,
            address(fee),
            3 ether,
            user,
            _route(1 ether, 3 ether, address(fee))
        );
        vm.stopPrank();
    }

    // ------------------------- THE SECOND HOLE, FOUND AFTER THE FIRST FIX
    //
    // The split fixed the ALLOWANCE half of the original flaw. It did not fix
    // the free-arbitrary-call half: `run` swept EXEC's whole tokenOut balance,
    // so one wei planted there in an earlier transaction read as a complete
    // fill. `amountIn = 1, minOut = 1` cleared every guard, the route did
    // nothing, and the input came back as dust - net cost, gas.

    function test_aPlantedBalanceAtTheExecutorIsNotCreditedToAFill() public {
        tokenOut.mint(address(exec), 1); // the plant, one wei, anyone can do it
        tokenIn.mint(attacker, 1);

        vm.startPrank(attacker);
        tokenIn.approve(address(fill), 1);
        vm.expectRevert(abi.encodeWithSelector(zSolverFill.Insufficient.selector, 0, 1));
        fill.fill(
            address(0xDEAD), // an EOA: no code, the call trivially "succeeds"
            address(0xDEAD),
            address(tokenIn),
            1,
            address(tokenOut),
            1,
            attacker,
            ""
        );
        vm.stopPrank();
    }

    function test_theFreeArbitraryCallCannotCommitItsSideEffects() public {
        // The side effect is the point: a fill that succeeds commits whatever
        // the arbitrary call did. It must not succeed on a planted balance.
        Planter planter = new Planter();
        tokenOut.mint(address(exec), 1);
        tokenIn.mint(attacker, 1);

        vm.startPrank(attacker);
        tokenIn.approve(address(fill), 1);
        vm.expectRevert();
        fill.fill(
            address(planter),
            address(planter),
            address(tokenIn),
            1,
            address(tokenOut),
            1,
            attacker,
            abi.encodeCall(Planter.plant, (address(tokenOut), attacker))
        );
        vm.stopPrank();
        assertEq(tokenOut.allowance(address(exec), attacker), 0, "an allowance was planted from the executor");
    }

    function test_aShrinkingRecipientCannotUnderflowPastTheBound() public {
        // `unchecked` made this wrap to ~2**256 and clear any bound while the
        // recipient ended the call POORER. Checked arithmetic reverts instead.
        ShrinkToken shrink = new ShrinkToken();
        shrink.mint(address(router), 1_000 ether);
        shrink.mint(user, 100 ether); // already above the token's cap

        vm.startPrank(user);
        tokenIn.approve(address(fill), 1 ether);
        vm.expectRevert();
        fill.fill(
            address(router),
            address(router),
            address(tokenIn),
            1 ether,
            address(shrink),
            50 ether,
            user,
            _route(1 ether, 3 ether, address(shrink))
        );
        vm.stopPrank();
        assertEq(shrink.balanceOf(user), 100 ether, "the user was left poorer by a fill that reported success");
    }

    function test_theMeasurementEndpointsCannotBeTheRecipient() public {
        vm.startPrank(user);
        tokenIn.approve(address(fill), 1 ether);
        bytes memory d = _route(1 ether, 3 ether, address(tokenOut));
        vm.expectRevert(zSolverFill.BadTarget.selector);
        fill.fill(address(router), address(router), address(tokenIn), 1 ether, address(tokenOut), 1, address(exec), d);
        vm.expectRevert(zSolverFill.BadTarget.selector);
        fill.fill(address(router), address(router), address(tokenIn), 1 ether, address(tokenOut), 1, address(fill), d);
        vm.expectRevert(zSolverFill.BadTarget.selector);
        fill.fill(address(router), address(router), address(tokenIn), 1 ether, address(tokenOut), 1, address(0), d);
        vm.stopPrank();
    }

    // ------------------------------------------------------ THE GUARDS

    function test_theSameTokenBothSidesIsRefused() public {
        vm.prank(user);
        vm.expectRevert(zSolverFill.SameToken.selector);
        fill.fill(
            address(router), address(router), address(tokenIn), 1 ether, address(tokenIn), 1, user, ""
        );
    }

    function test_mismatchedValueIsRefused() public {
        vm.deal(user, 10 ether);
        vm.prank(user);
        vm.expectRevert(zSolverFill.BadValue.selector);
        fill.fill{value: 1 ether}(
            address(router), address(router), address(tokenIn), 1 ether, address(tokenOut), 1, user, ""
        );
    }

    function test_reentrancyIsRefused() public {
        Reenterer r = new Reenterer();
        r.set(fill);
        vm.startPrank(user);
        tokenIn.approve(address(fill), 1 ether);
        vm.expectRevert();
        fill.fill(
            address(r),
            address(r),
            address(tokenIn),
            1 ether,
            address(tokenOut),
            1,
            user,
            abi.encodeCall(Reenterer.swap, ())
        );
        vm.stopPrank();
    }

    // --------------------------------------------- THE ONE-WEI BRICK
    //
    // The ETH refund used to be a plain transfer to msg.sender, so any
    // integrator without a payable receive was one stray wei away from every
    // fill reverting, permanently, at an attacker's cost of one wei.

    function test_aDonatedWeiCannotBrickAContractIntegrator() public {
        BlindCaller caller = new BlindCaller();
        tokenIn.mint(address(caller), 10 ether);

        uint256 pre = address(fill).balance;
        payable(address(fill)).transfer(1 wei); // the grief
        assertEq(address(fill).balance, pre + 1 wei, "the donation did not land");

        uint256 out = caller.go(
            fill,
            address(router),
            address(tokenIn),
            1 ether,
            address(tokenOut),
            3 ether,
            _route(1 ether, 3 ether, address(tokenOut))
        );
        assertEq(out, 3 ether, "a contract without a payable receive could not fill");
    }

    // ------------------------------------------------------ ETH PATHS

    function test_anEthInputFills() public {
        bytes memory data =
            abi.encodeCall(GoodRouter.swap, (address(0), 1 ether, address(tokenOut), 3 ether, address(exec)));
        vm.prank(user);
        uint256 out = fill.fill{value: 1 ether}(
            address(router), address(router), address(0), 1 ether, address(tokenOut), 3 ether, user, data
        );
        assertEq(out, 3 ether);
    }

    function test_anEthOutputFills() public {
        bytes memory data =
            abi.encodeCall(GoodRouter.swap, (address(tokenIn), 1 ether, address(0), 2 ether, address(exec)));
        uint256 before = user.balance;
        vm.startPrank(user);
        tokenIn.approve(address(fill), 1 ether);
        uint256 out =
            fill.fill(address(router), address(router), address(tokenIn), 1 ether, address(0), 2 ether, user, data);
        vm.stopPrank();
        assertEq(out, 2 ether);
        assertEq(user.balance - before, 2 ether, "the ETH output was swept instead of paid");
    }
}
