// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {DutchAuction} from "../src/DutchAuction.sol";
import {Swapbol} from "../src/forwarders/Swapbol.sol";

/// @notice Swapbol will not forward to `DutchAuction`, and that is the design.
///
/// @dev THIS FILE USED TO ASSERT THE OPPOSITE, and it is worth saying why
///      rather than deleting it.
///
///      It was written when Swapbol took `board` as a free parameter, so it
///      forwarded anywhere the caller pointed it - the original header claimed
///      a decaying, partially-fillable order composed with the live zRouter
///      "with no new contract and no allowlisting". True at the time, and the
///      allowlisting clause is precisely what stopped being true: Swapbol now
///      pins four immutable boards in its constructor and reverts
///      `UnknownBoard` for anything else.
///
///      That is not a regression. A forwarder that will call any address a
///      caller names is a forwarder that will call a contract written to abuse
///      it, and Swapbol holds balances mid-plan. The allowlist is the fix.
///
///      Two facts make the old test unrecoverable rather than merely stale:
///
///        - `DutchAuction` is NOT DEPLOYED. `Dutchboard` is the contract that
///          shipped, at 0x000000a213b430D14Bae6062c176289B05e04489, and it IS
///          one of Swapbol's four. Everything the old file wanted to prove
///          about decay, partial fills and snwap's minOut is proven against
///          Dutchboard by its own suite.
///        - So a fork test of DutchAuction-through-Swapbol is a fork test of
///          a composition that cannot exist on chain.
///
///      What is left worth pinning is the boundary itself, which no other test
///      states outright: an unknown board is refused BY NAME, before any
///      balance moves.
contract DutchAuctionSnwapForkTest is Test {
    Swapbol swapbol;
    DutchAuction auction;

    address constant BOARD_V1 = 0x000000fF3D7A2d373615141d7489Ca66683DbecF;
    address constant BOARD_CURRENT = 0x000000dA7bb4B2A9E3e80e9A4D4157E26CA6189b;
    address constant DUTCHBOARD = 0x000000a213b430D14Bae6062c176289B05e04489;
    address constant FLOORBOARD = 0x00000080198137F790DA4C52bb902cf87c276748;

    /// @dev Forked, and against the DEPLOYED Swapbol rather than a fresh one.
    ///      Its constructor requires all four venues to have code, so it cannot
    ///      be built on a bare chain at all - and the allowlist worth pinning is
    ///      the one users actually route through, not one this test chose.
    address constant SWAPBOL = 0x00000087A6dc5071779Ed1F8274A39230768B976;

    function setUp() public {
        vm.createSelectFork(
            vm.envOr("FOUNDRY_ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet"))
        );
        swapbol = Swapbol(payable(SWAPBOL));
        auction = new DutchAuction();
    }

    /// @dev The four are immutable, so the set a deployment trusts is fixed at
    ///      construction and readable by anyone integrating against it.
    function test_OnlyFourBoardsAreEverForwardedTo() public view {
        assertEq(swapbol.boardV1(), BOARD_V1);
        assertEq(swapbol.boardCurrent(), BOARD_CURRENT);
        assertEq(swapbol.dutchboard(), DUTCHBOARD);
        assertEq(swapbol.floorboard(), FLOORBOARD);
    }

    /// @dev The refusal names the address it refused, which is what makes a
    ///      misconfigured integration debuggable instead of a silent revert.
    function test_AnUnknownBoardIsRefusedByName() public {
        vm.expectRevert(abi.encodeWithSelector(Swapbol.UnknownBoard.selector, address(auction)));
        swapbol.fill(address(auction), address(0), address(0), address(this), address(this), "");
    }

    /// @dev Including one that behaves perfectly well. Being a real, working
    ///      auction is not the property Swapbol screens on - being one of the
    ///      four addresses this deployment was built over is.
    function test_ARealAuctionIsRefusedJustTheSame() public {
        assertGt(address(auction).code.length, 0, "the auction is a real contract");
        vm.expectRevert(abi.encodeWithSelector(Swapbol.UnknownBoard.selector, address(auction)));
        swapbol.fill(address(auction), address(0), address(0), address(this), address(this), "");
    }
}
