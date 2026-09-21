// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import "forge-std/Test.sol";

interface ISLOW {
    function gate() external view returns (address);
    function depositToWithTip(address token, address to, uint256 amount, uint96 delay, uint256 tip, bytes calldata data)
        external
        payable
        returns (uint256 transferId);
}

interface ISLOWGate {
    function claim(uint256 transferId) external;
}

interface IERC20Min {
    function approve(address, uint256) external returns (bool);
}

/// @dev What a keeper spends to settle a tipped SLOW transfer, on every chain zSwap
/// offers auto-claim on. The page sizes the tip as `TIP_GAS` times a gas price with
/// headroom, so `TIP_GAS` has to cover the WHOLE claim transaction - the 21,000 base
/// and the calldata as well as execution - for an ether transfer and a token one.
/// The value is read out of zSwap.html, so the page cannot drift from what this
/// measures. Every contract the claim touches is cooled first: a keeper's
/// transaction starts cold, and the deposit made here would otherwise warm it.
contract SlowTipGasTest is Test {
    ISLOW constant SLOW = ISLOW(0x000000006513B7821171C8447ec7ECdfa3b956Fd);
    address constant KEEPER = address(0xBEEF);
    address constant TO = address(0xB0B);
    // Base cost plus `claim(uint256)` calldata, every byte priced as nonzero.
    uint256 constant TX_OVERHEAD = 21_000 + 36 * 16;

    function testMainnet() public {
        _chain("ETH_RPC_URL", "https://ethereum-rpc.publicnode.com", 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    }

    function testBase() public {
        _chain("BASE_RPC_URL", "https://mainnet.base.org", 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    }

    function testRobinhood() public {
        _chain(
            "ROBINHOOD_RPC_URL", "https://rpc.mainnet.chain.robinhood.com", 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
        );
    }

    function _chain(string memory env, string memory rpc, address token) internal {
        vm.createSelectFork(vm.envOr(env, rpc));
        uint256 budget = _tipGas();
        uint256 ethGas = _claimGas(address(0));
        uint256 tokGas = _claimGas(token);
        console2.log("claim tx gas, ether then token:", ethGas, tokGas);
        assertLe(ethGas, budget, "TIP_GAS does not cover an ether claim");
        assertLe(tokGas, budget, "TIP_GAS does not cover a token claim");
    }

    function _claimGas(address token) internal returns (uint256) {
        uint256 tip = 1e12;
        uint256 id;
        if (token == address(0)) {
            vm.deal(address(this), 1 ether + tip);
            id = SLOW.depositToWithTip{value: 1 ether + tip}(address(0), TO, 1 ether, 1 hours, tip, "");
        } else {
            deal(token, address(this), 1000);
            IERC20Min(token).approve(address(SLOW), 1000);
            vm.deal(address(this), tip);
            id = SLOW.depositToWithTip{value: tip}(token, TO, 1000, 1 hours, tip, "");
        }
        vm.warp(block.timestamp + 1 hours + 1);

        address gate = SLOW.gate();
        vm.cool(address(SLOW));
        vm.cool(gate);
        vm.cool(TO);
        vm.cool(KEEPER);
        if (token != address(0)) vm.cool(token);

        vm.prank(KEEPER);
        uint256 g = gasleft();
        ISLOWGate(gate).claim(id);
        return g - gasleft() + TX_OVERHEAD;
    }

    function _tipGas() internal view returns (uint256) {
        string[] memory a = vm.split(vm.readFile("zSwap.html"), "const TIP_GAS=");
        require(a.length == 2, "zSwap.html must declare TIP_GAS once");
        return vm.parseUint(vm.split(a[1], "n;")[0]);
    }
}
