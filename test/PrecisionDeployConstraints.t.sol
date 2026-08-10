// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";

/// @dev Deployment-time constraints that no functional test can reach, because
/// the test build always happens to satisfy them.
///
/// `PrecisionPoolFactory` takes the pool's creation code as a CONSTRUCTOR
/// ARGUMENT and stores it with SSTORE2, which writes the blob as contract code
/// and is therefore bounded by EIP-170 - 24,576 bytes, one of which SSTORE2
/// spends on a leading STOP. So the pool's creation code must fit in 24,575
/// bytes or the factory cannot be constructed at all.
///
/// That bound is live rather than theoretical. foundry.toml pins
/// `src/pools/PrecisionPoolFactory.sol` to `max_optimizer_runs = 200`, which
/// transitively pins PrecisionPool inside that compilation unit; the same
/// source compiled at the default 9,999,999 runs is materially larger and does
/// NOT fit. Both builds exist in `out/` simultaneously, under different paths,
/// and nothing about a passing test suite tells you which one a deployer
/// handed the factory - the tests only ever see the restricted build.
///
/// Two consequences worth stating plainly, because they are what make this a
/// deployment concern rather than a size trivium:
///
///   - Hand the factory the WRONG build and construction reverts. Loud, but
///     only at deploy time.
///   - Hand it a different-but-valid build and every pool address changes,
///     because `poolInitCodeHash` is the CREATE2 input. A salt mined against
///     one build is worthless against the other.
contract PrecisionDeployConstraintsTest is Test {
    /// @dev EIP-170. SSTORE2 spends one byte on the STOP prefix.
    uint256 constant MAX_CODE = 24_576;
    uint256 constant MAX_SSTORE2_PAYLOAD = MAX_CODE - 1;

    function test_PoolCreationCodeFitsInSSTORE2() public {
        uint256 len = type(PrecisionPool).creationCode.length;
        emit log_named_uint("PrecisionPool creation code bytes", len);
        emit log_named_uint("SSTORE2 headroom bytes", MAX_SSTORE2_PAYLOAD - len);
        assertLe(len, MAX_SSTORE2_PAYLOAD, "pool creation code no longer fits the factory's SSTORE2 blob");
    }

    /// @dev The blob really is stored as code, and it really is one byte longer
    ///      than the payload. Pins the relationship the bound above depends on
    ///      rather than trusting the library's documentation.
    function test_TheBlobIsTheCreationCodePlusOneByte() public {
        bytes memory cc = type(PrecisionPool).creationCode;
        PrecisionPoolFactory f = new PrecisionPoolFactory(address(0), cc);
        assertEq(f.poolCode().code.length, cc.length + 1, "SSTORE2 layout changed");
        assertEq(f.poolInitCodeHash(), keccak256(cc), "factory hashed something other than what it was given");
    }

    /// @dev THE REVERT IS NOT OBSERVABLE FROM A TEST, which is the whole
    ///      reason this file exists. Forge runs with `code_size_limit = None`
    ///      and this repo lists `code-size` and `init-code-size` in
    ///      `ignored_error_codes`, so an over-EIP-170 deployment succeeds in
    ///      the test EVM and only fails on a real chain. A suite that is fully
    ///      green tells you nothing about whether the factory can actually be
    ///      constructed.
    ///
    ///      So the guard has to be arithmetic on the length rather than an
    ///      expected revert. This pins the fact itself - an oversized blob is
    ///      accepted here - so that if a future toolchain starts enforcing the
    ///      limit, this test fails and points at the length assertions above
    ///      as the ones that matter.
    function test_TheTestEvmDoesNotEnforceEip170() public {
        bytes memory tooBig = new bytes(MAX_SSTORE2_PAYLOAD + 4_096);
        bytes memory real = type(PrecisionPool).creationCode;
        for (uint256 i; i < 32; ++i) {
            tooBig[i] = real[i];
        }
        PrecisionPoolFactory f = new PrecisionPoolFactory(address(0), tooBig);
        assertEq(
            f.poolCode().code.length,
            tooBig.length + 1,
            "the test EVM now enforces EIP-170; the length assertions above are the real guard"
        );
        assertGt(f.poolCode().code.length, MAX_CODE, "this blob was supposed to be over the limit");
    }

    /// @dev Every pool address is CREATE2-derived from `poolInitCodeHash`, so
    ///      two factories given different pool builds produce disjoint address
    ///      spaces from the same market tuple. Stated as a test because it is
    ///      the reason a mined salt is only valid for one exact build.
    function test_PoolAddressesFollowTheBuildTheFactoryWasGiven() public {
        bytes memory cc = type(PrecisionPool).creationCode;
        bytes memory altered = bytes.concat(cc, hex"00"); // any different blob

        PrecisionPoolFactory a = new PrecisionPoolFactory(address(0), cc);
        PrecisionPoolFactory b = new PrecisionPoolFactory(address(0), altered);

        assertTrue(a.poolInitCodeHash() != b.poolInitCodeHash(), "different builds must hash differently");

        PrecisionPoolFactory.Market memory m = PrecisionPoolFactory.Market({
            token0: address(0),
            token1: address(0xBEEF),
            sqrtPLow: 0.5e18,
            sqrtPHigh: 2e18,
            fee: 500,
            hook: address(0),
            feeRecipient: address(0),
            creatorFeeBps: 0
        });
        assertTrue(a.poolFor(m) != b.poolFor(m), "the same market must not resolve to the same address");
    }
}
