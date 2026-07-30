// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Dutchboard} from "../src/Dutchboard.sol";

contract InvariantERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "bal");
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allow");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract InvariantERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setApprovalForAll(address op, bool ok) external {
        isApprovedForAll[msg.sender][op] = ok;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "approved");
        ownerOf[id] = to;
    }

    /// @dev Drives push listings, including the selector check a compliant ERC-721
    ///      performs, so the receiver's answer is part of what the invariants cover.
    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data) external {
        require(ownerOf[id] == from, "owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "approved");
        ownerOf[id] = to;
        require(
            IPushReceiver(to).onERC721Received(msg.sender, from, id, data)
                == IPushReceiver.onERC721Received.selector,
            "receiver"
        );
    }
}

interface IPushReceiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// @dev Bounded list/fill/cancel operations over a tracked set of live listing ids, so
///      the invariants below can sum escrow across them. Both quote modes are exercised:
///      ERC20-quoted listings are the dimension DutchAuction has no equivalent of, and
///      the mixed population is what makes the "never custodies the quote" invariant
///      meaningful rather than vacuous.
contract Handler is Test {
    Dutchboard public board;
    InvariantERC20 public lot;
    InvariantERC20 public quote;
    InvariantERC721 public nft;

    address[3] public actors;
    uint256[] public liveIds;
    mapping(uint256 => bool) public isLive;
    mapping(uint256 => uint256) internal _liveIdx; // 1-indexed
    uint256 public nextNftId = 1;

    /// Total paid to sellers, split by quote mode, so settlement can be reconciled
    /// against seller balances from outside.
    uint256 public paidInQuote;
    uint256 public paidInEth;

    constructor(
        Dutchboard _board,
        InvariantERC20 _lot,
        InvariantERC20 _quote,
        InvariantERC721 _nft,
        address[3] memory _actors
    ) {
        board = _board;
        lot = _lot;
        quote = _quote;
        nft = _nft;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _addLive(uint256 id) internal {
        if (isLive[id]) return;
        isLive[id] = true;
        liveIds.push(id);
        _liveIdx[id] = liveIds.length;
    }

    function _removeLive(uint256 id) internal {
        if (!isLive[id]) return;
        uint256 idx = _liveIdx[id] - 1;
        uint256 last = liveIds.length - 1;
        if (idx != last) {
            uint256 moved = liveIds[last];
            liveIds[idx] = moved;
            _liveIdx[moved] = idx + 1;
        }
        liveIds.pop();
        delete _liveIdx[id];
        delete isLive[id];
    }

    /// @dev `ethQuote` flips between the native and ERC20 payment legs.
    function listERC20(uint256 actorSeed, uint128 amount, bool ethQuote) external {
        address seller = _actor(actorSeed);
        amount = uint128(bound(amount, 1, 1_000_000e18));
        lot.mint(seller, amount);
        vm.startPrank(seller);
        lot.approve(address(board), amount);
        uint256 id =
            board.listERC20(address(lot), ethQuote ? address(0) : address(quote), amount, 10 ether, 0, 0, 1 hours);
        vm.stopPrank();
        _addLive(id);
    }

    function listNFT(uint256 actorSeed, uint8 bundleSize, bool ethQuote) external {
        address seller = _actor(actorSeed);
        uint256 n = bound(uint256(bundleSize), 1, 5);
        uint256[] memory ids = new uint256[](n);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(board), true);
        for (uint256 i; i < n; ++i) {
            uint256 nid = nextNftId++;
            nft.mint(seller, nid);
            ids[i] = nid;
        }
        uint256 id = board.listNFT(address(nft), ethQuote ? address(0) : address(quote), ids, 5 ether, 0, 0, 1 hours);
        vm.stopPrank();
        _addLive(id);
    }

    /// The approval-free listing route. Escrow arrives before the board is told about it,
    /// which is a different ordering from every other entry point, so the escrow-solvency
    /// invariants need to see listings that got here this way.
    function pushListNFT(uint256 actorSeed, bool ethQuote) external {
        address seller = _actor(actorSeed);
        uint256 nid = nextNftId++;
        nft.mint(seller, nid);
        bytes memory terms = abi.encode(
            Dutchboard.PushTerms(ethQuote ? address(0) : address(quote), 5 ether, 0, 0, 1 hours)
        );
        vm.prank(seller);
        nft.safeTransferFrom(seller, address(board), nid, terms);
        _addLive(board.nextId() - 1);
    }

    function fill(uint256 actorSeed, uint256 liveSeed, uint128 take) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[liveSeed % liveIds.length];
        address buyer = _actor(actorSeed);

        Dutchboard.ListingView memory v = board.getListing(id);
        if (v.seller == address(0)) return; // defensive — should match isLive

        uint256 cost;
        if (v.isNFT) {
            cost = board.costOf(id, 0);
            _pay(buyer, v.quote, cost);
            vm.prank(buyer);
            if (v.quote == address(0)) board.fill{value: cost}(id, 0, buyer, cost);
            else board.fill(id, 0, buyer, cost);
            _removeLive(id);
        } else {
            take = uint128(bound(take, 1, v.remaining));
            cost = board.costOf(id, take);
            _pay(buyer, v.quote, cost);
            vm.prank(buyer);
            if (v.quote == address(0)) board.fill{value: cost}(id, take, buyer, cost);
            else board.fill(id, take, buyer, cost);
            if (take == v.remaining) _removeLive(id);
        }

        if (v.quote == address(0)) paidInEth += cost;
        else paidInQuote += cost;
    }

    /// @dev Two legs in one call, which is where the shared `_settle` accounting could
    ///      go wrong. The buyer is funded for exactly the batch, so `invariant_
    ///      boardNeverRetainsEth` and `invariant_quotePaidReachesSellers` become real
    ///      constraints on it: if `_settle` let one `msg.value` cover both ETH legs, the
    ///      second seller would be paid out of value nobody supplied and the totals
    ///      would stop reconciling.
    function fillMany(uint256 actorSeed, uint256 seedA, uint256 seedB, uint128 takeA, uint128 takeB) external {
        if (liveIds.length < 2) return;
        uint256 idA = liveIds[seedA % liveIds.length];
        uint256 idB = liveIds[seedB % liveIds.length];
        if (idA == idB) return; // one listing twice needs remainder bookkeeping this handler does not model
        address buyer = _actor(actorSeed);

        Dutchboard.ListingView memory a = board.getListing(idA);
        Dutchboard.ListingView memory b = board.getListing(idB);
        if (a.seller == address(0) || b.seller == address(0)) return;

        uint256[] memory ids = new uint256[](2);
        uint128[] memory takes = new uint128[](2);
        uint256[] memory maxCosts = new uint256[](2);
        (ids[0], ids[1]) = (idA, idB);
        takes[0] = a.isNFT ? 0 : uint128(bound(takeA, 1, a.remaining));
        takes[1] = b.isNFT ? 0 : uint128(bound(takeB, 1, b.remaining));

        maxCosts[0] = board.costOf(idA, takes[0]);
        maxCosts[1] = board.costOf(idB, takes[1]);

        // Fund each leg in its own quote asset; ETH legs share one value, counted once.
        uint256 ethNeeded;
        if (a.quote == address(0)) ethNeeded += maxCosts[0];
        if (b.quote == address(0)) ethNeeded += maxCosts[1];
        uint256 quoteNeeded;
        if (a.quote != address(0)) quoteNeeded += maxCosts[0];
        if (b.quote != address(0)) quoteNeeded += maxCosts[1];

        vm.deal(buyer, ethNeeded);
        if (quoteNeeded != 0) {
            quote.mint(buyer, quoteNeeded);
            vm.prank(buyer);
            quote.approve(address(board), quoteNeeded);
        }

        vm.prank(buyer);
        board.fillMany{value: ethNeeded}(ids, takes, maxCosts, buyer);

        if (a.isNFT || takes[0] == a.remaining) _removeLive(idA);
        if (b.isNFT || takes[1] == b.remaining) _removeLive(idB);

        if (a.quote == address(0)) paidInEth += maxCosts[0];
        else paidInQuote += maxCosts[0];
        if (b.quote == address(0)) paidInEth += maxCosts[1];
        else paidInQuote += maxCosts[1];
    }

    /// @dev Funds the buyer for exactly this fill, so the board's own balances stay
    ///      attributable — a buyer left holding surplus quote tokens would mask a leak.
    function _pay(address buyer, address quoteAsset, uint256 cost) internal {
        if (quoteAsset == address(0)) {
            vm.deal(buyer, cost);
        } else {
            quote.mint(buyer, cost);
            vm.prank(buyer);
            quote.approve(address(board), cost);
        }
    }

    function cancel(uint256 liveSeed) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[liveSeed % liveIds.length];
        Dutchboard.ListingView memory v = board.getListing(id);
        if (v.seller == address(0)) return;
        vm.prank(v.seller);
        board.cancel(id);
        _removeLive(id);
    }

    function warp(uint32 dt) external {
        skip(bound(uint256(dt), 1, 2 hours));
    }

    function liveIdsLength() external view returns (uint256) {
        return liveIds.length;
    }

    function liveIdAt(uint256 i) external view returns (uint256) {
        return liveIds[i];
    }
}

contract DutchboardInvariantTest is Test {
    Dutchboard board;
    InvariantERC20 lot;
    InvariantERC20 quote;
    InvariantERC721 nft;
    Handler handler;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAFE);

    function setUp() public {
        board = new Dutchboard();
        lot = new InvariantERC20();
        quote = new InvariantERC20();
        nft = new InvariantERC721();
        // The fork's CREATE address can hold real mainnet dust; zero it so the
        // "board holds no ETH" invariant is about this contract's own behaviour.
        vm.deal(address(board), 0);

        handler = new Handler(board, lot, quote, nft, [alice, bob, carol]);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = Handler.listERC20.selector;
        selectors[1] = Handler.listNFT.selector;
        selectors[2] = Handler.fill.selector;
        selectors[3] = Handler.cancel.selector;
        selectors[4] = Handler.warp.selector;
        selectors[5] = Handler.fillMany.selector;
        selectors[6] = Handler.pushListNFT.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        // Pin senders to deterministic addresses so the invariant fuzzer doesn't query
        // random accounts against the forked (pruned) RPC.
        targetSender(alice);
        targetSender(bob);
        targetSender(carol);
    }

    /// @dev Escrowed lot tokens equal Σ(remaining) across live ERC20 listings. Catches
    ///      both over-delivery to takers and escrow stranded by a closed listing.
    function invariant_lotEscrowMatchesSumOfRemaining() public view {
        uint256 sum;
        uint256 n = handler.liveIdsLength();
        for (uint256 i; i < n; ++i) {
            Dutchboard.ListingView memory v = board.getListing(handler.liveIdAt(i));
            if (v.initial != 0) sum += v.remaining; // ERC20 listings have initial > 0
        }
        assertEq(lot.balanceOf(address(board)), sum, "lot escrow mismatch");
    }

    /// @dev The board is never a custodian of the payment asset — the ERC20 leg is a
    ///      taker-to-seller transferFrom, so nothing should ever settle here. This is
    ///      the invariant the arbitrary quote asset introduces.
    function invariant_boardNeverCustodiesQuote() public view {
        assertEq(quote.balanceOf(address(board)), 0, "board custodied the quote asset");
    }

    /// @dev Same for ETH: cost is forwarded to the seller and the remainder refunded to
    ///      the caller within the same call, so no balance accrues between fills.
    function invariant_boardNeverRetainsEth() public view {
        assertEq(address(board).balance, 0, "board retained ETH");
    }

    /// @dev Sellers collectively received exactly what buyers collectively paid.
    function invariant_quotePaidReachesSellers() public view {
        uint256 received = quote.balanceOf(alice) + quote.balanceOf(bob) + quote.balanceOf(carol);
        assertEq(received, handler.paidInQuote(), "quote paid does not match quote received");
    }

    /// @dev remaining <= initial for every live listing.
    function invariant_remainingLeqInitial() public view {
        uint256 n = handler.liveIdsLength();
        for (uint256 i; i < n; ++i) {
            Dutchboard.ListingView memory v = board.getListing(handler.liveIdAt(i));
            assertLe(v.remaining, v.initial, "remaining exceeds initial");
        }
    }

    /// @dev Every NFT in a live bundle is escrowed here, and the board owns no NFT that
    ///      is not in some live bundle — so a closed listing can never strand one.
    function invariant_nftEscrowMatchesLiveBundles() public view {
        uint256 escrowed;
        uint256 n = handler.liveIdsLength();
        for (uint256 i; i < n; ++i) {
            uint256[] memory bundle = board.getListing(handler.liveIdAt(i)).ids;
            for (uint256 j; j < bundle.length; ++j) {
                assertEq(nft.ownerOf(bundle[j]), address(board), "NFT not escrowed");
                ++escrowed;
            }
        }
        uint256 held;
        for (uint256 k = 1; k < handler.nextNftId(); ++k) {
            if (nft.ownerOf(k) == address(board)) ++held;
        }
        assertEq(held, escrowed, "board holds an NFT outside any live bundle");
    }

    /// @dev The live price of every open listing stays inside its declared bracket.
    function invariant_priceWithinDeclaredBracket() public view {
        uint256 n = handler.liveIdsLength();
        for (uint256 i; i < n; ++i) {
            Dutchboard.ListingView memory v = board.getListing(handler.liveIdAt(i));
            assertLe(v.price, v.startPrice, "price above startPrice");
            assertGe(v.price, v.endPrice, "price below endPrice");
        }
    }

    /// @dev A live listing always has a non-zero unit of escrow behind it: an ERC20
    ///      listing with remaining == 0 should have been closed by the fill that
    ///      emptied it, never left open with nothing to sell.
    function invariant_liveListingsAreNonEmpty() public view {
        uint256 n = handler.liveIdsLength();
        for (uint256 i; i < n; ++i) {
            Dutchboard.ListingView memory v = board.getListing(handler.liveIdAt(i));
            assertTrue(v.seller != address(0), "live id points at a closed listing");
            if (v.isNFT) assertGt(v.ids.length, 0, "live NFT listing has an empty bundle");
            else assertGt(v.remaining, 0, "live ERC20 listing has nothing remaining");
        }
    }
}
