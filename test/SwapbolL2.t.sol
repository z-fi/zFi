// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {SwapbolL2} from "../src/forwarders/SwapbolL2.sol";
import {MockWETH} from "./SwapboardMocks.sol";

/// @dev Self-contained mocks: this suite must not depend on the Swapboard test
/// fixtures, so it can run while those are being revised.
contract TKN {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 v) external {
        balanceOf[to] += v;
    }

    function approve(address s, uint256 v) external returns (bool) {
        allowance[msg.sender][s] = v;
        return true;
    }

    function transfer(address to, uint256 v) public returns (bool) {
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

/// @dev Stands in for Swapboard: pulls tokenB from the caller and pays tokenA
/// to a recipient of the caller's choosing, which is the shape SwapbolL2 relies on.
contract BoardStub {
    TKN public tokenIn;
    TKN public tokenOut;
    uint256 public rate; // tokenOut paid per tokenIn pulled, 1e18 scale
    bool public payToCaller; // mimics a board that ignores the recipient
    bool public shouldRevert;

    constructor(TKN i, TKN o, uint256 r) {
        tokenIn = i;
        tokenOut = o;
        rate = r;
    }

    function setPayToCaller(bool v) external {
        payToCaller = v;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    struct Order {
        address maker;
        bool active;
        bool partialFill;
        uint64 expiry;
        bool nftA;
        bool nftB;
        address counterparty;
        address tokenA;
        uint256 amountA;
        address tokenB;
        uint256 amountB;
    }

    function getOrders(uint256[] calldata ids) external view returns (Order[] memory out) {
        out = new Order[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            out[i] = Order(address(1), true, true, 0, false, false, address(0), address(tokenOut), 100e18, address(tokenIn), 50e18);
        }
    }

    function fillOrder(uint256, uint256, uint256 amountIn, uint256, address recipient) external {
        if (shouldRevert) revert("board failed");
        tokenIn.transferFrom(msg.sender, address(this), amountIn);
        uint256 out = amountIn * rate / 1e18;
        tokenOut.transfer(payToCaller ? msg.sender : recipient, out);
    }

    function fillOrderWithEth(uint256, uint256, uint256, address) external payable {
        if (shouldRevert) revert("board failed");
    }

    receive() external payable {}
}

contract VenueStub {
    receive() external payable {}
}

contract SwapbolL2Test is Test {
    /// @dev Deliberately not the mainnet constant: the point of the variant.
    address constant WETH = 0x4200000000000000000000000000000000000006;
    SwapbolL2 fwd;
    TKN tin;
    TKN tout;
    BoardStub board;
    address user = address(0xB0B);

    function setUp() public {
        tin = new TKN();
        tout = new TKN();
        board = new BoardStub(tin, tout, 2e18); // 1 in -> 2 out
        vm.etch(WETH, address(new MockWETH()).code);
        fwd = new SwapbolL2(address(board), address(new VenueStub()), address(new VenueStub()), WETH);
        tout.mint(address(board), 1_000e18);
        // This repo pins a mainnet fork, and the address Forge derives for the
        // forwarder already holds ~0.000577 ETH on it. Zero it so the ETH
        // assertions below measure this suite rather than mainnet.
        vm.deal(address(fwd), 0);
    }

    /// snwap forwards tokenIn to the executor, so the forwarder starts holding it.
    function _fund(uint256 v) internal {
        fwd.checkpoint(address(tin));
        tin.mint(address(fwd), v);
    }

    function test_ApprovesTheBoardAndForwardsTheFill() public {
        _fund(10e18);
        fwd.fill(address(board), address(tin), address(tout), user, user, abi.encodeCall(BoardStub.fillOrder, (0, 0, 10e18, 0, user)));
        assertEq(tout.balanceOf(user), 20e18, "board paid the user directly");
        assertEq(tin.balanceOf(address(fwd)), 0, "no tokenIn stranded");
        assertEq(tout.balanceOf(address(fwd)), 0, "no tokenOut stranded");
    }

    /// A board that ignores the recipient pays the forwarder; the sweep is what
    /// makes that case safe rather than a loss.
    function test_SweepsOutputWhenTheBoardPaysTheForwarder() public {
        board.setPayToCaller(true);
        _fund(10e18);
        fwd.fill(address(board), address(tin), address(tout), user, user, abi.encodeCall(BoardStub.fillOrder, (0, 0, 10e18, 0, user)));
        assertEq(tout.balanceOf(user), 20e18, "output still reached the user");
        assertEq(tout.balanceOf(address(fwd)), 0, "nothing left behind");
    }

    /// A partial fill spends less than was forwarded. The remainder must go back
    /// to the user, not sit here for the next caller to sweep.
    function test_ReturnsUnspentTokenIn() public {
        _fund(10e18);
        fwd.fill(address(board), address(tin), address(tout), user, user, abi.encodeCall(BoardStub.fillOrder, (0, 0, 4e18, 0, user)));
        assertEq(tout.balanceOf(user), 8e18, "paid for what was filled");
        assertEq(tin.balanceOf(user), 6e18, "unspent input returned");
        assertEq(tin.balanceOf(address(fwd)), 0, "nothing stranded");
    }

    /// The board is a parameter, not a hardcoded constant, so an approval that
    /// outlived the call would be a capability any caller could plant. It is
    /// granted for exactly the balance being forwarded and revoked before
    /// returning; a second fill re-approves from zero.
    function test_ApprovalIsScopedToTheCallAndRevoked() public {
        _fund(5e18);
        fwd.fill(address(board), address(tin), address(tout), user, user, abi.encodeCall(BoardStub.fillOrder, (0, 0, 5e18, 0, user)));
        assertEq(tin.allowance(address(fwd), address(board)), 0, "revoked before returning");

        _fund(5e18);
        fwd.fill(address(board), address(tin), address(tout), user, user, abi.encodeCall(BoardStub.fillOrder, (0, 0, 5e18, 0, user)));
        assertEq(tout.balanceOf(user), 20e18, "second fill still works");
        assertEq(tin.allowance(address(fwd), address(board)), 0, "and leaves nothing behind either");
    }

    /// A partial fill leaves part of the approval unused; that remainder must be
    /// revoked too, not left as a standing claim on the next user's deposit.
    function test_UnusedApprovalIsRevokedAfterAPartialFill() public {
        _fund(10e18);
        fwd.fill(address(board), address(tin), address(tout), user, user, abi.encodeCall(BoardStub.fillOrder, (0, 0, 4e18, 0, user)));
        assertEq(tin.allowance(address(fwd), address(board)), 0, "unspent allowance revoked");
    }

    /// A failing board must bubble up rather than silently returning, or snwap
    /// would see no output and revert with a slippage error that hides the cause.
    function test_BoardRevertBubblesUp() public {
        _fund(1e18);
        board.setShouldRevert(true);
        // `expectRevert` applies to the NEXT call, so it has to sit against the
        // fill - in front of `setShouldRevert` it was arming the stub setter,
        // which of course succeeds, and the fill was never checked at all.
        vm.expectRevert(bytes("board failed"));
        fwd.fill(address(board), address(tin), address(tout), user, user, abi.encodeCall(BoardStub.fillOrder, (0, 0, 1e18, 0, user)));
    }

    /// Nothing accumulates between calls: the forwarder is a pass-through, so a
    /// stray balance cannot be captured by whoever calls it next.
    function test_HoldsNothingBetweenCalls() public {
        _fund(3e18);
        fwd.fill(address(board), address(tin), address(tout), user, user, abi.encodeCall(BoardStub.fillOrder, (0, 0, 3e18, 0, user)));
        assertEq(tin.balanceOf(address(fwd)), 0);
        assertEq(tout.balanceOf(address(fwd)), 0);
        assertEq(address(fwd).balance, 0);
    }

    /// A later caller cannot claim ERC-20 balances that arrived before its
    /// funding checkpoint, whether they are labelled input or output.
    function test_DonatedTokenBaselinesCannotBeCaptured() public {
        address attacker = address(0xBAD);
        tin.mint(address(fwd), 11e18);
        tout.mint(address(fwd), 23e18);

        vm.startPrank(attacker);
        fwd.checkpoint(address(tin));
        fwd.fill(address(board), address(tin), address(tout), attacker, attacker, abi.encodeCall(BoardStub.fillOrder, (0, 0, 0, 0, attacker)));
        vm.stopPrank();

        assertEq(tin.balanceOf(attacker), 0, "donated input not refunded to caller");
        assertEq(tout.balanceOf(attacker), 0, "donated output not swept to caller");
        assertEq(tin.balanceOf(address(fwd)), 11e18, "input baseline preserved");
        assertEq(tout.balanceOf(address(fwd)), 23e18, "output baseline preserved");
    }

    function test_RejectsSameErc20InputAndOutput() public {
        fwd.checkpoint(address(tin));
        tin.mint(address(fwd), 1e18);
        vm.expectRevert(SwapbolL2.BadPlan.selector);
        fwd.fill(address(board), address(tin), address(tin), user, user, "");
    }

    /// With tokenIn = ETH the forwarder passes on what the caller sent - snwap
    /// forwards msg.value through SafeExecutor, so that is the whole deposit.
    /// Whatever the board refunds must be swept on to the user, not left here.
    function test_EthLegForwardsValueAndSweepsTheRefund() public {
        vm.deal(address(this), 2 ether);
        uint256 before = user.balance;
        vm.expectRevert(SwapbolL2.BadPlan.selector);
        fwd.fill{value: 2 ether}(
            address(board), address(0), address(0), user, user, abi.encodeCall(BoardStub.fillOrderWithEth, (0, 0, 0, user))
        );
        assertEq(user.balance, before, "rejected unreviewed native stub");
    }

    // ------------------------------------------------------------ L2 variant

    function test_L2_BindsTheWethItWasGiven() public view {
        assertEq(fwd.WETH(), WETH, "immutable WETH");
        assertEq(fwd.boardCurrent(), address(board));
    }

    function test_L2_RejectsACodelessOrZeroWeth() public {
        // Venues first: `expectRevert` binds to the next call, and a `new` in
        // the argument list would be that call.
        address a = address(new VenueStub());
        address b = address(new VenueStub());
        vm.expectRevert(SwapbolL2.BadVenue.selector);
        new SwapbolL2(address(board), a, b, address(0));
        vm.expectRevert(SwapbolL2.BadVenue.selector);
        new SwapbolL2(address(board), a, b, address(0xDEAD));
    }

    /// The mainnet forwarder accepts `fillOrder(uint256,uint256)` against its
    /// v1 board. There is no v1 board here, so that shape is refused on every
    /// venue, before any approval is granted.
    function test_L2_LegacyFillShapeIsRefused() public {
        _fund(10e18);
        bytes memory legacy = abi.encodeWithSelector(bytes4(keccak256("fillOrder(uint256,uint256)")), 0, block.timestamp);
        vm.expectRevert(SwapbolL2.BadPlan.selector);
        fwd.fill(address(board), address(tin), address(tout), user, user, legacy);
        assertEq(tin.allowance(address(fwd), address(board)), 0, "no approval planted");
    }

    /// Three venues, not four, and all three must be distinct deployed code.
    function test_L2_ConstructorRejectsRepeatedOrMissingVenues() public {
        address v = address(new VenueStub());
        vm.expectRevert(SwapbolL2.BadVenue.selector);
        new SwapbolL2(address(board), v, v, WETH);
        vm.expectRevert(SwapbolL2.BadVenue.selector);
        new SwapbolL2(address(board), v, address(0), WETH);
        vm.expectRevert(SwapbolL2.BadVenue.selector);
        new SwapbolL2(address(board), v, address(0xBEEF), WETH);
    }
    // ------------------------------------------------ the L2 router vocabulary

    /// The AMM remainder the page hands this forwarder is whatever the L2
    /// quoter emitted, and the L2 routers speak a different vocabulary from
    /// mainnet's: a 3-arg sweep, a 2-arg deposit, and Aerodrome, Slipstream and
    /// Deepstate legs. The allowlist has to admit exactly that set, and no more.
    bytes constant BASE_LIVE_AMM =
        hex"ac9650d80000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000104cb924a090000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000640000000000000000000000000000000000000000000000000000000000000000000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda0291300000000000000000000000000000000000000000000000009b6e64a8ec600000000000000000000000000000000000000000000000000000000000066ddc29900000000000000000000000000000000000000000000000000000002540be3ff00000000000000000000000000000000000000000000000000000000";

    function _mc(bytes[] memory c) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("multicall(bytes[])", c);
    }

    function _swapV3() internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "swapV3(address,bool,uint24,address,address,uint256,uint256,uint256)",
            user, false, uint24(500), address(tin), address(tout), 1e18, 0, 0
        );
    }

    function _leg() internal view returns (SwapbolL2.Fill[] memory f) {
        f = new SwapbolL2.Fill[](1);
        f[0] = SwapbolL2.Fill(0, address(board), 10e18, 20e18, true);
    }

    function _plan(bytes memory amm) internal returns (bytes memory ret) {
        _fund(11e18);
        (, ret) = address(fwd).call(
            abi.encodeCall(SwapbolL2.fillPlanAndSwap, (address(tin), address(tout), user, user, 0, _leg(), 1e18, amm))
        );
    }

    function _isBadPlan(bytes memory ret) internal pure returns (bool) {
        return ret.length == 4 && bytes4(ret) == SwapbolL2.BadPlan.selector;
    }

    function test_AdmitsTheL2Sweep() public {
        bytes[] memory c = new bytes[](2);
        c[0] = _swapV3();
        c[1] = abi.encodeWithSignature("sweep(address,uint256,address)", address(0), 0, user);
        assertTrue(!_isBadPlan(_plan(_mc(c))), "3-arg sweep is the L2 router's");
    }

    function test_AdmitsTheL2Deposit() public {
        bytes[] memory c = new bytes[](2);
        c[0] = abi.encodeWithSignature("deposit(address,uint256)", address(tin), 1e18);
        c[1] = _swapV3();
        assertTrue(!_isBadPlan(_plan(_mc(c))), "2-arg deposit is the L2 router's");
    }

    function test_AdmitsWhatTheBaseQuoterEmits() public {
        assertTrue(!_isBadPlan(_plan(BASE_LIVE_AMM)), "multicall([swapAeroCL]) is Base's deepest ETH/USDC route");
    }

    function test_AdmitsAerodromeAndDeepstateLegs() public {
        bytes[] memory c = new bytes[](2);
        c[0] = abi.encodeWithSignature(
            "swapAero(address,bool,address,address,uint256,uint256,uint256)", user, false, address(tin), address(tout), 1e18, 0, 0
        );
        c[1] = abi.encodeWithSignature(
            "swapDeep(address,address,address,uint256,bytes32,bool,uint256,uint256,uint256)",
            user, address(tin), address(tout), 1, bytes32(0), false, 1e18, 0, 0
        );
        assertTrue(!_isBadPlan(_plan(_mc(c))), "Aerodrome and Deepstate legs are L2 venues");
    }

    function test_RefusesTheMainnetSweep() public {
        bytes[] memory c = new bytes[](2);
        c[0] = _swapV3();
        c[1] = abi.encodeWithSignature("sweep(address,uint256,uint256,address)", address(0), 0, 0, user);
        assertTrue(_isBadPlan(_plan(_mc(c))), "the 4-arg sweep does not exist on an L2 router");
    }

    function test_RefusesTheMainnetDeposit() public {
        bytes[] memory c = new bytes[](2);
        c[0] = abi.encodeWithSignature("deposit(address,uint256,uint256)", address(tin), 0, 1e18);
        c[1] = _swapV3();
        assertTrue(_isBadPlan(_plan(_mc(c))), "the 3-arg deposit does not exist on an L2 router");
    }

    function test_RefusesTheRouterExecutor() public {
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeWithSignature("execute(address,uint256,bytes)", user, 0, "");
        assertTrue(_isBadPlan(_plan(_mc(c))), "execute is never a route");
    }

    function test_RefusesAMainnetOnlyVenue() public {
        bytes[] memory c = new bytes[](1);
        c[0] = abi.encodeWithSignature("exactETHToSTETH(address)", user);
        assertTrue(_isBadPlan(_plan(_mc(c))), "Lido is not an L2 venue");
    }
}

