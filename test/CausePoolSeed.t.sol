// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test, console} from "../lib/forge-std/src/Test.sol";

interface IERC20X { function approve(address,uint256) external returns (bool); function balanceOf(address) external view returns (uint256); }

/// The exact bytes dapp/coin/index.html builds for "Create pool", fired for real.
/// sl/sh/sp come from the page's own pxToSqrt + lqSeedPrice, computed in JS.
contract SeedTest is Test {
    address constant PF = 0x000000Eb27B557aB426d9E99cFd54EC455799e81;
    address constant SHARES = 0xf142CfA6Ca3DFa4A131f12aACEF4890e390d70D6;
    address constant WHALE = 0x18DB005428492F8Bc154c50ad0A4Bd23DE2750fF;
    address constant ZERO = address(0);
    uint256 constant FEE = 3000;

    // Needs a fork at head; foundry.toml pins earlier, so this skips by default:
    //   forge test --match-path test/CausePoolSeed.t.sol \
    //     --fork-url <rpc> --fork-block-number $(cast block-number --rpc-url <rpc>)
    function setUp() public { if (SHARES.code.length == 0) vm.skip(true); }

    function _seed(uint256 sl, uint256 sh, uint256 sp, uint256 a0, uint256 a1, address to)
        internal pure returns (bytes memory)
    {
        return abi.encodePacked(
            bytes4(0x7163352a),
            abi.encode(ZERO, SHARES, sl, sh, FEE, ZERO, ZERO, uint256(0)), // market
            abi.encode(sp, a0, a1, uint256(0), to)
        );
    }

    function test_createPoolFromThePageCalldata() public {
        uint256 a0 = 1 ether;              // ETH is token0
        uint256 a1 = 3_000_000e18;         // shares
        console.log("whale shares:", IERC20X(SHARES).balanceOf(WHALE) / 1e18);

        vm.prank(WHALE);
        IERC20X(SHARES).approve(PF, type(uint256).max);
        vm.deal(WHALE, 10 ether);

        uint256[4] memory sl = [uint256(54772255751000000000), 173205080757000000000, 547722557505000000000, 1224744871392000000000];
        uint256[4] memory sh = [uint256(54772255750517000000000), 17320508075689000000000, 5477225575052000000000, 2449489742783000000000];
        uint256[4] memory sp = [uint256(1732050807569119182848), 1732050807568934633472, 1732050807568810901504, 1732050807569038442496];
        string[4] memory nm = ["1000x", "100x", "10x", "2x"];

        address pool;
        for (uint256 i; i < 4; ++i) {
            vm.prank(WHALE);
            (bool ok, bytes memory ret) = PF.call{value: a0}(_seed(sl[i], sh[i], sp[i], a0, a1, WHALE));
            console.log(string.concat(nm[i], " accepted:"), ok);
            if (ok) { pool = abi.decode(ret, (address)); console.log("  pool:", pool); break; }
        }
        assertTrue(pool != address(0), "factory refused every band");
        assertGt(pool.code.length, 0, "pool has no code");
        console.log("pool ETH   :", pool.balance);
        console.log("pool shares:", IERC20X(SHARES).balanceOf(pool) / 1e18);
    }
}
