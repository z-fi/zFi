// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {FundingWorksMinter, IDAICO} from "../src/FundingWorksMinter.sol";

interface IMoloch {
    function shares() external view returns (address);
    function ragequit(address[] calldata tokens, uint256 sharesToBurn, uint256 lootToBurn) external;
}

interface IShares {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IDAICOBuy {
    function buy(address dao, address tribTkn, uint256 payAmt, uint256 minBuyAmt) external payable;
}

/// @dev Fork tests against the live deployed v2 collector DAO
contract FWLiveTest is Test {
    address constant DAO = 0xE7Aa6cA3a9Ca3fe92a425dFeaD24900B9BF49853;
    address constant SHARES = 0x883d646d0C8202Aa23F01d4aF45E4E73804c3a49;
    address constant DAICO = 0x000000000033e92DB97B4B3beCD2c255126C60aC;
    address constant MINTER = 0xB3B3f4f1535305c5f40F9c0d6bCaf38032bF7F8e;

    address buyer;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));
        buyer = makeAddr("live_buyer");
        vm.deal(buyer, 10 ether);
    }

    function test_liveCloseSale() public {
        FundingWorksMinter m = FundingWorksMinter(payable(MINTER));
        assertEq(m.dao(), DAO, "minter.dao == DAO");
        assertEq(m.shares(), SHARES, "minter.shares == SHARES");

        IShares shares = IShares(SHARES);
        uint256 totalBefore = shares.totalSupply();
        uint256 daoSharesBefore = shares.balanceOf(DAO);
        emit log_named_uint("Total supply before", totalBefore / 1e18);
        emit log_named_uint("DAO unsold shares", daoSharesBefore / 1e18);

        // Buy shares
        vm.prank(buyer);
        IDAICOBuy(DAICO).buy{value: 0.5 ether}(DAO, address(0), 0.5 ether, 0);
        uint256 buyerShares = shares.balanceOf(buyer);
        emit log_named_uint("Buyer shares", buyerShares / 1e18);

        // closeSale reverts before deadline
        vm.expectRevert(FundingWorksMinter.SaleActive.selector);
        m.closeSale();

        // Warp past deadline, execute permit burn
        vm.warp(m.deadline() + 1);
        m.closeSale();

        // Verify: DAO shares burned, totalSupply = circulating only
        assertEq(shares.balanceOf(DAO), 0, "DAO shares = 0 after closeSale");
        uint256 totalAfter = shares.totalSupply();
        emit log_named_uint("Total supply after", totalAfter / 1e18);

        // One-shot: second call reverts
        vm.expectRevert();
        m.closeSale();

        // Ragequit returns proportional ETH (not diluted)
        uint256 treasuryBal = DAO.balance;
        if (treasuryBal > 0 && buyerShares > 0) {
            uint256 buyerBefore = buyer.balance;
            address[] memory tokens = new address[](1);
            tokens[0] = address(0);
            vm.prank(buyer);
            IMoloch(DAO).ragequit(tokens, buyerShares, 0);
            uint256 received = buyer.balance - buyerBefore;
            uint256 expected = treasuryBal * buyerShares / totalAfter;
            assertEq(received, expected, "ragequit = proportional after burn");
            emit log_named_uint("Ragequit received", received);
        }
    }

    function test_liveFullSaleAndMint() public {
        FundingWorksMinter m = FundingWorksMinter(payable(MINTER));
        IShares shares = IShares(SHARES);

        uint256 remaining = shares.balanceOf(DAO);
        emit log_named_uint("Remaining shares", remaining / 1e18);

        // Buy enough to fill the sale
        uint256 payNeeded = remaining * 1e18 / 1_000_000e18;
        vm.deal(buyer, payNeeded + 1 ether);
        vm.prank(buyer);
        IDAICOBuy(DAICO).buy{value: payNeeded}(DAO, address(0), payNeeded, 0);

        emit log_named_uint("Treasury after fill", DAO.balance);

        // Mint NFT
        vm.warp(block.timestamp + 1);
        uint256 mintable = m.mintableFromTap();
        emit log_named_uint("Mintable NFTs", mintable);
        assertGe(mintable, 1, "at least 1 NFT mintable");

        m.mintFromTap(0);
        assertEq(m.nftCount(), 1, "1 NFT in vault");
        assertEq(address(m).balance, 0, "no dust in minter");
    }
}
