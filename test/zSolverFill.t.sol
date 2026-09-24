// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSolverFill} from "../src/utils/zSolverFill.sol";

interface IzRouter {
    function snwap(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) external payable returns (uint256 amountOut);
}

contract MockERC20 {
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

/// @dev Takes 1% on every transfer.
contract FeeToken is MockERC20 {
    function transfer(address to, uint256 v) public override returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v - v / 100;
        return true;
    }
}

/// @dev Pulls `aIn` of the input from the caller and pays `aOut` to `to`.
contract Router {
    function swap(address tIn, uint256 aIn, address tOut, uint256 aOut, address to) public payable {
        if (tIn != address(0)) MockERC20(tIn).transferFrom(msg.sender, address(this), aIn);
        if (tOut == address(0)) payable(to).transfer(aOut);
        else MockERC20(tOut).transfer(to, aOut);
    }

    /// @dev Takes the input and pays nothing.
    function take(address tIn, uint256 aIn) public payable {
        if (tIn != address(0)) MockERC20(tIn).transferFrom(msg.sender, address(this), aIn);
    }

    /// @dev Plants one unit of `tOut` into `fill` during the route.
    function plant(address tOut, address fill) public {
        MockERC20(tOut).transfer(fill, 1);
    }

    function bomb() public pure {
        assembly ("memory-safe") {
            revert(0x00, 0x10000)
        }
    }

    receive() external payable {}
}

contract Reenterer {
    function swap(zSolverFill f, address tIn, address tOut) public {
        f.fill(address(1), address(1), tIn, tOut, address(this), address(this), "");
    }
}

contract zSolverFillTest is Test {
    IzRouter constant ROUTER = IzRouter(0x000000000000FB114709235f1ccBFfb925F600e4);

    zSolverFill fill;
    Router router;
    MockERC20 tIn;
    MockERC20 tOut;
    address user = address(0xA11CE);
    address payee = address(0xB0B);

    event Filled(
        address indexed target,
        address indexed tokenIn,
        address indexed tokenOut,
        address to,
        uint256 spent,
        uint256 amountOut
    );

    function setUp() public {
        fill = new zSolverFill();
        vm.deal(address(fill), 0);
        router = new Router();
        tIn = new MockERC20();
        tOut = new MockERC20();
        tIn.mint(user, 100 ether);
        tOut.mint(address(router), 1_000 ether);
        vm.deal(address(router), 100 ether);
        vm.deal(user, 100 ether);
        vm.prank(user);
        tIn.approve(address(ROUTER), type(uint256).max);
    }

    function _data(address target, address spender, address a, address b, address to, bytes memory d)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodeCall(zSolverFill.fill, (target, spender, a, b, to, user, d));
    }

    function _swap(address a, uint256 aIn, address b, uint256 aOut) internal view returns (bytes memory) {
        return abi.encodeCall(Router.swap, (a, aIn, b, aOut, address(fill)));
    }

    function _snwap(address a, uint256 aIn, address b, uint256 min, bytes memory route, uint256 value)
        internal
        returns (uint256)
    {
        vm.prank(user);
        return ROUTER.snwap{value: value}(
            a, aIn, payee, b, min, address(fill), _data(address(router), address(router), a, b, payee, route)
        );
    }

    function _assertEmpty() internal view {
        assertEq(tIn.balanceOf(address(fill)), 0, "input left in fill");
        assertEq(tOut.balanceOf(address(fill)), 0, "output left in fill");
        assertEq(address(fill).balance, 0, "ether left in fill");
        assertEq(tIn.allowance(address(fill), address(router)), 0, "approval left standing");
    }

    function test_TokenToToken() public {
        uint256 out = _snwap(address(tIn), 10 ether, address(tOut), 25 ether, _swap(address(tIn), 10 ether, address(tOut), 30 ether), 0);
        assertEq(out, 30 ether);
        assertEq(tOut.balanceOf(payee), 30 ether);
        assertEq(tIn.balanceOf(user), 90 ether);
        _assertEmpty();
    }

    function test_UnspentInputRefunded() public {
        vm.expectEmit(true, true, true, true, address(fill));
        emit Filled(address(router), address(tIn), address(tOut), payee, 4 ether, 30 ether);
        _snwap(address(tIn), 10 ether, address(tOut), 1, _swap(address(tIn), 4 ether, address(tOut), 30 ether), 0);
        assertEq(tIn.balanceOf(user), 96 ether, "unspent input returns to refundTo");
        _assertEmpty();
    }

    function test_EthToToken() public {
        _snwap(address(0), 1 ether, address(tOut), 3 ether, _swap(address(0), 0, address(tOut), 3 ether), 1 ether);
        assertEq(tOut.balanceOf(payee), 3 ether);
        _assertEmpty();
    }

    function test_EthChangeRefunded() public {
        // The route keeps 0.4 ETH and bounces 0.6 back to the fill.
        vm.prank(user);
        ROUTER.snwap{value: 1 ether}(address(0), 0, payee, address(tOut), 0, address(fill), abi.encodeCall(
            zSolverFill.fill, (address(this), address(this), address(0), address(tOut), payee, user, abi.encodeCall(this.bounce, (address(fill))))
        ));
        assertEq(user.balance, 99.6 ether, "unspent ether returns to refundTo");
        assertEq(tOut.balanceOf(payee), 1 ether);
        _assertEmpty();
    }

    function bounce(address f) public payable {
        tOut.mint(f, 1 ether);
        payable(f).transfer(0.6 ether);
    }

    function test_TokenToEth() public {
        _snwap(address(tIn), 10 ether, address(0), 2 ether, _swap(address(tIn), 10 ether, address(0), 2 ether), 0);
        assertEq(payee.balance, 2 ether);
        _assertEmpty();
    }

    function test_StandingEtherIsNotOutput() public {
        vm.deal(address(fill), 5 ether);
        bytes memory route = abi.encodeCall(Router.take, (address(tIn), 10 ether));
        vm.expectRevert(zSolverFill.NoOutput.selector);
        _snwap(address(tIn), 10 ether, address(0), 1, route, 0);
        _snwap(address(tIn), 10 ether, address(0), 2 ether, _swap(address(tIn), 10 ether, address(0), 2 ether), 0);
        assertEq(payee.balance, 2 ether, "only the route's ether is output");
        assertEq(address(fill).balance, 5 ether);
    }

    function test_ShortRouteRevertsAtTheRouter() public {
        bytes memory route = _swap(address(tIn), 10 ether, address(tOut), 20 ether);
        vm.expectRevert();
        _snwap(address(tIn), 10 ether, address(tOut), 25 ether, route, 0);
        assertEq(tIn.balanceOf(user), 100 ether);
    }

    function test_RouteThatPaysNothingReverts() public {
        bytes memory route = abi.encodeCall(Router.take, (address(tIn), 10 ether));
        vm.expectRevert(zSolverFill.NoOutput.selector);
        _snwap(address(tIn), 10 ether, address(tOut), 1, route, 0);
    }

    function test_PlantedOutputIsNotOutput() public {
        tOut.mint(address(fill), 5 ether);
        bytes memory route = abi.encodeCall(Router.take, (address(tIn), 10 ether));
        vm.expectRevert(zSolverFill.NoOutput.selector);
        _snwap(address(tIn), 10 ether, address(tOut), 1, route, 0);
    }

    function test_OutputPlantedMidRouteStillCounts_ButOnlyForTheRoute() public {
        // A unit sent to the fill during the route is route output; it cannot
        // clear a real bound, which the router checks at the recipient.
        bytes memory route = abi.encodeCall(Router.plant, (address(tOut), address(fill)));
        vm.expectRevert();
        _snwap(address(tIn), 10 ether, address(tOut), 25 ether, route, 0);
    }

    function test_RouteThatPaysTheUserDirectlyReverts() public {
        bytes memory route = abi.encodeCall(Router.swap, (address(tIn), 10 ether, address(tOut), 30 ether, payee));
        vm.expectRevert(zSolverFill.NoOutput.selector);
        _snwap(address(tIn), 10 ether, address(tOut), 1, route, 0);
    }

    function test_FeeOnTransferOutputIsCheckedAtTheRecipient() public {
        FeeToken fee = new FeeToken();
        fee.mint(address(router), 100 ether);
        bytes memory route = _swap(address(tIn), 10 ether, address(fee), 30 ether);
        vm.prank(user);
        vm.expectRevert();
        ROUTER.snwap(address(tIn), 10 ether, payee, address(fee), 30 ether, address(fill),
            _data(address(router), address(router), address(tIn), address(fee), payee, route));
        vm.prank(user);
        uint256 out = ROUTER.snwap(address(tIn), 10 ether, payee, address(fee), 29 ether, address(fill),
            _data(address(router), address(router), address(tIn), address(fee), payee, route));
        assertEq(out, fee.balanceOf(payee));
        assertLt(out, 30 ether);
    }

    function test_BadTargets() public {
        address a = address(tIn);
        address b = address(tOut);
        address r = address(router);
        address f = address(fill);
        address[4][8] memory bad = [
            [f, r, payee, user], [a, r, payee, user], [b, r, payee, user], [r, f, payee, user],
            [r, a, payee, user], [r, b, payee, user], [r, r, f, user], [r, r, payee, f]
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(zSolverFill.BadTarget.selector);
            fill.fill(bad[i][0], bad[i][1], a, b, bad[i][2], bad[i][3], "");
        }
        vm.expectRevert(zSolverFill.SameToken.selector);
        fill.fill(r, r, a, a, payee, user, "");
    }

    function test_Reentrancy() public {
        Reenterer re = new Reenterer();
        bytes memory route = abi.encodeCall(Reenterer.swap, (fill, address(tIn), address(tOut)));
        vm.prank(user);
        vm.expectRevert(zSolverFill.Reentrancy.selector);
        ROUTER.snwap(address(tIn), 10 ether, payee, address(tOut), 1, address(fill),
            _data(address(re), address(router), address(tIn), address(tOut), payee, route));
    }

    function test_RevertDataIsCapped() public {
        bytes memory route = abi.encodeCall(Router.bomb, ());
        vm.prank(user);
        (bool ok, bytes memory ret) = address(ROUTER).call(abi.encodeCall(IzRouter.snwap, (
            address(tIn), 10 ether, payee, address(tOut), 1, address(fill),
            _data(address(router), address(router), address(tIn), address(tOut), payee, route))));
        assertFalse(ok);
        assertLe(ret.length, 0x100);
    }

    function test_NoOneCanSpendTheRouterApprovalThroughTheFill() public {
        // The user's standing approval is to zRouter. The fill's arbitrary call
        // runs as the fill, which no one has approved, so aiming it at a token's
        // transferFrom reaches nothing.
        MockERC20 other = new MockERC20();
        other.mint(user, 1 ether);
        vm.prank(user);
        other.approve(address(ROUTER), type(uint256).max);
        bytes memory steal = abi.encodeCall(MockERC20.transferFrom, (user, address(this), 1 ether));
        vm.expectRevert();
        fill.fill(address(other), address(other), address(0), address(tOut), payee, user, steal);
        assertEq(other.balanceOf(user), 1 ether);
        assertEq(tIn.balanceOf(user), 100 ether);
    }

    function testFuzz_RefundAndOutput(uint96 aIn, uint96 spend, uint96 aOut) public {
        aIn = uint96(bound(aIn, 1, 100 ether));
        spend = uint96(bound(spend, 0, aIn));
        aOut = uint96(bound(aOut, 1, 1_000 ether));
        _snwap(address(tIn), aIn, address(tOut), aOut, _swap(address(tIn), spend, address(tOut), aOut), 0);
        assertEq(tOut.balanceOf(payee), aOut);
        assertEq(tIn.balanceOf(user), 100 ether - spend);
        _assertEmpty();
    }
}
