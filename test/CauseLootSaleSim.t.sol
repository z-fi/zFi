// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "../lib/forge-std/src/Test.sol";

/// The loot branch of dapp/modules/coin.js, end to end against the deployed SafeSummoner.
///
/// Every piece of this was already covered somewhere and the combination was covered
/// nowhere: ShareOffering.t.sol proves the loot sentinel resolves, but against a DAO that
/// already exists and an offering it configures by hand. The dapp does it differently —
/// it predicts the DAO's address before anything is deployed and wires the sale from
/// inside init, through extraCalls that run in the DAO's own context. That is the path a
/// real launch takes and the path nothing executed.
///
/// The two calls have to agree on the mint sentinel. Point the allowance at one token and
/// the terms at another and the offering holds permission to mint shares while selling
/// loot: it would pass this file's first assertion and fail at the first buy, after the
/// summon has been paid for.
contract CauseLootSaleSimTest is Test {
    address constant SAFE_SUMMONER = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant SUMMONER = 0x0000000000330B8df9E3bc5E553074DA58eE9138;
    address constant MOLOCH_IMPL = 0x643A45B599D81be3f3A68F37EB3De55fF10673C1;
    address constant SHARE_OFFERING = 0x000000A4Ad929C9E108aD2B1D2fBeDe0C2Ae57e1;
    address constant RENDERER = 0x000000000011C799980827F52d3137b4abD6E654;

    /// The mint sentinel. Moloch._payout routes this to loot.mintFromMoloch.
    address constant LOOT = address(1007);

    // The dapp's fixed-raise curve: 10M units, 9,999,999 of them for sale.
    uint256 constant TOTAL = 10_000_000;
    uint256 constant CAP = (TOTAL - 1) * 1e18;

    address creator = address(0xCA05E);
    address backer = address(0xBACCE7);
    address backer2 = address(0xB2);

    struct Config {
        uint96 proposalThreshold; uint64 proposalTTL; uint64 timelockDelay;
        uint96 quorumAbsolute; uint96 minYesVotes; bool lockShares; bool lockLoot;
        uint256 autoFutarchyParam; uint256 autoFutarchyCap; address futarchyRewardToken;
        bool saleActive; address salePayToken; uint256 salePricePerShare; uint256 saleCap;
        bool saleMinting; bool saleIsLoot; address burnSingleton; uint256 saleBurnDeadline;
        address rollbackGuardian; address rollbackSingleton; uint40 rollbackExpiry;
    }
    struct SaleModule {
        address singleton; address payToken; uint40 deadline;
        uint256 price; uint256 cap; bool sellLoot; bool minting;
    }
    struct TapModule {
        address singleton; address token; uint256 budget; address beneficiary; uint128 ratePerSec;
    }
    struct SeedModule {
        address singleton; address tokenA; uint128 amountA; address tokenB;
        uint128 amountB; uint40 deadline; bool gateBySale; uint128 minSupply;
    }
    struct Call { address target; uint256 value; bytes data; }

    /// Past ShareOffering's deploy at 25,814,833 — the repo-wide pin at 25,640,000
    /// predates it, and forking there means testing a local instance rather than the
    /// singleton the launcher actually sends people to.
    uint256 constant FORK_BLOCK = 25_820_000;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")), FORK_BLOCK
        );
        // The launcher hardcodes this address, so the test uses the code that is really
        // at it. Substituting a local build on a fork that predates the deploy would
        // still pass and would prove nothing about what a launch actually calls, so an
        // empty address fails here rather than being quietly filled in.
        require(SHARE_OFFERING.code.length != 0, "ShareOffering not deployed at FORK_BLOCK");
        require(SAFE_SUMMONER.code.length != 0, "SafeSummoner not deployed at FORK_BLOCK");
        vm.deal(creator, 100 ether);
        vm.deal(backer, 1000 ether);
        vm.deal(backer2, 1000 ether);
    }

    /// coinLaunch()'s loot branch, transcribed.
    function _launchLoot(bytes32 salt, uint256 raiseWei, uint256 days_)
        internal
        returns (address dao, uint256 price)
    {
        address[] memory holders = new address[](1);
        holders[0] = creator;
        uint256[] memory shares = new uint256[](1);
        shares[0] = 1 ether;

        dao = _predictDAO(salt, holders, shares);
        price = raiseWei / TOTAL;

        // Both legs key to the same sentinel. This is the pairing under test.
        Call[] memory extra = new Call[](2);
        extra[0] = Call(dao, 0, abi.encodeWithSignature(
            "setAllowance(address,address,uint256)", SHARE_OFFERING, LOOT, type(uint256).max));
        extra[1] = Call(SHARE_OFFERING, 0, abi.encodeWithSignature(
            "configure(address,address,uint256,uint40,uint256)",
            LOOT, address(0), price, uint40(block.timestamp + days_ * 86400), CAP));

        Config memory cfg;
        cfg.proposalThreshold = 1 ether;
        cfg.proposalTTL = 7 days;
        cfg.timelockDelay = 2 days;
        cfg.quorumAbsolute = 1 ether;

        vm.prank(creator);
        (bool ok, bytes memory ret) = SAFE_SUMMONER.call{value: price}(
            abi.encodeWithSignature(
                "safeSummonDAICO(string,string,string,uint16,bool,address,bytes32,address[],uint256[],uint256[],(uint96,uint64,uint64,uint96,uint96,bool,bool,uint256,uint256,address,bool,address,uint256,uint256,bool,bool,address,uint256,address,address,uint40),(address,address,uint40,uint256,uint256,bool,bool),(address,address,uint256,address,uint128),(address,address,uint128,address,uint128,uint40,bool,uint128),(address,uint256,bytes)[])",
                "Save The Bees", "BEE", "ipfs://bafyloot", uint16(1000), true, RENDERER, salt,
                holders, shares, new uint256[](0), cfg,
                SaleModule(address(0), address(0), 0, 0, 0, false, false),
                TapModule(address(0), address(0), 0, address(0), 0),
                SeedModule(address(0), address(0), 0, address(0), 0, 0, false, 0),
                extra
            )
        );
        require(ok, "safeSummonDAICO reverted");
        assertEq(abi.decode(ret, (address)), dao, "coinPredict() diverged from the deployed DAO");
    }

    // ---- tests ----

    /// The founder's share is minted as a SHARE. If it landed in the loot supply the cap
    /// would be one unit short and the dapp's arithmetic would be wrong by that much.
    function test_lootRaise_deploysWithTheVoteHeldAndNoLootMinted() public {
        (address dao,) = _launchLoot(keccak256("loot1"), 10 ether, 30);

        assertEq(_bal(_shares(dao), creator), 1 ether, "creator does not hold exactly 1 share");
        assertEq(_supply(_shares(dao)), 1 ether, "shares supply is not just the founder's");
        assertEq(_supply(_loot(dao)), 0, "loot was minted before anyone bought any");
        assertEq(_remaining(dao), CAP, "the whole cap should be for sale at launch");
    }

    /// The buy that the mismatched-sentinel bug would fail: it mints loot, not shares.
    function test_buyingMintsLootAndLeavesTheShareSupplyAlone() public {
        (address dao, uint256 price) = _launchLoot(keccak256("loot2"), 10 ether, 30);
        uint256 want = 1_000_000 ether;
        uint256 cost = price * want / 1e18;

        vm.prank(backer);
        (bool ok,) = SHARE_OFFERING.call{value: cost}(
            abi.encodeWithSignature("buy(address,uint256)", dao, want));
        assertTrue(ok, "buying loot reverted");

        assertEq(_bal(_loot(dao), backer), want, "backer did not receive loot");
        assertEq(_bal(_shares(dao), backer), 0, "backer received shares from a loot sale");
        assertEq(_supply(_shares(dao)), 1 ether, "the share supply moved on a loot sale");
        assertEq(_supply(_loot(dao)), want, "loot supply does not match what was sold");
    }

    /// What the page tells a backer: loot funds the treasury and cannot govern it. Only
    /// shares carry weight and only shares are the quorum denominator, so the founder's
    /// single share is the entire electorate.
    function test_lootCarriesNoVoteAndNoQuorumWeight() public {
        (address dao, uint256 price) = _launchLoot(keccak256("loot3"), 10 ether, 30);
        vm.prank(backer);
        SHARE_OFFERING.call{value: price * 5_000_000}(
            abi.encodeWithSignature("buy(address,uint256)", dao, uint256(5_000_000 ether)));

        vm.roll(block.number + 1);
        uint48 snap = uint48(block.number - 1);
        assertEq(_pastVotes(_shares(dao), backer, snap), 0, "loot carried a vote");
        assertEq(_pastVotes(_shares(dao), creator, snap), 1 ether, "founder lost the vote");
        // The quorum denominator Moloch snapshots. 5M loot outstanding does not enter it.
        assertEq(_pastTotalSupply(_shares(dao), snap), 1 ether,
            "loot entered the quorum denominator");
    }

    /// The full raise buys the full advertised supply, and the treasury holds it.
    function test_fullRaiseBuysTheAdvertisedLootAndClosesTheSale() public {
        uint256 raise = 10 ether;
        (address dao, uint256 price) = _launchLoot(keccak256("loot4"), raise, 30);
        uint256 cost = price * (TOTAL - 1);

        vm.prank(backer);
        (bool ok,) = SHARE_OFFERING.call{value: cost}(
            abi.encodeWithSignature("buy(address,uint256)", dao, CAP));
        assertTrue(ok, "buying the full cap reverted");

        assertEq(_supply(_loot(dao)), CAP, "loot supply is not the advertised 9,999,999");
        assertApproxEqRel(cost, raise, 0.0001e18, "the full cap did not cost the advertised raise");
        assertEq(dao.balance, raise, "treasury does not hold the full raise");
        assertEq(_remaining(dao), 0, "a sold-out sale still offers room");

        vm.prank(backer2);
        (bool ok2,) = SHARE_OFFERING.call{value: price}(
            abi.encodeWithSignature("buy(address,uint256)", dao, uint256(1 ether)));
        assertFalse(ok2, "a sold-out sale still sold");
    }

    /// Ragequit has to burn the LOOT slot. This is the call the page would have got wrong.
    function test_ragequitBurnsLootAndPaysProRata() public {
        (address dao, uint256 price) = _launchLoot(keccak256("loot5"), 10 ether, 30);
        uint256 want = 2_000_000 ether;
        vm.prank(backer);
        SHARE_OFFERING.call{value: price * 2_000_000}(
            abi.encodeWithSignature("buy(address,uint256)", dao, want));

        uint256 treasury = dao.balance;
        uint256 denom = _supply(_shares(dao)) + _supply(_loot(dao));
        uint256 burn = want / 2;
        uint256 expected = treasury * burn / denom;

        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        uint256 before = backer.balance;
        vm.prank(backer);
        (bool ok,) = dao.call(
            abi.encodeWithSignature("ragequit(address[],uint256,uint256)", tokens, uint256(0), burn));
        assertTrue(ok, "ragequitting loot reverted");

        assertEq(backer.balance - before, expected, "ragequit did not pay pro-rata");
        assertEq(_bal(_loot(dao), backer), want - burn, "loot was not burnt");
    }

    /// The reason this sale is on ShareOffering at all: the ceiling is read off live
    /// supply, so burnt loot hands its room back instead of shrinking the raise.
    function test_burntLootReturnsItsRoomToTheSale() public {
        (address dao, uint256 price) = _launchLoot(keccak256("loot6"), 10 ether, 30);
        vm.prank(backer);
        SHARE_OFFERING.call{value: price * 1_000_000}(
            abi.encodeWithSignature("buy(address,uint256)", dao, uint256(1_000_000 ether)));
        assertEq(_remaining(dao), CAP - 1_000_000 ether, "room did not fall by what was sold");

        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        vm.prank(backer);
        dao.call(abi.encodeWithSignature(
            "ragequit(address[],uint256,uint256)", tokens, uint256(0), uint256(1_000_000 ether)));

        assertEq(_remaining(dao), CAP, "redeemed loot did not return its room to the sale");
    }

    // ---- helpers ----

    function _shares(address dao) internal view returns (address) {
        return _addr(dao, "shares()");
    }
    function _loot(address dao) internal view returns (address) {
        return _addr(dao, "loot()");
    }
    function _addr(address to, string memory sig) internal view returns (address a) {
        (bool ok, bytes memory r) = to.staticcall(abi.encodeWithSignature(sig));
        require(ok, "addr read failed");
        a = abi.decode(r, (address));
    }
    function _bal(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok, "balanceOf failed");
        return abi.decode(r, (uint256));
    }
    function _supply(address token) internal view returns (uint256) {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("totalSupply()"));
        require(ok, "totalSupply failed");
        return abi.decode(r, (uint256));
    }
    function _remaining(address dao) internal view returns (uint256) {
        (bool ok, bytes memory r) =
            SHARE_OFFERING.staticcall(abi.encodeWithSignature("remaining(address)", dao));
        require(ok, "remaining failed");
        return abi.decode(r, (uint256));
    }
    function _pastVotes(address token, address who, uint48 blk) internal view returns (uint256) {
        (bool ok, bytes memory r) =
            token.staticcall(abi.encodeWithSignature("getPastVotes(address,uint48)", who, blk));
        require(ok, "getPastVotes failed");
        return abi.decode(r, (uint256));
    }
    function _pastTotalSupply(address token, uint48 blk) internal view returns (uint256) {
        (bool ok, bytes memory r) =
            token.staticcall(abi.encodeWithSignature("getPastTotalSupply(uint48)", blk));
        require(ok, "getPastTotalSupply failed");
        return abi.decode(r, (uint256));
    }

    function _clone(address impl) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"602d5f8160095f39f35f5f365f5f37365f73", impl, hex"5af43d5f5f3e6029573d5ffd5b3d5ff3");
    }
    function _predictDAO(bytes32 salt, address[] memory holders, uint256[] memory shares)
        internal pure returns (address)
    {
        bytes32 s = keccak256(abi.encode(holders, shares, salt));
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), SUMMONER, s, keccak256(_clone(MOLOCH_IMPL)))))));
    }
}
