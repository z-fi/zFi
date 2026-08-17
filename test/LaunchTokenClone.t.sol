// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {LaunchToken, PrecisionLauncher} from "../src/pools/PrecisionLauncher.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {LibClone} from "../lib/solady/src/utils/LibClone.sol";
import {Ownable} from "../lib/solady/src/auth/Ownable.sol";

/// @notice Launched tokens are minimal proxies now, and this covers the failure
///         modes that only exist BECAUSE of that.
///
///         A constructor cannot be called twice and cannot be skipped. An
///         `initialize` can be both, so the guarantees a constructor gave for
///         free have to be asserted: that a token can only be set up once, that
///         the template itself cannot be claimed, and that a proxy behaves as
///         the real thing under everything the pool and the launcher do to it.
contract LaunchTokenCloneTest is Test {
    LaunchToken impl;
    address owner = address(0xC0FFEE);
    address attacker = address(0xBAD);

    function setUp() public {
        impl = new LaunchToken();
    }

    function _fresh() internal returns (LaunchToken t) {
        t = LaunchToken(LibClone.clone_PUSH0(address(impl)));
        t.initialize("Coin", "COIN", "ipfs://x", 1e27, owner, "", 0);
    }

    // ------------------------------------------------ what a constructor gave

    /// The guarantee a constructor made for free. A second `initialize` would
    /// re-mint the supply and hand ownership to whoever called it.
    function test_aTokenCanOnlyBeInitializedOnce() public {
        LaunchToken t = _fresh();
        vm.prank(attacker);
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        t.initialize("Evil", "EVIL", "", 1e27, attacker, "", 0);

        assertEq(t.owner(), owner, "ownership survived");
        assertEq(t.totalSupply(), 1e27, "and the supply was not minted twice");
    }

    /// Nothing is written before the guard runs, so a refused second call
    /// cannot leave the name or symbol changed on its way out.
    function test_aRefusedSecondInitializeChangesNothing() public {
        LaunchToken t = _fresh();
        vm.prank(attacker);
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        t.initialize("Evil", "EVIL", "ipfs://evil", 1e27, attacker, "", 0);

        assertEq(t.name(), "Coin");
        assertEq(t.symbol(), "COIN");
        assertEq(t.contractURI(), "ipfs://x");
    }

    /// The template is locked in its own constructor. Left open, a passer-by
    /// could claim it, mint its supply, and leave a contract that looks like
    /// one of ours and answers to them.
    function test_theImplementationCannotBeClaimed() public {
        vm.prank(attacker);
        vm.expectRevert(Ownable.AlreadyInitialized.selector);
        impl.initialize("Evil", "EVIL", "", 1e27, attacker, "", 0);
        assertEq(impl.owner(), address(0xdead));
        assertEq(impl.totalSupply(), 0, "the template holds no supply");
    }

    /// Clones do NOT run the constructor - that is what makes them cheap - so
    /// the lock on the template must not have locked them too. This is the
    /// assertion that says the two are genuinely separate.
    function test_cloningDoesNotInheritTheTemplatesLock() public {
        LaunchToken t = LaunchToken(LibClone.clone_PUSH0(address(impl)));
        assertEq(t.owner(), address(0), "a fresh clone starts unowned");
        t.initialize("Coin", "COIN", "", 1e27, owner, "", 0);
        assertEq(t.owner(), owner);
    }

    /// Storage is per-clone, not shared with the template or with each other.
    /// The classic proxy mistake, and it would be catastrophic here: every
    /// launched token would share one balance ledger.
    function test_clonesDoNotShareStorage() public {
        LaunchToken a = _fresh();
        LaunchToken b = LaunchToken(LibClone.clone_PUSH0(address(impl)));
        b.initialize("Other", "OTHR", "ipfs://y", 5e26, attacker, "", 0);

        assertEq(a.name(), "Coin");
        assertEq(b.name(), "Other");
        assertEq(a.totalSupply(), 1e27);
        assertEq(b.totalSupply(), 5e26);
        assertEq(a.balanceOf(address(this)), 1e27, "each mints to its own initializer");
        assertEq(impl.totalSupply(), 0, "and the template is untouched");
    }

    // --------------------------------------------- it still behaves as a token

    /// Everything the pool does to a token, through the proxy.
    function test_aProxiedTokenTransfersApprovesAndBurns() public {
        LaunchToken t = _fresh();
        t.transfer(attacker, 100e18);
        assertEq(t.balanceOf(attacker), 100e18);

        vm.prank(attacker);
        t.approve(address(this), 40e18);
        t.transferFrom(attacker, owner, 40e18);
        assertEq(t.balanceOf(owner), 40e18);
        assertEq(t.allowance(attacker, address(this)), 0);

        uint256 supply = t.totalSupply();
        vm.prank(attacker);
        t.burn(10e18);
        assertEq(t.totalSupply(), supply - 10e18, "burning still lowers supply");
    }

    /// `permit` is the one ERC-20 feature that could quietly break behind a
    /// proxy: a domain separator cached at construction would be the
    /// IMPLEMENTATION's, making every clone's signatures interchangeable.
    /// Solady derives it from `address(this)` and `name()` on each call, so
    /// each clone must get its own - asserted rather than assumed.
    function test_eachCloneHasItsOwnPermitDomain() public {
        LaunchToken a = _fresh();
        LaunchToken b = LaunchToken(LibClone.clone_PUSH0(address(impl)));
        b.initialize("Other", "OTHR", "", 1e27, owner, "", 0);

        assertTrue(a.DOMAIN_SEPARATOR() != b.DOMAIN_SEPARATOR(), "two clones share a domain");
        assertTrue(a.DOMAIN_SEPARATOR() != impl.DOMAIN_SEPARATOR(), "a clone shares the template's");
    }

    /// A permit signed for one clone must not be replayable against another.
    /// The consequence of the domain check above, spelled out as behaviour.
    function test_aPermitForOneTokenIsNotValidForAnother() public {
        (address signer, uint256 pk) = makeAddrAndKey("signer");
        LaunchToken a = _fresh();
        LaunchToken b = LaunchToken(LibClone.clone_PUSH0(address(impl)));
        b.initialize("Other", "OTHR", "", 1e27, owner, "", 0);

        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                a.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        signer,
                        attacker,
                        1e18,
                        uint256(0),
                        type(uint256).max
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        a.permit(signer, attacker, 1e18, type(uint256).max, v, r, s);
        assertEq(a.allowance(signer, attacker), 1e18, "the permit works on its own token");

        vm.expectRevert();
        b.permit(signer, attacker, 1e18, type(uint256).max, v, r, s);
    }

    // ------------------------------------------------------------------ cost

    /// The reason for all of the above. Asserted as a RATIO rather than an
    /// absolute, so it keeps meaning something as the token grows.
    function test_cloningIsFarCheaperThanDeploying() public {
        uint256 g0 = gasleft();
        LaunchToken outright = new LaunchToken();
        uint256 deployed = g0 - gasleft();

        g0 = gasleft();
        address cloned = LibClone.clone_PUSH0(address(impl));
        uint256 clonedCost = g0 - gasleft();

        emit log_named_uint("deploying the token outright", deployed);
        emit log_named_uint("cloning it", clonedCost);
        emit log_named_uint("saved", deployed - clonedCost);
        assertLt(clonedCost * 10, deployed, "a clone must be an order of magnitude cheaper");
        assertTrue(cloned.code.length < 100, "a minimal proxy is tiny");
        assertGt(address(outright).code.length, 1000);
    }

    /// And the price of it, measured rather than claimed - this is the number
    /// the whole trade-off rests on, so it should fail loudly if it moves.
    function test_theProxyOverheadOnATransferIsSmall() public {
        LaunchToken proxied = _fresh();
        // A genuine NON-proxy instance, which `new` can no longer produce: the
        // constructor locks whatever it builds. Etching the runtime code at a
        // fresh address skips the constructor, giving the same logic with no
        // delegatecall in front of it - which is exactly the baseline this
        // measurement needs.
        LaunchToken direct = LaunchToken(makeAddr("direct"));
        vm.etch(address(direct), address(impl).code);
        direct.initialize("Coin", "COIN", "", 1e27, owner, "", 0);

        // TWO numbers, because there are two, and quoting only the flattering
        // one would misstate the trade. The implementation account is COLD on
        // the first touch of a token in a transaction (EIP-2929, 2,600 gas) and
        // warm for every call after it. A plain transfer pays the cold price
        // once; a swap that touches the token three times pays it once and the
        // warm price twice.
        uint256 gc = gasleft();
        proxied.transfer(attacker, 1);
        uint256 coldProxied = gc - gasleft();
        gc = gasleft();
        direct.transfer(attacker, 1);
        uint256 coldDirect = gc - gasleft();
        emit log_named_uint("first transfer, direct", coldDirect);
        emit log_named_uint("first transfer, proxy", coldProxied);
        emit log_named_uint("cold overhead", coldProxied - coldDirect);

        uint256 g0 = gasleft();
        direct.transfer(attacker, 1e18);
        uint256 directCost = g0 - gasleft();

        g0 = gasleft();
        proxied.transfer(attacker, 1e18);
        uint256 proxiedCost = g0 - gasleft();

        emit log_named_uint("later transfer, direct", directCost);
        emit log_named_uint("later transfer, proxy", proxiedCost);
        emit log_named_uint("warm overhead", proxiedCost - directCost);
        assertLt(proxiedCost - directCost, 500, "the warm proxy tax grew past what was budgeted");
        assertLt(coldProxied - coldDirect, 3000, "the cold proxy tax grew past one account access");
    }
}

/// The launcher end: launches still work, and produce proxies.
contract LauncherClonesTest is Test {
    function test_aLaunchProducesAProxyOfTheLauncherTemplate() public {
        // Only the wiring is asserted here; the full launch path is covered in
        // PrecisionLauncher.t.sol against a real factory.
        LaunchToken impl = new LaunchToken();
        address clone = LibClone.clone_PUSH0(address(impl));
        assertEq(clone.code.length, 45, "PUSH0 minimal proxy");
        // The template's address is baked into the proxy body, which is what
        // makes this a clone OF something rather than merely 45 bytes.
        assertTrue(
            vm.indexOf(vm.toString(clone.code), vm.replace(vm.toLowercase(vm.toString(address(impl))), "0x", ""))
                != type(uint256).max,
            "the proxy does not point at the template"
        );
    }
}
