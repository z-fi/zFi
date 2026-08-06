// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "../lib/forge-std/src/Test.sol";

interface IDutchAuction {
    function listNFT(
        address token,
        uint256[] calldata ids,
        uint128 startPrice,
        uint128 endPrice,
        uint40 startTime,
        uint40 duration
    ) external returns (uint256 id);

    function priceOf(uint256 id) external view returns (uint256);
    function fill(uint256 id, uint128 take) external payable;
    function cancel(uint256 id) external;
}

interface IERC721 {
    function ownerOf(uint256) external view returns (address);
    function approve(address, uint256) external;
    function getApproved(uint256) external view returns (address);
    function transferFrom(address, address, uint256) external;
}

/// Mirrors the NFT branch of dapp/modules/auction.js against the deployed
/// DutchAuction: the same two-step approve-then-list the UI performs, with the
/// same startTime/duration/endPrice arithmetic, and the decay curve the form draws.
contract AuctionLaunchSimTest is Test {
    IDutchAuction constant AUCTION = IDutchAuction(0x0000000003635fd3852E772C6E09Ce2aF25d7133);
    // Milady Maker — an entry from the dapp's POPULAR_NFT_COLLECTIONS, so the
    // listing runs against a real collection rather than a local mock.
    IERC721 constant NFT = IERC721(0x5Af0D9827E0c53E4799BB226655A1de152A425a5);

    // Held in storage on purpose: a local `block.timestamp` can be rematerialised by
    // the via_ir optimizer inside a loop, which cannot see vm.warp mutate it, so warp
    // targets computed from a local silently compound. A storage read cannot.
    uint256 listedAt;

    address seller = address(0x5E11E7);
    address buyer = address(0xB0FFED);
    uint256 tokenId;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")), 25_640_000);
        vm.deal(seller, 10 ether);
        vm.deal(buyer, 1000 ether);

        // Move a real token to the seller so the listing exercises a live collection.
        tokenId = 1;
        address owner = NFT.ownerOf(tokenId);
        vm.prank(owner);
        NFT.transferFrom(owner, seller, tokenId);
        assertEq(NFT.ownerOf(tokenId), seller, "fixture failed to seed the seller");
    }

    /// The dapp's exact parameter derivation for the form's defaults:
    /// floor 1%, duration 3 days, startTime 0 ("now").
    function _list(uint128 startPrice, uint16 floorPct, uint40 durationDays) internal returns (uint256 id) {
        uint128 endPrice = uint128((uint256(startPrice) * floorPct) / 100);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;

        vm.startPrank(seller);
        // Step 1: approve, guarded by getApproved like the UI does.
        if (NFT.getApproved(tokenId) != address(AUCTION)) NFT.approve(address(AUCTION), tokenId);
        // Step 2: list. startTime 0 means "start now" — the contract substitutes
        // block.timestamp. A literal 0 would otherwise be a fully-elapsed auction.
        id = AUCTION.listNFT(address(NFT), ids, startPrice, endPrice, 0, uint40(durationDays) * 86400);
        vm.stopPrank();
    }

    function test_defaultFormParametersList() public {
        uint256 id = _list(10 ether, 1, 3);
        assertEq(AUCTION.priceOf(id), 10 ether, "auction does not open at the start price");
        // Listing escrows the NFT — the seller no longer holds it.
        assertEq(NFT.ownerOf(tokenId), address(AUCTION), "NFT was not escrowed by the listing");
    }

    /// startTime 0 must mean "now". If the contract took it literally the auction
    /// would already be fully elapsed and open at the floor, so the form's headline
    /// price would be a lie from the first block.
    function test_startTimeZeroMeansNow() public {
        uint256 id = _list(10 ether, 1, 3);
        assertEq(AUCTION.priceOf(id), 10 ether);
        assertGt(AUCTION.priceOf(id), (10 ether * 1) / 100, "auction opened at the floor instead of the start price");
    }

    /// auctionUpdatePreview() draws a linear decay and labels the price at
    /// 25/50/75/100% elapsed. Check the contract agrees at each of those marks.
    function test_decayMatchesTheFormPreview() public {
        uint128 startPrice = 10 ether;
        uint16 floorPct = 1;
        uint40 durationDays = 3;
        uint256 endPrice = (uint256(startPrice) * floorPct) / 100;
        uint256 duration = uint256(durationDays) * 86400;

        uint256 id = _list(startPrice, floorPct, durationDays);
        listedAt = block.timestamp;

        uint256[4] memory pcts = [uint256(25), 50, 75, 100];
        for (uint256 i; i < pcts.length; ++i) {
            uint256 elapsed = (duration * pcts[i]) / 100;
            vm.warp(listedAt + elapsed);
            // The preview's model: start - (start - end) * frac.
            uint256 expected = startPrice - ((uint256(startPrice) - endPrice) * elapsed) / duration;
            assertEq(AUCTION.priceOf(id), expected, "on-chain price diverged from the preview's curve");
        }

        // Past the end it holds at the floor rather than going negative or reverting.
        vm.warp(listedAt + duration + 1 days);
        assertEq(AUCTION.priceOf(id), endPrice, "price does not settle at the floor after the duration");
    }

    /// A 0% floor is the case the form puts behind a confirm(). Confirm the warning
    /// is accurate: the NFT really does reach 0 and can be taken for gas.
    function test_zeroFloorDecaysToFree() public {
        uint256 id = _list(10 ether, 0, 3);
        vm.warp(block.timestamp + 3 days);
        assertEq(AUCTION.priceOf(id), 0, "0% floor did not decay to zero");

        vm.prank(buyer);
        AUCTION.fill{value: 0}(id, 0);
        assertEq(NFT.ownerOf(tokenId), buyer, "buyer could not take the NFT for free at a 0% floor");
    }

    /// The seller's NFT is escrowed at listing time, so the way back matters:
    /// the auction page's "Cancel Listing" must actually return it.
    function test_cancelReturnsTheNFT() public {
        uint256 id = _list(10 ether, 1, 3);
        assertEq(NFT.ownerOf(tokenId), address(AUCTION));
        vm.prank(seller);
        AUCTION.cancel(id);
        assertEq(NFT.ownerOf(tokenId), seller, "cancel did not return the NFT to the seller");
    }

    /// Parameter combinations the form can currently be deeplinked into. Each one
    /// reverts on-chain, which is why the setters clamp their inputs.
    function test_outOfRangeParametersRevert() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = tokenId;
        vm.startPrank(seller);
        NFT.approve(address(AUCTION), tokenId);

        // floor > 100%: endPrice above startPrice.
        vm.expectRevert();
        AUCTION.listNFT(address(NFT), ids, 10 ether, 20 ether, 0, 3 days);

        // duration 0.
        vm.expectRevert();
        AUCTION.listNFT(address(NFT), ids, 10 ether, 0.1 ether, 0, 0);

        // start price 0.
        vm.expectRevert();
        AUCTION.listNFT(address(NFT), ids, 0, 0, 0, 3 days);
        vm.stopPrank();
    }

    /// A buyer paying the live price gets the NFT, and the seller gets the ETH.
    function test_fillPaysTheSeller() public {
        uint256 id = _list(10 ether, 1, 3);
        vm.warp(block.timestamp + 1 days);
        uint256 price = AUCTION.priceOf(id);
        uint256 before = seller.balance;

        vm.prank(buyer);
        AUCTION.fill{value: price}(id, 0);

        assertEq(NFT.ownerOf(tokenId), buyer, "buyer did not receive the NFT");
        assertEq(seller.balance - before, price, "seller was not paid the live price");
    }
}
