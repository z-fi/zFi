// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "forge-std/Test.sol";
import {ClassicalCurveSale, IZAMM, ZAMM, ERC20} from "../src/dao/ClassicalCurveSale.sol";

/// @notice Exercises the LIVE deployed ClassicalCurveSale (not a fresh local deploy)
///         with the exact parameters dapp/modules/coin.js encodes, so the audit
///         conclusions are about the bytecode users actually transact against.
contract ClassicalCurveSaleDeployedTest is Test {
    ClassicalCurveSale constant SALE = ClassicalCurveSale(payable(0x000000005d9b18764E12E5aeefD6dA73110F85eb));

    // dapp/modules/coin.js launch() template
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant CAP = 800_000_000e18;
    uint256 constant START_PRICE = 1_666_666_667;
    uint256 constant END_PRICE = 26_666_666_672;
    uint256 constant LP_TOKENS = 200_000_000e18;

    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork(vm.envOr("FOUNDRY_ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")));
        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _launch(ClassicalCurveSale.CreatorFee memory cf, bytes32 salt) internal returns (address token) {
        vm.prank(creator);
        token = SALE.launch(
            creator,
            "Test",
            "TST",
            "ipfs://x",
            SUPPLY,
            salt,
            CAP,
            START_PRICE,
            END_PRICE,
            100, // feeBps 1%
            0, // graduationTarget: sell full cap
            LP_TOKENS,
            address(0), // lpRecipient: burn
            25, // poolFeeBps
            500, // sniperFeeBps
            300, // sniperDuration
            1000, // maxBuyBps
            cf,
            0,
            0
        );
    }

    function _defaultFee() internal view returns (ClassicalCurveSale.CreatorFee memory) {
        return ClassicalCurveSale.CreatorFee(creator, 5, 5, true, false);
    }

    /// Full lifecycle on the deployed bytecode: launch, buy out the cap, graduate, verify LP burn.
    function test_deployed_fullLifecycle() public {
        // The live contract already custodies ETH for other in-flight curves, so
        // this curve's residue is measured as a delta against that baseline.
        uint256 baseETH = address(SALE).balance;
        address token = _launch(_defaultFee(), bytes32(uint256(1)));
        assertEq(ERC20(token).totalSupply(), SUPPLY);
        assertEq(ERC20(token).balanceOf(address(SALE)), SUPPLY, "all supply escrowed");

        // Past the sniper window so fees are the steady-state 1%.
        vm.warp(block.timestamp + 301);

        // Buy out the whole cap in maxBuyBps-sized chunks (10% of cap each).
        uint256 chunk = CAP / 10;
        for (uint256 i; i < 10; ++i) {
            address buyer = address(uint160(0x1000 + i));
            vm.deal(buyer, 100 ether);
            vm.prank(buyer);
            SALE.buy{value: 20 ether}(token, chunk, 0, block.timestamp + 1);
        }

        (,, uint256 sold,,,,,, uint256 raised,,,, bool graduated, bool seeded,,,,) = SALE.curves(token);
        assertEq(sold, CAP, "cap fully sold");
        assertTrue(graduated, "graduated on full cap");
        assertFalse(seeded, "not yet seeded");
        emit log_named_decimal_uint("raised ETH", raised, 18);

        // Anyone can graduate.
        vm.prank(bob);
        uint256 liq = SALE.graduate(token);
        assertGt(liq, 0, "LP minted");

        (,,,,,,,,,,,,, bool seeded2,,,,) = SALE.curves(token);
        assertTrue(seeded2, "seeded");

        (IZAMM.PoolKey memory key, uint256 poolId) = SALE.poolKeyOf(token);
        assertEq(SALE.poolToken(poolId), token, "pool registered");

        // LP went to the burn address, so the graduated liquidity is permanent.
        assertEq(_zammBal(address(0xdead), poolId), liq, "LP burned");

        // Curve inventory is fully drained: nothing left for the creator to dump.
        assertEq(ERC20(token).balanceOf(address(SALE)), 0, "no residual token inventory");
        assertEq(address(SALE).balance, baseETH, "no residual ETH left over from this curve");
    }

    /// The dapp's default creatorFee makes the graduated pool unreachable by any
    /// caller other than the sale contract itself. This is the composability finding.
    function test_deployed_creatorFee_blocksDirectZammSwaps() public {
        address token = _launch(_defaultFee(), bytes32(uint256(2)));
        vm.warp(block.timestamp + 301);
        _buyOutAndGraduate(token);

        (IZAMM.PoolKey memory key,) = SALE.poolKeyOf(token);

        // Direct ZAMM swap reverts -- aggregators, zRouter and the generic ZAMM UI cannot trade this pool.
        vm.prank(alice);
        vm.expectRevert();
        ZAMM.swapExactIn{value: 1 ether}(key, 1 ether, 0, true, alice, block.timestamp + 1);

        // Routed through the sale it succeeds.
        vm.prank(alice);
        uint256 out = SALE.swapExactIn{value: 1 ether}(key, 1 ether, 0, true, alice, block.timestamp + 1);
        assertGt(out, 0, "routed buy works");
        assertEq(ERC20(token).balanceOf(alice), out);
    }

    /// With no creator fee the pool is a plain ZAMM pool anyone can trade.
    function test_deployed_noCreatorFee_allowsDirectZammSwaps() public {
        ClassicalCurveSale.CreatorFee memory none;
        address token = _launch(none, bytes32(uint256(3)));
        vm.warp(block.timestamp + 301);
        _buyOutAndGraduate(token);

        (IZAMM.PoolKey memory key,) = SALE.poolKeyOf(token);
        vm.prank(alice);
        uint256 out = ZAMM.swapExactIn{value: 1 ether}(key, 1 ether, 0, true, alice, block.timestamp + 1);
        assertGt(out, 0, "direct ZAMM buy works without creator fee");
    }

    /// Nobody can front-run the graduated pool into existence and set its starting price.
    function test_deployed_preSeedPoolCreationBlocked() public {
        address token = _launch(_defaultFee(), bytes32(uint256(4)));
        (IZAMM.PoolKey memory key,) = SALE.poolKeyOf(token);

        vm.prank(alice);
        vm.expectRevert();
        ZAMM.addLiquidity{value: 1 ether}(key, 1 ether, 1e18, 0, 0, alice, block.timestamp + 1);
    }

    /// The launch() path is NOT drainable: every token exists inside the sale, so the
    /// only sellable supply is supply someone bought, and selling it back is exactly the
    /// redemption they paid for. The creator cannot obtain a single token pre-graduation.
    function test_deployed_launchPathHasNoOutsideSupply() public {
        address token = _launch(_defaultFee(), bytes32(uint256(5)));

        // Nothing circulates at launch -- not even for the creator.
        assertEq(ERC20(token).balanceOf(address(SALE)), SUPPLY, "entire supply escrowed");
        assertEq(ERC20(token).balanceOf(creator), 0, "creator holds nothing");

        // The template leaves no vesting escrow at all (supply == cap + lpTokens).
        (uint128 vestTotal,,,,) = SALE.creatorVests(token);
        assertEq(vestTotal, 0, "no creator allocation");

        // Vesting is unreachable pre-graduation even when a launch does allocate one.
        vm.prank(creator);
        vm.expectRevert();
        SALE.claimVested(token);

        // A buyer funds the curve.
        vm.warp(block.timestamp + 301);
        vm.prank(alice);
        SALE.buy{value: 5 ether}(token, 100_000_000e18, 0, block.timestamp + 1);
        (,,,,,,,, uint256 raised,,,,,,,,,) = SALE.curves(token);
        assertGt(raised, 0, "buyer ETH in the curve");

        // The creator has no tokens to sell, so the H1 drain has no entry point.
        assertEq(ERC20(token).balanceOf(creator), 0, "still nothing to dump");
        vm.prank(creator);
        vm.expectRevert();
        SALE.sell(token, 1e18, 0, block.timestamp + 1);

        // Alice can only ever redeem what she bought, and it round-trips at a loss
        // (the 1% fee), never a profit -- so the curve cannot be milked.
        uint256 bal = ERC20(token).balanceOf(alice);
        uint256 beforeETH = alice.balance;
        vm.prank(alice);
        SALE.sell(token, bal, 0, block.timestamp + 1);
        assertLt(alice.balance - beforeETH, 5 ether, "round trip returns less than paid");
        (,,,,,,,, uint256 rem,,,,,,,,,) = SALE.curves(token);
        assertLe(rem, 5 ether, "curve never owes more than it took");
    }

    /// configure() accepts any ERC20 the caller can supply -- including one with
    /// circulating supply the caller can dump back into the curve to drain buyer ETH.
    /// This is the registry-filtering finding: such a curve emits the same Configured
    /// event the dapp indexes.
    function test_deployed_configureWithCirculatingTokenDrainsBuyers() public {
        RugToken rug = new RugToken();
        rug.mint(creator, SUPPLY + 500_000_000e18); // creator keeps 500M outside the curve

        ClassicalCurveSale.CreatorFee memory none;
        vm.startPrank(creator);
        rug.approve(address(SALE), type(uint256).max);
        SALE.configure(
            creator, address(rug), CAP, START_PRICE, END_PRICE, 0, 0, LP_TOKENS, address(0), 25, 0, 0, 0, none
        );
        vm.stopPrank();

        // A victim buys in.
        vm.prank(alice);
        SALE.buy{value: 5 ether}(address(rug), 100_000_000e18, 0, block.timestamp + 1);
        (,,,,,,,, uint256 raised,,,,,,,,,) = SALE.curves(address(rug));
        assertGt(raised, 0, "victim ETH in the curve");

        // The creator dumps their outside supply into the curve and takes the ETH.
        uint256 before = creator.balance;
        vm.startPrank(creator);
        rug.approve(address(SALE), type(uint256).max);
        SALE.sell(address(rug), 100_000_000e18, 0, block.timestamp + 1);
        vm.stopPrank();
        assertGt(creator.balance, before, "creator extracted buyer ETH with never-bought tokens");
        emit log_named_decimal_uint("drained", creator.balance - before, 18);
    }

    // ── helpers ──

    function _buyOutAndGraduate(address token) internal {
        uint256 chunk = CAP / 10;
        for (uint256 i; i < 10; ++i) {
            address buyer = address(uint160(0x2000 + i));
            vm.deal(buyer, 100 ether);
            vm.prank(buyer);
            SALE.buy{value: 20 ether}(token, chunk, 0, block.timestamp + 1);
        }
        SALE.graduate(token);
    }

    function _zammBal(address who, uint256 id) internal view returns (uint256 bal) {
        (bool ok, bytes memory ret) =
            address(ZAMM).staticcall(abi.encodeWithSignature("balanceOf(address,uint256)", who, id));
        if (ok && ret.length >= 32) bal = abi.decode(ret, (uint256));
    }
}

contract RugToken {
    string public name = "Rug";
    string public symbol = "RUG";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) public {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address to, uint256 amt) public returns (bool) {
        allowance[msg.sender][to] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) public returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) public returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}
