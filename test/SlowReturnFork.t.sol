// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Vm} from "../lib/forge-std/src/Vm.sol";

/// @notice The RETURN directions - L2 to Ethereum, and L2 to the other L2 -
///         measured against the deployed `SlowArrival` on mainnet.
///
///         zSwap does not build these yet. This file exists to establish
///         whether it could, and on what terms, because the answer is not
///         obvious from either end: the far side is deployed and routed, but
///         the near side is a canonical withdrawal that takes a working week
///         and needs somebody to finish it on L1.
///
///         What is proven here:
///
///           1. An arrival FROM an L2 authenticates its origin with no hint at
///              all. `SlowOrigin.recover` probes the caller's own
///              `l2Sender()` - which is exactly what `OptimismPortal` exposes
///              while it is executing a proven withdrawal - so the return leg
///              is strictly better off than the outbound one, where the hint is
///              load-bearing.
///           2. `forward` pushes an arriving withdrawal straight back out to
///              the other L2 through the canonical bridge, with the origin
///              preserved. That is a whole L2-to-L2 send with no counterparty.
///           3. The bounty pays whoever finalised the withdrawal. This is the
///              part that makes running a keeper a business rather than a
///              favour, and it is what the sender pays instead of waiting five
///              days to press a second button.
///
///         The mock below stands in for the portal and the outbox. It is not a
///         convenience: `SlowOrigin` deliberately identifies a bridge by
///         PROBING the caller rather than by holding an address, so a caller
///         that answers `l2Sender()` is, to that library, indistinguishable
///         from the real one. Faking it here is testing the real recovery path,
///         not bypassing it.
contract SlowReturnForkTest is Test {
    string constant L1_RPC = "https://ethereum-rpc.publicnode.com";

    address constant ARRIVAL = 0x9F8D89D298caBDC0D64cbA3888D0DA85Dc95097f;
    address constant SLOW = 0x000000006513B7821171C8447ec7ECdfa3b956Fd;
    address constant PORTAL = 0x49048044D57e1C92A77f79988d21Fa8fAF74E97e;

    address sender = address(0xA11CE);
    address recipient = address(0xB0B);
    address keeper = address(0xDEADBEEF);

    uint96 constant DELAY = 3600;
    uint256 constant AMOUNT = 1 ether;

    MockExit exit;

    function setUp() public {
        vm.createSelectFork(L1_RPC);
        exit = new MockExit();
        vm.deal(address(exit), 100 ether);
    }

    /// An L2 withdrawal that lands in SLOW on Ethereum, reversible by whoever
    /// sent it from the L2 - and the origin is AUTHENTICATED, not asserted.
    function test_aWithdrawalFromAnL2LandsAsAReversibleSlowPosition() public {
        vm.recordLogs();
        exit.arriveAs(sender, ARRIVAL, AMOUNT, recipient, DELAY, address(0), 0);

        uint256 id = _arrivedId();
        assertEq(_originOf(id), sender, "the L2 sender kept the reverse without naming itself");
        assertTrue(_authenticated(), "recovered by probe, not by hint - no one could have forged it");

        (, address from, address to,, uint256 amount) = _pending(id);
        assertEq(from, ARRIVAL);
        assertEq(to, recipient);
        assertEq(amount, AMOUNT);

        uint256 before = sender.balance;
        vm.prank(sender);
        (bool ok,) = ARRIVAL.call(abi.encodeWithSelector(bytes4(0x99c5ff88), id, sender));
        assertTrue(ok, "reverse failed");
        assertEq(sender.balance, before + AMOUNT);
    }

    /// The second leg of an L2-to-L2 send: the withdrawal lands here and leaves
    /// again in the same transaction, through Base's canonical portal.
    function test_anArrivingWithdrawalForwardsItselfOnToTheOtherL2() public {
        uint256 portalBefore = PORTAL.balance;

        vm.recordLogs();
        exit.forwardAs(sender, ARRIVAL, AMOUNT, 8453, recipient, DELAY, address(0), 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool forwarded;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == ARRIVAL
                    && logs[i].topics[0] == keccak256("Forwarded(uint256,address,address,uint256,uint96)")
            ) {
                assertEq(uint256(logs[i].topics[1]), 8453, "wrong destination");
                assertEq(address(uint160(uint256(logs[i].topics[2]))), sender, "the origin did not survive the hop");
                forwarded = true;
            }
        }
        assertTrue(forwarded, "the hop did not happen; the ether fell into rescue instead");
        assertEq(PORTAL.balance, portalBefore + AMOUNT, "the portal did not take the deposit");
        assertEq(_rescue(sender), 0, "nothing was stranded");
    }

    /// What makes it somebody's job. An OP exit is two L1 transactions - prove,
    /// then finalise a day later - and nobody does that for free.
    function test_theBountyPaysWhoeverFinalisedTheWithdrawal() public {
        uint256 bounty = 0.01 ether;
        uint256 before = keeper.balance;

        vm.recordLogs();
        // tx.origin is the keeper, because the keeper funded the finalise.
        // `msg.sender` cannot carry it: during a withdrawal that is the portal.
        vm.prank(address(this), keeper);
        exit.arriveAs(sender, ARRIVAL, AMOUNT, recipient, DELAY, address(0), bounty);

        assertEq(keeper.balance, before + bounty, "the finaliser was not paid");
        (,,,, uint256 amount) = _pending(_arrivedId());
        assertEq(amount, AMOUNT - bounty, "the bounty comes out of the payload, as it must");
    }

    /// The limit worth knowing before building on this: an L2-to-L2 hop whose
    /// origin is a CONTRACT is refused rather than sent, because Nitro would
    /// alias the refund addresses on the second leg and strand them. The money
    /// is not lost - it waits in `rescue` - but a Safe cannot use this route.
    function test_aContractOriginCannotHopOnToRobinhood() public {
        vm.recordLogs();
        exit.forwardAs(address(exit), ARRIVAL, AMOUNT, 4663, recipient, DELAY, address(0), 0);

        assertEq(_rescue(address(exit)), AMOUNT, "a refused hop must hold the ether for its origin");
    }

    // -------------------------------------------------------------------- helpers

    function _arrivedId() internal returns (uint256) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Arrived(uint256,address,address,uint256,uint96,bool)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == ARRIVAL && logs[i].topics[0] == topic) {
                _lastArrived = logs[i].data;
                return uint256(logs[i].topics[1]);
            }
        }
        revert("no Arrived event");
    }

    bytes internal _lastArrived;

    function _authenticated() internal view returns (bool) {
        (,, bool auth) = abi.decode(_lastArrived, (uint256, uint96, bool));
        return auth;
    }

    function _originOf(uint256 id) internal view returns (address) {
        (, bytes memory r) = ARRIVAL.staticcall(abi.encodeWithSelector(bytes4(0x794b2a07), id));
        return abi.decode(r, (address));
    }

    function _rescue(address who) internal view returns (uint256) {
        (, bytes memory r) = ARRIVAL.staticcall(abi.encodeWithSelector(bytes4(0x839006f2), who));
        return abi.decode(r, (uint256));
    }

    function _pending(uint256 id) internal view returns (uint96, address, address, uint256, uint256) {
        (, bytes memory r) = SLOW.staticcall(abi.encodeWithSelector(bytes4(0x6577b86a), id));
        return abi.decode(r, (uint96, address, address, uint256, uint256));
    }
}

/// Stands in for `OptimismPortal` mid-`finalizeWithdrawalTransaction`, and for
/// the Arbitrum `Bridge` mid-`executeCall`: a caller that will tell
/// `SlowOrigin` who is behind it. Both real ones answer exactly this way, and
/// `SlowOrigin` looks for nothing else.
contract MockExit {
    address public l2Sender;

    function arriveAs(
        address origin,
        address arrival,
        uint256 value,
        address to,
        uint96 delay,
        address hint,
        uint256 bounty
    ) external {
        l2Sender = origin;
        (bool ok,) =
            arrival.call{value: value}(abi.encodeWithSelector(bytes4(0x24eb6264), to, delay, hint, bounty));
        require(ok, "arrive reverted");
        l2Sender = address(0);
    }

    function forwardAs(
        address origin,
        address arrival,
        uint256 value,
        uint256 dst,
        address to,
        uint96 delay,
        address hint,
        uint256 bounty
    ) external {
        l2Sender = origin;
        (bool ok,) = arrival.call{value: value}(
            abi.encodeWithSelector(bytes4(0xae46f6e1), dst, to, delay, hint, bounty)
        );
        require(ok, "forward reverted");
        l2Sender = address(0);
    }

    receive() external payable {}
}
