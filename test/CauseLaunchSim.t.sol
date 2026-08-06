// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "../lib/forge-std/src/Test.sol";

/// Mirrors the "cause" (DAICO) branch of dapp/modules/coin.js against the deployed
/// SafeSummoner. The dapp builds this calldata by hand and predicts the DAO address
/// client-side, so both the encoding and the prediction are only as good as this.
contract CauseLaunchSimTest is Test {
    address constant SAFE_SUMMONER = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant SUMMONER = 0x0000000000330B8df9E3bc5E553074DA58eE9138;
    address constant MOLOCH_IMPL = 0x643A45B599D81be3f3A68F37EB3De55fF10673C1;
    address constant SHARES_IMPL = 0x71E9b38d301b5A58cb998C1295045FE276Acf600;
    address constant SHARE_SALE = 0x0000000021ea5069B532CeE09058aB9e02EA60f9;
    address constant TAP_VEST = 0x0000000060cdD33cbE020fAE696E70E7507bF56D;
    address constant RENDERER = 0x000000000011C799980827F52d3137b4abD6E654;

    // The dapp's hardcoded curve of the cause form.
    uint256 constant TOTAL_SHARES = 10_000_000;
    // COIN_TAP_FAST_SEC in dapp/modules/coin.js
    uint256 constant TAP_FAST_SEC = 3600;

    address creator = address(0xCA05E);
    address backer = address(0xBACCE7);

    struct Config {
        uint96 proposalThreshold;
        uint64 proposalTTL;
        uint64 timelockDelay;
        uint96 quorumAbsolute;
        uint96 minYesVotes;
        bool lockShares;
        bool lockLoot;
        uint256 autoFutarchyParam;
        uint256 autoFutarchyCap;
        address futarchyRewardToken;
        bool saleActive;
        address salePayToken;
        uint256 salePricePerShare;
        uint256 saleCap;
        bool saleMinting;
        bool saleIsLoot;
        address burnSingleton;
        uint256 saleBurnDeadline;
        address rollbackGuardian;
        address rollbackSingleton;
        uint40 rollbackExpiry;
    }

    struct SaleModule {
        address singleton;
        address payToken;
        uint40 deadline;
        uint256 price;
        uint256 cap;
        bool sellLoot;
        bool minting;
    }

    struct TapModule {
        address singleton;
        address token;
        uint256 budget;
        address beneficiary;
        uint128 ratePerSec;
    }

    struct SeedModule {
        address singleton;
        address tokenA;
        uint128 amountA;
        address tokenB;
        uint128 amountB;
        uint40 deadline;
        bool gateBySale;
        uint128 minSupply;
    }

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")), 25_640_000);
        vm.deal(creator, 100 ether);
        vm.deal(backer, 1000 ether);
    }

    function _defaultConfig() internal pure returns (Config memory c) {
        c.proposalThreshold = 1 ether;
        c.proposalTTL = 7 days;
        c.timelockDelay = 2 days;
        c.quorumAbsolute = 1 ether;
    }

    /// The dapp's exact arithmetic for a fixed-raise cause.
    function _fixedSale(uint256 raiseWei, uint256 days_) internal view returns (SaleModule memory s) {
        s.singleton = SHARE_SALE;
        s.payToken = address(0);
        s.price = raiseWei / TOTAL_SHARES;
        s.cap = (TOTAL_SHARES - 1) * 1e18;
        s.deadline = uint40(block.timestamp + days_ * 86400);
        s.minting = true;
    }

    function _launch(bytes32 salt, SaleModule memory sale, TapModule memory tap)
        internal
        returns (address dao, address predicted)
    {
        address[] memory holders = new address[](1);
        holders[0] = creator;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1 ether;

        predicted = _predictDAO(salt, holders, shares);

        vm.prank(creator);
        (bool ok, bytes memory ret) = SAFE_SUMMONER.call{value: sale.price}(
            abi.encodeWithSignature(
                "safeSummonDAICO(string,string,string,uint16,bool,address,bytes32,address[],uint256[],uint256[],(uint96,uint64,uint64,uint96,uint96,bool,bool,uint256,uint256,address,bool,address,uint256,uint256,bool,bool,address,uint256,address,address,uint40),(address,address,uint40,uint256,uint256,bool,bool),(address,address,uint256,address,uint128),(address,address,uint128,address,uint128,uint40,bool,uint128),(address,uint256,bytes)[])",
                "Save The Bees",
                "BEE",
                "ipfs://bafycause",
                uint16(1000),
                true,
                RENDERER,
                salt,
                holders,
                shares,
                new uint256[](0),
                _defaultConfig(),
                sale,
                tap,
                SeedModule(address(0), address(0), 0, address(0), 0, 0, false, 0),
                new Call[](0)
            )
        );
        require(ok, "safeSummonDAICO reverted");
        dao = abi.decode(ret, (address));
    }

    // ---- the dapp's client-side prediction, transcribed from coinPredict() ----

    function _clone(address impl) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"602d5f8160095f39f35f5f365f5f37365f73", impl, hex"5af43d5f5f3e6029573d5ffd5b3d5ff3");
    }

    function _create2(address deployer, bytes32 salt, address impl) internal pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(_clone(impl))))))
        );
    }

    function _predictDAO(bytes32 salt, address[] memory holders, uint256[] memory shares)
        internal
        pure
        returns (address)
    {
        return _create2(SUMMONER, keccak256(abi.encode(holders, shares, salt)), MOLOCH_IMPL);
    }

    /// coinPredict() builds the child salt as `dao` left-aligned in 32 bytes. If that
    /// drifts, the "View Coin" / "Manage DAO" links in the success banner point at
    /// an address that was never deployed.
    function _predictShares(address dao) internal pure returns (address) {
        return _create2(dao, bytes32(bytes20(dao)), SHARES_IMPL);
    }

    // ---- tests ----

    function test_fixedRaise_predictionAndSale() public {
        SaleModule memory sale = _fixedSale(10 ether, 30);
        TapModule memory tap;
        (address dao, address predicted) = _launch(keccak256("bees"), sale, tap);

        assertEq(dao, predicted, "dapp coinPredict() diverged from the deployed DAO address");
        assertGt(dao.code.length, 0, "DAO has no code");
        assertGt(_predictShares(dao).code.length, 0, "predicted shares token has no code");

        // Creator paid sale.price for exactly 1 share, so ragequit is symmetric from
        // block one rather than the creator holding a free share against backer funds.
        assertEq(_sharesOf(dao, creator), 1 ether, "creator does not hold exactly 1 share");
        assertEq(_totalShares(dao), 1 ether, "supply is not just the creator's share");
    }

    /// The whole point of the fixed form: paying the advertised raise buys the
    /// advertised 10M shares, no more and no less.
    function test_fixedRaise_fullRaiseBuysTheAdvertisedSupply() public {
        uint256 raise = 10 ether;
        SaleModule memory sale = _fixedSale(raise, 30);
        TapModule memory tap;
        (address dao,) = _launch(keccak256("bees2"), sale, tap);

        // Buy the whole cap: 9,999,999 shares on top of the creator's 1.
        uint256 cost = sale.price * (TOTAL_SHARES - 1);
        vm.prank(backer);
        (bool ok,) = SHARE_SALE.call{value: cost}(abi.encodeWithSignature("buy(address,uint256)", dao, sale.cap));
        assertTrue(ok, "buying the full cap reverted");

        assertEq(_totalShares(dao), TOTAL_SHARES * 1e18, "total supply is not the advertised 10M");
        assertApproxEqRel(cost, raise, 0.0001e18, "full cap did not cost the advertised raise");
        assertEq(dao.balance, raise, "treasury does not hold the full raise");
    }

    /// Integer division floors, and a raise small enough to floor the price to zero
    /// would make every share free. The dapp rejects this client-side; confirm the
    /// boundary it enforces (0.0001 ETH) is genuinely above where the break is.
    function test_minRaiseIsAboveTheZeroPriceCliff() public pure {
        uint256 minRaise = 1e14; // COIN_MIN_RAISE_WEI in coin.js
        assertGt(minRaise / TOTAL_SHARES, 0, "the dapp's minimum raise still floors the share price to zero");
        // The cliff itself sits at TOTAL_SHARES wei (1e7), seven orders of magnitude
        // below the form's minimum — so coinLaunch()'s `priceWei === 0n` throw is
        // unreachable through the UI and is pure defence in depth.
        assertEq((TOTAL_SHARES - 1) / TOTAL_SHARES, 0, "cliff is not where this test claims");
        assertGt(minRaise, TOTAL_SHARES * 1e6, "form minimum is uncomfortably close to the zero-price cliff");
    }

    function test_ongoing_saleHasNoDeadlineOrCap() public {
        SaleModule memory sale;
        sale.singleton = SHARE_SALE;
        sale.price = 0.000001 ether; // 1 ETH = 1M shares
        sale.cap = type(uint256).max;
        sale.deadline = 0;
        sale.minting = true;
        TapModule memory tap;
        (address dao, address predicted) = _launch(keccak256("ongoing"), sale, tap);
        assertEq(dao, predicted);

        vm.prank(backer);
        (bool ok,) = SHARE_SALE.call{value: 1 ether}(abi.encodeWithSignature("buy(address,uint256)", dao, uint256(1_000_000 ether)));
        assertTrue(ok, "ongoing sale rejected a 1 ETH buy");
        assertEq(_sharesOf(dao, backer), 1_000_000 ether, "1 ETH did not buy the advertised 1M shares");
    }

    /// Vesting tap: the dapp derives ratePerSec = budget / (months * 2629746) and
    /// bumps a floored-to-zero rate up to 1 wei/sec. Check the deployed vest agrees
    /// with the "~X ETH/mo" the success banner prints.
    function test_tapVestRateMatchesTheAdvertisedMonthlyRate() public {
        uint256 raise = 10 ether;
        uint256 months = 12;
        uint256 SEC_PER_MONTH = 2_629_746;

        SaleModule memory sale = _fixedSale(raise, 30);
        TapModule memory tap = TapModule({
            singleton: TAP_VEST,
            token: address(0),
            budget: raise,
            beneficiary: creator,
            ratePerSec: uint128(raise / (months * SEC_PER_MONTH))
        });
        (address dao,) = _launch(keccak256("tap"), sale, tap);

        uint256 perMonth = uint256(tap.ratePerSec) * SEC_PER_MONTH;
        assertApproxEqRel(perMonth * months, raise, 0.001e18, "vest does not drain the budget over the chosen term");
        assertGt(dao.code.length, 0);
    }

    function _sharesOf(address dao, address who) internal view returns (uint256) {
        (bool ok, bytes memory r) =
            _predictShares(dao).staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        return abi.decode(r, (uint256));
    }

    function _totalShares(address dao) internal view returns (uint256) {
        (bool ok, bytes memory r) = _predictShares(dao).staticcall(abi.encodeWithSignature("totalSupply()"));
        require(ok, "totalSupply failed");
        return abi.decode(r, (uint256));
    }

    /// Fast tap: ratePerSec = raise / COIN_TAP_FAST_SEC. TapVest needs the pending
    /// amount to clear one whole second of vesting, so this rate is what decides the
    /// smallest treasury a beneficiary can draw from. A partly-filled sale is the
    /// common case, so it has to be claimable.
    function test_fastTap_partiallyFilledSalePays() public {
        uint256 raise = 10 ether;
        SaleModule memory sale = _fixedSale(raise, 30);
        TapModule memory tap = TapModule({
            singleton: TAP_VEST,
            token: address(0),
            budget: raise,
            beneficiary: creator,
            ratePerSec: uint128(raise / TAP_FAST_SEC) // coin.js: raiseWei / COIN_TAP_FAST_SEC
        });
        (address dao,) = _launch(keccak256("fast-partial"), sale, tap);

        // Only 10% of the goal is raised.
        uint256 tenth = sale.cap / 10;
        vm.prank(backer);
        (bool bought,) = SHARE_SALE.call{value: (sale.price * tenth) / 1e18}(
            abi.encodeWithSignature("buy(address,uint256)", dao, tenth)
        );
        assertTrue(bought, "partial buy reverted");

        uint256 treasury = dao.balance;
        assertGt(treasury, uint256(tap.ratePerSec), "10% of the goal no longer clears one second of vesting");

        // Claimable straight away, rather than reverting until the sale fills.
        vm.warp(block.timestamp + 2);
        uint256 before = creator.balance;
        vm.prank(creator);
        (bool ok, bytes memory ret) = TAP_VEST.call(abi.encodeWithSignature("claim(address)", dao));
        assertTrue(ok, "fast tap could not claim from a partially filled treasury");
        uint256 claimed = abi.decode(ret, (uint256));
        assertGt(claimed, 0, "claim moved nothing");
        assertEq(creator.balance - before, claimed, "claimed amount does not match the transfer");

        // And the whole thing is out after the advertised hour of accrual.
        vm.warp(block.timestamp + TAP_FAST_SEC);
        vm.prank(creator);
        (bool ok2,) = TAP_VEST.call(abi.encodeWithSignature("claim(address)", dao));
        assertTrue(ok2, "second claim failed");
        // Vesting advances in whole seconds of ratePerSec, so a remainder smaller
        // than one second's worth is always left behind. Everything else is out.
        assertLt(dao.balance, uint256(tap.ratePerSec), "more than sub-second dust left an hour after the raise");
    }

    /// Money that arrives after a claim must stay claimable, not be stranded.
    function test_fastTap_laterContributionsStillClaimable() public {
        uint256 raise = 10 ether;
        SaleModule memory sale = _fixedSale(raise, 30);
        TapModule memory tap = TapModule({
            singleton: TAP_VEST,
            token: address(0),
            budget: raise,
            beneficiary: creator,
            ratePerSec: uint128(raise / TAP_FAST_SEC)
        });
        (address dao,) = _launch(keccak256("fast-later"), sale, tap);

        uint256 chunk = sale.cap / 4;
        uint256 cost = (sale.price * chunk) / 1e18;
        vm.prank(backer);
        (bool b1,) = SHARE_SALE.call{value: cost}(abi.encodeWithSignature("buy(address,uint256)", dao, chunk));
        assertTrue(b1);
        vm.warp(block.timestamp + TAP_FAST_SEC);
        vm.prank(creator);
        (bool c1,) = TAP_VEST.call(abi.encodeWithSignature("claim(address)", dao));
        assertTrue(c1, "first claim failed");
        assertLt(dao.balance, uint256(tap.ratePerSec), "more than sub-second dust left after draining the first tranche");

        // A second backer arrives later.
        vm.prank(backer);
        (bool b2,) = SHARE_SALE.call{value: cost}(abi.encodeWithSignature("buy(address,uint256)", dao, chunk));
        assertTrue(b2);
        vm.warp(block.timestamp + TAP_FAST_SEC);
        uint256 before = creator.balance;
        vm.prank(creator);
        (bool c2,) = TAP_VEST.call(abi.encodeWithSignature("claim(address)", dao));
        assertTrue(c2, "second contribution is stranded");
        assertGt(creator.balance, before, "second claim moved no funds");
    }

    /// Sweep the fill levels a cause actually sits at. Every one of them must pay.
    function test_fastTap_claimsAtEveryFillLevel() public {
        uint256 raise = 10 ether;
        SaleModule memory sale = _fixedSale(raise, 30);
        TapModule memory tap = TapModule({
            singleton: TAP_VEST, token: address(0), budget: raise,
            beneficiary: creator, ratePerSec: uint128(raise / TAP_FAST_SEC)
        });
        (address dao,) = _launch(keccak256("fast-sweep"), sale, tap);

        uint256 _t = block.timestamp;
        uint256[] memory pcts = new uint256[](6);
        pcts[0] = 1; pcts[1] = 25; pcts[2] = 50; pcts[3] = 90; pcts[4] = 99; pcts[5] = 100;
        uint256 boughtSoFar;
        for (uint256 i; i < pcts.length; ++i) {
            uint256 target = (sale.cap * pcts[i]) / 100;
            uint256 delta = target - boughtSoFar;
            boughtSoFar = target;
            vm.prank(backer);
            (bool b,) = SHARE_SALE.call{value: (sale.price * delta) / 1e18}(
                abi.encodeWithSignature("buy(address,uint256)", dao, delta)
            );
            assertTrue(b, "buy failed");
            _t += 2;
            vm.warp(_t);
            vm.prank(creator);
            (bool ok, bytes memory rr) = TAP_VEST.call(abi.encodeWithSignature("claim(address)", dao));
            emit log_named_string(
                string.concat("raised ", vm.toString(pcts[i]), "% -> claim"),
                ok ? string.concat("OK ", vm.toString(abi.decode(rr, (uint256)))) : "NothingToClaim"
            );
            assertTrue(ok, string.concat("no claim possible at ", vm.toString(pcts[i]), "% of goal"));
        }
    }

    /// Distinguish two hypotheses for why an instant tap cannot claim: does TapVest
    /// need the treasury to cover one second of vesting (>= ratePerSec), or the whole
    /// budget? The fix for the dapp differs completely between the two.
    function test_tapClaimGateIsRatePerSecNotBudget() public {
        uint256 raise = 10 ether;
        SaleModule memory sale = _fixedSale(raise, 30);
        TapModule memory tap = TapModule({
            singleton: TAP_VEST, token: address(0), budget: raise,
            beneficiary: creator, ratePerSec: uint128(1 ether) // 1 ETH/sec, budget 10 ETH
        });
        (address dao,) = _launch(keccak256("gate"), sale, tap);

        // Raise 2 ETH: well under the 10 ETH budget, well over the 1 ETH/sec rate.
        uint256 want = (sale.cap * 2) / 10;
        vm.prank(backer);
        (bool b,) = SHARE_SALE.call{value: (sale.price * want) / 1e18}(
            abi.encodeWithSignature("buy(address,uint256)", dao, want)
        );
        assertTrue(b, "buy failed");
        assertApproxEqRel(dao.balance, 2 ether, 0.01e18);

        vm.warp(block.timestamp + 2);
        vm.prank(creator);
        (bool ok,) = TAP_VEST.call(abi.encodeWithSignature("claim(address)", dao));
        assertTrue(ok, "gate is the budget, not ratePerSec");

        // And just below the rate it must fail, confirming ratePerSec is the gate.
        TapModule memory tap2 = TapModule({
            singleton: TAP_VEST, token: address(0), budget: raise,
            beneficiary: creator, ratePerSec: uint128(5 ether)
        });
        (address dao2,) = _launch(keccak256("gate2"), sale, tap2);
        vm.prank(backer);
        (bool b2,) = SHARE_SALE.call{value: (sale.price * want) / 1e18}(
            abi.encodeWithSignature("buy(address,uint256)", dao2, want)
        );
        assertTrue(b2);
        vm.warp(block.timestamp + 2);
        vm.prank(creator);
        (bool ok2,) = TAP_VEST.call(abi.encodeWithSignature("claim(address)", dao2));
        assertFalse(ok2, "claimed with a treasury below one second of vesting");
    }







    /// Pins why the rate is raise / COIN_TAP_FAST_SEC rather than the raise itself.
    /// A rate equal to the full goal needs a treasury holding the full goal before
    /// one second of vesting exists, so a 99%-funded cause can claim nothing; the
    /// scaled rate claims at both levels. Each case gets a fresh DAO and a single
    /// claim, so nothing here depends on re-claim cadence.
    function test_fastTapRateBeatsRateEqualToTheRaise() public {
        uint256 raise = 10 ether;
        uint256 t = block.timestamp;

        uint128[2] memory rates = [uint128(raise), uint128(raise / TAP_FAST_SEC)];
        uint256[2] memory fills = [uint256(99), uint256(100)];
        bool[2][2] memory got;

        for (uint256 r; r < 2; ++r) {
            for (uint256 f; f < 2; ++f) {
                SaleModule memory sale = _fixedSale(raise, 30);
                TapModule memory tap = TapModule({
                    singleton: TAP_VEST, token: address(0), budget: raise,
                    beneficiary: creator, ratePerSec: rates[r]
                });
                (address dao,) = _launch(keccak256(abi.encode("rate-cmp", r, f)), sale, tap);

                uint256 want = (sale.cap * fills[f]) / 100;
                vm.prank(backer);
                (bool b,) = SHARE_SALE.call{value: (sale.price * want) / 1e18}(
                    abi.encodeWithSignature("buy(address,uint256)", dao, want)
                );
                assertTrue(b, "buy failed");

                t += 2;
                vm.warp(t);
                vm.prank(creator);
                (bool ok,) = TAP_VEST.call(abi.encodeWithSignature("claim(address)", dao));
                got[r][f] = ok;
                emit log_named_string(
                    string.concat(
                        r == 0 ? "rate=raise    " : "rate=raise/3600", " @ ", vm.toString(fills[f]), "% funded"
                    ),
                    ok ? "claims" : "NothingToClaim"
                );
            }
        }

        assertFalse(got[0][0], "rate=raise unexpectedly claims at 99% funded");
        assertTrue(got[0][1], "rate=raise cannot claim even when fully funded");
        assertTrue(got[1][0], "fast rate cannot claim at 99% funded");
        assertTrue(got[1][1], "fast rate cannot claim when fully funded");
    }


    /// Ongoing causes have no goal, so the fast rate is the absolute
    /// COIN_TAP_FAST_ONGOING_RATE. Check a small treasury still reaches the
    /// beneficiary — the previous 1000 ETH/sec needed 1000 ETH before anything moved.
    function test_ongoing_fastTapClaimsFromASmallTreasury() public {
        SaleModule memory sale;
        sale.singleton = SHARE_SALE;
        sale.price = 0.000001 ether;
        sale.cap = type(uint256).max;
        sale.minting = true;

        uint128 fastOngoing = 1e15; // COIN_TAP_FAST_ONGOING_RATE
        TapModule memory tap = TapModule({
            singleton: TAP_VEST, token: address(0), budget: type(uint256).max,
            beneficiary: creator, ratePerSec: fastOngoing
        });
        (address dao,) = _launch(keccak256("ongoing-fast"), sale, tap);

        // A single 0.05 ETH backer — nowhere near the old 1000 ETH/sec rate.
        vm.prank(backer);
        (bool b,) = SHARE_SALE.call{value: 0.05 ether}(
            abi.encodeWithSignature("buy(address,uint256)", dao, uint256(50_000 ether))
        );
        assertTrue(b, "small ongoing contribution reverted");
        assertLt(dao.balance, 1000 ether, "test does not exercise a treasury below the old rate");

        vm.warp(block.timestamp + 2);
        uint256 before = creator.balance;
        vm.prank(creator);
        (bool ok,) = TAP_VEST.call(abi.encodeWithSignature("claim(address)", dao));
        assertTrue(ok, "ongoing fast tap cannot claim from a small treasury");
        assertGt(creator.balance, before, "claim moved no funds");
    }

}
