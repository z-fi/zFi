// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";
import {zQuoterV4} from "../src/zQuoterV4.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @dev Exhaustive router soundness matrix.
///
/// THE CONTRACT UNDER TEST: for any request, the router must either
///   (a) produce a route that EXECUTES and delivers close to what it quoted, or
///   (b) refuse to quote.
/// A route that builds but reverts, or delivers materially less than promised,
/// is a failure. Quote-plausibility alone is not enough — every bug in this
/// saga passed a quote-only check:
///   * the V4 protocol-fee misread returned confident INFLATED numbers
///   * the partial-fill bug returned confident DUST (122 units for ~$40)
/// Both produced routes that reverted or delivered nothing on execution.
///
/// Dimensions covered here that the first matrix missed:
///   * exact-OUT as well as exact-in (the partial-fill bug lived in the
///     exact-in branch precisely because exact-out was already guarded)
///   * three trade sizes (pool selection and tick crossing are size-dependent;
///     the inflated V4 pool was detectable by being size-INvariant)
///   * all four builders, matching what zSwap's cascade actually calls
contract zQuoterExhaustiveTest is Test {
    /// @dev Defaults so the suite runs without tribal knowledge. Both are
    /// overridable by env. The block is chosen to be AFTER the currently
    /// deployed zQuoter/zRouter, so live-address tests are possible here.
    string constant DEFAULT_RPC = "https://gateway.tenderly.co/public/mainnet";
    uint256 constant DEFAULT_FORK_BLOCK = 25_640_000;

    zQuoter q;

    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant V4_HELPER = 0x00005d8a3675b7b00BA172Aa85485Fc5D23121B6;

    address constant _ETH = address(0);
    address constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant _WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant _RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address constant _WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant _USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant _BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    address[8] toks = [_ETH, _WETH, _WSTETH, _RETH, _WBTC, _USDC, _USDT, _BOLD];
    string[8] syms = ["ETH", "WETH", "wstETH", "rETH", "WBTC", "USDC", "USDT", "BOLD"];
    // whole-unit value in USD, used to derive comparable notionals
    uint256[8] usd = [1900, 1900, 2300, 2150, 67000, 1, 1, 1];
    uint8[8] dec = [18, 18, 18, 18, 8, 6, 6, 18];

    address user;

    receive() external payable {}
    uint256 routed;
    uint256 refused;
    uint256 broke;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string(DEFAULT_RPC)), vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));
        vm.etch(V4_HELPER, address(new zQuoterV4()).code);
        q = new zQuoter();
        user = address(this);
    }

    function _amt(uint256 i, uint256 notionalUsd) internal view returns (uint256) {
        return notionalUsd * (10 ** dec[i]) / usd[i];
    }

    function _fund(address t, uint256 amt) internal {
        if (t == _ETH) {
            vm.deal(user, amt * 3 + 1 ether);
        } else {
            // no totalSupply adjustment: forge cannot locate the slot on some tokens
            deal(t, user, amt * 3);
            // Low-level, return value DELIBERATELY ignored. USDT's approve returns
            // nothing, so `IERC20(t).approve(...)` reverts decoding a bool from
            // empty returndata - in this helper, not in the router. That is the
            // bare "EvmError: Revert" that killed these suites, and it fires on
            // the first pair with USDT as the INPUT, so everything after it in
            // the loop never ran.
            // Zero FIRST. USDT refuses a non-zero -> non-zero allowance change,
            // and this helper runs three times per pair (small/mid/large), so the
            // second approve of the run reverted with a bare "approve failed".
            t.call(abi.encodeWithSignature("approve(address,uint256)", ZROUTER, uint256(0)));
            (bool okApprove,) =
                t.call(abi.encodeWithSignature("approve(address,uint256)", ZROUTER, type(uint256).max));
            require(okApprove, "approve failed");
        }
    }

    function _bal(address t, address w) internal view returns (uint256) {
        return t == _ETH ? w.balance : IERC20(t).balanceOf(w);
    }

    /// Execute `cd` and verify delivery. `want` is the quoted output (exact-in)
    /// or the exact target (exact-out).
    function _exec(
        string memory label,
        address tin,
        address tout,
        uint256 spend,
        bytes memory cd,
        uint256 mv,
        uint256 want
    ) internal {
        if (cd.length == 0 || want == 0) {
            refused++;
            return;
        }
        _fund(tin, spend + mv);
        uint256 before = _bal(tout, user);
        (bool ok,) = ZROUTER.call{value: mv}(cd);
        if (!ok) {
            broke++;
            emit log_named_string(label, "!!! QUOTED BUT REVERTED");
            return;
        }
        uint256 got = _bal(tout, user) - before;
        if (got == 0) {
            broke++;
            emit log_named_string(label, "!!! DELIVERED NOTHING");
            return;
        }
        if (got * 100 < want * 90) {
            broke++;
            emit log_named_string(label, "!!! DELIVERED FAR LESS THAN QUOTED");
            emit log_named_uint("  want", want);
            emit log_named_uint("  got ", got);
            return;
        }
        routed++;
    }

    function _exactIn(uint256 i, uint256 j, uint256 notional) internal {
        uint256 amt = _amt(i, notional);
        string memory label = string.concat(syms[i], "->", syms[j], " in $", vm.toString(notional));
        try q.buildBestSwapViaETHMulticall(user, user, false, toks[i], toks[j], amt, 200, type(uint256).max) returns (
            zQuoter.Quote memory a, zQuoter.Quote memory b, bytes[] memory, bytes memory mc, uint256 mv
        ) {
            _exec(label, toks[i], toks[j], amt, mc, mv, b.amountOut > 0 ? b.amountOut : a.amountOut);
        } catch {
            refused++;
        }
    }

    function _exactOut(uint256 i, uint256 j, uint256 notional) internal {
        uint256 want = _amt(j, notional);
        string memory label = string.concat(syms[i], "->", syms[j], " OUT $", vm.toString(notional));
        try q.buildBestSwapViaETHMulticall(user, user, true, toks[i], toks[j], want, 200, type(uint256).max) returns (
            zQuoter.Quote memory a, zQuoter.Quote memory, bytes[] memory, bytes memory mc, uint256 mv
        ) {
            // fund generously: exact-out spends up to amountIn plus slippage
            _exec(label, toks[i], toks[j], a.amountIn * 2 + 1, mc, mv, want);
        } catch {
            refused++;
        }
    }

    function _split(uint256 i, uint256 j, uint256 notional) internal {
        uint256 amt = _amt(i, notional);
        string memory label = string.concat(syms[i], "->", syms[j], " split");
        try q.buildSplitSwap(user, toks[i], toks[j], amt, 300, type(uint256).max) returns (
            zQuoter.Quote[2] memory legs, bytes memory mc, uint256 mv
        ) {
            _exec(label, toks[i], toks[j], amt, mc, mv, legs[0].amountOut + legs[1].amountOut);
        } catch {
            refused++;
        }
    }

    function _hop3(uint256 i, uint256 j, uint256 notional) internal {
        uint256 amt = _amt(i, notional);
        string memory label = string.concat(syms[i], "->", syms[j], " 3hop");
        try q.build3HopMulticall(user, false, toks[i], toks[j], amt, 300, type(uint256).max) returns (
            zQuoter.Quote memory,
            zQuoter.Quote memory,
            zQuoter.Quote memory c,
            bytes[] memory,
            bytes memory mc,
            uint256 mv
        ) {
            _exec(label, toks[i], toks[j], amt, mc, mv, c.amountOut);
        } catch {
            refused++;
        }
    }

    function _hybrid(uint256 i, uint256 j, uint256 notional) internal {
        uint256 amt = _amt(i, notional);
        string memory label = string.concat(syms[i], "->", syms[j], " hybrid");
        try q.buildHybridSplit(user, toks[i], toks[j], amt, 300, type(uint256).max) returns (
            zQuoter.Quote[2] memory legs, bytes memory mc, uint256 mv
        ) {
            _exec(label, toks[i], toks[j], amt, mc, mv, legs[0].amountOut + legs[1].amountOut);
        } catch {
            refused++;
        }
    }

    /// Roll the fork back to a clean pre-swap state, preserving the tallies.
    ///
    /// A forge test is ONE transaction and the V4 path writes transient storage,
    /// which clears per TRANSACTION rather than per call. So the second swap in a
    /// loop like the ones below ran against slots the first had already set and
    /// reverted, and the whole test died with a bare "EvmError: Revert" partway
    /// through - five suites here, all reporting the router as broken while every
    /// pair executes correctly on its own. `revertToState` restores transient
    /// storage along with everything else, which is what makes each iteration a
    /// fresh transaction. The counters are storage and would be rolled back with
    /// it, so they are carried across by hand.
    function _fresh(uint256 snap) internal {
        (uint256 r, uint256 rf, uint256 bk) = (routed, refused, broke);
        vm.revertToState(snap);
        (routed, refused, broke) = (r, rf, bk);
    }

    function _report() internal {
        emit log_named_uint("executed OK    ", routed);
        emit log_named_uint("refused (safe) ", refused);
        emit log_named_uint("BROKEN         ", broke);
        assertEq(broke, 0, "router quoted a route that did not deliver");
    }

    function test_exactIn_allPairs_smallMidLarge() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 8; ++i) {
            for (uint256 j; j < 8; ++j) {
                if (i == j) continue;
                _fresh(snap);
                _exactIn(i, j, 1);
                _exactIn(i, j, 40);
                _exactIn(i, j, 5000);
            }
        }
        _report();
        assertGt(routed, 100, "most pairs should route at most sizes");
    }

    function test_exactOut_allPairs() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 8; ++i) {
            for (uint256 j; j < 8; ++j) {
                if (i == j) continue;
                _fresh(snap);
                _exactOut(i, j, 40);
            }
        }
        _report();
    }

    function test_splitBuilder_allPairs() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 8; ++i) {
            for (uint256 j; j < 8; ++j) {
                if (i == j) continue;
                _fresh(snap);
                _split(i, j, 5000);
            }
        }
        _report();
    }

    function test_3hopBuilder_allPairs() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 8; ++i) {
            for (uint256 j; j < 8; ++j) {
                if (i == j) continue;
                _fresh(snap);
                _hop3(i, j, 40);
            }
        }
        _report();
    }

    /// @dev zSwap considers this fourth exact-in candidate for non-trivial trades.
    ///      Exercise every curated pair rather than only the ETH->USDT regression.
    function test_hybridBuilder_allPairs() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 8; ++i) {
            for (uint256 j; j < 8; ++j) {
                if (i == j) continue;
                _fresh(snap);
                _hybrid(i, j, 5000);
            }
        }
        _report();
    }
}
