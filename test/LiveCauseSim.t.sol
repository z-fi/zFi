// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "../lib/forge-std/src/Test.sol";

interface IMoloch {
    function shares() external view returns (address);
    function allowance(address token, address spender) external view returns (uint256);
    function ragequit(address[] calldata tokens, uint256 sharesToBurn, uint256 lootToBurn) external;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface ITapVest {
    function claimable(address dao) external view returns (uint256);
    function claim(address dao) external returns (uint256);
}

/// Executes the live "CELL" DAICO on a mainnet fork. Every claim I made about the
/// cap, the deadline, the tap and ragequit is re-derived here by actually running it.
contract LiveCauseSimTest is Test {
    address constant DAO = 0xD5dcE9BEE03e69362981afE48323A657fCceB8bE;
    address constant SHARE_SALE = 0x0000000021ea5069B532CeE09058aB9e02EA60f9;
    address constant TAP_VEST = 0x0000000060cdD33cbE020fAE696E70E7507bF56D;
    address constant BENEFICIARY = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;

    uint256 constant PRICE = 333_000_000_000;
    uint256 constant DEADLINE = 1788203204;
    uint256 constant SUMMON = 1787425655;

    IERC20 sh;
    address backer = address(0xB4CE7);
    address stranger = address(0x57AA9E);

    function setUp() public {
        // foundry.toml pins fork_block_number well before this DAO was summoned, so
        // under the default profile there is nothing at DAO to call. Skip rather than
        // fail: this suite is only meaningful against a fork at (or after) the summon.
        //   forge test --match-path test/LiveCauseSim.t.sol \
        //     --fork-url <archive> --fork-block-number $(cast block-number --rpc-url <archive>)
        if (DAO.code.length == 0) {
            vm.skip(true);
            return;
        }
        sh = IERC20(IMoloch(DAO).shares());
    }

    function _sharesLeft() internal view returns (uint256) {
        return IMoloch(DAO).allowance(DAO, SHARE_SALE) / 1e18;
    }

    function _buy(address who, uint256 shares) internal returns (bool ok) {
        uint256 cost = shares * PRICE;
        vm.deal(who, cost);
        vm.prank(who);
        (ok,) = SHARE_SALE.call{value: cost}(abi.encodeWithSignature("buy(address,uint256)", DAO, shares * 1e18));
    }

    function _fill() internal returns (uint256 bought) {
        bought = _sharesLeft();
        assertTrue(_buy(backer, bought), "filling the sale failed");
    }

    /// A) Does the sale stop at the 3.33 ETH cap?
    function test_A_saleHardCap() public {
        console.log("shares available :", _sharesLeft());
        console.log("treasury before  :", DAO.balance);
        uint256 bought = _fill();
        console.log("bought           :", bought);
        console.log("treasury at cap  :", DAO.balance);
        console.log("shares supply    :", sh.totalSupply() / 1e18);
        console.log("allowance left   :", IMoloch(DAO).allowance(DAO, SHARE_SALE));

        assertFalse(_buy(stranger, 1), "SALE OVERSHOT ITS CAP");
        console.log("one more share   : REVERTED (correct)");
    }

    /// B) Does the sale stop at the deadline?
    function test_B_deadline() public {
        assertTrue(_buy(stranger, 1), "buy before deadline should work");
        console.log("buy before close : ok");
        vm.warp(DEADLINE + 1);
        assertFalse(_buy(stranger, 1), "SALE SOLD PAST ITS DEADLINE");
        console.log("buy after close  : REVERTED (correct)");
    }

    /// C) How much can the multisig pull the instant a full raise lands?
    function test_C_tapAtSaleClose() public {
        _fill();
        vm.warp(DEADLINE);
        uint256 c = ITapVest(TAP_VEST).claimable(DAO);
        console.log("treasury at close:", DAO.balance);
        console.log("claimable at once:", c);
        console.log("pct of treasury  :", c * 100 / DAO.balance);

        uint256 before = BENEFICIARY.balance;
        vm.prank(stranger); // anyone may poke it; funds go to the beneficiary
        ITapVest(TAP_VEST).claim(DAO);
        console.log("multisig received:", BENEFICIARY.balance - before);
        console.log("treasury after   :", DAO.balance);
    }

    /// D) Ragequit with the tap untouched — is it a clean refund?
    function test_D_ragequitBeforeTap() public {
        _fill();
        vm.warp(DEADLINE);
        address[] memory toks = new address[](1);
        toks[0] = address(0);
        vm.prank(backer);
        IMoloch(DAO).ragequit(toks, 1000e18, 0);
        console.log("1000 shares cost :", 1000 * PRICE);
        console.log("1000 shares back :", backer.balance);
    }

    /// E) Same ragequit, after the multisig claims everything vested.
    function test_E_ragequitAfterTap() public {
        _fill();
        vm.warp(DEADLINE);
        vm.prank(stranger);
        ITapVest(TAP_VEST).claim(DAO);
        address[] memory toks = new address[](1);
        toks[0] = address(0);
        vm.prank(backer);
        IMoloch(DAO).ragequit(toks, 1000e18, 0);
        console.log("1000 shares cost :", 1000 * PRICE);
        console.log("1000 shares back :", backer.balance);
        console.log("treasury left    :", DAO.balance);
    }

    /// F) One month after summon — is the whole budget gone?
    function test_F_fullDrain() public {
        _fill();
        vm.warp(SUMMON + 2_629_746);
        console.log("claimable at 1mo :", ITapVest(TAP_VEST).claimable(DAO));
        console.log("treasury         :", DAO.balance);
        vm.prank(stranger);
        ITapVest(TAP_VEST).claim(DAO);
        console.log("treasury after   :", DAO.balance);
        console.log("tap budget left  :", IMoloch(DAO).allowance(address(0), TAP_VEST));
    }
}
