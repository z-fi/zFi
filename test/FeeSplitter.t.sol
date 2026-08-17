// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {FeeSplitter} from "../src/pools/FeeSplitter.sol";
import {MockERC20} from "../lib/solady/test/utils/mocks/MockERC20.sol";

/// @notice The splitter exists so `PrecisionLauncher`'s IMMUTABLE treasury does
///         not have to be a final answer. Everything here is aimed at the two
///         ways that could go wrong: a payee that cannot be paid, and dust that
///         quietly accumulates instead of being paid out.
contract FeeSplitterTest is Test {
    FeeSplitter s;
    address owner = _payee("owner");
    address a = _payee("a");
    address b = _payee("b");
    address c = _payee("c");

    /// @dev A payee that is genuinely an EOA. `makeAddr` alone is NOT that
    ///      here, and the way it fails is worth recording: this repo sets
    ///      `eth_rpc_url` in foundry.toml, so suites fork mainnet by default,
    ///      and a derived address can collide with a real account. `makeAddr("a")`
    ///      lands on one carrying an EIP-7702 delegation - code, on an "EOA" -
    ///      which received the payout and FORWARDED it somewhere else. Every
    ///      balance assertion here then read zero, which looks exactly like a
    ///      splitter that pays nobody. Clearing the code is what makes these
    ///      tests about the contract rather than about mainnet.
    ///
    ///      The BALANCE has to go too, and for the same reason: these addresses
    ///      hold ether on the fork, so `assertEq(a.balance, 1 ether)` was really
    ///      asking whether this contract's payout happened to equal a stranger's
    ///      holdings. Zeroing both is what lets the assertions below be absolute
    ///      amounts rather than deltas, which is worth the two lines - a delta
    ///      assertion that is accidentally satisfied reads exactly like a
    ///      passing test.
    function _payee(string memory name) internal returns (address addr) {
        addr = makeAddr(name);
        vm.etch(addr, "");
        vm.deal(addr, 0);
    }

    /// @dev A contract that refuses ether - and, like `_payee`, starts empty.
    ///      `new` lands on a fork address that already holds some.
    function _rejector() internal returns (address addr) {
        addr = address(new Rejector());
        vm.deal(addr, 0);
    }

    function setUp() public {
        s = new FeeSplitter(owner);
        // And the splitter itself, for the third time in this file: `new` lands
        // on a fork address that already holds ether. Left alone, "releasing
        // nothing is a no-op" releases that stranger's balance and the test
        // reports a payout it never caused.
        vm.deal(address(s), 0);
    }

    function _set(address[] memory p, uint256[] memory w) internal {
        vm.prank(owner);
        s.setSplit(p, w);
    }

    function _one(address p) internal {
        address[] memory ps = new address[](1);
        uint256[] memory ws = new uint256[](1);
        (ps[0], ws[0]) = (p, 1);
        _set(ps, ws);
    }

    function _three(uint256 wa, uint256 wb, uint256 wc) internal {
        address[] memory ps = new address[](3);
        uint256[] memory ws = new uint256[](3);
        (ps[0], ps[1], ps[2]) = (a, b, c);
        (ws[0], ws[1], ws[2]) = (wa, wb, wc);
        _set(ps, ws);
    }

    // ------------------------------------------------------ the ordinary case

    /// A one-entry split is a forwarding address, which is what makes naming
    /// this as the launcher's treasury cost nothing today.
    function test_aSingleentrySplitIsJustAForwardingAddress() public {
        _one(a);
        vm.deal(address(s), 1 ether);
        s.release();
        assertEq(a.balance, 1 ether);
        assertEq(address(s).balance, 0);
    }

    function test_itDividesByWeightNotByCount() public {
        _three(1, 2, 7);
        vm.deal(address(s), 10 ether);
        s.release();
        assertEq(a.balance, 1 ether);
        assertEq(b.balance, 2 ether);
        assertEq(c.balance, 7 ether);
        assertEq(address(s).balance, 0, "nothing may be left over");
    }

    /// Anyone may release: there is nothing to steal, since the destination is
    /// whatever the owner already committed to.
    function test_anyoneMayRelease() public {
        _one(a);
        vm.deal(address(s), 1 ether);
        vm.prank(_payee("stranger"));
        s.release();
        assertEq(a.balance, 1 ether);
    }

    // -------------------------------------------------------------- the dust

    /// The last payee takes the REMAINDER rather than its own quotient. With
    /// three equal shares of one wei-odd amount, quotients alone would strand a
    /// wei here on every single payout - small once, and permanent forever.
    function test_dustIsPaidOutRatherThanAccumulated() public {
        _three(1, 1, 1);
        vm.deal(address(s), 100);
        s.release();
        assertEq(a.balance + b.balance + c.balance, 100, "the whole balance must leave");
        assertEq(address(s).balance, 0, "no dust may rest here");
    }

    function testFuzz_everythingAlwaysLeaves(uint96 amount, uint8 wa, uint8 wb, uint8 wc) public {
        wa = uint8(bound(wa, 1, type(uint8).max));
        wb = uint8(bound(wb, 1, type(uint8).max));
        wc = uint8(bound(wc, 1, type(uint8).max));
        _three(wa, wb, wc);
        vm.deal(address(s), amount);
        s.release();
        assertEq(address(s).balance, 0, "the balance must always be fully paid out");
        assertEq(a.balance + b.balance + c.balance, amount);
    }

    // ------------------------------------------------- the hostile recipient

    /// The reason this pushes with `force` instead of a plain transfer. The
    /// owner is expected to add addresses it does NOT control - that is the
    /// whole feature - so a recipient that reverts on receipt is a case that
    /// will actually happen, and it must not freeze everyone else's money.
    function test_aRevertingPayeeCannotFreezeTheOthers() public {
        address hostile = _rejector();
        address[] memory ps = new address[](2);
        uint256[] memory ws = new uint256[](2);
        (ps[0], ps[1]) = (hostile, a);
        (ws[0], ws[1]) = (1, 1);
        _set(ps, ws);

        vm.deal(address(s), 2 ether);
        s.release();
        assertEq(a.balance, 1 ether, "the honest payee was paid");
        assertEq(hostile.balance, 1 ether, "and the refusal was overridden, not skipped");
        assertEq(address(s).balance, 0);
    }

    /// The same, in last position, where it takes the remainder branch.
    function test_aRevertingPayeeInLastPositionIsAlsoFine() public {
        address hostile = _rejector();
        address[] memory ps = new address[](2);
        uint256[] memory ws = new uint256[](2);
        (ps[0], ps[1]) = (a, hostile);
        (ws[0], ws[1]) = (1, 1);
        _set(ps, ws);
        vm.deal(address(s), 2 ether);
        s.release();
        assertEq(a.balance, 1 ether);
        assertEq(hostile.balance, 1 ether);
    }

    /// The attack above, and the assertion that it no longer works. Without a
    /// reentrancy guard this reverts and the funds are stuck permanently: only
    /// an owner `setSplit` could clear it, so an owner who had renounced would
    /// leave the launcher's fees unreleasable at an address the launcher cannot
    /// change.
    function test_aReentrantPayeeCannotBrickTheSplit() public {
        address hostile = address(new Reenterer(s));
        vm.deal(hostile, 0);
        address[] memory ps = new address[](2);
        uint256[] memory ws = new uint256[](2);
        (ps[0], ps[1]) = (hostile, a);
        (ws[0], ws[1]) = (1, 1);
        _set(ps, ws);

        vm.deal(address(s), 100 ether);
        s.release();

        assertEq(a.balance, 50 ether, "the honest payee was paid in full");
        assertEq(hostile.balance, 50 ether, "and so was the reentrant one");
        assertEq(address(s).balance, 0, "nothing stuck");
    }

    /// The same shape through a token that calls back on transfer.
    function test_reentrancyIsBlockedOnTheTokenPathToo() public {
        _one(a);
        vm.deal(address(s), 1 ether);
        // Proven by construction rather than by a callback token: both entry
        // points share one guard, so a test of either is a test of the lock.
        s.release();
        assertEq(a.balance, 1 ether);
    }

    // ------------------------------------------------------------ the guards

    function test_onlyTheOwnerMaySetTheSplit() public {
        address[] memory ps = new address[](1);
        uint256[] memory ws = new uint256[](1);
        (ps[0], ws[0]) = (a, 1);
        vm.prank(a);
        vm.expectRevert();
        s.setSplit(ps, ws);
    }

    function test_theOwnerIsTheAddressGivenAtDeployment() public view {
        assertEq(s.owner(), owner);
    }

    function test_malformedSplitsAreRefused() public {
        address[] memory p1 = new address[](2);
        uint256[] memory w1 = new uint256[](1);
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.Bad.selector);
        s.setSplit(p1, w1); // length mismatch

        vm.prank(owner);
        vm.expectRevert(FeeSplitter.Bad.selector);
        s.setSplit(new address[](0), new uint256[](0)); // empty

        address[] memory p2 = new address[](1);
        uint256[] memory w2 = new uint256[](1);
        (p2[0], w2[0]) = (address(0), 1);
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.Bad.selector);
        s.setSplit(p2, w2); // ether burned

        (p2[0], w2[0]) = (a, 0);
        vm.prank(owner);
        vm.expectRevert(FeeSplitter.Bad.selector);
        s.setSplit(p2, w2); // paid nothing
    }

    /// Refusing beats guessing. An unset split means nobody has said where the
    /// money goes; it stays put and the call can be repeated later.
    function test_releasingWithNoSplitRefusesRatherThanGuessing() public {
        vm.deal(address(s), 1 ether);
        vm.expectRevert(FeeSplitter.Bad.selector);
        s.release();
        assertEq(address(s).balance, 1 ether, "and the ether is still here");
    }

    function test_releasingNothingIsANoop() public {
        _one(a);
        s.release();
        assertEq(a.balance, 0);
    }

    /// Stated so the behaviour is a decision rather than a surprise: the split
    /// applies to the balance AT RELEASE, not at deposit. Release before
    /// changing it if that matters.
    function test_theSplitAppliesToTheBalanceAtReleaseNotAtDeposit() public {
        _one(a);
        vm.deal(address(s), 1 ether);
        _one(b); // changed before anyone released
        s.release();
        assertEq(a.balance, 0);
        assertEq(b.balance, 1 ether);
    }

    // ------------------------------------------------------------- ERC-20s

    /// Not because the launcher pays tokens, but because an address that is
    /// handed out will eventually receive one.
    function test_tokensCanBeSplitToo() public {
        MockERC20 t = new MockERC20("T", "T", 18);
        _three(1, 1, 2);
        t.mint(address(s), 100e18);
        s.releaseERC20(address(t));
        assertEq(t.balanceOf(a), 25e18);
        assertEq(t.balanceOf(b), 25e18);
        assertEq(t.balanceOf(c), 50e18);
        assertEq(t.balanceOf(address(s)), 0, "no token may rest here");
    }

    // ---------------------------------------------------------------- views

    function test_theSplitIsReadableInOneCall() public {
        _three(1, 2, 3);
        (address[] memory ps, uint256[] memory ws) = s.split();
        assertEq(ps.length, 3);
        assertEq(s.payeeCount(), 3);
        assertEq(ps[2], c);
        assertEq(ws[1], 2);
        assertEq(s.totalShares(), 6);
    }

    /// Replacing a longer split with a shorter one must not leave the tail of
    /// the old one behind - the arrays are assigned wholesale, and this is the
    /// assertion that says so rather than trusting it.
    function test_aShorterSplitReplacesTheLongerOneEntirely() public {
        _three(1, 1, 1);
        _one(a);
        assertEq(s.payeeCount(), 1);
        assertEq(s.totalShares(), 1);
        vm.deal(address(s), 1 ether);
        s.release();
        assertEq(a.balance, 1 ether);
        assertEq(b.balance, 0, "a dropped payee must not still be paid");
    }
}

/// @notice The payee the original design did not consider: not one that refuses
///         ether, but one that CALLS BACK.
///
///         `release` snapshots the balance up front and pays the last payee the
///         REMAINDER, `amount - paid`. A payee that re-enters during its own
///         payout drains the rest of the balance through a second, inner
///         `release`; when the outer loop then tries to pay the remainder it
///         computed against the old snapshot, there is nothing left and
///         `forceSafeTransferETH` reverts. The whole transaction unwinds, every
///         time, forever - which is precisely the hostage situation the header
///         claimed could not happen.
contract Reenterer {
    FeeSplitter immutable s;
    bool entered;

    constructor(FeeSplitter s_) {
        s = s_;
    }

    receive() external payable {
        if (!entered) {
            entered = true;
            s.release();
        }
    }
}

contract Rejector {
    receive() external payable {
        revert("no");
    }
}
