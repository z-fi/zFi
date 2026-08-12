// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;
import {Test} from "forge-std/Test.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {MockERC20} from "./SwapboardMocks.sol";

/// @notice The reservation path is the only case where a listing id is NOT the
///         token's address. Every address-keyed read must still agree.
contract TokenListReservationTest is Test {
    TokenList constant REG = TokenList(payable(0x0000006013dF75A31678B786061C2B54bf531524));
    address constant SAFE = 0x006CD14F36F65eCbB29b2519cCBe63A0DC8549F2;
    /// The activation target must be an ERC-20 that is NOT already listed:
    /// `activateReserved` rejects a token whose address-derived id already holds
    /// a position. This was DAI, described here as "unlisted ERC-20" - true when
    /// written, and false since somebody listed DAI on the live registry, at
    /// which point the suite failed with a bare BadInput() that reads like a
    /// broken reservation path. Deploy the target instead: a fresh contract
    /// cannot have been listed, so the premise cannot rot again.

    function test_ActivatedReservationStaysReadable() public {
        // Defaulted, not required: an unset ETH_RPC_URL made this suite fail at
        // setUp with "environment variable not found", which reads as a broken
        // test rather than a missing variable. Matches foundry.toml's eth_rpc_url.
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")));
        address target = address(new MockERC20("PRB", 18));
        assertFalse(REG.isListed(uint256(uint160(target))), "target must start unlisted");

        bytes32 key = keccak256("probe.reservation");

        vm.prank(SAFE);
        uint256 id = REG.reserve(key, "Probe", "PRB", 18, 0x112233, 1000, "", "", "a reservation");
        assertEq(id, REG.reservationId(key), "id is not the reservation id");
        assertTrue(id >> 255 == 1, "foreign flag not set");
        assertTrue(REG.isListed(id), "reservation not listed");

        vm.prank(SAFE);
        REG.activateReserved(id, target);

        // THE INVARIANT: the id did NOT become the address.
        assertTrue(id != uint256(uint160(target)), "id collapsed to the address");
        emit log_named_uint("id (hash-derived)", id);
        emit log_named_uint("uint160(target)  ", uint256(uint160(target)));

        // The naive offline shortcut is WRONG here — this is the documented trap.
        assertFalse(REG.isListed(uint256(uint160(target))), "naive id unexpectedly resolved");
        // idFor is the correct entry point.
        assertEq(REG.idFor(target), id, "idFor did not resolve the binding");
        assertTrue(REG.isListed(REG.idFor(target)), "idFor path says not listed");

        // Every address-keyed read must agree — the bug the comment records.
        assertEq(REG.get(target).symbol, REG.get(id).symbol, "get(address) disagrees");
        assertEq(REG.logoOf(target), REG.logoOf(id), "logoOf(address) disagrees");
        { (uint24 c1, string memory h1) = REG.themeOf(target); (uint24 c2, string memory h2) = REG.themeOf(id); assertEq(uint256(c1), uint256(c2), "themeOf color disagrees"); assertEq(h1, h2, "themeOf hex disagrees"); }

        // Metadata was pulled from the real token on activation.
        assertEq(REG.get(id).symbol, "PRB", "symbol not synced from token");
        assertTrue(REG.get(id).deployed, "still flagged undeployed");
        assertTrue(REG.get(id).synced, "not flagged synced");
        // And it is soulbound to the token it now describes.
        assertEq(REG.ownerOf(id), target, "not held by the token");
        emit log("RESULT: activated reservation is consistent across every read path");
    }
}
