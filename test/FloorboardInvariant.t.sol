// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {Floorboard} from "../src/Floorboard.sol";

contract InvERC20 {
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

/// @dev Drives the board through every state-changing path a bid can take.
///      Every action is bounded rather than guarded by try/catch where possible,
///      so a revert the fuzzer finds is a real finding rather than noise.
contract Handler is Test {
    Floorboard immutable board;
    InvERC20 immutable quote;
    InvERC20 immutable token;
    address[3] actors;

    uint256[] public liveIds;
    /// @notice Total quote this handler has ever paid out to sellers.
    uint256 public paidToSellers;

    constructor(Floorboard _board, InvERC20 _quote, InvERC20 _token, address[3] memory _actors) {
        board = _board;
        quote = _quote;
        token = _token;
        actors = _actors;
        for (uint256 i; i < 3; ++i) {
            quote.mint(_actors[i], 1e30);
            token.mint(_actors[i], 1e30);
            vm.prank(_actors[i]);
            quote.approve(address(_board), type(uint256).max);
            vm.prank(_actors[i]);
            token.approve(address(_board), type(uint256).max);
        }
    }

    function liveIdsLength() external view returns (uint256) {
        return liveIds.length;
    }

    function liveIdAt(uint256 i) external view returns (uint256) {
        return liveIds[i];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    function openBid(uint256 seed, uint128 want, uint96 start, uint96 span, uint40 duration) external {
        want = uint128(bound(want, 1, 1e24));
        uint96 sp = uint96(bound(start, 1, 1e24));
        uint96 ep = uint96(bound(span, sp, 1e25));
        uint40 dur = uint40(bound(duration, 1, 365 days));

        address bidder = _actor(seed);
        Floorboard.Terms memory t = Floorboard.Terms({
            token: address(token),
            quote: address(quote),
            want: want,
            startPrice: sp,
            endPrice: ep,
            startTime: 0,
            duration: dur,
            isNFT: false,
            ids: new uint256[](0)
        });
        vm.prank(bidder);
        uint256 id = board.bid(t);
        liveIds.push(id);
    }

    function hit(uint256 idSeed, uint256 sellerSeed, uint128 give) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[idSeed % liveIds.length];
        (, uint128 remaining) = _state(id);
        if (remaining == 0) return;
        give = uint128(bound(give, 1, remaining));

        (bool ok, uint256 proceeds) = board.quoteHit(id, give);
        if (!ok) return;

        address seller = _actor(sellerSeed);
        vm.prank(seller);
        board.hit(id, give, 0, false);
        paidToSellers += proceeds;
    }

    function withdrawSome(uint256 idSeed, uint128 amount) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[idSeed % liveIds.length];
        (address holder, uint128 remaining) = _state(id);
        if (holder == address(0) || remaining < 2) return;
        amount = uint128(bound(amount, 1, remaining - 1));
        vm.prank(holder);
        board.withdraw(id, amount, false);
    }

    function cancel(uint256 idSeed) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[idSeed % liveIds.length];
        (address holder,) = _state(id);
        if (holder == address(0)) return;
        vm.prank(holder);
        board.cancel(id);
    }

    /// @dev Permissionless on purpose: swept by an address that owns nothing.
    function sweep(uint256 idSeed) external {
        if (liveIds.length == 0) return;
        uint256 id = liveIds[idSeed % liveIds.length];
        (address holder,) = _state(id);
        if (holder == address(0)) return;
        if (block.timestamp < board.expiryOf(id)) return;
        vm.prank(address(0xDEAD));
        board.sweep(id);
    }

    function warp(uint40 delta) external {
        vm.warp(block.timestamp + bound(delta, 1, 30 days));
    }

    function _state(uint256 id) internal view returns (address bidder, uint128 remaining) {
        Floorboard.BidView memory v = board.getBid(id);
        return (v.bidder, v.remaining);
    }
}

contract FloorboardInvariantTest is Test {
    Floorboard board;
    InvERC20 quote;
    InvERC20 token;
    Handler handler;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0xCAFE);

    function setUp() public {
        vm.warp(1_000_000);
        // A WETH address is required but never exercised: every path here is
        // token-quoted, which keeps the invariants about escrow arithmetic
        // rather than about the wrapper.
        board = new Floorboard(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        quote = new InvERC20();
        token = new InvERC20();
        vm.deal(address(board), 0);

        handler = new Handler(board, quote, token, [alice, bob, carol]);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = Handler.openBid.selector;
        selectors[1] = Handler.hit.selector;
        selectors[2] = Handler.withdrawSome.selector;
        selectors[3] = Handler.cancel.selector;
        selectors[4] = Handler.sweep.selector;
        selectors[5] = Handler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        targetSender(alice);
        targetSender(bob);
        targetSender(carol);
    }

    /// @dev The solvency invariant. Escrow is pooled across every bid, so this
    ///      is the only statement that covers the board as a whole.
    function invariant_balanceCoversEscrow() public view {
        assertGe(quote.balanceOf(address(board)), board.escrowed(address(quote)));
    }

    /// @dev Pooled escrow is exactly the sum of what live bids still hold. A
    ///      failure here is escrow either stranded by a close or double-counted
    ///      across bids — the shape of the underflow bug that `_take` had
    ///      before the unspent ceiling was refunded on buyout.
    function invariant_escrowMatchesSumOfLocked() public view {
        uint256 sum;
        uint256 n = handler.liveIdsLength();
        for (uint256 i; i < n; ++i) {
            sum += board.getBid(handler.liveIdAt(i)).locked;
        }
        assertEq(sum, board.escrowed(address(quote)));
    }

    /// @dev THE RESERVE INVARIANT. Every remaining unit could still fill at
    ///      `endPrice`, and each payment floors, so `locked` must never fall
    ///      below that bound. This is what makes `withdraw`'s refund safe, and
    ///      it was previously only argued on paper.
    function invariant_lockedCoversWorstCaseOutlay() public view {
        uint256 n = handler.liveIdsLength();
        for (uint256 i; i < n; ++i) {
            Floorboard.BidView memory v = board.getBid(handler.liveIdAt(i));
            if (v.bidder == address(0)) continue;
            uint256 worstCase = (uint256(v.endPrice) * v.remaining) / v.initial;
            assertGe(uint256(v.locked), worstCase);
        }
    }

    /// @dev A closed bid must owe nothing; otherwise escrow is stranded.
    function invariant_closedBidsHoldNoEscrow() public view {
        uint256 n = handler.liveIdsLength();
        for (uint256 i; i < n; ++i) {
            Floorboard.BidView memory v = board.getBid(handler.liveIdAt(i));
            if (v.bidder == address(0)) assertEq(v.locked, 0);
        }
    }

    function invariant_remainingNeverExceedsInitial() public view {
        uint256 n = handler.liveIdsLength();
        for (uint256 i; i < n; ++i) {
            Floorboard.BidView memory v = board.getBid(handler.liveIdAt(i));
            assertLe(v.remaining, v.initial);
        }
    }

    /// @dev Withdrawals and fills together can never account for more than the
    ///      lot, which is what keeps `_bidFillProgress` from underflowing.
    function invariant_withdrawalsAndFillsFitTheLot() public view {
        uint256 n = handler.liveIdsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.liveIdAt(i);
            Floorboard.BidView memory v = board.getBid(id);
            assertLe(uint256(board.withdrawn(id)) + v.remaining, v.initial);
        }
    }

    /// @dev The climb never leaves its declared bracket, in either direction.
    function invariant_priceWithinBracket() public view {
        uint256 n = handler.liveIdsLength();
        for (uint256 i; i < n; ++i) {
            Floorboard.BidView memory v = board.getBid(handler.liveIdAt(i));
            if (v.bidder == address(0)) continue;
            assertGe(v.price, v.startPrice);
            assertLe(v.price, v.endPrice);
        }
    }

    /// @dev An expired bid must never quote as takeable, however the schedule
    ///      would otherwise read.
    function invariant_expiredBidsAreNeverTakeable() public view {
        uint256 n = handler.liveIdsLength();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.liveIdAt(i);
            Floorboard.BidView memory v = board.getBid(id);
            if (v.bidder == address(0)) continue;
            if (block.timestamp >= board.expiryOf(id)) assertFalse(v.takeable);
        }
    }

    /// @dev Quote assets only ever move board -> seller. Anything the board
    ///      still holds beyond its escrow would be unattributable.
    function invariant_boardRetainsNoSurplusQuote() public view {
        assertEq(quote.balanceOf(address(board)), board.escrowed(address(quote)));
    }

    /// @dev The board is not a token custodian on the sell side: bought assets
    ///      pass straight from seller to bid holder in one hop.
    function invariant_boardNeverCustodiesTheBoughtAsset() public view {
        assertEq(token.balanceOf(address(board)), 0);
    }

    function invariant_boardNeverRetainsEth() public view {
        assertEq(address(board).balance, 0);
    }
}
