// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PM} from "../src/PM.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

contract PMMockToken is ERC20 {
    function name() public pure override returns (string memory) {
        return "Mock";
    }

    function symbol() public pure override returns (string memory) {
        return "MOCK";
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract PMHandler is Test {
    PM public pm;
    PMMockToken public tok;
    address[] public actors;
    address public sink = address(0xBEEF5);

    uint256[] public mids;
    uint256 nonce;

    // per-asset ledger (index 0 = ETH, 1 = token)
    uint256[2] public paidIn;
    uint256[2] public paidOut;

    // per-market ghosts
    mapping(uint256 => uint8) public gState;
    mapping(uint256 => uint256) public gPot; // pot snapshot at settlement
    mapping(uint256 => uint256) public gWinners;
    mapping(uint256 => uint256) public mIn;
    mapping(uint256 => uint256) public mExit;
    mapping(uint256 => uint256) public mClaimed;
    mapping(uint256 => uint256) public mClaims;
    mapping(uint256 => uint256) public mToFees;

    // failure flags
    bool public unexpectedRevert;
    string public why;
    bool public doubleClaim;
    bool public stateRegress;
    bool public residualTooBig;

    mapping(bytes32 => uint256) public calls;

    constructor(PM pm_, PMMockToken tok_) {
        pm = pm_;
        tok = tok_;
        for (uint256 i; i < 5; ++i) {
            address a = address(uint160(0xA11CE0 + i));
            actors.push(a);
            vm.deal(a, 1e30);
            tok.mint(a, 1e30);
            vm.prank(a);
            tok.approve(address(pm), type(uint256).max);
            vm.prank(a);
            pm.setResolverFeeBps(uint16(i * 250)); // 0..1000
        }
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function _mid(uint256 s) internal view returns (uint256) {
        // favour the newest markets so most actions land on live ones
        uint256 n = mids.length;
        if (s % 4 != 0 && n > 6) return mids[n - 1 - (s >> 2) % 6];
        return mids[s % n];
    }

    function _ai(address asset) internal pure returns (uint256) {
        return asset == address(0) ? 0 : 1;
    }

    function _bal(address asset) internal view returns (uint256) {
        return asset == address(0) ? address(pm).balance : tok.balanceOf(address(pm));
    }

    function marketCount() external view returns (uint256) {
        return mids.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _fail(string memory w) internal {
        unexpectedRevert = true;
        why = w;
    }

    /*////////////////////////////// actions //////////////////////////////*/

    function createMarket(uint256 s, uint256 closeIn, bool eth, bool canClose, uint16 exitBps, uint16 lateBps) public {
        if (mids.length >= 60) return;
        calls["create"]++;
        address resolver = _actor(s);
        address creator = _actor(s >> 8);
        closeIn = bound(closeIn, 1, 20 days);
        // bias toward edge taxes
        exitBps = uint16(s % 4 == 0 ? 0 : s % 4 == 1 ? 5000 : bound(exitBps, 0, 5000));
        lateBps = uint16((s >> 3) % 3 == 0 ? 0 : (s >> 3) % 3 == 1 ? 5000 : bound(lateBps, 0, 5000));
        vm.prank(creator);
        uint256 id = pm.createMarket(
            string(abi.encodePacked("m", nonce++)),
            resolver,
            eth ? address(0) : address(tok),
            uint48(block.timestamp + closeIn),
            canClose,
            exitBps,
            lateBps
        );
        mids.push(id);
    }

    function setFee(uint256 s, uint16 bps) public {
        calls["setFee"]++;
        vm.prank(_actor(s));
        pm.setResolverFeeBps(uint16(bound(bps, 0, 1000)));
    }

    function bet(uint256 s, uint256 ms, bool yes, uint256 amt, bool tiny) public {
        if (mids.length == 0) return;
        uint256 id = _mid(ms);
        PM.MarketView memory v = pm.getMarket(id);
        if (v.state != PM.State.Open || block.timestamp >= v.close) {
            id = _liveMarket(ms);
            if (id == 0) return;
            v = pm.getMarket(id);
        }
        amt = tiny ? bound(amt, 1, 50) : bound(amt, 1, 1e24);
        address a = _actor(s);
        address to = _actor(s >> 16);
        uint256 ai = _ai(v.asset);
        uint256 b0 = _bal(v.asset);
        if (v.asset == address(0)) {
            vm.prank(a);
            try pm.betETH{value: amt}(id, yes, to, 0, "") {}
                catch {
                calls["betFail"]++;
                return;
            }
        } else {
            vm.prank(a);
            try pm.bet(id, yes, amt, to, 0) {}
                catch {
                calls["betFail"]++;
                return;
            }
        }
        calls["bet"]++;
        uint256 d = _bal(v.asset) - b0;
        require(d == amt, "bal delta");
        paidIn[ai] += amt;
        mIn[id] += amt;
    }

    function exit(uint256 s, uint256 ms, bool yes, uint256 frac, bool toSink) public {
        if (mids.length == 0) return;
        uint256 id = _mid(ms);
        PM.MarketView memory v = pm.getMarket(id);
        address a = _actor(s);
        uint256 sid = yes ? id : id | 1;
        uint256 have = pm.balanceOf(a, sid);
        if (have == 0) {
            for (uint256 k; k < actors.length && have == 0; ++k) {
                a = actors[k];
                have = pm.balanceOf(a, sid);
            }
            if (have == 0) return;
        }
        uint256 sh = bound(frac, 1, have);
        bool canExit = v.state == PM.State.Open && block.timestamp < v.close && v.exitBps != 0;
        uint256 b0 = _bal(v.asset);
        vm.prank(a);
        try pm.exit(id, yes, sh, toSink ? sink : address(0)) returns (uint256 amt) {
            calls["exit"]++;
            if (!canExit) _fail("exit when not allowed");
            uint256 d = b0 - _bal(v.asset);
            if (d != amt) _fail("exit delta");
            if (amt > sh) _fail("exit > shares");
            paidOut[_ai(v.asset)] += d;
            mExit[id] += d;
        } catch (bytes memory err) {
            if (canExit && bytes4(err) != PM.AmountZero.selector) _fail("exit reverted");
        }
    }

    function _liveMarket(uint256 s) internal view returns (uint256) {
        uint256 n = mids.length;
        for (uint256 k; k < n; ++k) {
            uint256 id = mids[(s % n + k) % n];
            PM.MarketView memory v = pm.getMarket(id);
            if (v.state == PM.State.Open && block.timestamp < v.close) return id;
        }
        return 0;
    }

    /// Exits at a chosen point of the late ramp.
    function exitOnRamp(uint256 s, uint256 ms, uint256 pt, bool yes) public {
        if (mids.length == 0) return;
        uint256 id = _mid(ms);
        PM.MarketView memory v = pm.getMarket(id);
        if (v.state != PM.State.Open || block.timestamp >= v.close) return;
        uint256 t = bound(pt, block.timestamp, uint256(v.close) - 1);
        vm.warp(t);
        calls["rampWarp"]++;
        exit(s, ms, yes, type(uint256).max, false);
    }

    function transfer(uint256 s, uint256 r, uint256 ms, bool yes, uint256 amt) public {
        if (mids.length == 0) return;
        uint256 id = _mid(ms);
        uint256 sid = yes ? id : id | 1;
        address a = _actor(s);
        uint256 have = pm.balanceOf(a, sid);
        if (have == 0) return;
        calls["transfer"]++;
        vm.prank(a);
        pm.transfer(_actor(r), sid, bound(amt, 0, have));
    }

    function approveAndTransferFrom(uint256 s, uint256 r, uint256 ms, bool yes, uint256 amt, bool op) public {
        if (mids.length == 0) return;
        uint256 id = _mid(ms);
        uint256 sid = yes ? id : id | 1;
        address a = _actor(s);
        address spender = _actor(r);
        uint256 have = pm.balanceOf(a, sid);
        if (have == 0) return;
        amt = bound(amt, 0, have);
        vm.prank(a);
        if (op) pm.setOperator(spender, true);
        else pm.approve(spender, sid, amt);
        calls["transferFrom"]++;
        vm.prank(spender);
        pm.transferFrom(a, _actor(r >> 8), sid, amt);
        if (op) {
            vm.prank(a);
            pm.setOperator(spender, false);
        } else if (a != spender && pm.allowance(a, spender, sid) != 0) {
            _fail("allowance not consumed");
        }
    }

    function unauthorizedTransferFrom(uint256 s, uint256 r, uint256 ms) public {
        if (mids.length == 0) return;
        uint256 id = _mid(ms);
        address a = _actor(s);
        address thief = _actor(r);
        if (a == thief || pm.isOperator(a, thief) || pm.allowance(a, thief, id) != 0) return;
        uint256 have = pm.balanceOf(a, id);
        if (have == 0) return;
        vm.prank(thief);
        try pm.transferFrom(a, thief, id, have) {
            _fail("unauthorized transferFrom");
        } catch {}
    }

    function closeMarket(uint256 ms, uint256 s) public {
        if (mids.length == 0) return;
        uint256 id = _mid(ms);
        PM.MarketView memory v = pm.getMarket(id);
        address caller = s % 3 == 0 ? _actor(s) : v.resolver;
        vm.prank(caller);
        try pm.closeMarket(id) {
            calls["close"]++;
            if (caller != v.resolver || !v.canClose || v.state != PM.State.Open || block.timestamp >= v.close) {
                _fail("bad close");
            }
        } catch {}
    }

    function warp(uint256 dt, bool big) public {
        calls["warp"]++;
        big = big && dt % 8 == 0;
        vm.warp(block.timestamp + (big ? bound(dt, 20 days, 45 days) : bound(dt, 1, 12 hours)));
    }

    function resolve(uint256 ms, bool yes, uint256 s) public {
        if (mids.length == 0) return;
        uint256 id = _mid(ms);
        PM.MarketView memory v = pm.getMarket(id);
        address caller = s % 4 == 0 ? _actor(s) : v.resolver;
        if (s % 4 == 1 && v.state == PM.State.Open && block.timestamp < v.close) {
            vm.warp(v.close); // make resolution reachable
            v = pm.getMarket(id);
        }
        uint256 f0 = pm.feesOwed(v.resolver, v.asset);
        uint256 pot0 = v.pot;
        vm.prank(caller);
        try pm.resolve(id, yes) {
            calls["resolve"]++;
            if (
                caller != v.resolver || v.state != PM.State.Open || block.timestamp < v.close
                    || block.timestamp >= uint256(v.close) + 30 days
            ) _fail("bad resolve");
            _snap(id, v.resolver, v.asset, f0, pot0);
        } catch {}
    }

    function voidMarket(uint256 ms, uint256 s) public {
        if (mids.length == 0) return;
        uint256 id = _mid(ms);
        PM.MarketView memory v = pm.getMarket(id);
        address caller = s % 2 == 0 ? _actor(s) : v.resolver;
        uint256 f0 = pm.feesOwed(v.resolver, v.asset);
        uint256 pot0 = v.pot;
        vm.prank(caller);
        try pm.void(id) {
            calls["void"]++;
            if (v.state != PM.State.Open) _fail("void settled");
            if (caller != v.resolver && block.timestamp < uint256(v.close) + 30 days) _fail("early void");
            _snap(id, v.resolver, v.asset, f0, pot0);
        } catch {}
    }

    function _snap(uint256 id, address resolver, address asset, uint256 f0, uint256 pot0) internal {
        PM.MarketView memory w = pm.getMarket(id);
        if (w.state == PM.State.Open) {
            _fail("still open");
            return;
        }
        gState[id] = uint8(w.state);
        gPot[id] = w.pot;
        gWinners[id] = w.winners;
        uint256 feeDelta = pm.feesOwed(resolver, asset) - f0;
        mToFees[id] = feeDelta;
        if (w.pot + feeDelta != pot0) _fail("settle conservation");
        if (w.state == PM.State.Void) {
            if (w.winners != w.yes + w.no) _fail("void winners");
        } else {
            if (w.winners != (w.state == PM.State.Yes ? w.yes : w.no)) _fail("winners");
            if (w.yes == 0 || w.no == 0) _fail("one-sided not voided");
        }
    }

    function claim(uint256 s, uint256 ms, bool toSink) public {
        if (mids.length == 0) return;
        uint256 id = _mid(ms);
        _claim(_actor(s), id, toSink);
    }

    function _claimable(address a, uint256 id, PM.MarketView memory v) internal view returns (uint256 sh) {
        if (v.state == PM.State.Void) sh = pm.balanceOf(a, id) + pm.balanceOf(a, id | 1);
        else if (v.state == PM.State.Yes) sh = pm.balanceOf(a, id);
        else if (v.state == PM.State.No) sh = pm.balanceOf(a, id | 1);
    }

    function _claim(address a, uint256 id, bool toSink) internal {
        PM.MarketView memory v = pm.getMarket(id);
        uint256 sh = _claimable(a, id, v);
        uint256 expect = v.state == PM.State.Open || sh == 0 ? 0 : sh * v.pot / v.winners;
        uint256 b0 = _bal(v.asset);
        vm.prank(a);
        try pm.claim(id, toSink ? sink : address(0)) returns (uint256 amt) {
            calls["claim"]++;
            if (amt != expect || expect == 0) _fail("claim amount");
            uint256 d = b0 - _bal(v.asset);
            if (d != amt) _fail("claim delta");
            paidOut[_ai(v.asset)] += d;
            mClaimed[id] += d;
            mClaims[id]++;
            // second claim must fail
            vm.prank(a);
            try pm.claim(id, address(0)) {
                doubleClaim = true;
            } catch {}
        } catch {
            if (expect != 0) _fail("claim reverted");
        }
    }

    /// Settles a random market (forcing time) and has everyone claim.
    function settleAndClaimAll(uint256 ms, bool yes, bool asVoid) public {
        if (mids.length == 0) return;
        uint256 id = _mid(ms);
        PM.MarketView memory v = pm.getMarket(id);
        if (v.state == PM.State.Open) {
            if (block.timestamp < v.close) {
                if (ms % 3 != 0) return;
                vm.warp(v.close);
            }
            if (block.timestamp >= uint256(v.close) + 30 days || asVoid) {
                voidMarket(ms, 1);
            } else {
                resolve(ms, yes, 1);
            }
        }
        for (uint256 i; i < actors.length; ++i) {
            _claim(actors[i], id, i % 2 == 0);
        }
        v = pm.getMarket(id);
        uint256 left = v.state == PM.State.Void ? v.yes + v.no : v.state == PM.State.Yes ? v.yes : v.no;
        if (left == 0) {
            calls["fullyClaimed"]++;
            uint256 residual = v.pot - mClaimed[id];
            if (residual > mClaims[id]) residualTooBig = true;
        }
    }

    function withdrawFees(uint256 s, bool eth, bool toSink) public {
        address a = _actor(s);
        address asset = eth ? address(0) : address(tok);
        for (uint256 k; k < actors.length && pm.feesOwed(a, asset) == 0 && s % 5 != 0; ++k) {
            a = actors[k];
        }
        uint256 owed = pm.feesOwed(a, asset);
        uint256 b0 = _bal(asset);
        vm.prank(a);
        try pm.withdrawFees(asset, toSink ? sink : address(0)) returns (uint256 amt) {
            calls["withdraw"]++;
            if (amt != owed) _fail("fee amt");
            uint256 d = b0 - _bal(asset);
            paidOut[_ai(asset)] += d;
        } catch {
            if (owed != 0) _fail("withdraw reverted");
        }
    }

    /*////////////////////////////// checks //////////////////////////////*/

    function checkStates() external view returns (bool ok) {
        ok = true;
        for (uint256 i; i < mids.length; ++i) {
            uint256 id = mids[i];
            PM.MarketView memory v = pm.getMarket(id);
            if (gState[id] != 0) {
                if (uint8(v.state) != gState[id] || v.pot != gPot[id] || v.winners != gWinners[id]) ok = false;
            } else if (v.state != PM.State.Open) {
                ok = false; // settled outside the handler's knowledge
            }
        }
    }

    function feesFor(address asset) public view returns (uint256 f) {
        for (uint256 i; i < actors.length; ++i) {
            f += pm.feesOwed(actors[i], asset);
        }
    }
}

/// Audited at runs = 128, depth = 300 (38,400 calls per invariant, no reverts).
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = true
contract PMAuditInvariant is StdInvariant, Test {
    PM pm;
    PMMockToken tok;
    PMHandler h;

    function setUp() public {
        vm.warp(1_700_000_000);
        pm = new PM();
        tok = new PMMockToken();
        h = new PMHandler(pm, tok);
        // seed a few markets so actions have targets
        h.createMarket(1, 3 days, true, true, 0, 5000);
        h.createMarket(2, 5 days, false, false, 5000, 5000);
        h.createMarket(5, 2 hours, true, false, 100, 0);
        h.createMarket(6, 7 days, false, true, 3000, 2500);
        targetContract(address(h));
        excludeSender(address(pm));
    }

    function _obligations(address asset) internal view returns (uint256 open, uint256 settled) {
        uint256 n = h.marketCount();
        for (uint256 i; i < n; ++i) {
            PM.MarketView memory v = pm.getMarket(h.mids(i));
            if (v.asset != asset) continue;
            if (v.state == PM.State.Open) {
                open += v.pot;
            } else {
                uint256 rem = v.state == PM.State.Void ? v.yes + v.no : v.state == PM.State.Yes ? v.yes : v.no;
                if (v.winners != 0) settled += rem * v.pot / v.winners;
            }
        }
    }

    function _solvent(address asset, uint256 ai) internal view {
        uint256 bal = asset == address(0) ? address(pm).balance : tok.balanceOf(address(pm));
        (uint256 open, uint256 settled) = _obligations(asset);
        uint256 fees = h.feesFor(asset);
        assertGe(bal, open + fees, "loose solvency");
        assertGe(bal, open + settled + fees, "strict solvency");
        assertEq(bal, h.paidIn(ai) - h.paidOut(ai), "ledger");
        assertLe(h.paidOut(ai), h.paidIn(ai), "out <= in");
    }

    function invariant_solvencyETH() public view {
        _solvent(address(0), 0);
    }

    function invariant_solvencyToken() public view {
        _solvent(address(tok), 1);
    }

    function invariant_openPotCoversShares() public view {
        uint256 n = h.marketCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = h.mids(i);
            PM.MarketView memory v = pm.getMarket(id);
            if (v.state == PM.State.Open) {
                assertGe(v.pot, v.yes + v.no, "pot < shares");
                assertEq(v.pot, h.mIn(id) - h.mExit(id), "open pot ledger");
            } else {
                assertEq(v.pot + h.mToFees(id), h.mIn(id) - h.mExit(id), "settled pot ledger");
                assertLe(h.mClaimed(id), v.pot, "claimed > pot");
                uint256 rem = v.state == PM.State.Void ? v.yes + v.no : v.state == PM.State.Yes ? v.yes : v.no;
                assertLe(rem, v.winners, "remaining > winners");
            }
        }
    }

    function invariant_stateMachine() public view {
        assertTrue(h.checkStates(), "state/pot/winners changed after settlement");
    }

    function invariant_flags() public view {
        assertFalse(h.unexpectedRevert(), h.why());
        assertFalse(h.doubleClaim(), "double claim");
        assertFalse(h.residualTooBig(), "residual > claims");
    }

    function invariant_supplyMatchesBalances() public view {
        uint256 n = h.marketCount();
        uint256 k = h.actorCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = h.mids(i);
            for (uint256 side; side < 2; ++side) {
                uint256 sid = id | side;
                uint256 sum;
                for (uint256 j; j < k; ++j) {
                    sum += pm.balanceOf(h.actors(j), sid);
                }
                assertEq(sum, pm.totalSupply(sid), "supply != sum balances");
            }
        }
    }

    function afterInvariant() public view {
        console.log("markets", h.marketCount());
        console.log("bets", h.calls("bet"));
        console.log("exits", h.calls("exit"));
        console.log("claims", h.calls("claim"));
        console.log("resolves", h.calls("resolve"));
        console.log("voids", h.calls("void"));
        console.log("fullyClaimed", h.calls("fullyClaimed"));
        console.log("withdraws", h.calls("withdraw"));
        console.log("betFail", h.calls("betFail"));
        console.log("transfers", h.calls("transfer") + h.calls("transferFrom"));
    }
}

/// Directed edge cases.
contract PMAuditDirected is Test {
    PM pm;
    address r = address(0xAA01);
    address a = address(0xAA02);
    address b = address(0xAA03);

    function setUp() public {
        vm.warp(1_700_000_000);
        pm = new PM();
        vm.deal(a, 100 ether);
        vm.deal(b, 100 ether);
    }

    function test_voidZeroSharesPotToResolver() public {
        uint256 id = pm.createMarket("x", r, address(0), uint48(block.timestamp + 100), false, 5000, 0);
        vm.prank(a);
        pm.betETH{value: 1 ether}(id, true, a, 0, "");
        vm.prank(a);
        pm.exit(id, true, 1 ether, a);
        assertEq(pm.getMarket(id).pot, 0.5 ether);
        vm.warp(block.timestamp + 100);
        vm.prank(r);
        pm.resolve(id, true); // both sides empty -> void, pot to resolver
        assertEq(pm.feesOwed(r, address(0)), 0.5 ether);
        assertEq(uint8(pm.getMarket(id).state), 3);
        vm.prank(r);
        pm.withdrawFees(address(0), r);
        assertEq(address(pm).balance, 0);
    }

    function test_oneSidedResolveVoidsFeeFree() public {
        vm.prank(r);
        pm.setResolverFeeBps(1000);
        uint256 id = pm.createMarket("x", r, address(0), uint48(block.timestamp + 100), false, 0, 0);
        vm.prank(a);
        pm.betETH{value: 1 ether}(id, true, a, 0, "");
        vm.warp(block.timestamp + 100);
        vm.prank(r);
        pm.resolve(id, false);
        assertEq(pm.feesOwed(r, address(0)), 0);
        vm.prank(a);
        assertEq(pm.claim(id, a), 1 ether);
    }

    function test_rampExitsEveryPoint() public {
        uint256 id = pm.createMarket("x", r, address(0), uint48(block.timestamp + 1000), false, 1, 5000);
        vm.prank(a);
        uint256 sh = pm.betETH{value: 10 ether}(id, true, a, 0, "");
        for (uint256 t; t < 1000; t += 37) {
            vm.warp(1_700_000_000 + t);
            vm.prank(a);
            pm.exit(id, true, sh / 40, a);
            PM.MarketView memory v = pm.getMarket(id);
            assertGe(v.pot, v.yes + v.no);
        }
    }

    function test_closeAtOpenBlock() public {
        uint256 id = pm.createMarket("x", r, address(0), uint48(block.timestamp + 1000), true, 0, 5000);
        vm.prank(r);
        pm.closeMarket(id);
        // span == 0: trading is closed, quote returns zeros rather than dividing by zero
        (uint256 s, uint256 p) = pm.quote(id, true, 1 ether);
        assertEq(s + p, 0);
        vm.prank(a);
        vm.expectRevert(PM.TradingClosed.selector);
        pm.betETH{value: 1}(id, true, a, 0, "");
        vm.prank(r);
        pm.resolve(id, true); // no shares -> void
        assertEq(uint8(pm.getMarket(id).state), 3);
    }

    /// Claim math is full precision: shares * pot above 2^256 still pays out.
    function test_claimHugeSupplyToken() public {
        PMMockToken t = new PMMockToken();
        uint256 big = 2 ** 130;
        t.mint(a, big);
        t.mint(b, big);
        vm.prank(a);
        t.approve(address(pm), type(uint256).max);
        vm.prank(b);
        t.approve(address(pm), type(uint256).max);
        uint256 id = pm.createMarket("x", r, address(t), uint48(block.timestamp + 100), false, 0, 0);
        vm.prank(a);
        pm.bet(id, true, big, a, 0);
        vm.prank(b);
        pm.bet(id, false, big, b, 0);
        vm.warp(block.timestamp + 100);
        vm.prank(r);
        pm.resolve(id, true);
        vm.prank(a);
        assertEq(pm.claim(id, a), 2 * big);
    }
}
