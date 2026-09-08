// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Vm} from "../lib/forge-std/src/Vm.sol";

/// @notice zSwap's L1->L2 send, run against the DEPLOYED contracts rather than
///         against a mock.
///
///         test/ui/slow-bridge.test.mjs pins the bytes the page hands the
///         wallet. It cannot say whether those bytes DO anything: its chain is
///         fixture data, and a deposit aimed one word wrong looks identical to
///         a correct one from inside it. So this file takes the page's own
///         output, decodes it, and then executes the same call on a fork of
///         each real chain.
///
///         What is actually at stake is the reverse. `SLOW` records
///         `pendingTransfers[id].from = msg.sender`, and only that address may
///         `reverse` or `clawback`. Bridge the deposit directly and `from` is
///         the portal, the bridge, or an alias with no key on either side - the
///         money arrives and can never be taken back. `SlowArrival` becomes the
///         depositor instead and hands the right to the origin it recovered,
///         and the two chains recover it DIFFERENTLY: OP Stack does not alias an
///         EOA, Nitro aliases every retryable sender. Both branches are
///         exercised here, including the one where the hint is missing.
contract SlowBridgeForkTest is Test {
    string constant L1_RPC = "https://ethereum-rpc.publicnode.com";
    string constant BASE_RPC = "https://mainnet.base.org";
    string constant RH_RPC = "https://rpc.mainnet.chain.robinhood.com";

    address constant SLOW = 0x000000006513B7821171C8447ec7ECdfa3b956Fd;
    address constant ARRIVAL = 0x9F8D89D298caBDC0D64cbA3888D0DA85Dc95097f;
    address constant PORTAL = 0x49048044D57e1C92A77f79988d21Fa8fAF74E97e;
    address constant INBOX = 0x1A07cc4BD17E0118BdB54D70990D2158AbAD7a2D;

    /// @dev The offset both stacks add to an L1 sender they alias.
    uint160 constant ALIAS = uint160(0x1111000000000000000000000000000000001111);

    address sender = address(0xA11CE);
    address recipient = address(0xB0B);
    address stranger = address(0xBADD);

    uint96 constant DELAY = 3600;
    uint256 constant AMOUNT = 1 ether;

    function _alias(address a) internal pure returns (address) {
        unchecked {
            return address(uint160(a) + ALIAS);
        }
    }

    // ---------------------------------------------------------- the page's bytes

    /// The exact calldata zSwap.html hands the wallet for a 1 ETH time-locked
    /// send to Base, captured from the page driven in test/ui/harness.mjs with
    /// account 0x1111…1111 and recipient 0x2222…2222. Decoding it here is what
    /// ties everything below to the page rather than to this file's opinion of
    /// what the page ought to build.
    bytes constant PAGE_OP_LOCKED =
        hex"e9e05c420000000000000000000000009f8d89d298cabdc0d64cba3888d0da85dc95097f"
        hex"0000000000000000000000000000000000000000000000000de0b6b3a7640000"
        hex"00000000000000000000000000000000000000000000000000000000000c3500"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"00000000000000000000000000000000000000000000000000000000000000a0"
        hex"0000000000000000000000000000000000000000000000000000000000000084"
        hex"24eb62640000000000000000000000002222222222222222222222222222222222222222"
        hex"0000000000000000000000000000000000000000000000000000000000000e10"
        hex"0000000000000000000000001111111111111111111111111111111111111111"
        hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"00000000000000000000000000000000000000000000000000000000";

    function test_thePageAimsTheDepositAtSlowArrivalAndNamesItsSender() public pure {
        bytes memory args = _tail(PAGE_OP_LOCKED);
        (address to, uint256 value, uint64 gasLimit, bool isCreation, bytes memory inner) =
            abi.decode(args, (address, uint256, uint64, bool, bytes));

        assertEq(to, ARRIVAL, "a locked send must land on SlowArrival, not on the recipient");
        assertEq(value, AMOUNT, "the deposit's L2 value is the amount");
        assertEq(gasLimit, 800_000, "the far side runs depositTo, not a bare transfer");
        assertEq(isCreation, false);

        assertEq(bytes4(inner), bytes4(0x24eb6264), "arrive(address,uint96,address,uint256)");
        (address arriveTo, uint96 delay, address hint, uint256 bounty) =
            abi.decode(_tail(inner), (address, uint96, address, uint256));
        assertEq(arriveTo, 0x2222222222222222222222222222222222222222, "the recipient the user typed");
        assertEq(delay, DELAY);
        assertEq(hint, 0x1111111111111111111111111111111111111111, "the origin hint IS the sender");
        assertEq(bounty, 0, "an L1->L2 message executes itself; nobody needs paying");
    }

    // ------------------------------------------------------ Ethereum: the entries

    /// The deposit is a real call to Base's portal, not a shape assertion. A
    /// wrong `msg.value`, a gas limit under the portal's floor, or a malformed
    /// tail all revert here.
    function test_theBaseDepositIsAcceptedByThePortal() public {
        vm.createSelectFork(L1_RPC);
        vm.deal(sender, 10 ether);

        bytes memory inner = abi.encodeWithSelector(bytes4(0x24eb6264), recipient, DELAY, sender, uint256(0));
        vm.prank(sender);
        (bool ok,) = PORTAL.call{value: AMOUNT}(
            abi.encodeWithSelector(bytes4(0xe9e05c42), ARRIVAL, AMOUNT, uint64(800_000), false, inner)
        );
        assertTrue(ok, "OptimismPortal rejected the deposit the page builds");
        assertEq(sender.balance, 9 ether, "the portal takes exactly the amount and no more");
    }

    /// Robinhood is the one that costs extra: the ticket has to carry its own
    /// submission fee and prepay its destination gas, or it is accepted and
    /// then never redeems. The page quotes both; this asserts the total it
    /// sends is enough for the inbox to take, and that a short one is refused.
    function test_theRobinhoodTicketCarriesItsOwnFees() public {
        vm.createSelectFork(L1_RPC);
        vm.deal(sender, 10 ether);

        bytes memory inner = abi.encodeWithSelector(bytes4(0x24eb6264), recipient, DELAY, sender, uint256(0));
        uint256 gasLimit = 800_000;
        uint256 maxFee = 0.2 gwei;

        (, bytes memory raw) = INBOX.staticcall(
            abi.encodeWithSelector(bytes4(0xa66b327d), inner.length, block.basefee * 2)
        );
        uint256 submission = (abi.decode(raw, (uint256)) * 3) / 2;
        assertGt(submission, 0, "the inbox quoted no submission fee");

        uint256 total = AMOUNT + submission + gasLimit * maxFee;
        bytes memory ticket = abi.encodeWithSelector(
            bytes4(0x679b6ded), ARRIVAL, AMOUNT, submission, sender, sender, gasLimit, maxFee, inner
        );

        vm.prank(sender);
        (bool ok,) = INBOX.call{value: total}(ticket);
        assertTrue(ok, "the Inbox rejected the ticket the page builds");

        // The failure the fee quote exists to prevent.
        vm.prank(sender);
        (bool short,) = INBOX.call{value: total - 1}(ticket);
        assertFalse(short, "an underfunded ticket must not be accepted");
    }

    // ----------------------------------------------------- Base: OP does not alias

    function test_onBaseTheDepositLandsAsAReversibleSlowPosition() public {
        vm.createSelectFork(BASE_RPC);

        // OP Stack aliases a deposit sender only when msg.sender != tx.origin,
        // so an EOA arrives as itself and needs no hint to be recovered.
        uint256 id = _arrive(sender, sender);

        assertEq(_originOf(id), sender, "the sender kept the reverse");
        (, address from, address to,, uint256 amount) = _pending(id);
        assertEq(from, ARRIVAL, "SlowArrival is the depositor, which is the whole point");
        assertEq(to, recipient);
        assertEq(amount, AMOUNT);

        uint256 before = sender.balance;
        vm.prank(sender);
        (bool ok,) = ARRIVAL.call(abi.encodeWithSelector(bytes4(0x99c5ff88), id, sender));
        assertTrue(ok, "reverse failed");
        assertEq(sender.balance, before + AMOUNT, "the ether came back");

        (uint96 gone,,,,) = _pending(id);
        assertEq(gone, 0, "the pending transfer is cleared");
    }

    function test_onBaseTheRecipientClaimsItAsAnOrdinarySlowTransfer() public {
        vm.createSelectFork(BASE_RPC);
        uint256 id = _arrive(sender, sender);

        vm.warp(block.timestamp + DELAY + 1);
        uint256 before = recipient.balance;
        // `claim` is `msg.sender == pt.to`. The recipient never touches
        // SlowArrival - being bridged is not something they have to know.
        vm.prank(recipient);
        (bool ok,) = SLOW.call(abi.encodeWithSelector(bytes4(0x379607f5), id));
        assertTrue(ok, "the recipient could not claim a bridged lock");
        assertEq(recipient.balance, before + AMOUNT);
    }

    function test_nobodyElseCanReverseIt() public {
        vm.createSelectFork(BASE_RPC);
        uint256 id = _arrive(sender, sender);

        vm.prank(stranger);
        vm.expectRevert(bytes4(keccak256("NotOrigin()")));
        (bool ok,) = ARRIVAL.call(abi.encodeWithSelector(bytes4(0x99c5ff88), id, stranger));
        ok; // the revert is the assertion
    }

    // ------------------------------------------ Robinhood: Nitro aliases everyone

    /// The route that does not work without the hint. A retryable from an L1
    /// EOA arrives as `alias(EOA)`, so the caller SlowArrival sees is an
    /// address with no key on either chain.
    function test_onRobinhoodTheHintIsWhatSavesTheReverse() public {
        vm.createSelectFork(RH_RPC);

        uint256 id = _arrive(_alias(sender), sender);
        assertEq(_originOf(id), sender, "the hint was not honoured; the reverse is stranded");

        uint256 before = sender.balance;
        vm.prank(sender);
        (bool ok,) = ARRIVAL.call(abi.encodeWithSelector(bytes4(0x99c5ff88), id, sender));
        assertTrue(ok, "reverse failed on Robinhood");
        assertEq(sender.balance, before + AMOUNT);
    }

    /// The same arrival with no hint, to show what the page is avoiding: the
    /// position is real and the recipient is still paid, but the reverse
    /// belongs to an address nobody can sign for.
    function test_onRobinhoodWithoutAHintTheReverseIsLostToTheAlias() public {
        vm.createSelectFork(RH_RPC);

        uint256 id = _arrive(_alias(sender), address(0));
        assertEq(_originOf(id), _alias(sender), "this is the defect SlowArrival exists to fix");

        vm.prank(sender);
        vm.expectRevert(bytes4(keccak256("NotOrigin()")));
        (bool ok,) = ARRIVAL.call(abi.encodeWithSelector(bytes4(0x99c5ff88), id, sender));
        ok;
    }

    // -------------------------------------------------------------------- helpers

    /// Runs `arrive` as `caller` would after the bridge delivered it, and
    /// returns the transferId out of the `Arrived` log.
    function _arrive(address caller, address hint) internal returns (uint256 id) {
        vm.deal(caller, AMOUNT + 1 ether);
        vm.recordLogs();
        vm.prank(caller);
        (bool ok,) = ARRIVAL.call{value: AMOUNT}(
            abi.encodeWithSelector(bytes4(0x24eb6264), recipient, DELAY, hint, uint256(0))
        );
        assertTrue(ok, "arrive reverted, which it is written never to do");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Arrived(uint256,address,address,uint256,uint96,bool)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == ARRIVAL && logs[i].topics[0] == topic) return uint256(logs[i].topics[1]);
        }
        revert("no Arrived event - the deposit failed and the ether went to rescue");
    }

    function _originOf(uint256 id) internal view returns (address) {
        (, bytes memory r) = ARRIVAL.staticcall(abi.encodeWithSelector(bytes4(0x794b2a07), id));
        return abi.decode(r, (address));
    }

    function _pending(uint256 id) internal view returns (uint96, address, address, uint256, uint256) {
        (, bytes memory r) = SLOW.staticcall(abi.encodeWithSelector(bytes4(0x6577b86a), id));
        return abi.decode(r, (uint96, address, address, uint256, uint256));
    }

    /// Everything after the 4-byte selector.
    function _tail(bytes memory d) internal pure returns (bytes memory out) {
        out = new bytes(d.length - 4);
        for (uint256 i; i < out.length; ++i) out[i] = d[i + 4];
    }
}
