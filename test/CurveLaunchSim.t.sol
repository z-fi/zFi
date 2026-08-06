// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "../lib/forge-std/src/Test.sol";

interface ICurveSale {
    struct CreatorFee {
        address recipient;
        uint16 buyBps;
        uint16 sellBps;
        bool onBuy;
        bool onSell;
    }

    function launch(
        address creator,
        string calldata name,
        string calldata symbol,
        string calldata uri,
        uint256 supply,
        bytes32 salt,
        uint256 cap,
        uint256 startPrice,
        uint256 endPrice,
        uint16 feeBps,
        uint256 graduationTarget,
        uint256 lpTokens,
        address lpRecipient,
        uint16 poolFeeBps,
        uint16 sniperFeeBps,
        uint16 sniperDuration,
        uint16 maxBuyBps,
        CreatorFee calldata creatorFee,
        uint40 vestCliff,
        uint40 vestDuration
    ) external returns (address);

    function buyExactIn(address token, uint256 minAmountOut, uint256 deadline) external payable;
    function sell(address token, uint256 amount, uint256 minProceeds, uint256 deadline) external;
    function graduable(address token) external view returns (bool);
    function graduate(address token) external returns (uint256);

    function curves(address token)
        external
        view
        returns (
            address creator,
            uint256 cap,
            uint256 sold,
            uint256 virtualReserve,
            uint256 startPrice,
            uint256 endPrice,
            uint16 feeBps,
            uint16 poolFeeBps,
            uint256 raisedETH,
            uint256 graduationTarget,
            uint256 lpTokens,
            address lpRecipient,
            bool graduated,
            bool seeded,
            uint16 sniperFeeBps,
            uint16 sniperDuration,
            uint16 maxBuyBps,
            uint40 launchTime
        );
}

interface IERC20Meta {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function approve(address, uint256) external returns (bool);
}

/// Mirrors exactly what dapp/modules/coin.js sends for a "coin" (curve) launch,
/// then walks the curve from first buy to graduation on a mainnet fork.
contract CurveLaunchSimTest is Test {
    ICurveSale constant SALE = ICurveSale(0x000000005d9b18764E12E5aeefD6dA73110F85eb);
    address constant TOKEN_IMPL = 0xC54843C7419B3B7813d4C1065dA7f88104cdb047;

    address creator = address(0xC0FFEE);
    address buyer = address(0xBEEF);

    function setUp() public {
        // Pinned to the repo's shared fork block so a launch simulated today and one
        // simulated next month agree. Override the endpoint with ETH_RPC_URL.
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://eth-mainnet.public.blastapi.io")), 25_640_000);
        vm.deal(creator, 100 ether);
        vm.deal(buyer, 100 ether);
    }

    function _launch(bytes32 salt) internal returns (address token) {
        vm.prank(creator);
        token = SALE.launch(
            creator,
            "Test Coin",
            "TEST",
            "ipfs://bafytest",
            1_000_000_000e18,
            salt,
            800_000_000e18,
            1666666667,
            26666666672,
            100,
            0,
            200_000_000e18,
            address(0),
            25,
            500,
            300,
            1000,
            ICurveSale.CreatorFee(creator, 5, 5, true, false),
            0,
            0
        );
    }

    /// The dapp predicts the token address client-side (CREATE2 over a PUSH0 clone)
    /// and mines a vanity salt against it. If the prediction drifts, the mining loop
    /// is silently useless and the "View Coin" link points at nothing.
    function test_dappCreate2PredictionMatches() public {
        bytes32 salt = keccak256("zfi-sim");
        bytes32 create2Salt = keccak256(abi.encode(creator, "Test Coin", "TEST", salt));
        bytes memory initCode = abi.encodePacked(
            hex"602d5f8160095f39f35f5f365f5f37365f73", TOKEN_IMPL, hex"5af43d5f5f3e6029573d5ffd5b3d5ff3"
        );
        address predicted = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(SALE), create2Salt, keccak256(initCode))))
            )
        );
        assertEq(_launch(salt), predicted, "dapp CREATE2 prediction diverged from the sale contract");
    }

    function test_launchMetadataAndSupply() public {
        address token = _launch(keccak256("meta"));
        assertEq(IERC20Meta(token).name(), "Test Coin");
        assertEq(IERC20Meta(token).symbol(), "TEST");
        assertEq(IERC20Meta(token).totalSupply(), 1_000_000_000e18);
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSignature("contractURI()"));
        assertTrue(ok, "token has no contractURI(); the dapp list reads metadata from it");
        assertEq(abi.decode(ret, (string)), "ipfs://bafytest");
    }

    function test_buySellRoundTrip() public {
        address token = _launch(keccak256("trade"));
        // Past the sniper window so the 5% sniper fee doesn't distort the round trip.
        vm.warp(block.timestamp + 301);

        uint256 preBuy = buyer.balance;
        vm.prank(buyer);
        SALE.buyExactIn{value: 1 ether}(token, 0, block.timestamp + 60);
        uint256 cost = preBuy - buyer.balance; // excess ETH is refunded by the sale
        uint256 out = IERC20Meta(token).balanceOf(buyer);
        assertGt(out, 0);
        emit log_named_uint("buy cost (wei)", cost);

        vm.prank(buyer);
        IERC20Meta(token).approve(address(SALE), out);
        uint256 ethBefore = buyer.balance;
        vm.prank(buyer);
        SALE.sell(token, out, 0, block.timestamp + 60);
        uint256 back = buyer.balance - ethBefore;
        emit log_named_uint("sell proceeds (wei)", back);
        // Fees mean you never get all of it back, but a round trip must not exceed the input.
        assertLt(back, cost, "sell returned more than the buy cost");
        assertGt(back, (cost * 90) / 100, "round trip lost more than 10% to fees");
    }

    /// maxBuyBps = 10% of the cap per buy, so graduation needs many buys.
    /// The dapp advertises "~5.33 ETH graduation" — check that against the contract.
    function test_graduation() public {
        address token = _launch(keccak256("grad"));
        vm.warp(block.timestamp + 301);
        vm.deal(buyer, 1000 ether);

        uint256 spent;
        for (uint256 i; i < 40; ++i) {
            (,,,,,,,,,,,, bool graduated,,,,,) = SALE.curves(token);
            if (graduated) break;
            vm.prank(buyer);
            try SALE.buyExactIn{value: 1 ether}(token, 0, block.timestamp + 60) {
                spent += 1 ether;
            } catch {
                break;
            }
        }
        (,, uint256 sold,,,,,, uint256 raised,,,, bool grad,,,,,) = SALE.curves(token);
        emit log_named_uint("sold", sold / 1e18);
        emit log_named_uint("raisedETH (wei)", raised);
        emit log_named_uint("spent (wei)", spent);
        emit log_named_string("graduated", grad ? "yes" : "no");
        assertTrue(grad, "curve never graduated within 40 x 1 ETH buys");
        assertEq(sold, 800_000_000e18, "graduated without selling the full 800M cap");
        // The launch panel tells creators "~5.33 ETH graduation". That number is
        // user-facing and derived from the hardcoded curve params, so pin it here
        // rather than leaving it to drift if the params are ever retuned.
        assertApproxEqRel(raised, 5.33 ether, 0.01e18, "graduation raise no longer matches the ~5.33 ETH the dapp advertises");
    }
}
