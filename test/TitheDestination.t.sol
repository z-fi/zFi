// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";

/// @notice The tithe's destination, executed against the real contracts.
///
///         `_tithe` sends a tenth of every fee this launcher ever collects to a
///         hardcoded address, calling a hardcoded selector, and credits a
///         hardcoded record. Those are source CONSTANTS: nothing in the code can
///         check them, the comments around them assert several properties, and
///         the arrangement is permanent for every token ever launched.
///
///         An audit flagged exactly this - that `_tithe` treats call success as
///         proof the record minted, and never inspects returndata, so a payable
///         fallback with no `depositTo` would look identical to success while
///         burning the ether to nobody's credit. That objection cannot be
///         settled by reading either contract. It is settled here, by making the
///         call and measuring what moved.
contract TitheDestinationTest is Test {
    address constant BETH_BURNER = 0x2cb662Ec360C34a45d7cA0126BCd53C9a1fd48F9;
    address constant TITHE_RECORD = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;
    uint256 constant TITHE_GAS = 200_000;

    address payer = makeAddr("payer");

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_745_140
        );
        vm.deal(payer, 100 ether);
    }

    function _beth(address who) internal view returns (uint256) {
        (bool ok, bytes memory d) = BETH_BURNER.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return ok ? abi.decode(d, (uint256)) : 0;
    }

    /// The claim: `depositTo(address)` credits the NAMED argument, not the
    /// caller. If it credited the caller, every tithe would accrue to the
    /// launcher instead of the record, and nothing on-chain would say so.
    function test_depositToCreditsTheNamedRecordNotTheCaller() public {
        uint256 amount = 1 ether;
        uint256 recordBefore = _beth(TITHE_RECORD);
        uint256 callerBefore = _beth(payer);

        vm.prank(payer);
        (bool ok,) = BETH_BURNER.call{value: amount}(abi.encodeWithSelector(0xb760faf9, TITHE_RECORD));
        assertTrue(ok, "depositTo reverted");

        assertEq(_beth(TITHE_RECORD) - recordBefore, amount, "the record was not credited 1:1");
        assertEq(_beth(payer), callerBefore, "the CALLER was credited instead");
    }

    /// The ether must be gone, not held. A burner that merely custodies would
    /// make the tithe a transfer to whoever controls it rather than a burn.
    function test_theEtherIsBurnedRatherThanHeld() public {
        assertEq(BETH_BURNER.balance, 0, "the burner already holds ether");
        vm.prank(payer);
        (bool ok,) = BETH_BURNER.call{value: 3 ether}(abi.encodeWithSelector(0xb760faf9, TITHE_RECORD));
        assertTrue(ok);
        assertEq(BETH_BURNER.balance, 0, "the burner kept the ether");
    }

    /// `_tithe` caps the call at `TITHE_GAS` and treats exceeding it as a
    /// failure, so a `depositTo` that cost more would silently stop recording
    /// while still burning. The margin is the thing being asserted.
    function test_depositToFitsWellWithinTheGasCap() public {
        vm.prank(payer);
        uint256 before = gasleft();
        (bool ok,) = BETH_BURNER.call{value: 1 ether}(abi.encodeWithSelector(0xb760faf9, TITHE_RECORD));
        uint256 used = before - gasleft();
        assertTrue(ok);

        emit log_named_uint("depositTo gas", used);
        emit log_named_uint("TITHE_GAS cap", TITHE_GAS);
        assertLt(used, TITHE_GAS / 2, "less headroom than the comment claims");
    }

    /// A second deposit must accumulate rather than overwrite, since the tithe
    /// runs once per fee collection for the life of the launcher.
    function test_tithesAccumulate() public {
        uint256 start = _beth(TITHE_RECORD);
        vm.startPrank(payer);
        for (uint256 i; i < 3; ++i) {
            (bool ok,) = BETH_BURNER.call{value: 0.5 ether}(abi.encodeWithSelector(0xb760faf9, TITHE_RECORD));
            assertTrue(ok);
        }
        vm.stopPrank();
        assertEq(_beth(TITHE_RECORD) - start, 1.5 ether, "deposits did not accumulate");
    }

    /// The credit is only worth something if the holder can move it. The record
    /// is a 45-byte minimal proxy, so "it is a contract" says nothing about
    /// whether it can spend an ERC-20 - this asserts the token side of that:
    /// a standard transfer from the record succeeds when it initiates one.
    function test_theRecordCanMoveWhatItIsCredited() public {
        vm.prank(payer);
        (bool ok,) = BETH_BURNER.call{value: 2 ether}(abi.encodeWithSelector(0xb760faf9, TITHE_RECORD));
        assertTrue(ok);

        address sink = makeAddr("sink");
        vm.prank(TITHE_RECORD);
        (bool moved,) = BETH_BURNER.call(abi.encodeWithSignature("transfer(address,uint256)", sink, 1 ether));
        assertTrue(moved, "BETH cannot be transferred out of the record");
        assertEq(_beth(sink), 1 ether);
    }

    /// Documented for what it is: this proves the TOKEN permits it, not that the
    /// DAO's own governance exposes a way to call `transfer`. That is a property
    /// of the DAO implementation behind the proxy, not of the tithe.
    function test_theRecordIsAProxyAsExpected() public view {
        assertEq(TITHE_RECORD.code.length, 45, "the record is not the minimal proxy it was assumed to be");
        assertGt(BETH_BURNER.code.length, 0, "no burner");
    }
}
