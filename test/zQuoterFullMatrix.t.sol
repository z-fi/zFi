// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";
import {zQuoterV4} from "../src/zQuoterV4.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @dev Exhaustive matrix over every pair in the zSwap dropdown, in BOTH
/// directions, that does not merely check the quote is plausible but actually
/// EXECUTES the swap and measures the tokens received.
///
/// Motivation: every bug in this saga looked fine at quote time and failed at
/// execution — the V4 protocol-fee misread produced confident inflated numbers,
/// and the partial-fill bug produced confident dust. A quote-only check would
/// have passed both. The contract here is: for any pair, EITHER we produce a
/// route that executes and delivers at least the promised minimum, OR we refuse
/// to quote. A route that builds but reverts is a failure.
contract zQuoterFullMatrixTest is Test {
    /// @dev Defaults so the suite runs without tribal knowledge. Both are
    /// overridable by env. The block is chosen to be AFTER the currently
    /// deployed zQuoter/zRouter, so live-address tests are possible here.
    string constant DEFAULT_RPC = "https://gateway.tenderly.co/public/mainnet";
    uint256 constant DEFAULT_FORK_BLOCK = 25_906_900;

    zQuoter q;

    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    /// zQuoter hardcodes this; the helper is etched here to mirror deployment.
    address constant V4_HELPER = 0x00005d8a3675b7b00BA172Aa85485Fc5D23121B6;

    address constant ETH = address(0);
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    address[8] toks = [ETH, WETH, WSTETH, RETH, WBTC, USDC, USDT, BOLD];
    string[8] syms = ["ETH", "WETH", "wstETH", "rETH", "WBTC", "USDC", "USDT", "BOLD"];
    // ~$40 notional each
    uint256[8] amts = [
        21052631578947368,
        21052631578947368,
        17391304347826086,
        18604651162790697,
        60000,
        40000000,
        40000000,
        40000000000000000000
    ];

    address user = address(0xB0B);

    /// @dev Outcome of one pair. Returned rather than accumulated in storage:
    /// the loop rolls the fork back between pairs (see the test below), and a
    /// counter in storage is state like any other - it would be rolled back too,
    /// and the totals would report the last pair instead of all of them.
    enum R {
        ROUTED,
        REFUSED,
        BROKE
    }

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string(DEFAULT_RPC)), vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));
        vm.etch(V4_HELPER, address(new zQuoterV4()).code);
        // Against the DEPLOYED quoter when ZQUOTER names one, otherwise a local
        // build. The default proves the source is right; it does not prove the
        // bytecode at a live address behaves the way the source says, and those
        // are different claims - the deployed artifact is built with a different
        // profile (runs=20, yul=false) to fit EIP-170. Point this at a fresh
        // deployment to check the thing users will actually route through:
        //   ZQUOTER=0x... forge test --match-test test_fullMatrix_executes
        address dep = vm.envOr("ZQUOTER", address(0));
        if (dep == address(0)) {
            // The DEPLOYED quoter when ZQUOTER names one, a local build otherwise.
        //
        // The default proves the source is right; it does not prove the bytecode
        // at a live address behaves the way the source says, and those are
        // different claims - the shippable artifact is built with a different
        // profile (runs=20, yul=false) to fit EIP-170, so this suite has always
        // exercised a differently-optimised build than users route through.
        // Point it at a deployment to close that:
        //   ZQUOTER=0x... FORK_BLOCK=<after deploy> forge test --match-test test_fullMatrix
        address dep = vm.envOr("ZQUOTER", address(0));
        if (dep == address(0)) {
            q = new zQuoter();
        } else {
            require(dep.code.length != 0, "ZQUOTER has no code at this fork block");
            q = zQuoter(payable(dep));
            emit log_named_address("quoter under test (deployed)", dep);
        }
        } else {
            require(dep.code.length != 0, "ZQUOTER has no code at this fork block");
            q = zQuoter(payable(dep));
            emit log_named_address("quoter under test (deployed)", dep);
        }
    }

    function _fund(address t, uint256 amt) internal {
        if (t == ETH) {
            vm.deal(user, amt * 2);
            return;
        }
        if (t == WETH) {
            // WETH9 computes totalSupply() as address(this).balance rather than reading a
            // storage slot, so `deal(..., adjustSupply: true)` cannot find a slot to write
            // and aborts with "No storage use detected for target". Set the balance without
            // the supply probe, then top up WETH's own ETH by the same amount so its
            // supply == backing identity still holds and any downstream withdraw() is
            // funded. Done with cheatcodes rather than a pranked deposit() because prank
            // rewrites msg.sender but leaves the value coming from the test contract.
            deal(WETH, user, amt * 2);
            vm.deal(WETH, WETH.balance + amt * 2);
        } else {
            deal(t, user, amt * 2, true);
        }
        // Low-level, and the return value is DELIBERATELY ignored. USDT's
        // approve returns nothing at all, so `IERC20(t).approve(...)` reverts
        // decoding a bool from empty returndata - not in the router, in this
        // helper. That killed the whole test at the first pair with USDT as the
        // INPUT (USDT->ETH, i=6), which is why the run reported a bare
        // "EvmError: Revert" and the last two rows of the matrix never ran.
        // Approving from zero, so USDT's other quirk - a non-zero-to-non-zero
        // approve reverting - does not arise.
        vm.prank(user);
        (bool okApprove,) = t.call(abi.encodeWithSignature("approve(address,uint256)", ZROUTER, type(uint256).max));
        require(okApprove, "approve failed");
    }

    function _bal(address t, address who) internal view returns (uint256) {
        return t == ETH ? who.balance : IERC20(t).balanceOf(who);
    }

    /// Quote, then execute, then verify the recipient actually received it.
    function _run(uint256 i, uint256 j) internal returns (R) {
        address tin = toks[i];
        address tout = toks[j];
        uint256 amt = amts[i];
        string memory pair = string.concat(syms[i], "->", syms[j]);

        bytes memory cd;
        uint256 msgVal;
        uint256 expected;
        try q.buildBestSwapViaETHMulticall(user, user, false, tin, tout, amt, 100, type(uint256).max) returns (
            zQuoter.Quote memory a, zQuoter.Quote memory b, bytes[] memory, bytes memory mc, uint256 mv
        ) {
            expected = b.amountOut > 0 ? b.amountOut : a.amountOut;
            cd = mc;
            msgVal = mv;
        } catch {
            emit log_named_string(pair, "REFUSED at quote (acceptable)");
            return R.REFUSED;
        }

        if (cd.length == 0 || expected == 0) {
            emit log_named_string(pair, "no route (acceptable)");
            return R.REFUSED;
        }

        _fund(tin, amt + msgVal);
        uint256 before = _bal(tout, user);

        vm.prank(user);
        (bool ok,) = ZROUTER.call{value: msgVal}(cd);

        if (!ok) {
            emit log_named_string(pair, "!!! QUOTED BUT EXECUTION REVERTED");
            return R.BROKE;
        }

        uint256 got = _bal(tout, user) - before;
        if (got == 0) {
            emit log_named_string(pair, "!!! EXECUTED BUT DELIVERED NOTHING");
            return R.BROKE;
        }
        // Delivered must be within 5% of the quote (slippage bound is 1%).
        if (got * 100 < expected * 95) {
            emit log_named_string(pair, "!!! DELIVERED FAR LESS THAN QUOTED");
            emit log_named_uint("  quoted", expected);
            emit log_named_uint("  got   ", got);
            return R.BROKE;
        }
        return R.ROUTED;
    }

    /// @dev EVERY PAIR STARTS FROM THE SAME CLEAN FORK.
    ///
    /// This is not tidiness, it is the difference between the test measuring
    /// the router and measuring itself. A forge test is ONE transaction, and
    /// the V4 path writes transient storage - which clears at the end of a
    /// TRANSACTION, not at the end of a call. So the second swap in a test ran
    /// against tstore slots the first swap had already set, and reverted.
    ///
    /// It reported that as "!!! QUOTED BUT EXECUTION REVERTED", the loudest
    /// message it has, on ten major pairs including ETH->USDC - all of which
    /// execute perfectly when they are the first swap in their own test. The
    /// suite then aborted outright partway through the fifth row, so half the
    /// matrix never ran at all. An exhaustive check that fabricates failures
    /// and then stops early is worse than no check: the reason this file exists
    /// is that a real execution bug hid behind a confident quote, and that is
    /// exactly the signal these false positives were burying.
    ///
    /// `revertToState` restores transient storage along with everything else,
    /// which is what makes each pair a fresh transaction. The snapshot is taken
    /// once and reused; the counters live in memory because storage is state and
    /// would be rolled back with it.
    function test_fullMatrix_executes() public {
        uint256 routed;
        uint256 refused;
        uint256 broke;

        uint256 clean = vm.snapshotState();
        for (uint256 i; i < 8; ++i) {
            for (uint256 j; j < 8; ++j) {
                if (i == j) continue;
                vm.revertToState(clean);
                R r = _run(i, j);
                if (r == R.ROUTED) routed++;
                else if (r == R.REFUSED) refused++;
                else broke++;
            }
        }
        emit log_named_uint("routed+executed ", routed);
        emit log_named_uint("refused (safe)  ", refused);
        emit log_named_uint("BROKEN (bad)    ", broke);
        assertEq(broke, 0, "some pairs quoted a route that did not execute");
        assertGt(routed, 40, "expected most pairs to route");
    }
}
