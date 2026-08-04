// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;
import "forge-std/Test.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";

contract InitcodeSizeTest is Test {
    /// @dev A deploy-time budget guard. The factory now carries the pool's
///      creation code as a CONSTRUCTOR ARGUMENT, so deploying the factory
///      through a CREATE2 factory makes that whole blob both the initcode and
///      the transaction calldata. EIP-3860 caps CREATE/CREATE2 initcode at 49152 bytes.
    uint256 constant MAX_INITCODE = 49152;
    uint256 constant MAX_RUNTIME = 24576;

    function test_SizeBudget() public {
        bytes memory poolCreation = type(PrecisionPool).creationCode;
        emit log_named_uint("pool creationCode", poolCreation.length);

        // Deploying the FACTORY through a CREATE2 factory means this whole blob
        // is the initcode, and also the calldata of the deploy transaction.
        bytes memory factoryInit =
            abi.encodePacked(type(PrecisionPoolFactory).creationCode, abi.encode(address(0xdead), poolCreation));
        emit log_named_uint("factory initcode (incl. pool code arg)", factoryInit.length);
        emit log_named_uint("EIP-3860 headroom", MAX_INITCODE - factoryInit.length);

        // SSTORE2 stores the pool code as contract code: 200 gas per byte.
        emit log_named_uint("SSTORE2 deploy gas for pool code", poolCreation.length * 200);
        // EIP-3860 initcode word charge.
        emit log_named_uint("EIP-3860 word charge", ((factoryInit.length + 31) / 32) * 2);
        // Calldata, all-nonzero worst case at 16 gas/byte.
        emit log_named_uint("calldata gas (worst case)", factoryInit.length * 16);

        bytes memory poolRuntime = vm.getDeployedCode("PrecisionPool.sol:PrecisionPool");
        emit log_named_uint("pool runtime", poolRuntime.length);
        emit log_named_uint("pool runtime headroom", MAX_RUNTIME - poolRuntime.length);

        assertLt(factoryInit.length, MAX_INITCODE, "factory initcode exceeds EIP-3860");
        assertLt(poolCreation.length, MAX_INITCODE, "pool initcode exceeds EIP-3860");
        assertLt(poolRuntime.length, MAX_RUNTIME, "pool runtime exceeds EIP-170");
    }

}
