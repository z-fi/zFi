// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionRoute} from "../src/pools/PrecisionRoute.sol";
import {PrecisionPoolLens} from "../src/pools/PrecisionPoolLens.sol";

interface ISummoner {
    function create2Deploy(bytes calldata creationCode, bytes32 salt) external returns (address);
}

/// @dev The broadcast, rehearsed. Reads the FROZEN artifacts out of `deploy/`
/// - the same bytes that would go on chain - sends them to the real
/// SafeSummoner on a mainnet fork, and checks that every contract lands at the
/// address the runbook advertises and is wired to the factory that actually
/// deployed.
///
/// This is the closest thing to a dry run that exists. It catches the failures
/// that only appear at broadcast: a salt that no longer matches its payload, a
/// dependent built against a superseded factory address, a calldata file that
/// drifted from the artifact it claims to encode, and an address already
/// occupied on mainnet.
///
/// It deliberately reads `deploy/` rather than recompiling. `check-create2-
/// artifacts.mjs` already proves the artifacts reproduce from source; the open
/// question at broadcast time is whether those exact bytes behave, and
/// recompiling here would test something else.
contract PrecisionBroadcastRehearsalTest is Test {
    address constant SUMMONER = 0x00000000004473e1f31C8266612e7FD5504e6f2a;
    address constant EXECUTOR = 0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db;
    address constant POLICY_OWNER = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;

    address deployer = address(0xD3919E4);

    function _hex(string memory path) internal view returns (bytes memory) {
        return vm.parseBytes(vm.trim(vm.readFile(path)));
    }

    function _addr(string memory name) internal view returns (address) {
        return vm.parseAddress(vm.trim(vm.readFile(string.concat("deploy/", name, ".address.txt"))));
    }

    /// @dev Sends the frozen calldata exactly as a broadcast would.
    function _deploy(string memory name) internal returns (address landed) {
        bytes memory calldata_ = _hex(string.concat("deploy/", name, ".deploy.calldata.txt"));
        address expected = _addr(name);

        assertEq(expected.code.length, 0, string.concat(name, ": address is already occupied on mainnet"));

        vm.prank(deployer);
        (bool ok, bytes memory ret) = SUMMONER.call(calldata_);
        assertTrue(ok, string.concat(name, ": create2Deploy reverted"));
        landed = abi.decode(ret, (address));

        assertEq(landed, expected, string.concat(name, ": landed at a different address than the runbook says"));
        assertGt(landed.code.length, 0, string.concat(name, ": no code at the deployed address"));
    }

    function test_TheWholeSuiteDeploysWhereTheRunbookSaysItWill() public {
        vm.deal(deployer, 100 ether);
        assertGt(SUMMONER.code.length, 0, "SafeSummoner is not deployed on this fork");

        // 1. Factory first. Everything else embeds its address.
        address factory = _deploy("PrecisionPoolFactory");

        // The single check that matters most: the factory must be holding the
        // pool build we mined against. If this differs, every market address it
        // will ever produce is not the one the repo describes - and nothing
        // about a successful deployment would tell you.
        assertEq(
            PrecisionPoolFactory(factory).poolInitCodeHash(),
            keccak256(type(PrecisionPool).creationCode),
            "factory went out over a different pool build"
        );
        assertEq(PrecisionPoolFactory(factory).trustedExecutor(), EXECUTOR, "wrong executor baked in");

        // 2-6. The dependents, each keyed to the factory address above.
        address route = _deploy("PrecisionRoute");
        address zap = _deploy("PrecisionZap");
        address lens = _deploy("PrecisionPoolLens");
        address hook = _deploy("ConstantSurchargeHook");
        address policy = _deploy("PrecisionPoolPolicy");

        // Every dependent points at the factory that actually landed, not at a
        // superseded one from an earlier mining round.
        assertEq(address(PrecisionRoute(payable(route)).factory()), factory, "route points elsewhere");
        assertEq(address(PrecisionPoolLens(lens).factory()), factory, "lens points elsewhere");
        assertEq(
            _staticAddress(zap, "factory()"), factory, "zap points elsewhere"
        );
        assertEq(_staticAddress(hook, "factory()"), factory, "hook points elsewhere");
        assertEq(_staticAddress(policy, "factory()"), factory, "policy points elsewhere");
        assertEq(_staticAddress(policy, "owner()"), POLICY_OWNER, "policy owner is not the intended address");
        assertEq(PrecisionRoute(payable(route)).trustedExecutor(), EXECUTOR, "route executor wrong");
    }

    function _staticAddress(address target, string memory sig) internal view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok && ret.length == 32, "call failed");
        return abi.decode(ret, (address));
    }

    /// @dev A real market, created and seeded through the freshly deployed
    /// factory on a fork of live mainnet - with live USDC, not a mock. This is
    /// the step that has never happened: every test to date built its own
    /// factory in memory.
    function test_AMarketCanBeSeededAndTradedThroughTheDeployedSuite() public {
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        vm.deal(deployer, 10_000 ether);

        address factory = _deploy("PrecisionPoolFactory");
        _deploy("PrecisionPoolLens");

        // A named market, which is what the runbook says to ship: only its fee
        // recipient can initialise it.
        PrecisionPoolFactory.Market memory m = PrecisionPoolFactory.Market({
            token0: address(0),
            token1: USDC,
            sqrtPLow: 42426406871192,
            sqrtPHigh: 46904157598234,
            fee: 3000,
            hook: address(0),
            feeRecipient: deployer,
            creatorFeeBps: 1000
        });

        deal(USDC, deployer, 20_000_000e6);
        vm.startPrank(deployer);
        IERC20Min(USDC).approve(factory, type(uint256).max);
        (address pool, uint256 lp,,) = PrecisionPoolFactory(factory).createAndSeed{value: 1_000 ether}(
            m, 44721359549995, 1_000 ether, 10_000_000e6, 0, deployer
        );
        vm.stopPrank();

        assertGt(lp, 0, "seed minted nothing");
        assertEq(PrecisionPoolFactory(factory).isPool(pool), true, "factory did not index its own pool");
        assertEq(pool, PrecisionPoolFactory(factory).poolFor(m), "pool is not at its derived address");

        // Trade it, with real USDC.
        address trader = address(0xBEEF);
        vm.deal(trader, 100 ether);
        vm.prank(trader);
        uint256 out = PrecisionPool(payable(pool)).swapExactIn{value: 5 ether}(address(0), 5 ether, 0, trader);
        assertGt(out, 0, "swap produced nothing");
        assertEq(IERC20Min(USDC).balanceOf(trader), out, "trader was not paid");

        // And exit.
        vm.prank(deployer);
        (uint256 a0, uint256 a1) = PrecisionPool(payable(pool)).removeLiquidity(lp / 10, 0, 0, deployer);
        assertTrue(a0 != 0 || a1 != 0, "exit paid nothing");

        // Still solvent against live token behaviour.
        assertGe(address(pool).balance, PrecisionPool(payable(pool)).reserve0(), "token0 backing broken");
        assertGe(IERC20Min(USDC).balanceOf(pool), PrecisionPool(payable(pool)).reserve1(), "token1 backing broken");
    }
}

interface IERC20Min {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}
