// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @dev A token that hands control to an attacker during `transferFrom`, which
/// is what makes the seed window reachable. Nothing exotic: any token with a
/// transfer hook the attacker can register does this.
contract ReenteringToken is MockERC20("REENTER", 18) {
    PrecisionPoolFactory public factory;
    PrecisionPoolFactory.Market public market;
    bool public armed;
    bool public fired;
    bool public innerSucceeded;
    bytes public innerRevert;

    function arm(PrecisionPoolFactory f, PrecisionPoolFactory.Market memory m) external {
        factory = f;
        market = m;
        armed = true;
    }

    function _reenter() internal {
        if (!armed || fired) return;
        fired = true;
        // Seed the same market first, at a price of our choosing: the bottom of
        // the band, which is the worst corner for whoever deposits next.
        try factory.createAndSeed{value: 0}(
            market, market.sqrtPLow, 0, 5e23, 0, address(this)
        ) {
            innerSucceeded = true;
        } catch (bytes memory err) {
            innerRevert = err;
        }
    }

    function transferFrom(address f, address t, uint256 amt) public override returns (bool) {
        bool ok = super.transferFrom(f, t, amt);
        _reenter();
        return ok;
    }
}

/// @dev Findings from the factory audit pass.
contract PrecisionFactoryAuditTest is Test {
    PrecisionPoolFactory factory;
    ReenteringToken tok;
    address attacker = address(0xBAD);
    address victim = address(0xC11);

    function setUp() public {
        factory = new PrecisionPoolFactory(address(0), type(PrecisionPool).creationCode);
        tok = new ReenteringToken();
        tok.mint(victim, 1e26);
        tok.mint(address(tok), 1e26);
        vm.deal(victim, 1_000 ether);
    }

    function _market() internal view returns (PrecisionPoolFactory.Market memory) {
        return PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(tok),
            sqrtPLow: 0.5e18,
            sqrtPHigh: 2e18,
            fee: 500,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
    }

    /// @dev THE SEED TOCTOU. `createAndSeed` reads `totalSupply() == 0`, then
    /// makes two external transfers, then lets the pool choose between the seed
    /// and proportional branches. A callback inside those transfers could
    /// re-enter on the same market and seed it first; the outer call would then
    /// find a pool with supply, silently take the proportional path, ignore
    /// `sqrtPriceInit` entirely, and deposit into whatever corner of the band
    /// the attacker chose. `minLP` does not help - it bounds shares, not price.
    ///
    /// The factory now takes the route lock across the whole deposit, so the
    /// re-entry is refused and the victim either seeds at their own price or
    /// gets nothing.
    function test_ASeedCannotBeFrontRunFromInsideItsOwnTransfer() public {
        PrecisionPoolFactory.Market memory m = _market();
        tok.arm(factory, m);

        vm.startPrank(victim);
        tok.approve(address(factory), type(uint256).max);
        (address pool,,,) = factory.createAndSeed{value: 100 ether}(m, 1e18, 100 ether, 1e24, 0, victim);
        vm.stopPrank();

        assertTrue(tok.fired(), "the callback never ran; this test proves nothing");
        assertFalse(tok.innerSucceeded(), "reentrant seed succeeded - the window is open");
        assertEq(bytes4(tok.innerRevert()), PrecisionPoolFactory.Reentrancy.selector, "wrong refusal");

        // And the victim got the price they asked for, not the attacker's.
        uint256 sqrtP = PrecisionPool(payable(pool)).sqrtPriceCurrent();
        assertApproxEqRel(sqrtP, 1e18, 0.01e18, "victim did not seed at their own price");
        assertGt(PrecisionPool(payable(pool)).balanceOf(victim), 0, "victim got no shares");
    }

    /// @dev The same lock must not fire on ordinary sequential use.
    function test_TheLockDoesNotBlockNormalDeposits() public {
        PrecisionPoolFactory.Market memory m = _market();
        vm.startPrank(victim);
        tok.approve(address(factory), type(uint256).max);
        (address pool,,,) = factory.createAndSeed{value: 100 ether}(m, 1e18, 100 ether, 1e24, 0, victim);
        // A second, proportional deposit through the other entry point.
        factory.seed{value: 10 ether}(m, 0, 10 ether, 1e23, 0, victim);
        vm.stopPrank();
        assertGt(PrecisionPool(payable(pool)).balanceOf(victim), 0);
    }

    /// @dev THE MEMPOOL HALF OF THE SAME FINDING. The lock closes the
    /// in-transaction squat; it cannot close a front-run in a previous block.
    /// There, `seed` used to convert silently: `totalSupply() != 0` skips
    /// `_checkCreator`, `sqrtPriceInit` is ignored, and the deposit lands
    /// proportionally at whatever price the squatter chose, with `minLP`
    /// bounding shares rather than price.
    ///
    /// A nonzero `sqrtPriceInit` is now read as a stated intent to seed, so
    /// that caller gets a revert instead of a position they did not choose. No
    /// new parameter - the argument is already documented as meaningful only
    /// for an empty pool, so a caller topping up passes zero and is unaffected.
    function test_ASeedThatLostTheRaceRevertsRatherThanConverting() public {
        PrecisionPoolFactory.Market memory m = _market();

        // The squatter gets there first, at the bottom of the band.
        address squatter = address(0xBEEF);
        tok.mint(squatter, 1e26);
        vm.deal(squatter, 1_000 ether);
        vm.startPrank(squatter);
        tok.approve(address(factory), type(uint256).max);
        factory.createAndSeed{value: 50 ether}(m, m.sqrtPLow, 50 ether, 5e23, 0, squatter);
        vm.stopPrank();

        // The honest caller still believes they are initialising.
        vm.startPrank(victim);
        tok.approve(address(factory), type(uint256).max);
        vm.expectRevert(PrecisionPoolFactory.Bad.selector);
        factory.seed{value: 100 ether}(m, 1e18, 100 ether, 1e24, 0, victim);

        // Passing zero says "top me up at whatever the price is", which is a
        // different request and still works.
        (, uint256 lp,,) = factory.seed{value: 10 ether}(m, 0, 10 ether, 1e23, 0, victim);
        vm.stopPrank();
        assertGt(lp, 0, "a genuine top-up must still go through");
    }

    /// @dev `_routeHash` copies a hardcoded `0xe0` bytes of calldata. If a
    ///      `Route` field is added, reordered or made dynamic, the commitment
    ///      silently covers the wrong bytes - it would still hash something,
    ///      just not the intent. The constructor now asserts the encoded size,
    ///      so a drifted struct cannot be deployed; this pins the same fact at
    ///      test time, where the failure names the cause.
    function test_RouteEncodesToTheSizeTheIntentHashAssumes() public pure {
        PrecisionPoolFactory.Route memory r;
        assertEq(abi.encode(r).length, 0xe0, "Route size changed; _routeHash covers the wrong bytes");
    }

    /// @dev `poolInitCodeHash` is keccak of the BARE creation code, while the
    ///      CREATE2 preimage is `blob ++ abi.encode(constructorArgs)`. It is
    ///      correct for verifying the blob, but it is not the Uniswap-style
    ///      constant an integrator will assume, and you cannot derive a pool
    ///      address from it. Pinned so the distinction is executable rather
    ///      than only written down.
    function test_PoolInitCodeHashIsTheBlobNotTheCreate2Preimage() public view {
        bytes memory blob = type(PrecisionPool).creationCode;
        assertEq(factory.poolInitCodeHash(), keccak256(blob), "not the bare blob hash");

        PrecisionPoolFactory.Market memory m = _market();
        bytes memory withArgs = abi.encodePacked(
            blob,
            abi.encode(
                address(factory), m.token0, m.token1, m.sqrtPLow, m.sqrtPHigh, m.fee, m.hook, m.feeRecipient,
                m.creatorFeeBps
            )
        );
        assertTrue(
            factory.poolInitCodeHash() != keccak256(withArgs),
            "the two hashes coincided; the distinction this pins has evaporated"
        );

        // The address derives from the WITH-ARGS hash, which is the point.
        address derived = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), keccak256(abi.encode(m)), keccak256(withArgs))
                    )
                )
            )
        );
        assertEq(derived, factory.poolFor(m), "address derivation does not use the with-args hash");
    }
}
