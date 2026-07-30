// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {zQuoter} from "../src/zQuoter.sol";

/// Executes EVERY venue that produces a quote, not just the one that wins.
///
/// The existing fork-exec suite calls buildBestSwap and executes the winner, so
/// a venue is only ever execution-tested on blocks where it happens to price
/// best. That is liquidity-dependent and moves block to block: at the repo's old
/// pin UNI_V4 won WBTC->ETH and execution failed; at a current block UNI_V3 wins,
/// V4 is never built, and the suite goes green with the V4 path untested. The
/// failure was not fixed, it was hidden by a liquidity shift - and zSwap's
/// builders will route a user into V4 the moment V4 prices best again.
///
/// So: quote the pair, then build and execute calldata for every venue that
/// returned a price, independently of ranking.
contract QuoterExposed is zQuoter {
    function buildFor(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 amountLimit,
        uint256 deadline,
        Quote memory q
    ) external view returns (bytes memory) {
        return _buildSwapFromQuote(to, exactOut, tokenIn, tokenOut, swapAmount, amountLimit, deadline, q);
    }
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract zQuoterPerVenueExecTest is Test {
    string constant DEFAULT_RPC = "https://gateway.tenderly.co/public/mainnet";
    uint256 constant DEFAULT_FORK_BLOCK = 25_640_000;

    address constant ROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant ETH = address(0);
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    QuoterExposed q;

    string[8] names = ["UNI_V2", "SUSHI", "ZAMM", "UNI_V3", "UNI_V4", "CURVE", "LIDO", "WETH_WRAP"];

    receive() external payable {}

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string(DEFAULT_RPC)), vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));
        q = new QuoterExposed();
    }

    function _bal(address t, address who) internal view returns (uint256) {
        return t == ETH ? who.balance : IERC20(t).balanceOf(who);
    }

    /// Quotes the pair, then builds and executes each venue's own calldata.
    /// Returns how many venues were tried and how many reverted.
    function _execEveryVenue(address tokenIn, address tokenOut, uint256 amtIn)
        internal
        returns (uint256 tried, uint256 failed)
    {
        (, zQuoter.Quote[] memory qs) = q.getQuotes(false, tokenIn, tokenOut, amtIn);

        for (uint256 i; i < qs.length; ++i) {
            if (qs[i].amountOut == 0) continue; // venue has no route for this pair
            uint256 minOut = qs[i].amountOut * 9000 / 10_000; // 10% tolerance

            bytes memory cd =
                q.buildFor(address(this), false, tokenIn, tokenOut, amtIn, minOut, block.timestamp + 1800, qs[i]);

            uint256 msgValue = tokenIn == ETH ? amtIn : 0;
            if (tokenIn != ETH) {
                deal(tokenIn, address(this), amtIn);
                // Raw calls: USDT returns no bool, and rejects a non-zero->non-zero
                // approve, so it must be zeroed between loop iterations.
                (bool z,) = tokenIn.call(abi.encodeWithSelector(0x095ea7b3, ROUTER, uint256(0)));
                (bool a,) = tokenIn.call(abi.encodeWithSelector(0x095ea7b3, ROUTER, type(uint256).max));
                require(z || a, "approve failed");
            }
            vm.deal(address(this), msgValue + 1 ether);

            uint256 before = _bal(tokenOut, address(this));
            (bool ok,) = ROUTER.call{value: msgValue}(cd);
            uint256 got = ok ? _bal(tokenOut, address(this)) - before : 0;

            ++tried;
            if (!ok || got == 0) {
                ++failed;
                emit log_named_string("  BROKEN venue", names[uint8(qs[i].source)]);
                emit log_named_uint("    quoted out", qs[i].amountOut);
            } else {
                emit log_named_string("  ok", names[uint8(qs[i].source)]);
            }
        }
    }

    function _report(string memory pair, address tIn, address tOut, uint256 amt) internal {
        emit log_string(pair);
        (uint256 tried, uint256 failed) = _execEveryVenue(tIn, tOut, amt);
        emit log_named_uint("  venues quoting", tried);
        emit log_named_uint("  venues failing", failed);
        assertEq(failed, 0, string.concat(pair, ": a quoting venue could not execute"));
    }

    // The token->ETH direction, which is where every historical failure clustered.
    function test_everyVenue_WBTC_to_ETH() public {
        _report("WBTC->ETH", WBTC, ETH, 0.1e8);
    }

    function test_everyVenue_USDT_to_ETH() public {
        _report("USDT->ETH", USDT, ETH, 100_000e6);
    }

    function test_everyVenue_WSTETH_to_ETH() public {
        _report("wstETH->ETH", WSTETH, ETH, 1 ether);
    }

    function test_everyVenue_USDC_to_ETH() public {
        _report("USDC->ETH", USDC, ETH, 100_000e6);
    }

    // ETH-in direction for contrast.
    function test_everyVenue_ETH_to_USDC() public {
        _report("ETH->USDC", ETH, USDC, 10 ether);
    }

    function test_everyVenue_ETH_to_WBTC() public {
        _report("ETH->WBTC", ETH, WBTC, 10 ether);
    }
}

/// Does the SOURCE in this repo still match the quoter zSwap actually calls?
/// Everything above tests `new zQuoter()`. That only tells us about production
/// if the deployed bytecode agrees, so compare their quotes head to head.
contract zQuoterDeployedVsSourceTest is Test {
    string constant DEFAULT_RPC = "https://gateway.tenderly.co/public/mainnet";
    uint256 constant DEFAULT_FORK_BLOCK = 25_640_000;
    address constant LIVE = 0x0000002d9a651b729e3aFBE57Fc84FFDa4a98a13; // zSwap.html
    address constant ETH = address(0);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    zQuoter src;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string(DEFAULT_RPC)), vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));
        src = new zQuoter();
    }

    uint256 constant EIP170 = 24_576;

    /// @dev There is deliberately no bytecode-equality assertion against `new zQuoter()`.
    ///      zQuoter only fits EIP-170 when built with `FOUNDRY_PROFILE=zquoter`
    ///      (optimizer_runs = 20, yul = false), which produces 24,438 B; the default
    ///      profile this suite compiles under produces 32,359 B. Comparing them compares
    ///      two different optimizer configurations and can only ever fail, which is what it
    ///      used to do — reporting "DEPLOYED QUOTER != REPO SOURCE" when nothing had
    ///      drifted. `compilation_restrictions` cannot fix this because it has no way to
    ///      express `yul = false`; see the note in foundry.toml.
    ///
    ///      Verified out-of-band on 2026-07-31: building src/zQuoter.sol under the zquoter
    ///      profile reproduces the live contract at LIVE exactly. All 24,438 bytes match
    ///      except the trailing 43-byte CBOR metadata, which differs only because the
    ///      deployment used solc 0.8.34 and this repo pins 0.8.36. The deployed quoter IS
    ///      this source.
    ///
    ///      What this suite asserts instead is behavioural equivalence — `test_quotesAgree_*`
    ///      below run the same pairs through both the live contract and a local build and
    ///      require identical venue choice and identical output. That is the property a
    ///      bytecode hash was standing in for, and it survives a compiler bump.
    function test_liveQuoterIsDeployableSize() public view {
        uint256 liveSize = LIVE.code.length;
        assertGt(liveSize, 0, "no code at LIVE - wrong address or fork block");
        assertLe(liveSize, EIP170, "live quoter exceeds EIP-170");
    }

    function _cmp(address tIn, address tOut, uint256 amt, string memory label) internal {
        (zQuoter.Quote memory bs,) = src.getQuotes(false, tIn, tOut, amt);
        (zQuoter.Quote memory bl,) = zQuoter(payable(LIVE)).getQuotes(false, tIn, tOut, amt);
        emit log_named_string("pair", label);
        emit log_named_uint("  source best out  ", bs.amountOut);
        emit log_named_uint("  deployed best out", bl.amountOut);
        assertEq(uint8(bs.source), uint8(bl.source), "venue choice diverges");
        assertEq(bs.amountOut, bl.amountOut, "quote diverges");
    }

    function test_quotesAgree_ETH_to_USDC() public {
        _cmp(ETH, USDC, 10 ether, "ETH->USDC");
    }

    function test_quotesAgree_WBTC_to_ETH() public {
        _cmp(WBTC, ETH, 0.1e8, "WBTC->ETH");
    }
}
