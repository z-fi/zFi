// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";

/// @notice Sweeping REAL launched coins, against the deployed contracts.
///
///         `LaunchFeeEconomics.t.sol` proves the split is right against locally
///         deployed copies of the source. That is not the same claim as "the
///         thing on mainnet, holding real ether, with real creators, pays out
///         when pressed" - the deployed bytecode, the real BETH burner and the
///         real pool state are all outside that test's reach.
///
///         The dapp is about to grow a Collect button, which will make this
///         call for the first time in the launcher's life: 0.59 ETH has accrued
///         across nineteen markets and not one sweep has ever happened. So the
///         button's first press should not be the first time anyone finds out
///         what the call does. This runs it, at head, on every launched coin.
interface ILauncher {
    function collectFees(address token)
        external
        returns (uint256 creatorEth, uint256 protocolEth, uint256 titheEth, uint256 tokensBurned, bool titheRecorded);
    function collectFeesMany(address[] calldata tokens)
        external
        returns (uint256 swept, uint256 creatorEth, uint256 protocolEth, uint256 titheEth, uint256 tokensBurned, bool allRecorded);
    function creatorOf(address token) external view returns (address);
    function poolOf(address token) external view returns (address);
}

interface IFactory {
    function poolsForCreatorSlice(address creator, uint256 start, uint256 n)
        external view returns (address[] memory);
}

interface IPool {
    function token1() external view returns (address);
    function creatorOwed0() external view returns (uint256);
    function creatorOwed1() external view returns (uint256);
    function reserve0() external view returns (uint256);
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function symbol() external view returns (string memory);
}

contract LaunchFeesLiveSweepTest is Test {
    ILauncher constant LAUNCHER = ILauncher(0x0000002fC8E77585A008Aa45d78A71ad36293aEe);
    IFactory constant FACTORY = IFactory(0x000000Eb27B557aB426d9E99cFd54EC455799e81);
    address constant TREASURY = 0x000000aA142133107c7D2664F900f80e28BbfFbd;
    address constant BETH = 0x2cb662Ec360C34a45d7cA0126BCd53C9a1fd48F9;
    address constant TITHE_RECORD = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;

    address stranger = address(0xDEADBEEF);

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")));
        vm.deal(stranger, 1 ether);
    }

    function _tokens() internal view returns (address[] memory toks) {
        address[] memory pools = FACTORY.poolsForCreatorSlice(address(LAUNCHER), 0, 40);
        toks = new address[](pools.length);
        for (uint256 i; i < pools.length; ++i) toks[i] = IPool(pools[i]).token1();
    }

    function _beth(address who) internal view returns (uint256) {
        (bool ok, bytes memory d) = BETH.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return ok ? abi.decode(d, (uint256)) : 0;
    }

    /// Every live coin, swept one at a time. Nothing may revert, and each
    /// payout must land where the contract says it lands.
    function test_everyLaunchedCoinCanBeSweptToday() public {
        address[] memory toks = _tokens();
        uint256 totalCreator;
        uint256 swept;

        for (uint256 i; i < toks.length; ++i) {
            address tok = toks[i];
            address pool = LAUNCHER.poolOf(tok);
            address creator = LAUNCHER.creatorOf(tok);
            uint256 owed0 = IPool(pool).creatorOwed0();
            uint256 owed1 = IPool(pool).creatorOwed1();

            uint256 cBefore = creator.balance;
            uint256 tBefore = TREASURY.balance;
            uint256 supplyBefore = IERC20(tok).totalSupply();
            uint256 recordBefore = _beth(TITHE_RECORD);

            // Pressed by somebody who is NOT the creator, which is what the
            // dapp's button allows and what has to be safe.
            vm.prank(stranger);
            (uint256 creatorEth, uint256 protocolEth, uint256 titheEth, uint256 burned, bool recorded) =
                LAUNCHER.collectFees(tok);

            assertEq(creatorEth + protocolEth + titheEth, owed0, "the three parts do not sum to what the pool held");
            assertEq(creator.balance - cBefore, creatorEth, "the creator was not paid");
            assertEq(TREASURY.balance - tBefore, protocolEth, "the treasury was not paid");
            assertEq(burned, owed1, "the token side was not fully burned");
            assertEq(supplyBefore - IERC20(tok).totalSupply(), burned, "supply did not fall by the burn");
            assertTrue(recorded, "the tithe failed to record");
            assertEq(_beth(TITHE_RECORD) - recordBefore, titheEth, "the tithe was not credited");
            assertEq(stranger.balance, 1 ether, "the caller took a cut");

            if (owed0 != 0) {
                emit log_named_string("swept", IERC20(tok).symbol());
                emit log_named_decimal_uint("  to creator", creatorEth, 18);
                swept++;
            }
            totalCreator += creatorEth;
        }

        emit log_named_uint("coins with fees", swept);
        emit log_named_decimal_uint("total paid to creators", totalCreator, 18);
        assertGt(totalCreator, 0, "nothing was owed anywhere - this test proved nothing");
    }

    /// A second sweep immediately after must be a no-op, not a revert and not a
    /// double payment. The button is pressable twice and somebody will.
    function test_sweepingTwiceIsHarmless() public {
        address[] memory toks = _tokens();
        for (uint256 i; i < toks.length; ++i) {
            vm.prank(stranger);
            LAUNCHER.collectFees(toks[i]);
        }
        for (uint256 i; i < toks.length; ++i) {
            address creator = LAUNCHER.creatorOf(toks[i]);
            uint256 before = creator.balance;
            vm.prank(stranger);
            (uint256 creatorEth,,, uint256 burned,) = LAUNCHER.collectFees(toks[i]);
            assertEq(creatorEth, 0, "a second sweep paid again");
            assertEq(burned, 0, "a second sweep burned again");
            assertEq(creator.balance, before);
        }
    }

    /// What the Collect all button does: every coin one creator owns, in one
    /// transaction. Must match sweeping them individually, to the wei.
    function test_collectFeesManyMatchesSweepingOneByOne() public {
        address[] memory toks = _tokens();

        uint256 snap = vm.snapshotState();
        uint256 oneByOne;
        for (uint256 i; i < toks.length; ++i) {
            vm.prank(stranger);
            (uint256 c,,,,) = LAUNCHER.collectFees(toks[i]);
            oneByOne += c;
        }
        vm.revertToState(snap);

        vm.prank(stranger);
        (uint256 swept, uint256 creatorEth,,,, bool allRecorded) = LAUNCHER.collectFeesMany(toks);

        emit log_named_uint("markets swept", swept);
        assertEq(creatorEth, oneByOne, "the batch paid a different amount than the loop");
        assertTrue(allRecorded, "a tithe failed to record in the batch");
    }

    /// The claim the dapp makes to holders when it says collecting raises the
    /// floor: the token side is burned, so circulating supply falls.
    function test_sweepingRetiresSupply() public {
        address[] memory toks = _tokens();
        uint256 burnedTotal;
        for (uint256 i; i < toks.length; ++i) {
            uint256 before = IERC20(toks[i]).totalSupply();
            vm.prank(stranger);
            (,,, uint256 burned,) = LAUNCHER.collectFees(toks[i]);
            assertEq(before - IERC20(toks[i]).totalSupply(), burned);
            burnedTotal += burned;
        }
        emit log_named_uint("tokens retired across all markets", burnedTotal / 1e18);
        assertGt(burnedTotal, 0, "no supply was retired");
    }
}
