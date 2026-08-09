// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {SwapboardView} from "../src/SwapboardView.sol";
import {Dutchboard} from "../src/Dutchboard.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev A board that reports whatever orders the test hands it, so the bounded
/// candidate set can be exercised at its cap without minting real escrow.
contract StubBoard {
    struct Order {
        address maker;
        bool active;
        bool partialFill;
        uint64 expiry;
        bool nftA;
        bool nftB;
        address counterparty;
        address tokenA;
        uint256 amountA;
        address tokenB;
        uint256 amountB;
    }

    Order[] internal book;

    function push(Order memory o) external {
        book.push(o);
    }

    function nextOrderId() external view returns (uint256) {
        return book.length;
    }

    function getOrders(uint256[] calldata ids) external view returns (Order[] memory out) {
        out = new Order[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] < book.length) out[i] = book[ids[i]];
        }
    }
}

/// @notice Regression tests for the SwapboardView security review.
contract SwapboardViewAuditTest is Test {
    SwapboardView lens;
    address IN = address(0xAAA1);
    address OUT = address(0xBBB2);

    function setUp() public {
        lens = new SwapboardView();
    }

    function _o(uint256 id, uint256 amountA, uint256 amountB, bool partialFill)
        internal
        view
        returns (SwapboardView.OrderView memory v)
    {
        v.orderId = id;
        v.tokenA = OUT;
        v.amountA = amountA;
        v.tokenB = IN;
        v.amountB = amountB;
        v.partialFill = partialFill;
    }

    // ---------------------------------------- free-row sentinel is board-qualified

    /// A Swapboard order selling for NFT tokenId 0 has `amountB == 0`, which used
    /// to collide with the Dutchboard free-row sentinel: it sorted ahead of every
    /// real order and was emitted as a leg paying nothing for the whole of
    /// `amountA`. The row is not plannable at all and must simply be dropped.
    function test_NftTokenIdZeroIsNotAFreeRow() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](2);
        c[0] = _o(1, 1_000_000e18, 0, false); // nftB, tokenId 0
        c[0].nftB = true;
        c[1] = _o(2, 110e18, 100e18, true); // the only real row

        (SwapboardView.Fill[] memory f, uint256 bin, uint256 bout) = lens.previewPlan(c, 100e18, 100e18);

        assertEq(f.length, 1, "the NFT row must not produce a leg");
        assertEq(f[0].orderId, 2, "the real row is the one planned");
        assertEq(bin, 100e18);
        assertEq(bout, 110e18, "phantom free output must not inflate bookOut");
    }

    /// Exact-out twin: `amountB == 0` used to give the row a cost of 0, sorting it
    /// first and clearing any ceiling.
    function test_NftTokenIdZeroIsNotFreeOnExactOut() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](2);
        // Sized to FIT the target: an oversized all-or-nothing row is skipped for
        // an unrelated reason, so it would not exercise the sentinel at all.
        c[0] = _o(1, 60e18, 0, false);
        c[0].nftB = true;
        c[1] = _o(2, 110e18, 100e18, true);

        (SwapboardView.Fill[] memory f, uint256 bout, uint256 bin) = lens.previewPlanOut(c, 110e18, 200e18);

        assertEq(f.length, 1, "the NFT row must not produce a leg");
        assertEq(f[0].orderId, 2);
        assertEq(bout, 110e18);
        assertEq(bin, 100e18, "a phantom zero-cost leg must not undercut the ceiling");
    }

    /// On an NFT leg the amount IS a tokenId, so a high tokenId used to read as
    /// enormous depth at an extraordinary rate and dominate the sort.
    function test_NftTokenIdIsNotScoredAsDepth() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](2);
        c[0] = _o(1, type(uint128).max, 1, false); // nftA: amountA is tokenId
        c[0].nftA = true;
        c[1] = _o(2, 110e18, 100e18, true);

        (SwapboardView.Fill[] memory f,, uint256 bout) = lens.previewPlan(c, 100e18, 100e18);

        assertEq(f.length, 1, "tokenId must not be plannable as a quantity");
        assertEq(f[0].orderId, 2);
        assertEq(bout, 110e18);
    }

    /// A genuine Dutchboard free row - no NFT flags - still works.
    function test_GenuineFreeRowStillTaken() public view {
        SwapboardView.OrderView[] memory c = new SwapboardView.OrderView[](1);
        c[0] = _o(1, 50e18, 0, true); // decayed to zero price

        (SwapboardView.Fill[] memory f, uint256 bin, uint256 bout) = lens.previewPlan(c, 100e18, 1e18);

        assertEq(f.length, 1, "a real free row is real liquidity");
        assertEq(f[0].payIn, 0, "costs no input");
        assertEq(bin, 0);
        assertEq(bout, 50e18);
    }

    // ------------------------------------------- dust cannot crowd out liquidity

    /// The candidate set is capped at 256. Ranked on rate alone, 257 orders each
    /// resting one wei at a keen price were 257 of the best rates in the book and
    /// evicted every row with real depth, so planHybrid returned dust legs and
    /// routed the whole trade to the AMM. Ranking on rate x usable depth prices
    /// that out: a wei of escrow is worth a wei however keenly it is priced.
    function test_DustCannotEvictDepth() public {
        StubBoard board = new StubBoard();

        // The row that actually matters: full depth at 1.05.
        board.push(
            StubBoard.Order({
                maker: address(0xD1),
                active: true,
                partialFill: true,
                expiry: 0,
                nftA: false,
                nftB: false,
                counterparty: address(0),
                tokenA: OUT,
                amountA: 105e18,
                tokenB: IN,
                amountB: 100e18
            })
        );

        // 300 newer dust orders at a far better rate, 1 wei of depth each.
        for (uint256 i; i < 300; ++i) {
            board.push(
                StubBoard.Order({
                    maker: address(0xD2),
                    active: true,
                    partialFill: true,
                    expiry: 0,
                    nftA: false,
                    nftB: false,
                    counterparty: address(0),
                    tokenA: OUT,
                    amountA: 10,
                    tokenB: IN,
                    amountB: 1
                })
            );
        }

        (, uint256 bookIn, uint256 bookOut,,) =
            lens.planHybrid(address(0), address(board), IN, OUT, 100e18, address(this), 100e18, 0);

        assertGt(bookIn, 99e18, "the deep row must survive the candidate cap");
        assertGt(bookOut, 104e18, "plan collapsed to dust legs");
    }

    // --------------------------------------------------- native ETH metadata

    /// Dutchboard prices in `quote`, and quote == address(0) is native ETH. The
    /// staticcall to the zero address succeeds with empty returndata, so the row
    /// used to render with a blank symbol.
    function test_NativeEthQuoteIsLabelled() public {
        Dutchboard board = new Dutchboard(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        MockERC20 sell = new MockERC20("SELL", 18);
        address maker = makeAddr("maker");

        sell.mint(maker, 100e18);
        vm.startPrank(maker);
        sell.approve(address(board), 100e18);
        board.listERC20(address(sell), address(0), 100e18, 10e18, 1e18, 0, 1 hours, 0);
        vm.stopPrank();

        (SwapboardView.OrderView[] memory rows,) = lens.getRecentDutchListings(address(board), 0, 10, 100);

        assertEq(rows.length, 1, "listing not surfaced");
        assertEq(rows[0].tokenB, address(0), "quote is native ETH");
        assertEq(rows[0].symbolB, "ETH", "native ETH must be named, not left blank");
        assertEq(rows[0].decimalsB, 18);
        assertEq(rows[0].symbolA, "SELL", "the ERC20 leg still reads its own symbol");
    }
}
