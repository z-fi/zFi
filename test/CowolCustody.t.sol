// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Cowol} from "../src/forwarders/Cowol.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function approve(address to, uint256 a) external returns (bool) {
        allowance[msg.sender][to] = a;
        return true;
    }
}

/// Cowol is the one forwarder that HOLDS user tokens between transactions, so
/// custody has to be recorded per order rather than per token: `swap` is
/// reachable by anyone through the public zRouter.snwap -> SafeExecutor path and
/// `recover` is permissionless. These pin that a second depositor can never
/// reach the first one's resting deposit, in either direction.
contract CowolCustody is Test {
    Cowol cowol;
    MockToken usdc;

    address constant SAFE_EXECUTOR = 0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db;
    address victim = address(0xBEEF);
    address attacker = address(0xBAD);

    function setUp() public {
        vm.warp(1_800_000_000);
        cowol = new Cowol();
        usdc = new MockToken();
    }

    function _swap(uint256 sellAmount, uint256 feeAmount, address receiver, uint32 validTo) internal {
        bytes memory data =
            abi.encode(address(0x1111), receiver, sellAmount, uint256(1), validTo, bytes32(0), feeAmount);
        vm.prank(SAFE_EXECUTOR);
        cowol.swap(address(0), address(usdc), address(0), address(0), data);
    }

    function _digest(uint256 sellAmount, uint256 feeAmount, address receiver, uint32 validTo)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Order(address sellToken,address buyToken,address receiver,uint256 sellAmount,"
                    "uint256 buyAmount,uint32 validTo,bytes32 appData,uint256 feeAmount,"
                    "string kind,bool partiallyFillable,string sellTokenBalance,string buyTokenBalance)"
                ),
                address(usdc),
                address(0x1111),
                receiver,
                sellAmount,
                uint256(1),
                validTo,
                bytes32(0),
                feeAmount,
                keccak256("sell"),
                false,
                keccak256("erc20"),
                keccak256("erc20")
            )
        );
        return keccak256(
            abi.encodePacked(bytes2(0x1901), bytes32(0xc078f884a2676e1345748b1feace7b0abee5d00ecadb6e574dcdd109a63e8943), structHash)
        );
    }

    /// A second, tiny deposit cannot reach the first one: the first is reserved
    /// to its own order, so the fresh balance the second order is measured
    /// against is its own one wei and nothing more, and its recovery returns
    /// exactly that wei.
    function test_dustDepositCannotTouchTheVictimsDeposit() public {
        usdc.mint(address(cowol), 1001e6);
        _swap(1000e6, 1e6, victim, uint32(block.timestamp + 300));
        assertEq(cowol.committed(address(usdc)), 1001e6, "victim's deposit reserved");

        // Writing an order over the whole balance is now refused outright.
        usdc.mint(address(cowol), 1);
        vm.expectRevert();
        _swap(1001e6 + 1, 0, attacker, uint32(block.timestamp + 1));

        // The most the attacker can claim is the wei they actually put in.
        _swap(1, 0, attacker, uint32(block.timestamp + 1));
        bytes32 atk = _digest(1, 0, attacker, uint32(block.timestamp + 1));

        vm.warp(block.timestamp + 2);
        cowol.recover(atk);

        assertEq(usdc.balanceOf(attacker), 1, "attacker recovers only their own dust");
        assertEq(usdc.balanceOf(address(cowol)), 1001e6, "victim's deposit untouched");
    }

    /// And the victim still gets their own deposit back on expiry.
    function test_victimRecoversTheirOwnDeposit() public {
        usdc.mint(address(cowol), 1001e6);
        uint32 validTo = uint32(block.timestamp + 300);
        _swap(1000e6, 1e6, victim, validTo);
        bytes32 d = _digest(1000e6, 1e6, victim, validTo);

        vm.warp(uint256(validTo) + 1);
        cowol.recover(d);

        assertEq(usdc.balanceOf(victim), 1001e6, "victim made whole");
        assertEq(cowol.committed(address(usdc)), 0, "reservation released");
        assertFalse(cowol.validDigests(d), "signature revoked with the refund");
    }

    /// Recovering twice must not pay twice.
    function test_recoverIsSingleUse() public {
        usdc.mint(address(cowol), 100);
        uint32 validTo = uint32(block.timestamp + 60);
        _swap(100, 0, victim, validTo);
        bytes32 d = _digest(100, 0, victim, validTo);

        vm.warp(uint256(validTo) + 1);
        cowol.recover(d);
        vm.expectRevert();
        cowol.recover(d);
        assertEq(usdc.balanceOf(victim), 100);
    }

    /// There is no longer a token-keyed default to exploit: recovery needs a
    /// real order, so a stray donation cannot be swept to `address(0)` - or to
    /// anyone else.
    function test_strayDonationCannotBeRecovered() public {
        MockToken stray = new MockToken();
        stray.mint(address(cowol), 500e6);

        vm.expectRevert();
        cowol.recover(bytes32(uint256(1)));

        assertEq(stray.balanceOf(address(cowol)), 500e6, "donation still sitting there");
        assertEq(stray.balanceOf(address(0)), 0, "nothing burned");
    }
}
