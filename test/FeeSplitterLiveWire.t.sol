// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";

/// @notice The two transactions the multisig was handed, rehearsed against the
///         deployed splitter holding real ether.
///
///         `setSplit` is signed once and decides where every protocol fee this
///         system ever collects goes. It is worth knowing that the exact
///         calldata handed over does what it is supposed to, rather than
///         finding out during a multisig ceremony. The first transaction has
///         since been executed on mainnet; the tests now rehearse both it and
///         the permissionless release that remains.
interface IFeeSplitter {
    function setSplit(address[] calldata payees, uint256[] calldata shares) external;
    function release() external;
    function payeeCount() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function owner() external view returns (address);
    function split() external view returns (address[] memory, uint256[] memory);
}

contract FeeSplitterLiveWireTest is Test {
    IFeeSplitter constant FS = IFeeSplitter(0x000000aA142133107c7D2664F900f80e28BbfFbd);
    address constant MULTISIG = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;
    address stranger = address(0xDEADBEEF);

    // The literal bytes being handed over, not a re-encoding of them.
    bytes constant SET_SPLIT_CALLDATA =
        hex"ac246ee7"
        hex"0000000000000000000000000000000000000000000000000000000000000040"
        hex"0000000000000000000000000000000000000000000000000000000000000080"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"000000000000000000000000006cd14f36f65ecbb29b2519ccbe63a0dc8549f2"
        hex"0000000000000000000000000000000000000000000000000000000000000001"
        hex"0000000000000000000000000000000000000000000000000000000000000001";

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")));
        vm.deal(stranger, 1 ether);
    }

    /// The state it is in right now, stated so a later run shows it moved.
    /// The first transaction HAS been signed and mined: as of 2026-08-28 the
    /// splitter holds a split - exactly the one `SET_SPLIT_CALLDATA` describes -
    /// and what waits is only the release, which nobody has triggered yet.
    function test_todayTheSplitIsSetAndEtherWaits() public {
        assertEq(FS.owner(), MULTISIG, "the owner is not the multisig");
        assertEq(FS.payeeCount(), 1, "the split is not what was signed");
        (address[] memory p, uint256[] memory w) = FS.split();
        assertEq(p.length, 1, "more than one payee");
        assertEq(p[0], MULTISIG, "the payee is not the multisig");
        assertEq(w[0], 1, "the share is not one");
        assertGt(address(FS).balance, 0, "nothing is waiting to be released");
    }

    /// The handoff calldata, executed verbatim by the multisig.
    function test_theSetSplitCalldataDoesWhatItSays() public {
        vm.prank(MULTISIG);
        (bool ok,) = address(FS).call(SET_SPLIT_CALLDATA);
        assertTrue(ok, "setSplit reverted");

        (address[] memory p, uint256[] memory w) = FS.split();
        assertEq(p.length, 1, "more than one payee");
        assertEq(p[0], MULTISIG, "the payee is not the multisig");
        assertEq(w[0], 1);
        assertEq(FS.totalShares(), 1);
    }

    /// And nobody else can sign it. The whole protocol share rests on this.
    function test_aStrangerCannotSetTheSplit() public {
        vm.prank(stranger);
        (bool ok,) = address(FS).call(SET_SPLIT_CALLDATA);
        assertFalse(ok, "anyone could redirect the protocol fees");
    }

    /// The second transaction: the ether actually leaves, in full, to the
    /// multisig - and anyone may trigger it once the split exists.
    function test_releasePaysTheWholeBalanceToTheMultisig() public {
        vm.prank(MULTISIG);
        (bool ok,) = address(FS).call(SET_SPLIT_CALLDATA);
        assertTrue(ok);

        uint256 held = address(FS).balance;
        uint256 before = MULTISIG.balance;

        // Permissionless, so a stranger triggering it must still pay the payee.
        vm.prank(stranger);
        FS.release();

        emit log_named_decimal_uint("released to the multisig", held, 18);
        assertEq(MULTISIG.balance - before, held, "the multisig was not paid in full");
        assertEq(address(FS).balance, 0, "ether was left behind");
        assertEq(stranger.balance, 1 ether, "the caller took a cut");
    }

    /// Fees that arrive AFTER the split is set need no further ceremony - the
    /// multisig signs once, and every later sweep is a permissionless release.
    function test_laterFeesNeedNoSecondCeremony() public {
        vm.prank(MULTISIG);
        (bool ok,) = address(FS).call(SET_SPLIT_CALLDATA);
        assertTrue(ok);
        vm.prank(stranger);
        FS.release();

        vm.deal(address(FS), 0.25 ether);
        uint256 before = MULTISIG.balance;
        vm.prank(stranger);
        FS.release();
        assertEq(MULTISIG.balance - before, 0.25 ether, "a later fee did not flow through");
    }
}
