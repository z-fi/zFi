// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import {FundingWorksMinter, IDAICO} from "../src/FundingWorksMinter.sol";

interface IMoloch {
    function shares() external view returns (address);
    function ragequittable() external view returns (bool);
    function ragequit(address[] calldata tokens, uint256 sharesToBurn, uint256 lootToBurn) external;
    function proposalTTL() external view returns (uint64);
    function timelockDelay() external view returns (uint64);
    function quorumBps() external view returns (uint16);
}

interface IShares {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IDAICOBuy {
    function buy(address dao, address tribTkn, uint256 payAmt, uint256 minBuyAmt) external payable;
}

interface IFWView {
    function MINT_PRICE() external view returns (uint256);
    function MINT_PERIOD() external view returns (uint256);
    function INITIAL_PAYOUT_PCT() external view returns (uint256);
    function mintEnabled() external view returns (bool);
    function mintPaused() external view returns (bool);
    function mintStartTime() external view returns (uint256);
    function vestingStarted() external view returns (bool);
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address) external view returns (uint256);
}

contract FundingWorksMinterTest is Test {
    IFWView constant FW = IFWView(0xb33d806a94B6770C9d309E0842a75f8E6edCd5A6);

    address deployer;
    address buyer1;
    address buyer2;

    FundingWorksMinter minter;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        deployer = address(uint160(uint256(keccak256("fw_deployer"))));
        buyer1 = address(uint160(uint256(keccak256("fw_buyer1"))));
        buyer2 = address(uint160(uint256(keccak256("fw_buyer2"))));

        vm.deal(deployer, 100 ether);
        vm.deal(buyer1, 100 ether);
        vm.deal(buyer2, 100 ether);
    }

    function _deploy() internal {
        vm.prank(deployer);
        minter = new FundingWorksMinter(
            "FW S02 Collectors",
            "FWC",
            "ipfs://QmFWCollector",
            keccak256(abi.encode("fw-s02", block.timestamp))
        );

        // Verify
        address dao = minter.dao();
        assertTrue(dao != address(0), "DAO deployed");
        IMoloch m = IMoloch(dao);
        assertTrue(m.ragequittable(), "ragequittable");
        assertEq(m.proposalTTL(), 12 hours, "proposalTTL = 12h");
        assertEq(m.timelockDelay(), 12 hours, "timelockDelay = 12h");
        assertEq(m.quorumBps(), 1500, "quorum = 15%");
    }

    function _isMintOpen() internal view returns (bool) {
        return FW.mintEnabled()
            && !FW.mintPaused()
            && block.timestamp <= FW.mintStartTime() + FW.MINT_PERIOD();
    }

    function test_fullLifecycle() public {
        _deploy();

        address dao = minter.dao();
        IShares shares = IShares(IMoloch(dao).shares());
        IDAICOBuy daicoContract = IDAICOBuy(minter.DAICO());

        // Buy shares - ~1.11M supply, 1M per ETH. Buy most of sale
        vm.prank(buyer1);
        daicoContract.buy{value: 0.6 ether}(dao, address(0), 0.6 ether, 0);
        assertEq(shares.balanceOf(buyer1), 540_000e18, "buyer1: 540k shares");

        vm.prank(buyer2);
        daicoContract.buy{value: 0.5 ether}(dao, address(0), 0.5 ether, 0);
        assertEq(shares.balanceOf(buyer2), 450_000e18, "buyer2: 450k shares");

        // Mint NFTs via tap - treasury has 90% of 1.1 ETH ≈ 0.99 ETH
        // Need full sale (~1.111 ETH) to hit 1 ETH in treasury for 1 NFT
        vm.warp(block.timestamp + 1);

        uint256 mintable = minter.mintableFromTap();
        emit log_named_uint("Mintable NFTs from tap", mintable);
        if (_isMintOpen() && mintable > 0) {
            minter.mintFromTap(0);

            uint256 nfts = minter.nftCount();
            emit log_named_uint("NFTs minted", nfts);

            uint256[] memory ids = minter.allNftIds();
            for (uint256 i; i < ids.length; i++) {
                assertEq(FW.ownerOf(ids[i]), address(minter), "vault owns");
            }

            uint256 totalLocked = minter.totalLockedEth();
            emit log_named_uint("Total locked ETH", totalLocked);
        } else {
            emit log("Not enough for NFT or FW mint closed - skipping");
        }

        // Ragequit
        uint256 buyer2Before = buyer2.balance;
        if (dao.balance > 0) {
            address[] memory tokens = new address[](1);
            tokens[0] = address(0);
            vm.prank(buyer2);
            IMoloch(dao).ragequit(tokens, 450_000e18, 0);
            assertGt(buyer2.balance, buyer2Before, "ragequit ETH");
            emit log_named_uint("ragequit recovered", buyer2.balance - buyer2Before);
        }
    }

    function test_sweep() public {
        _deploy();
        address dao = minter.dao();
        vm.deal(address(minter), 0.5 ether);

        uint256 daoBefore = dao.balance;
        vm.prank(dao);
        minter.sweep();
        assertEq(address(minter).balance, 0);
        assertEq(dao.balance, daoBefore + 0.5 ether);
    }

    function test_onlyDAO() public {
        _deploy();
        vm.prank(buyer1);
        vm.expectRevert(FundingWorksMinter.NotDAO.selector);
        minter.sweep();

        vm.prank(buyer1);
        vm.expectRevert(FundingWorksMinter.NotDAO.selector);
        minter.burnToDAO(1);
    }

    function test_nothingToMint() public {
        _deploy();
        vm.expectRevert(FundingWorksMinter.NothingToMint.selector);
        minter.mintFromBalance(0);
    }

    function test_fullSaleMints1NFT() public {
        _deploy();

        address dao = minter.dao();
        IShares shares = IShares(IMoloch(dao).shares());
        IDAICOBuy daicoContract = IDAICOBuy(minter.DAICO());

        // Fill the entire sale. saleSupply = 1,111,112 shares at 1M/ETH = 1.111112 ETH
        // DAICO: buyAmt = payAmt * forAmt / tribAmt = 1.111112 * 1M = 1,111,112 shares
        // 10% to LP (111,111.2 shares), 90% to buyer (1,000,000.8 shares)
        uint256 exactPay = 1_111_112 * 1e18 / 1_000_000; // 1.111112 ETH
        vm.prank(buyer1);
        daicoContract.buy{value: exactPay}(dao, address(0), exactPay, 0);

        uint256 buyer1Shares = shares.balanceOf(buyer1);
        emit log_named_uint("buyer1 shares", buyer1Shares / 1e18);
        emit log_named_uint("buyer1 shares (exact)", buyer1Shares);

        // Treasury should have ~1 ETH (90% of 1.111112 ETH)
        uint256 treasuryBal = dao.balance;
        emit log_named_uint("DAO treasury ETH (wei)", treasuryBal);
        assertGe(treasuryBal, 1 ether, "treasury >= 1 ETH for NFT mint");

        // Tap should have the full treasury claimable (instant vesting)
        uint256 claimable = IDAICO(minter.DAICO()).claimableTap(dao);
        emit log_named_uint("claimable tap (wei)", claimable);

        // Mint the NFT
        vm.warp(block.timestamp + 1);
        if (_isMintOpen()) {
            uint256 mintable = minter.mintableFromTap();
            emit log_named_uint("mintable NFTs", mintable);
            assertGe(mintable, 1, "at least 1 NFT mintable");

            minter.mintFromTap(1);

            assertEq(minter.nftCount(), 1, "1 NFT in vault");
            uint256[] memory ids = minter.allNftIds();
            assertEq(FW.ownerOf(ids[0]), address(minter), "minter holds NFT");

            emit log_named_uint("NFT id", ids[0]);
            emit log_named_uint("locked ETH", minter.totalLockedEth());
            emit log_named_uint("minter dust", address(minter).balance);
            emit log_named_uint("DAO treasury after mint", dao.balance);
        } else {
            emit log("FW mint closed - skipping NFT mint verification");
        }
    }

    function test_closeSale() public {
        _deploy();

        address dao = minter.dao();
        IShares shares = IShares(IMoloch(dao).shares());
        IDAICOBuy daicoContract = IDAICOBuy(minter.DAICO());

        // Verify shares address matches prediction
        assertEq(address(shares), minter.shares(), "shares prediction matches");

        // ~1.11 ETH sale supply = 1,111,112 shares. Buy 0.5 ETH = 450k shares (after 10% LP)
        vm.prank(buyer1);
        daicoContract.buy{value: 0.5 ether}(dao, address(0), 0.5 ether, 0);
        uint256 buyer1Shares = shares.balanceOf(buyer1);
        assertEq(buyer1Shares, 450_000e18, "buyer1: 450k shares");

        // DAO still holds unsold shares
        uint256 daoSharesBefore = shares.balanceOf(dao);
        assertGt(daoSharesBefore, 0, "DAO holds unsold shares");
        emit log_named_uint("DAO unsold shares", daoSharesBefore / 1e18);
        emit log_named_uint("Total supply before", shares.totalSupply() / 1e18);

        // closeSale should revert before deadline
        vm.expectRevert(FundingWorksMinter.SaleActive.selector);
        minter.closeSale();

        // Warp past deadline
        vm.warp(minter.deadline() + 1);

        // closeSale - permissionless
        minter.closeSale();

        // DAO shares burned
        assertEq(shares.balanceOf(dao), 0, "DAO shares = 0 after closeSale");

        // totalSupply = circulating only (450k buyer + 50k LP = 500k)
        uint256 totalAfter = shares.totalSupply();
        emit log_named_uint("Total supply after", totalAfter / 1e18);
        // buyer gets 450k, LP gets 50k (10% of 500k total bought)
        assertEq(totalAfter, 500_000e18, "totalSupply = circulating only (buyer + LP)");

        // closeSale is one-shot: second call should revert (permit already spent)
        vm.expectRevert();
        minter.closeSale();

        // Ragequit returns proportional ETH
        vm.deal(dao, 1 ether);
        uint256 buyer1Before = buyer1.balance;
        address[] memory tokens = new address[](1);
        tokens[0] = address(0);
        vm.prank(buyer1);
        IMoloch(dao).ragequit(tokens, buyer1Shares, 0);

        uint256 ragequitReceived = buyer1.balance - buyer1Before;
        emit log_named_uint("Ragequit received ETH", ragequitReceived);
        // buyer1 owns 450k of 500k total (90%), gets 90% of 1 ETH = 0.9 ETH
        assertEq(ragequitReceived, 0.9 ether, "ragequit returns proportional ETH");
    }
}
