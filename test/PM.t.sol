// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PM} from "../src/PM.sol";

interface IERC20P {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function nonces(address) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IWST is IERC20P {
    function getWstETHByStETH(uint256) external view returns (uint256);
}

interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

interface IRouter {
    function snwap(
        address tokenIn,
        uint256 amountIn,
        address recipient,
        address tokenOut,
        uint256 amountOutMin,
        address executor,
        bytes calldata executorData
    ) external payable returns (uint256);
    function ethToExactWSTETH(address to, uint256 exactOut) external payable;
}

address constant WST = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
address constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

/// Stands in for a DEX leg: stakes the ETH it is sent and forwards the wstETH.
contract StakeExecutor {
    function stake(address to) external payable {
        (bool ok,) = WST.call{value: msg.value}("");
        require(ok);
        IWST(WST).transfer(to, IWST(WST).balanceOf(address(this)));
    }

    function stakeAndReenter(PM pm, uint256 marketId) external payable {
        (bool ok,) = WST.call{value: msg.value}("");
        require(ok);
        uint256 bal = IWST(WST).balanceOf(address(this));
        IWST(WST).approve(address(pm), bal);
        pm.bet(marketId, true, bal, address(this), 0);
    }
}

/// Wins an ETH market and tries to claim twice from its receive hook.
contract GreedyClaimer {
    PM pm;
    uint256 id;

    constructor(PM pm_, uint256 id_) payable {
        pm = pm_;
        id = id_;
    }

    function bet() external {
        pm.betETH{value: address(this).balance}(id, true, address(this), 0, "");
    }

    function claim() external {
        pm.claim(id, address(this));
    }

    receive() external payable {
        if (msg.sender == address(pm)) pm.claim(id, address(this));
    }
}

contract PMTest is Test {
    PM pm;
    StakeExecutor exec;

    address resolver = makeAddr("resolver");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol;
    uint256 carolKey;

    uint48 close;
    uint256 id; // wstETH market
    uint256 ethId; // ETH market
    uint256 boldId; // BOLD market

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        pm = new PM();
        exec = new StakeExecutor();
        (carol, carolKey) = makeAddrAndKey("carol");
        // Forge's stock actor and deploy addresses carry mainnet dust and 7702 sweeper code.
        vm.deal(address(pm), 0);
        vm.etch(alice, "");
        vm.etch(bob, "");
        vm.etch(carol, "");
        vm.etch(resolver, "");
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);

        vm.prank(resolver);
        pm.setResolverFeeBps(100);

        close = uint48(block.timestamp + 1 days);
        id = pm.createMarket("Will it rain?", resolver, WST, close, true, 0, 0);
        ethId = pm.createMarket("Will it rain?", resolver, address(0), close, true, 0, 0);
        boldId = pm.createMarket("Will it rain?", resolver, BOLD, close, true, 0, 0);
    }

    function _betETH(address who, uint256 market, bool yes, uint256 eth) internal returns (uint256) {
        vm.prank(who);
        return pm.betETH{value: eth}(market, yes, who, 0, "");
    }

    function _wstFor(address who, uint256 eth) internal returns (uint256 wst) {
        uint256 before = IWST(WST).balanceOf(who);
        vm.prank(who);
        (bool ok,) = WST.call{value: eth}("");
        require(ok);
        wst = IWST(WST).balanceOf(who) - before;
    }

    function _permitSig(address token, uint256 key, address owner, uint256 value)
        internal
        view
        returns (uint8, bytes32, bytes32)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                IERC20P(token).DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner,
                        address(pm),
                        value,
                        IERC20P(token).nonces(owner),
                        block.timestamp
                    )
                )
            )
        );
        return vm.sign(key, digest);
    }

    function _one(uint256 x) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    /*//////////////////////////////////////////////////////////////
                              IDS & CREATION
    //////////////////////////////////////////////////////////////*/

    function test_ids() public view {
        assertEq(id & 1, 0);
        assertEq(id, pm.getMarketId(address(this), "Will it rain?", resolver, WST, close, true, 0, 0));
        assertTrue(id != ethId && id != boldId && ethId != boldId);
        assertEq(pm.decimals(boldId | 1), 18);
        assertEq(pm.decimals(ethId), 18);
    }

    function test_createMarket_guards() public {
        vm.expectRevert(PM.MarketExists.selector);
        pm.createMarket("Will it rain?", resolver, WST, close, true, 0, 0);
        vm.expectRevert(PM.BadParams.selector);
        pm.createMarket(string(new bytes(1_025)), resolver, WST, close, true, 0, 0);
        vm.expectRevert(PM.BadParams.selector);
        pm.createMarket("x", resolver, WST, close, true, 5_001, 0);
        vm.expectRevert(PM.BadParams.selector);
        pm.createMarket("x", resolver, WST, close, true, 0, 5_001);
        vm.expectRevert(PM.BadParams.selector);
        pm.createMarket("x", resolver, WST, uint48(block.timestamp), true, 0, 0);
        vm.expectRevert(PM.BadParams.selector);
        pm.createMarket("x", address(pm), WST, close, true, 0, 0);
        address noCode = makeAddr("eoa");
        vm.etch(noCode, "");
        vm.expectRevert(PM.WrongAsset.selector);
        pm.createMarket("x", resolver, noCode, close, true, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                WSTETH / ZAP
    //////////////////////////////////////////////////////////////*/

    function test_betETH_wstETH_defaultRoute_matchesLidoRate() public {
        uint256 expected = IWST(WST).getWstETHByStETH(1 ether);
        uint256 shares = _betETH(alice, id, true, 1 ether);
        assertApproxEqAbs(shares, expected, 2);
        assertEq(pm.balanceOf(alice, id), shares);
        assertEq(pm.totalSupply(id), shares);
        assertEq(IWST(WST).balanceOf(address(pm)), shares);
        assertEq(address(pm).balance, 0);
    }

    function test_betETH_slippage() public {
        vm.prank(alice);
        vm.expectRevert(PM.Slippage.selector);
        pm.betETH{value: 1 ether}(id, true, alice, 1 ether, "");
    }

    function test_betETH_snwapRoute() public {
        bytes memory route = abi.encodeCall(
            IRouter.snwap,
            (address(0), 0, address(pm), WST, 0, address(exec), abi.encodeCall(StakeExecutor.stake, (address(pm))))
        );
        vm.prank(alice);
        uint256 shares = pm.betETH{value: 1 ether}(id, false, alice, 0.5 ether, route);
        assertEq(pm.balanceOf(alice, id | 1), shares);
        assertEq(IWST(WST).balanceOf(address(pm)), shares);
    }

    function test_betETH_refundsOnlyUnspentETH() public {
        // ETH already escrowed by an ETH market must not leak into a zap's refund.
        _betETH(bob, ethId, true, 5 ether);
        uint256 exactOut = 0.5 ether;
        bytes memory route = abi.encodeCall(IRouter.ethToExactWSTETH, (address(pm), exactOut));
        uint256 ethBefore = alice.balance;
        vm.prank(alice);
        uint256 shares = pm.betETH{value: 2 ether}(id, true, alice, exactOut, route);
        assertEq(shares, exactOut);
        uint256 spent = ethBefore - alice.balance;
        assertGt(spent, 0.5 ether);
        assertLt(spent, 0.7 ether);
        assertEq(address(pm).balance, 5 ether);
    }

    function test_betETH_routeCannotReenter() public {
        bytes memory route = abi.encodeCall(
            IRouter.snwap,
            (address(0), 0, address(pm), WST, 0, address(exec), abi.encodeCall(StakeExecutor.stakeAndReenter, (pm, id)))
        );
        vm.prank(alice);
        vm.expectRevert(PM.Locked.selector);
        pm.betETH{value: 1 ether}(id, true, alice, 0, route);
    }

    function test_betETH_erc20MarketNeedsRoute() public {
        vm.prank(alice);
        vm.expectRevert(PM.WrongAsset.selector);
        pm.betETH{value: 1 ether}(boldId, true, alice, 0, "");
    }

    function test_receiveRejectsStrayETH() public {
        vm.prank(alice);
        (bool ok,) = address(pm).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_betWithPermit_wstETH() public {
        uint256 wst = _wstFor(carol, 1 ether);
        (uint8 v, bytes32 r, bytes32 s) = _permitSig(WST, carolKey, carol, wst);
        vm.prank(carol);
        pm.betWithPermit(id, true, wst, carol, 0, block.timestamp, v, r, s);
        assertEq(pm.balanceOf(carol, id), wst);
        assertEq(IWST(WST).balanceOf(carol), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                   BOLD
    //////////////////////////////////////////////////////////////*/

    function test_bold_permitAndPermit2_thenSettle() public {
        deal(BOLD, carol, 1_000e18);
        deal(BOLD, bob, 1_000e18);

        (uint8 v, bytes32 r, bytes32 s) = _permitSig(BOLD, carolKey, carol, 600e18);
        vm.prank(carol);
        pm.betWithPermit(boldId, true, 600e18, carol, 0, block.timestamp, v, r, s);

        // Permit2 path, signed by carol for her NO side.
        vm.prank(carol);
        IERC20P(BOLD).approve(PERMIT2, type(uint256).max);
        uint256 nonce = 7;
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 tokenPerms =
            keccak256(abi.encode(keccak256("TokenPermissions(address token,uint256 amount)"), BOLD, 400e18));
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
                ),
                tokenPerms,
                address(pm),
                nonce,
                deadline
            )
        );
        (v, r, s) = vm.sign(
            carolKey, keccak256(abi.encodePacked("\x19\x01", IPermit2Domain(PERMIT2).DOMAIN_SEPARATOR(), structHash))
        );
        vm.prank(carol);
        pm.betWithPermit2(boldId, false, 400e18, carol, 0, nonce, deadline, abi.encodePacked(r, s, v));

        // The signature is bound to its signer: bob cannot spend it.
        vm.prank(bob);
        vm.expectRevert();
        pm.betWithPermit2(boldId, false, 400e18, bob, 0, nonce + 1, deadline, abi.encodePacked(r, s, v));

        vm.startPrank(bob);
        IERC20P(BOLD).approve(address(pm), 1_000e18);
        pm.bet(boldId, false, 1_000e18, bob, 0);
        vm.stopPrank();

        assertEq(pm.totalSupply(boldId), 600e18);
        assertEq(pm.totalSupply(boldId | 1), 1_400e18);

        vm.warp(close);
        vm.prank(resolver);
        pm.resolve(boldId, false);

        uint256 pot = 2_000e18;
        uint256 fee = pot / 100;
        vm.prank(bob);
        uint256 pb = pm.claim(boldId, bob);
        vm.prank(carol);
        uint256 pc = pm.claim(boldId, carol);
        assertEq(pb, 1_000e18 * (pot - fee) / 1_400e18);
        assertEq(pc, 400e18 * (pot - fee) / 1_400e18);

        vm.prank(resolver);
        assertEq(pm.withdrawFees(BOLD, resolver), fee);
        assertEq(IERC20P(BOLD).balanceOf(resolver), fee);
        assertLe(IERC20P(BOLD).balanceOf(address(pm)), 1);
    }

    function test_bet_minShares() public {
        uint256 m = pm.createMarket("late bold", resolver, BOLD, close, true, 0, 2_000);
        deal(BOLD, bob, 10e18);
        vm.warp(block.timestamp + 12 hours);
        vm.startPrank(bob);
        IERC20P(BOLD).approve(address(pm), 10e18);
        vm.expectRevert(PM.Slippage.selector);
        pm.bet(m, true, 10e18, bob, 9.1e18);
        assertEq(pm.bet(m, true, 10e18, bob, 9e18), 9e18);
        vm.stopPrank();
    }

    function test_erc20Paths_rejectETHMarket() public {
        vm.prank(alice);
        vm.expectRevert(PM.WrongAsset.selector);
        pm.bet(ethId, true, 1, alice, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                    ETH
    //////////////////////////////////////////////////////////////*/

    function test_eth_market_settlesInETH() public {
        _betETH(alice, ethId, true, 1 ether);
        _betETH(bob, ethId, false, 3 ether);
        assertEq(address(pm).balance, 4 ether);
        assertEq(IWST(WST).balanceOf(address(pm)), 0);

        vm.prank(alice);
        vm.expectRevert(PM.WrongAsset.selector);
        pm.betETH{value: 1 ether}(ethId, true, alice, 0, hex"00");

        vm.warp(close);
        vm.prank(resolver);
        pm.resolve(ethId, true);

        uint256 before = alice.balance;
        vm.prank(alice);
        pm.claim(ethId, alice);
        assertEq(alice.balance - before, 4 ether - 0.04 ether);

        vm.prank(resolver);
        pm.withdrawFees(address(0), resolver);
        assertEq(resolver.balance, 0.04 ether);
        assertEq(address(pm).balance, 0);
    }

    function test_eth_claimCannotReenter() public {
        GreedyClaimer g = new GreedyClaimer{value: 1 ether}(pm, ethId);
        g.bet();
        _betETH(bob, ethId, false, 1 ether);
        vm.warp(close);
        vm.prank(resolver);
        pm.resolve(ethId, true);
        vm.expectRevert();
        g.claim();
        assertEq(address(pm).balance, 2 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                RESOLUTION
    //////////////////////////////////////////////////////////////*/

    function test_resolve_winnersSplitPot_feeAccrues() public {
        uint256 a = _betETH(alice, id, true, 1 ether);
        uint256 c = _betETH(carol, id, true, 3 ether);
        uint256 b = _betETH(bob, id, false, 2 ether);
        uint256 pot = a + b + c;

        vm.warp(close);
        vm.prank(resolver);
        pm.resolve(id, true);

        uint256 fee = pot * 100 / 10_000;
        assertEq(pm.feesOwed(resolver, WST), fee);

        vm.prank(alice);
        uint256 pa = pm.claim(id, alice);
        vm.prank(carol);
        uint256 pc = pm.claim(id, carol);
        assertEq(pa, a * (pot - fee) / (a + c));
        assertEq(pc, c * (pot - fee) / (a + c));

        vm.prank(resolver);
        pm.withdrawFees(WST, resolver);
        assertLe(IWST(WST).balanceOf(address(pm)), 2);

        vm.prank(bob);
        vm.expectRevert(PM.NothingToClaim.selector);
        pm.claim(id, bob);
        vm.prank(alice);
        vm.expectRevert(PM.NothingToClaim.selector);
        pm.claim(id, alice);
    }

    function test_feeIsSnapshotAtCreation() public {
        vm.prank(resolver);
        pm.setResolverFeeBps(1_000);
        uint256 a = _betETH(alice, id, true, 1 ether);
        uint256 b = _betETH(bob, id, false, 1 ether);
        vm.warp(close);
        vm.prank(resolver);
        pm.resolve(id, false);
        assertEq(pm.feesOwed(resolver, WST), (a + b) * 100 / 10_000);
    }

    function test_oneSided_voidsAndRefunds() public {
        uint256 a = _betETH(alice, id, true, 1 ether);
        vm.warp(close);
        vm.prank(resolver);
        pm.resolve(id, true);
        assertEq(uint8(pm.getMarket(id).state), uint8(PM.State.Void));
        assertEq(pm.feesOwed(resolver, WST), 0);
        vm.prank(alice);
        assertEq(pm.claim(id, alice), a);
    }

    function test_void_refundsBothSides() public {
        uint256 y = _betETH(alice, id, true, 1 ether);
        uint256 n = _betETH(alice, id, false, 2 ether);
        vm.prank(resolver);
        pm.void(id);
        (,, uint256[] memory claimable) = pm.positions(alice, _one(id));
        assertEq(claimable[0], y + n);
        vm.prank(alice);
        assertEq(pm.claim(id, alice), y + n);
    }

    function test_unresolvedMarket_anyoneVoidsAfterWindow() public {
        uint256 a = _betETH(alice, id, true, 1 ether);
        uint256 b = _betETH(bob, id, false, 1 ether);

        vm.warp(close + pm.RESOLVE_WINDOW() - 1);
        vm.prank(bob);
        vm.expectRevert(PM.TooEarly.selector);
        pm.void(id);

        vm.warp(close + pm.RESOLVE_WINDOW());
        vm.prank(resolver);
        vm.expectRevert(PM.TooLate.selector);
        pm.resolve(id, true);

        vm.prank(bob);
        pm.void(id);
        vm.prank(alice);
        assertEq(pm.claim(id, alice), a);
        vm.prank(bob);
        assertEq(pm.claim(id, bob), b);
    }

    function test_tradingEndsAtClose() public {
        _betETH(alice, id, true, 1 ether);
        vm.warp(close);
        vm.prank(bob);
        vm.expectRevert(PM.TradingClosed.selector);
        pm.betETH{value: 1 ether}(id, false, bob, 0, "");
    }

    function test_closeMarket() public {
        vm.prank(alice);
        vm.expectRevert(PM.Unauthorized.selector);
        pm.closeMarket(id);
        vm.prank(resolver);
        pm.closeMarket(id);
        (uint256 qs,) = pm.quote(id, true, 1 ether);
        assertEq(qs, 0);
        vm.prank(alice);
        vm.expectRevert(PM.TradingClosed.selector);
        pm.betETH{value: 1 ether}(id, true, alice, 0, "");
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_pagesNewestFirst_andByResolver() public {
        vm.prank(alice);
        uint256 id4 = pm.createMarket("Fourth", resolver, WST, close, false, 0, 0);

        (PM.MarketView[] memory page, uint256 next) = pm.getMarkets(0, 2);
        assertEq(page.length, 2);
        assertEq(page[0].marketId, id4);
        assertEq(page[1].marketId, boldId);
        assertEq(page[1].asset, BOLD);
        assertEq(next, 2);
        (page, next) = pm.getMarkets(next, 5);
        assertEq(page.length, 2);
        assertEq(page[1].marketId, id);
        assertEq(page[1].description, "Will it rain?");
        assertEq(next, 0);

        (page,) = pm.getMarketsBy(address(this), 0, 10);
        assertEq(page.length, 3);
        (page,) = pm.getMarketsBy(alice, 0, 10);
        assertEq(page.length, 1);
    }

    function test_quote() public {
        _betETH(alice, id, true, 1 ether);
        _betETH(bob, id, false, 3 ether);
        uint256 amt = 1 ether;
        (uint256 qs, uint256 q) = pm.quote(id, true, amt);
        assertEq(qs, amt);
        uint256 y = pm.totalSupply(id);
        uint256 n = pm.totalSupply(id | 1);
        uint256 pot = y + n + amt;
        assertEq(q, amt * (pot - pot / 100) / (y + amt));
    }

    /*//////////////////////////////////////////////////////////////
                             EXIT & LATE TAXES
    //////////////////////////////////////////////////////////////*/

    function _shares(uint256 market, uint256 amount) internal view returns (uint256 shares) {
        (shares,) = pm.quote(market, true, amount);
    }

    function _pot(uint256 market) internal view returns (uint256) {
        return pm.getMarket(market).pot;
    }

    function test_exit_disabledByDefault() public {
        _betETH(alice, ethId, true, 1 ether);
        vm.prank(alice);
        vm.expectRevert(PM.NoExit.selector);
        pm.exit(ethId, true, 1 ether, alice);
    }

    function test_exit_taxStaysInPot_forHolders() public {
        uint256 m = pm.createMarket("exit", resolver, address(0), close, true, 1_000, 0);
        _betETH(alice, m, true, 1 ether);
        _betETH(bob, m, false, 1 ether);

        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 out = pm.exit(m, true, 0.5 ether, alice);
        assertEq(out, 0.45 ether);
        assertEq(alice.balance - before, 0.45 ether);
        assertEq(_pot(m), 1.55 ether);
        assertEq(address(pm).balance, 1.55 ether);

        vm.prank(bob);
        vm.expectRevert();
        pm.exit(m, true, 1, bob); // holds no YES

        vm.warp(close);
        vm.prank(alice);
        vm.expectRevert(PM.TradingClosed.selector);
        pm.exit(m, true, 0.5 ether, alice);

        vm.prank(resolver);
        pm.resolve(m, true);
        before = alice.balance;
        vm.prank(alice);
        pm.claim(m, alice);
        // Alice's remaining 0.5 shares take the whole pot, including her own exit tax, less the 1% fee.
        assertEq(alice.balance - before, 1.55 ether - 0.0155 ether);
    }

    function test_exit_wstETH_paysWstETH() public {
        uint256 m = pm.createMarket("exit", resolver, WST, close, true, 200, 0);
        uint256 shares = _betETH(alice, m, false, 1 ether);
        vm.prank(alice);
        uint256 out = pm.exit(m, false, shares, alice);
        assertEq(out, shares * 9_800 / 10_000);
        assertEq(IWST(WST).balanceOf(alice), out);
        assertEq(IWST(WST).balanceOf(address(pm)), shares - out);
    }

    function test_lateTax_rampsLinearly_andPaysEarlyMoney() public {
        uint256 m = pm.createMarket("late", resolver, address(0), close, true, 0, 2_000);
        assertEq(_betETH(alice, m, true, 1 ether), 1 ether);

        vm.warp(block.timestamp + 12 hours);
        assertEq(_shares(m, 1 ether), 0.9 ether);
        (, uint256 q) = pm.quote(m, true, 1 ether);
        assertEq(_betETH(carol, m, true, 1 ether), 0.9 ether);
        _betETH(bob, m, false, 1 ether); // 0.9 shares

        vm.warp(close - 1);
        assertApproxEqAbs(_shares(m, 1 ether), 0.8 ether, 1e13);

        vm.warp(close);
        vm.prank(resolver);
        pm.resolve(m, true);
        vm.prank(alice);
        uint256 pa = pm.claim(m, alice);
        vm.prank(carol);
        uint256 pc = pm.claim(m, carol);
        uint256 net = 3 ether - 0.03 ether;
        assertEq(pa, net * 1 ether / 1.9 ether);
        assertEq(pc, net * 0.9 ether / 1.9 ether);
        assertGt(pa, pc);
        assertGt(pc, q); // bob's later NO money only adds to what YES winners split
    }

    function test_void_splitsTaxedPotProRata() public {
        uint256 m = pm.createMarket("void", resolver, address(0), close, true, 1_000, 2_000);
        _betETH(alice, m, true, 1 ether); // 1 share
        vm.warp(block.timestamp + 12 hours);
        _betETH(bob, m, false, 1 ether); // 0.9 share
        vm.prank(alice);
        pm.exit(m, true, 0.5 ether, alice); // takes 0.45

        vm.prank(resolver);
        pm.void(m);
        uint256 pot = 2 ether - 0.45 ether;
        uint256 a0 = alice.balance;
        uint256 b0 = bob.balance;
        vm.prank(alice);
        pm.claim(m, alice);
        vm.prank(bob);
        pm.claim(m, bob);
        assertEq(alice.balance - a0, pot * 0.5 ether / 1.4 ether);
        assertEq(bob.balance - b0, pot * 0.9 ether / 1.4 ether);
        assertGe(alice.balance - a0, 0.5 ether); // at least par
        assertLe(address(pm).balance, 1);
    }

    function test_void_afterEveryoneExits_potGoesToResolver() public {
        uint256 m = pm.createMarket("empty", resolver, address(0), close, true, 1_000, 0);
        _betETH(alice, m, true, 1 ether);
        vm.prank(alice);
        pm.exit(m, true, 1 ether, alice);
        vm.warp(close);
        vm.prank(resolver);
        pm.resolve(m, true); // one-sided, so void
        assertEq(pm.feesOwed(resolver, address(0)), 0.1 ether);
        vm.prank(resolver);
        pm.withdrawFees(address(0), resolver);
        assertEq(address(pm).balance, 0);
    }

    /// Random bets and exits never let the pot fall below the shares outstanding, and the
    /// contract always holds exactly the pot; after settlement everything pays out to dust.
    function testFuzz_potCoversShares(uint256 seed) public {
        uint256 m = pm.createMarket("fuzz", resolver, address(0), close, true, 750, 3_000);
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i != 24; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            address u = who[r % 3];
            bool yes = (r >> 8) & 1 == 0;
            vm.warp(block.timestamp + (r >> 16) % 1 hours);
            if (block.timestamp >= close) break;
            uint256 held = pm.balanceOf(u, yes ? m : m | 1);
            if ((r >> 64) % 3 == 0 && held != 0) {
                vm.prank(u);
                pm.exit(m, yes, held / ((r >> 96) % 3 + 1), u);
            } else {
                _betETH(u, m, yes, 1 + (r >> 128) % 5 ether);
            }
            uint256 supply = pm.totalSupply(m) + pm.totalSupply(m | 1);
            assertGe(_pot(m), supply);
            assertEq(address(pm).balance, _pot(m));
        }

        vm.warp(close);
        vm.prank(resolver);
        pm.resolve(m, seed & 1 == 0);
        for (uint256 i; i != 3; ++i) {
            (,, uint256[] memory c) = pm.positions(who[i], _one(m));
            if (c[0] != 0) {
                vm.prank(who[i]);
                pm.claim(m, who[i]);
            }
        }
        uint256 fees = pm.feesOwed(resolver, address(0));
        assertLe(address(pm).balance, fees + 3);
        assertGe(address(pm).balance, fees);
    }

    /*//////////////////////////////////////////////////////////////
                            REVIEW REGRESSIONS
    //////////////////////////////////////////////////////////////*/

    /// Hedging both sides early and exiting one near close costs the late tax, not just exitBps.
    function test_exit_paysLateTaxWhenHigher() public {
        uint256 m = pm.createMarket("hedge", resolver, address(0), close, true, 500, 5_000);
        _betETH(alice, m, true, 10 ether);
        vm.warp(close - 1 hours);
        uint256 lateNet = _shares(m, 10 ether);
        vm.prank(alice);
        uint256 out = pm.exit(m, true, 10 ether, alice);
        assertEq(out, lateNet);
        assertLt(out, 9.5 ether);
    }

    /// Taxes round up, so dust can't slip through untaxed.
    function test_dust_isTaxed() public {
        uint256 late = pm.createMarket("late dust", resolver, address(0), close, true, 0, 5_000);
        uint256 exitOnly = pm.createMarket("exit dust", resolver, address(0), close, true, 100, 0);

        _betETH(alice, exitOnly, true, 99);
        vm.prank(alice);
        assertEq(pm.exit(exitOnly, true, 99, alice), 98);

        vm.warp(close - 1);
        vm.prank(alice);
        vm.expectRevert(PM.AmountZero.selector);
        pm.betETH{value: 1}(late, true, alice, 0, "");
    }

    /// Market ids are scoped to their creator: nobody can take another's market or list.
    function test_marketIdsScopedToCreator() public {
        vm.prank(bob);
        uint256 squat = pm.createMarket("Will it rain?", resolver, WST, close, true, 0, 0);
        assertTrue(squat != id);
        assertEq(pm.marketCountBy(bob), 1);
        assertEq(pm.marketCountBy(address(this)), 3);
        vm.expectRevert(PM.MarketExists.selector);
        pm.createMarket("Will it rain?", resolver, WST, close, true, 0, 0);
    }

    function test_quote_zeroWhenNotTrading() public {
        (uint256 s, uint256 p) = pm.quote(12345 << 1, true, 1 ether);
        assertEq(s + p, 0);
        vm.warp(close);
        (s, p) = pm.quote(id, true, 1 ether);
        assertEq(s + p, 0);
    }

    function test_betETH_zeroValueReverts() public {
        vm.prank(alice);
        vm.expectRevert(PM.AmountZero.selector);
        pm.betETH(ethId, true, alice, 0, "");
    }

    function test_decimals_clampsGarbage() public {
        BadDecimals t = new BadDecimals();
        uint256 m = pm.createMarket("dec", resolver, address(t), close, true, 0, 0);
        assertEq(pm.decimals(m | 1), 18);
    }
}

contract BadDecimals {
    function decimals() external pure returns (uint256) {
        return 300;
    }
}
