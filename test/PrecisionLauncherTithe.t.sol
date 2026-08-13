// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {LaunchToken, PrecisionLauncher} from "../src/pools/PrecisionLauncher.sol";

interface IBETH {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function depositTo(address) external payable;
}

/// @dev FORKED, because the tithe is the one thing in this contract that cannot
/// be checked against a mock. Sending ETH somewhere irreversible on the strength
/// of an address someone pasted is exactly the move that loses money, so the
/// burner's behaviour is asserted against the real deployed contract:
///
///   - that the ETH is actually DESTROYED rather than parked, and
///   - that the BETH record lands on the DAO rather than on this contract.
///
/// The second is not a nicety. A plain `transfer` to the burner credits BETH to
/// `msg.sender`, which here would be the launcher - a contract with no way to
/// move an ERC-20 - so the record of every burn the protocol ever makes would be
/// stranded at the one address least able to use it. `depositTo` is what avoids
/// that, and this file is what proves the distinction is real rather than
/// assumed from a selector.
contract PrecisionLauncherTitheTest is Test {
    IBETH constant BETH = IBETH(0x2cb662Ec360C34a45d7cA0126BCd53C9a1fd48F9);
    address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;

    PrecisionPoolFactory factory;
    PrecisionLauncher launcher;

    address creator = address(0xC0FFEE);
    address treasury = address(0x7EA);
    address alice = address(0xA11CE);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")), 25_640_000);
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        launcher = new PrecisionLauncher(factory, treasury);
        vm.deal(alice, 1_000 ether);
    }

    // ------------------------------------------------------- THE PRIMITIVE

    /// The burner must destroy ETH rather than hold it, and must credit the
    /// record where told. Everything downstream rests on this.
    function testBurnerDestroysEthAndCreditsTheNamedAddress() public {
        uint256 burnerEthBefore = address(BETH).balance;
        uint256 daoBethBefore = BETH.balanceOf(DAO);
        uint256 supplyBefore = BETH.totalSupply();

        address sender = address(0xBEEF);
        vm.deal(sender, 5 ether);
        vm.prank(sender);
        BETH.depositTo{value: 5 ether}(DAO);

        // The ETH is GONE - the burner does not retain it.
        assertEq(address(BETH).balance, burnerEthBefore, "burner parked the ETH instead of burning it");
        // The record went to the DAO, not to the sender.
        assertEq(BETH.balanceOf(DAO) - daoBethBefore, 5 ether, "DAO was not credited");
        assertEq(BETH.balanceOf(sender), 0, "sender was credited instead of the named address");
        assertEq(BETH.totalSupply() - supplyBefore, 5 ether, "supply did not record the burn");
    }

    /// The distinction `depositTo` exists for: a plain send credits the SENDER.
    /// Were the launcher to do that, every burn record would be stranded in it.
    function testPlainSendWouldStrandTheRecordOnTheSender() public {
        address sender = address(0xBEEF);
        vm.deal(sender, 1 ether);
        vm.prank(sender);
        (bool ok,) = address(BETH).call{value: 1 ether}("");
        assertTrue(ok, "burner refused a plain send");

        assertEq(BETH.balanceOf(sender), 1 ether, "plain send did not credit the sender");
        assertEq(address(BETH).balance, 0, "burner parked the ETH");
    }

    // ----------------------------------------------------------- THE TITHE

    /// The whole path, end to end, against the real burner.
    function testCollectedFeesTitheToEthereum() public {
        (address t, address p) =
            launcher.launch("Tithe", "TITHE", "", 1_000_000_000 ether, 0, 3 ether, creator);
        LaunchToken token = LaunchToken(t);
        PrecisionPool pool = PrecisionPool(payable(p));

        vm.startPrank(alice);
        pool.swapExactIn{value: 40 ether}(address(0), 40 ether, 0, alice);
        token.approve(address(pool), type(uint256).max);
        pool.swapExactIn(address(token), token.balanceOf(alice) / 2, 0, alice);
        vm.stopPrank();

        uint256 daoBethBefore = BETH.balanceOf(DAO);
        uint256 burnerEthBefore = address(BETH).balance;
        uint256 creatorBefore = creator.balance;
        uint256 treasuryBefore = treasury.balance;
        uint256 accrued = pool.creatorOwed0();

        (uint256 creatorEth, uint256 protocolEth, uint256 titheEth, uint256 tokensBurned,) =
            launcher.collectFees(t);

        // Every wei is accounted for and none is retained.
        assertEq(creatorEth + protocolEth + titheEth, accrued, "the split lost or invented wei");
        assertEq(creator.balance - creatorBefore, creatorEth, "creator underpaid");
        assertEq(treasury.balance - treasuryBefore, protocolEth, "treasury underpaid");

        // A literal tenth, burned, with the record on the DAO.
        assertEq(titheEth, accrued / 10, "tithe is not a tenth");
        assertEq(protocolEth, titheEth, "treasury and tithe are not equal tenths");
        assertEq(creatorEth, titheEth * 8, "creator is not eight tenths");
        assertEq(BETH.balanceOf(DAO) - daoBethBefore, titheEth, "DAO record does not match the tithe");
        assertEq(address(BETH).balance, burnerEthBefore, "tithe was parked, not burned");

        // And the launcher kept neither the ETH nor the record.
        assertEq(BETH.balanceOf(address(launcher)), 0, "launcher was credited the burn record");
        assertGt(tokensBurned, 0, "token side did not burn");
    }

    /// The tithe compounds across sweeps rather than being a one-off.
    function testTitheAccumulatesAcrossSweeps() public {
        (address t, address p) = launcher.launch("T", "T", "", 1_000_000_000 ether, 0, 3 ether, creator);
        PrecisionPool pool = PrecisionPool(payable(p));

        uint256 daoBefore = BETH.balanceOf(DAO);
        uint256 total;

        for (uint256 i; i < 3; ++i) {
            vm.prank(alice);
            pool.swapExactIn{value: 10 ether}(address(0), 10 ether, 0, alice);
            (,, uint256 titheEth,,) = launcher.collectFees(t);
            assertGt(titheEth, 0, "a sweep tithed nothing");
            total += titheEth;
        }

        assertEq(BETH.balanceOf(DAO) - daoBefore, total, "record drifted from the sum of tithes");
    }

    /// THE FALLBACK, which nothing else reaches. Every other test here runs
    /// against the real burner, which works - so the branch that exists for the
    /// day it does not is otherwise dead code, and dead code in a path that can
    /// wedge the fee stream is precisely the defect this contract already had
    /// once. A reverting burner is etched in to force it.
    ///
    /// The tithe must still leave, and the sweep must still succeed: the RECORD
    /// is what gets sacrificed, never the BURN and never the creator's income.
    function testASeizedBurnerCannotWedgeTheSweep() public {
        (address t, address p) = launcher.launch("F", "F", "", 1_000_000_000 ether, 0, 3 ether, creator);
        PrecisionPool pool = PrecisionPool(payable(p));

        vm.prank(alice);
        pool.swapExactIn{value: 20 ether}(address(0), 20 ether, 0, alice);

        // PUSH1 0, PUSH1 0, REVERT - refuses everything, including a plain send.
        vm.etch(address(BETH), hex"60006000fd");

        uint256 launcherBefore = address(launcher).balance;
        uint256 burnerBefore = address(BETH).balance;
        uint256 creatorBefore = creator.balance;

        (uint256 creatorEth,, uint256 titheEth,,) = launcher.collectFees(t);

        assertGt(titheEth, 0, "nothing was tithed");
        assertGt(creatorEth, 0, "creator income was collateral damage");
        assertEq(creator.balance - creatorBefore, creatorEth, "creator underpaid");

        // The ETH left the launcher and reached the burner, forced past its
        // refusal. No record is minted - that is the accepted cost.
        assertEq(address(launcher).balance, launcherBefore, "tithe was retained");
        assertEq(address(BETH).balance - burnerBefore, titheEth, "tithe did not reach the burner");
    }

/// THE ACTUAL DEPLOY CONFIGURATION: treasury is the Zorg Moloch DAO, which
    /// is also `TITHE_RECORD`. So the DAO takes 20% of the ETH side - a tenth
    /// as ETH and a tenth as the BETH record of the burn.
    ///
    /// Worth a forked test rather than an assumption: the DAO is a minimal
    /// proxy to a 21 KB implementation, so whether it accepts a plain ETH
    /// transfer is a property of code nobody here wrote. `forceSafeTransferETH`
    /// means a refusal cannot wedge the sweep either way, but a treasury that
    /// silently needs the SELFDESTRUCT path on every collection is worth
    /// knowing about before it is immutable.
    function testTreasuryAsTheDaoTakesBothShares() public {
        PrecisionLauncher dao = new PrecisionLauncher(factory, DAO);
        (address t, address p) = dao.launch("D", "D", "", 1_000_000_000 ether, 0, 3 ether, creator);
        PrecisionPool pool = PrecisionPool(payable(p));

        vm.prank(alice);
        pool.swapExactIn{value: 30 ether}(address(0), 30 ether, 0, alice);

        uint256 ethBefore = DAO.balance;
        uint256 bethBefore = BETH.balanceOf(DAO);

        (, uint256 protocolEth, uint256 titheEth,,) = dao.collectFees(t);

        assertGt(protocolEth, 0, "treasury share vanished");
        assertEq(protocolEth, titheEth, "the DAO's two tenths are not equal");
        assertEq(DAO.balance - ethBefore, protocolEth, "DAO did not receive the treasury share as ETH");
        assertEq(BETH.balanceOf(DAO) - bethBefore, titheEth, "DAO did not receive the burn record");
    }

    /// WHICH PATH THE DAO IS PAID BY. `forceSafeTransferETH` tries an ordinary
    /// send under a gas stipend first and only force-pushes via a
    /// self-destructing helper if that fails. The distinction matters for a
    /// contract treasury: the forced path delivers ETH WITHOUT running the
    /// recipient's code, so a DAO that needs its `receive()` to fire in order
    /// to account for income would silently stop being notified.
    ///
    /// Nothing breaks either way - the ETH lands, and that is what makes the
    /// sweep ungriefable - but the answer should be known before the address is
    /// immutable rather than discovered from a treasury that looks emptier than
    /// the chain says it is.
    function testDaoAcceptsEthOnTheOrdinaryPath() public {
        // Solady's stipend for the non-griefing attempt.
        (bool ok,) = DAO.call{value: 1 ether, gas: 100_000}("");
        assertTrue(ok, "DAO needs the forced path - its receive() hook will not run on payment");
    }

    /// A burner that CONSUMES gas rather than refusing it.
    ///
    /// L-1 from the external review: `testASeizedBurnerCannotWedgeTheSweep`
    /// passed for a NARROWER reason than its name claimed, so a reader
    /// auditing by test name would have believed it covered this case too.
    ///
    /// This is the case `testASeizedBurnerCannotWedgeTheSweep` does not reach,
    /// and the distinction is the whole finding. That test etches `60006000fd`
    /// - five bytes that revert immediately and hand every unspent drop of gas
    /// back. A seized contract need not be so polite. `5b600056` is
    /// `JUMPDEST PUSH1 0 JUMP`: it spins until the gas it was given is gone.
    ///
    /// Uncapped, that is fatal and permanent. EIP-150 gives the callee 63/64 of
    /// what remains, so it burns 63/64 and `forceSafeTransferETH` is left with
    /// 1/64 - not enough to CREATE the self-destructing contract - and the
    /// sweep reverts out of gas at EVERY gas limit, because raising the limit
    /// raises the callee's consumption in proportion. `collectFees` is the only
    /// way to clear `creatorOwed`, so that freezes the fee stream and the token
    /// burn for every token this launcher ever launched.
    ///
    /// `TITHE_GAS` is what makes it survivable: the callee's consumption is
    /// pinned to a constant, so every extra gas the caller supplies lands in
    /// the leftover instead. "Fails at all limits" becomes "succeeds at any
    /// sufficient limit", which is the property that matters.
    function testAGasBurningBurnerCannotWedgeTheSweep() public {
        (address t, address p) = launcher.launch("H", "H", "", 1_000_000_000 ether, 0, 3 ether, creator);
        PrecisionPool pool = PrecisionPool(payable(p));

        vm.prank(alice);
        pool.swapExactIn{value: 20 ether}(address(0), 20 ether, 0, alice);

        // JUMPDEST, PUSH1 0, JUMP - an infinite loop that eats whatever it is given.
        vm.etch(address(BETH), hex"5b600056");

        uint256 launcherBefore = address(launcher).balance;
        uint256 burnerBefore = address(BETH).balance;
        uint256 creatorBefore = creator.balance;

        (uint256 creatorEth,, uint256 titheEth,,) = launcher.collectFees(t);

        assertGt(titheEth, 0, "nothing was tithed");
        assertGt(creatorEth, 0, "creator income was collateral damage");
        assertEq(creator.balance - creatorBefore, creatorEth, "creator underpaid");

        // Forced past the loop. The record is lost - that is the accepted cost,
        // and the same one a refusing burner extracts.
        assertEq(address(launcher).balance, launcherBefore, "tithe was retained");
        assertEq(address(BETH).balance - burnerBefore, titheEth, "tithe did not reach the burner");
    }

    /// The sweep must report WHICH path the tithe took, so a burner that
    /// silently stops minting records is detectable rather than invisible.
    /// Without this the cap trades a liveness risk for an unobservable
    /// correctness one: a gas repricing that lifts `depositTo` past `TITHE_GAS`
    /// would degrade every future tithe to an unrecorded burn with no signal.
    function testTheSweepReportsWhetherTheRecordWasMinted() public {
        (address t, address p) = launcher.launch("W", "W", "", 1_000_000_000 ether, 0, 3 ether, creator);
        PrecisionPool pool = PrecisionPool(payable(p));

        vm.prank(alice);
        pool.swapExactIn{value: 20 ether}(address(0), 20 ether, 0, alice);

        // Healthy burner: the record mints, and the event says so.
        vm.recordLogs();
        launcher.collectFees(t);
        assertTrue(_lastTitheRecorded(), "a healthy burner reported an unrecorded tithe");

        vm.prank(alice);
        pool.swapExactIn{value: 20 ether}(address(0), 20 ether, 0, alice);

        // Seized burner: the ETH still burns, and the event reports the loss.
        vm.etch(address(BETH), hex"60006000fd");
        vm.recordLogs();
        launcher.collectFees(t);
        assertFalse(_lastTitheRecorded(), "a seized burner reported a record it never minted");
    }

    /// @dev Pulls `titheRecorded` out of the last `FeesCollected`. It is the
    ///      final word of the non-indexed data, and `token` is the only indexed
    ///      field, so topic0 alone identifies the event.
    function _lastTitheRecorded() internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("FeesCollected(address,uint256,uint256,uint256,uint256,bool)");
        for (uint256 i = logs.length; i != 0; --i) {
            Vm.Log memory l = logs[i - 1];
            if (l.topics.length != 0 && l.topics[0] == sig) {
                (,,,, bool recorded) =
                    abi.decode(l.data, (uint256, uint256, uint256, uint256, bool));
                return recorded;
            }
        }
        revert("no FeesCollected emitted");
    }

    /// A launch with no volume must tithe nothing and still not revert.
    function testNoVolumeTithesNothing() public {
        (address t,) = launcher.launch("Q", "Q", "", 1_000_000_000 ether, 0, 3 ether, creator);

        uint256 daoBefore = BETH.balanceOf(DAO);
        (uint256 c, uint256 pr, uint256 ti, uint256 b,) = launcher.collectFees(t);

        assertEq(c + pr + ti + b, 0, "fees materialised from nothing");
        assertEq(BETH.balanceOf(DAO), daoBefore, "tithed on zero volume");
    }
}
