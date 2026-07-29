// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import "../src/zQuoter.sol";
import {zQuoterV4} from "../src/zQuoterV4.sol";

interface IERC20x {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @dev Arbitrary-token sweep. The web dapp and API accept any address, so the
/// dropdown matrix alone does not establish router soundness. This walks a
/// sample of token-list.json against ETH and enforces the same contract:
/// execute-and-deliver, or refuse to quote. Never a route that reverts.
///
/// This is the empirical counterpart to the structural argument for fix #2 —
/// a pool that cannot fill now returns 0 instead of dust, so routing can never
/// prefer an unfillable leg. That property should hold for ANY token, not just
/// the ones we curated.
contract zQuoterTokenSweepTest is Test {
    zQuoter q;
    address constant ZR = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant V4H = 0x00005d8a3675b7b00BA172Aa85485Fc5D23121B6;
    address constant E = address(0);
    address u = address(0xB0B);
    uint256 okBuy; uint256 okSell; uint256 skipped; uint256 bad;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"), vm.envUint("FORK_BLOCK"));
        vm.etch(V4H, address(new zQuoterV4()).code);
        q = new zQuoter();
    }

    function _bal(address t, address w) internal view returns (uint256) {
        return t == E ? w.balance : IERC20x(t).balanceOf(w);
    }

    /// ETH -> token, then token -> ETH. Both must execute or be refused.
    function _t(address tok, uint8 d, string memory sym) internal {
        uint256 inAmt = 0.02 ether;
        vm.deal(u, 10 ether);
        // BUY
        uint256 bought;
        try q.buildBestSwapViaETHMulticall(u, u, false, E, tok, inAmt, 300, type(uint256).max)
        returns (zQuoter.Quote memory a, zQuoter.Quote memory b, bytes[] memory, bytes memory mc, uint256 mv) {
            uint256 want = b.amountOut > 0 ? b.amountOut : a.amountOut;
            if (mc.length == 0 || want == 0) { skipped++; return; }
            uint256 pre = _bal(tok, u);
            vm.prank(u);
            (bool ok,) = ZR.call{value: mv}(mc);
            if (!ok) { bad++; emit log_named_string(sym, "!!! BUY QUOTED BUT REVERTED"); return; }
            bought = _bal(tok, u) - pre;
            if (bought == 0) { bad++; emit log_named_string(sym, "!!! BUY DELIVERED NOTHING"); return; }
            if (bought * 100 < want * 90) { bad++; emit log_named_string(sym, "!!! BUY UNDER-DELIVERED"); return; }
            okBuy++;
        } catch { skipped++; return; }

        // SELL back
        vm.prank(u);
        IERC20x(tok).approve(ZR, type(uint256).max);
        try q.buildBestSwapViaETHMulticall(u, u, false, tok, E, bought, 300, type(uint256).max)
        returns (zQuoter.Quote memory a2, zQuoter.Quote memory b2, bytes[] memory, bytes memory mc2, uint256 mv2) {
            uint256 want2 = b2.amountOut > 0 ? b2.amountOut : a2.amountOut;
            if (mc2.length == 0 || want2 == 0) { skipped++; return; }
            uint256 pre2 = u.balance;
            vm.prank(u);
            (bool ok2,) = ZR.call{value: mv2}(mc2);
            if (!ok2) { bad++; emit log_named_string(sym, "!!! SELL QUOTED BUT REVERTED"); return; }
            if (u.balance <= pre2) { bad++; emit log_named_string(sym, "!!! SELL DELIVERED NOTHING"); return; }
            okSell++;
        } catch { skipped++; }
    }

    function test_tokenListSweep() public {
        _t(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, 18, "WETH");
        _t(0x514910771AF9Ca656af840dff83E8264EcF986CA, 18, "LINK");
        _t(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, 18, "UNI");
        _t(0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9, 18, "AAVE");
        _t(0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2, 18, "MKR");
        _t(0xc00e94Cb662C3520282E6f5717214004A7f26888, 18, "COMP");
        _t(0xD533a949740bb3306d119CC777fa900bA034cd52, 18, "CRV");
        _t(0x5A98FcBEA516Cf06857215779Fd812CA3beF1B32, 18, "LDO");
        _t(0xD33526068D116cE69F19A9ee46F0bd304F21A51f, 18, "RPL");
        _t(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, 18, "stETH");
        _t(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704, 18, "cbETH");
        _t(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf, 8, "cbBTC");
        _t(0x18084fbA666a33d37592fA2633fD49a74DD93a88, 18, "tBTC");
        _t(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f, 18, "GHO");
        _t(0x808507121B80c02388fAd14726482e061B8da827, 18, "PENDLE");
        _t(0xC011a73ee8576Fb46F5E1c5751cA3B9Fe0af2a6F, 18, "SNX");
        _t(0x6982508145454Ce325dDbE47a25d4ec3d2311933, 18, "PEPE");
        _t(0x95aD61b0a150d79219dCF64E1E6Cc01f0B64C4cE, 18, "SHIB");
        _t(0xdAC17F958D2ee523a2206206994597C13D831ec7, 6, "USDT");
        _t(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48, 6, "USDC");
        _t(0x6B175474E89094C44Da98b954EedeAC495271d0F, 18, "DAI");
        _t(0x853d955aCEf822Db058eb8505911ED77F175b99e, 18, "FRAX");
        _t(0x6c3ea9036406852006290770BEdFcAbA0e23A0e8, 6, "PYUSD");
        _t(0x8E870D67F660D95d5be530380D0eC0bd388289E1, 18, "USDP");
        emit log_named_uint("buys executed ", okBuy);
        emit log_named_uint("sells executed", okSell);
        emit log_named_uint("refused (safe)", skipped);
        emit log_named_uint("BROKEN        ", bad);
        assertEq(bad, 0, "a token quoted a route that did not deliver");
    }
}
