// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
import {Test} from "../lib/forge-std/src/Test.sol";
import {PrecisionLauncher, LaunchToken} from "../src/pools/PrecisionLauncher.sol";
import {PrecisionPoolFactory} from "../src/pools/PrecisionPoolFactory.sol";
import {PrecisionPool} from "../src/pools/PrecisionPool.sol";

contract BandProbe is Test {
    address constant FACTORY = 0x000000Eb27B557aB426d9E99cFd54EC455799e81;
    address constant TREASURY = 0x000000aA142133107c7D2664F900f80e28BbfFbd;
    PrecisionLauncher L;
    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_745_140);
        L = new PrecisionLauncher(PrecisionPoolFactory(payable(FACTORY)), TREASURY);
    }
    function test_shape() public {
        uint256 poolsBefore = PrecisionPoolFactory(payable(FACTORY)).poolCount();
        (address t, address p) = L.launch("C","C","",1_000_000_000e18, 0, 30 ether, address(0xC0FFEE));
        PrecisionPool pool = PrecisionPool(payable(p));

        emit log_named_uint("new pools created", PrecisionPoolFactory(payable(FACTORY)).poolCount() - poolsBefore);
        emit log_named_address("token0 (ether side)", pool.token0());
        emit log_named_address("token1", pool.token1());
        emit log_named_uint("pool ETH at open (wei)", p.balance);
        emit log_named_uint("pool token at open", LaunchToken(t).balanceOf(p) / 1e18);
        emit log_named_uint("reserve0 (ether)", pool.reserve0());
        emit log_named_uint("fee bps*100", pool.fee());

        uint256 sl = pool.sqrtPLow();
        uint256 sh = pool.sqrtPHigh();
        emit log_named_uint("sqrtPLow", sl);
        emit log_named_uint("sqrtPHigh", sh);
        // price ratio across the band = (sqrtHigh/sqrtLow)^2
        emit log_named_uint("sqrt ratio", sh / sl);
        emit log_named_uint("PRICE ratio across band", (sh / sl) * (sh / sl));
    }
}
