// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {TokenList} from "../src/utils/TokenList.sol";
import {TokenListRenderer} from "../src/utils/TokenListRenderer.sol";

/// @notice Pre-deploy checks: the things that decide whether this contract can be
///         shipped at all, as opposed to whether its features behave.
contract TokenListDeployTest is Test {
    using LibString for string;

    address owner = address(0xA11CE);

    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    /// @dev The constructor writes four cards' worth of base64 logos to storage. If
    ///      that exceeds what one transaction may spend, the contract cannot be
    ///      deployed at all - which no amount of passing feature tests would reveal.
    ///
    ///      The ceiling is EIP-7825's PER-TRANSACTION gas cap of 16,777,216, NOT the
    ///      block gas limit. This assertion previously read 25,000,000 "comfortably
    ///      inside a 36M mainnet block", which stopped being the binding constraint
    ///      when the cap shipped: blocks now carry a 60M limit and no transaction in
    ///      them exceeds 2^24. Seeding the original eleven tokens cost ~24.4M here and
    ///      ~25.3M once deployment calldata is counted, so it was undeployable while
    ///      this test passed. The budget below leaves room for the ~0.6M of calldata
    ///      the deployment transaction adds on top of what `gasleft()` measures.
    ///      MEASURED PER TRANSACTION, because the cap is per transaction and the pair
    ///      ships as two of them: `deploy/TokenList.md` deploys the renderer first and
    ///      the registry second, through separate CREATE2 factory calls with their own
    ///      calldata files. Measuring the two together was strictly conservative — it
    ///      charged one budget for a deposit cost that is actually split — and it made
    ///      the registry's own headroom a function of how large the renderer happens
    ///      to be, which is exactly the coupling splitting them apart was meant to end.
    function testDeploymentFitsInATransaction() public {
        uint256 before = gasleft();
        TokenListRenderer renderer = new TokenListRenderer();
        uint256 rendererGas = before - gasleft();

        before = gasleft();
        new TokenList(owner, renderer);
        uint256 registryGas = before - gasleft();

        emit log_named_uint("renderer deploy gas", rendererGas);
        emit log_named_uint("registry deploy gas", registryGas);
        emit log_named_uint("combined", rendererGas + registryGas);
        // 16,777,216 cap less headroom for the tx calldata each one carries.
        assertLt(rendererGas, 15_000_000);
        assertLt(registryGas, 15_000_000);
    }

    /// @dev M-05. Every seed constant describes Ethereum mainnet: the addresses, the
    ///      art, the links, and the native asset's own "Ether" text. Seeding on code
    ///      presence alone meant an unrelated contract at USDC's address on another
    ///      chain inherited Circle's logo, link and rank, and the native card called
    ///      BNB and AVAX "Ether". The same bytecode must still deploy anywhere — it
    ///      just starts empty where the constants do not apply.
    function testSeedingIsMainnetOnly() public {
        vm.chainId(8453);
        TokenList list = new TokenList(owner, new TokenListRenderer());
        assertEq(list.total(), 0);
        assertFalse(list.isListed(0));
        assertEq(list.owner(), owner); // deployable and curatable, just not pre-seeded
    }

    /// @dev The same bytecode must deploy to a chain where none of the canonical
    ///      tokens exist, seeding ETH alone rather than reverting or listing blanks.
    function testDeploysToABareChain() public {
        address[3] memory canonical = [WETH, USDC, USDT];
        for (uint256 i; i < canonical.length; ++i) {
            vm.etch(canonical[i], "");
        }

        TokenList list = new TokenList(owner, new TokenListRenderer());
        assertEq(list.total(), 1);
        TokenList.Token memory eth = list.get(list.idOf(TokenList.Kind.EVM, uint64(block.chainid), bytes32(0)));
        assertEq(eth.symbol, "ETH");
        assertTrue(list.tokenURI(list.idAt(0)).startsWith("data:application/json;base64,"));
    }

    /// @dev An EOA must not be listable: it would read as verified-onchain with no
    ///      metadata behind it.
    function testCannotListACodelessAddress() public {
        TokenList list = new TokenList(owner, new TokenListRenderer());
        vm.startPrank(owner);
        vm.expectRevert(TokenList.BadInput.selector);
        list.list(address(0xDEAD), 0, 0, "", "", "");
        vm.expectRevert(TokenList.BadInput.selector);
        list.list(address(0), 0, 0, "", "", "");
        vm.stopPrank();
    }

    function testAdvertisesItsInterfaces() public {
        TokenList list = new TokenList(owner, new TokenListRenderer());
        assertTrue(list.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(list.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(list.supportsInterface(0x5b5e139f)); // ERC-721Metadata
        assertFalse(list.supportsInterface(0xdeadbeef));
    }

    function testOwnershipIsTransferable() public {
        TokenList list = new TokenList(owner, new TokenListRenderer());
        assertEq(list.owner(), owner);

        vm.prank(owner);
        list.transferOwnership(address(0xBEEF));
        assertEq(list.owner(), address(0xBEEF));

        // Resolve the id first: an external call inside the argument list would be
        // the call `expectRevert` latches onto, not the one under test.
        uint256 wethId = list.idOf(WETH);

        // The old owner loses curation rights immediately.
        vm.prank(owner);
        vm.expectRevert();
        list.setRank(wethId, 1);

        vm.prank(address(0xBEEF));
        list.setRank(wethId, 1);
        assertEq(list.get(wethId).rank, 1);
    }

    /// @dev Deploying with no owner would strand the list: the ETH card is minted to
    ///      the owner, and ERC-721 cannot mint to the zero address. Fail loudly.
    function testCannotDeployWithoutAnOwner() public {
        // The renderer is deployed FIRST and on its own line on purpose: as an inline
        // argument it becomes the "next call" that `expectRevert` binds to, that call
        // succeeds, and the test passes without ever proving the guard exists.
        TokenListRenderer r = new TokenListRenderer();
        vm.expectRevert(TokenList.BadInput.selector);
        new TokenList(address(0), r);
    }

    /// @dev A codeless renderer would not revert — a staticcall to one succeeds with
    ///      empty returndata — so every card would silently render as an empty string.
    function testCannotDeployWithoutARenderer() public {
        vm.expectRevert(TokenList.BadInput.selector);
        new TokenList(owner, TokenListRenderer(address(0)));
        vm.expectRevert(TokenList.BadInput.selector);
        new TokenList(owner, TokenListRenderer(address(0xDEAD)));
    }
}
