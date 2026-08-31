// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";

/// @dev The deployed singletons the page hardcodes. If any of these is ever
///      repointed, this test fails loudly rather than testing an address the
///      page no longer uses.
interface IShareOffering {
    function sales(address dao)
        external
        view
        returns (address token, address payToken, uint40 deadline, uint256 price, uint256 cap);
    function remaining(address dao) external view returns (uint256);
    function buy(address dao, uint256 amount) external payable;
}

interface ITapVest {
    function taps(address dao)
        external
        view
        returns (address token, address beneficiary, uint128 ratePerSec, uint64 lastClaim);
    function claim(address dao) external returns (uint256);
}

interface IMoloch {
    function shares() external view returns (address);
    function loot() external view returns (address);
    function allowance(address token, address spender) external view returns (uint256);
    function ragequit(address[] calldata tokens, uint256 sharesToBurn, uint256 lootToBurn) external;
    function quorumBps() external view returns (uint16);
}

interface IToken {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function symbol() external view returns (string memory);
}

/// @title The page's own calldata, replayed against the real contracts.
///
/// WHY THIS TEST EXISTS AND THE UI SUITE DOES NOT REPLACE IT.
///
/// test/ui/cause-launch.test.mjs checks zSwap's cause calldata by decoding the
/// head and comparing it word by word against the ABI layout — as read by me,
/// from the same source the encoder was written from. That catches a
/// transposition. It cannot catch a shared misunderstanding: if the encoder and
/// the test both misread SafeSummoner's struct layout, they are wrong in the
/// same direction and both pass. The page ships as immutable contract code, so
/// that class of error is unrecoverable.
///
/// The only thing that settles the question is sending those exact bytes to the
/// deployed SafeSummoner and reading what actually came out. That is what this
/// does. The calldata is NOT constructed here — it is generated from the real
/// page by script/dump-cause-calldata.mjs into test/fixtures/cause-launch.json
/// and replayed verbatim. Nothing in this file re-implements the encoding, so
/// nothing in it can agree with the encoder by sharing its mistake.
///
/// Regenerate the fixture after any change to encCause():
///   node script/dump-cause-calldata.mjs
contract CauseLaunchCalldataTest is Test {
    address constant SAFE_SUMMONER = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant SHARE_OFFERING = 0x000000A4Ad929C9E108aD2B1D2fBeDe0C2Ae57e1;
    address constant TAP_VEST = 0x0000000060cdD33cbE020fAE696E70E7507bF56D;
    address constant LOOT_SENTINEL = 0x00000000000000000000000000000000000003eF;

    /// @dev The form the fixture was generated from: 10 ETH over 30 days,
    ///      released over 12 months. Read back out of the JSON so the numbers
    ///      asserted here and the numbers typed into the page cannot drift.
    uint256 goalWei;
    uint256 deadlineDays;
    uint256 vestSecs;
    /// @dev The second the page stamped the deadline with, recorded by the dumper.
    uint256 generatedAt;

    address launcher;
    address dao;
    address shares;
    address loot;

    address backer = address(uint160(uint256(keccak256("cause_calldata_backer"))));

    function setUp() public {
        vm.createSelectFork(vm.envOr("FOUNDRY_ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        string memory json = vm.readFile("test/fixtures/cause-launch.json");
        launcher = vm.parseJsonAddress(json, ".from");
        bytes memory data = vm.parseJsonBytes(json, ".data");
        address to = vm.parseJsonAddress(json, ".to");
        uint256 value = vm.parseJsonUint(json, ".value");

        goalWei = vm.parseUint(vm.parseJsonString(json, ".form.goal")) * 1 ether;
        deadlineDays = vm.parseUint(vm.parseJsonString(json, ".form.days"));
        vestSecs = vm.parseUint(vm.parseJsonString(json, ".form.vest"));
        generatedAt = vm.parseUint(vm.parseJsonString(json, ".generatedAt"));

        // The page must be talking to the summoner this test knows about.
        assertEq(to, SAFE_SUMMONER, "page targets a different summoner");

        vm.deal(launcher, 100 ether);
        vm.deal(backer, 100 ether);

        vm.prank(launcher);
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        assertTrue(ok, "the page's calldata reverted against the real SafeSummoner");
        dao = abi.decode(ret, (address));
        assertTrue(dao != address(0), "no DAO address returned");

        shares = IMoloch(dao).shares();
        loot = IMoloch(dao).loot();
    }

    /// The whole point: these bytes are accepted, and they build a DAO.
    function test_pageCalldata_summonsARealDAO() public view {
        assertTrue(dao.code.length > 0, "DAO has no code");
        assertTrue(shares.code.length > 0, "shares token has no code");
        assertTrue(loot.code.length > 0, "loot token has no code");
    }

    /// The founding share goes to WHOEVER SIGNED, not to the beneficiary. This
    /// is the bug the review caught: the two are different people the moment
    /// the beneficiary field is used, and the share carries the only vote.
    function test_foundingShare_belongsToTheLauncher() public view {
        assertEq(IToken(shares).balanceOf(launcher), 1 ether, "launcher does not hold the founding share");
        assertEq(IToken(shares).totalSupply(), 1 ether, "more than one share exists");
        assertEq(IToken(loot).totalSupply(), 0, "loot was minted before anyone backed");
    }

    /// The sale sells LOOT for ETHER, at the price the goal implies, with the
    /// ceiling the page set. Every number here is one the encoder wrote.
    function test_sale_isLootForEtherAtTheStatedPrice() public view {
        (address token, address payToken, uint40 deadline, uint256 price, uint256 cap) =
            IShareOffering(SHARE_OFFERING).sales(dao);

        assertEq(token, LOOT_SENTINEL, "sale does not mint loot");
        assertEq(payToken, address(0), "sale is not priced in ether");
        assertEq(price, goalWei / 10_000_000, "price does not follow from the goal");
        assertEq(cap, 9_999_999 ether, "wrong sale ceiling");
        /* Measured from when the PAGE stamped it, not from the fork's head
           block: the fixture is generated at some point before this runs, and
           comparing against `now` would make the test fail purely for being an
           hour old. What must hold is that the page put the typed window into
           the bytes. */
        assertEq(
            uint256(deadline) - generatedAt, deadlineDays * 1 days, "deadline is not the window that was typed"
        );
        assertGt(uint256(deadline), block.timestamp, "the fixture's sale has already closed - regenerate it");

        // The offering must actually be allowed to mint what it is selling.
        assertEq(
            IMoloch(dao).allowance(LOOT_SENTINEL, SHARE_OFFERING),
            type(uint256).max,
            "the offering cannot mint the loot it is configured to sell"
        );
        assertEq(IShareOffering(SHARE_OFFERING).remaining(dao), 9_999_999 ether, "nothing is actually for sale");
    }

    /// The tap streams to the beneficiary over the RELEASE window, which is
    /// deliberately far longer than the raise — that gap is what a backer's
    /// burn is worth.
    function test_tap_streamsOverTheReleaseWindow() public view {
        (address token, address beneficiary, uint128 ratePerSec,) = ITapVest(TAP_VEST).taps(dao);

        assertEq(token, address(0), "tap does not stream ether");
        // No beneficiary was typed into the form, so it defaults to the launcher.
        assertEq(beneficiary, launcher, "tap points somewhere unexpected");
        assertEq(uint256(ratePerSec), goalWei / vestSecs, "rate does not spend the goal over the release window");
        assertEq(IMoloch(dao).allowance(address(0), TAP_VEST), goalWei, "tap budget is not the goal");

        // The property the preset exists for: when backing closes, almost
        // nothing has been released, so a last-day backer still has a claim.
        uint256 releasedByDeadline = uint256(ratePerSec) * deadlineDays * 1 days;
        assertLt(releasedByDeadline * 10, goalWei, "more than a tenth is claimable when backing closes");
    }

    /// Governance stayed with the launcher: a loot raise hands over no vote.
    function test_raise_handsOverNoVote() public {
        vm.prank(backer);
        IShareOffering(SHARE_OFFERING).buy{value: 1 ether}(dao, 1_000_000 ether);

        assertEq(IToken(loot).balanceOf(backer), 1_000_000 ether, "backer did not receive loot");
        assertEq(IToken(shares).balanceOf(backer), 0, "backing minted voting shares");
        assertEq(IToken(shares).totalSupply(), 1 ether, "the electorate grew");
    }

    /// The round trip the whole format rests on: back it, then burn back out
    /// for a share of what has not been released.
    function test_backThenBurn_returnsTheUndrawnShare() public {
        vm.prank(backer);
        IShareOffering(SHARE_OFFERING).buy{value: 1 ether}(dao, 1_000_000 ether);

        uint256 treasury = dao.balance;
        uint256 total = IToken(shares).totalSupply() + IToken(loot).totalSupply();
        uint256 held = IToken(loot).balanceOf(backer);
        uint256 expected = treasury * held / total;

        address[] memory tokens = new address[](1);
        tokens[0] = address(0);

        uint256 before = backer.balance;
        vm.prank(backer);
        IMoloch(dao).ragequit(tokens, 0, held);

        assertEq(backer.balance - before, expected, "burn did not pay the pro-rata share");
        assertEq(IToken(loot).balanceOf(backer), 0, "loot was not burned");
        // Nothing had been released yet, so a backer who leaves immediately is
        // very nearly whole — they only ever dilute against the founding share.
        assertApproxEqRel(backer.balance - before, 1 ether, 0.000002e18, "an immediate exit lost real money");
    }

    /// Releasing moves ether out of the refundable pool, and anybody may do it.
    function test_release_isPermissionlessAndShrinksTheBurn() public {
        vm.prank(backer);
        IShareOffering(SHARE_OFFERING).buy{value: 1 ether}(dao, 1_000_000 ether);

        vm.warp(block.timestamp + 30 days);

        uint256 benBefore = launcher.balance;
        // A stranger sends it; the ether still goes to the beneficiary.
        vm.prank(backer);
        ITapVest(TAP_VEST).claim(dao);
        uint256 released = launcher.balance - benBefore;
        assertGt(released, 0, "nothing was released after thirty days");

        uint256 total = IToken(shares).totalSupply() + IToken(loot).totalSupply();
        uint256 held = IToken(loot).balanceOf(backer);
        uint256 nowWorth = dao.balance * held / total;
        assertLt(nowWorth, 1 ether, "releasing did not reduce what a burn pays");
    }

    /// THE RATE IS ABSOLUTE, AND THIS TEST EXISTS TO SAY SO IN NUMBERS.
    ///
    /// `assertLt(nowWorth, 1 ether)` above passes at ten times the rate, or a
    /// thousand - an eighty-two percent loss reads the same as a one percent
    /// one. That is the assertion that let the real behaviour go unnoticed:
    /// the tap pays `goal / window` per second REGARDLESS of what was raised,
    /// so a cause that fills a tenth of its goal is emptied in a tenth of the
    /// window, and its backers can be left with nothing long before the window
    /// they were shown has run.
    ///
    /// So this pins the actual arithmetic. It is not a bug to be fixed on
    /// chain - the raise is unknown when the tap is configured, so the rate
    /// cannot be derived from it - which is exactly why the page has to SAY it.
    /// If this test ever starts failing, the tap's semantics changed and the
    /// page's copy about under-subscribed causes needs to change with it.
    function test_theTapDrainsInProportionToTheSHORTFALL_notTheWindow() public {
        // A tenth of the goal, on the form's own defaults: 10 ETH over 30 days,
        // released over twelve months.
        vm.prank(backer);
        IShareOffering(SHARE_OFFERING).buy{value: 1 ether}(dao, 1_000_000 ether);
        uint256 raised = dao.balance;
        assertApproxEqAbs(raised, 1 ether, 1e12, "the fixture no longer raises one ether");

        // ONE TWELFTH OF THE WINDOW. Proportional vesting would pay about a
        // twelfth of the treasury here. The rate is `goal / window`, so it pays
        // a twelfth of the GOAL - which on a tenth-funded raise is most of the
        // money: 10 ETH / 31556952s * 31 days = 0.849 ETH against 1.0 raised.
        vm.warp(block.timestamp + 31 days);
        vm.prank(backer);
        ITapVest(TAP_VEST).claim(dao);

        assertLt(dao.balance, raised / 5, "over 20% survived one twelfth of the window - has the tap become proportional?");
        assertGt(dao.balance, 0, "the fixture drained completely at 31 days; the arithmetic below needs revisiting");

        uint256 total = IToken(shares).totalSupply() + IToken(loot).totalSupply();
        uint256 held = IToken(loot).balanceOf(backer);
        uint256 nowWorth = dao.balance * held / total;
        // A backer one month into a twelve-month release keeps under a fifth of
        // what they put in. The old assertion - `< 1 ether` - called this a
        // pass, and would have called a 99% loss a pass too.
        assertLt(nowWorth, 0.2 ether, "a backer kept more than a fifth - the drain is not what the page describes");

        // And it is gone entirely well before the window the backer was shown.
        vm.warp(block.timestamp + 9 days);
        vm.prank(backer);
        ITapVest(TAP_VEST).claim(dao);
        // Dust only - the tap floors to whole seconds, so a few hundred
        // gwei survive. That residue IS what a backer's burn pays out at this
        // point: about 0.000000113 ETH against the 1 ETH they put in.
        assertLt(dao.balance, 1e12, "the treasury outlasted day 40 of a twelve-month release");
    }
}
