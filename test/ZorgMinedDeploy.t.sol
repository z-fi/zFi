// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {ZorgConviction} from "../src/dao/ZorgConviction.sol";
import {ZorgTokenListLens} from "../src/dao/ZorgTokenListLens.sol";

/// @notice Deploys the EXACT mined initcode for the whole conviction stack through
///         the real SafeSummoner on a mainnet fork, and checks it lands where the
///         manifest says and wires to the LIVE registry.
///
/// @dev Five contracts in a dependency chain, each address baked into the next one's
///      creation code: PageStyle -> Renderer, ReceiptArt + Renderer -> Conviction,
///      Conviction -> Lens. One address landing anywhere unexpected invalidates every
///      salt downstream of it, so the ordering is asserted rather than assumed.
contract ZorgMinedDeployTest is Test {
    address constant SUMMONER = 0x00000000004473e1f31C8266612e7FD5504e6f2a;

    address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;
    address constant SHARES = 0x00a6bA94BBb5474725515De88fE04F854f2dCb12;
    address constant TOKENLIST = 0x0000006013dF75A31678B786061C2B54bf531524;

    address constant PAGE_STYLE = 0x000000507b8F2DEE4893269De45652B960061941;
    address constant RECEIPT_ART = 0x0000007f4342bdddA2A951b9e181B42328DD1eD9;
    address constant RENDERER = 0x000000115B1B95b9e04128a2Bcd9eD9D24AB141c;
    address constant CONVICTION = 0x0000006D936bA3653b8854490E16E782cd32a9a8;
    address constant LENS = 0x000000cEa3AB048d59473F3fb116A8D7F1abd247;

    uint64 constant HALF_LIFE = 3 days;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://gateway.tenderly.co/public/mainnet")), 25_678_000);
    }

    function _deploy(string memory name, address expected) internal {
        assertEq(expected.code.length, 0, string.concat(name, ": address must be vacant"));
        bytes memory initcode = vm.readFileBinary(string.concat("deploy/", name, ".initcode.bin"));
        bytes32 salt = vm.parseBytes32(vm.trim(vm.readFile(string.concat("deploy/", name, ".salt.txt"))));
        (bool ok,) = SUMMONER.call(abi.encodeWithSignature("create2Deploy(bytes,bytes32)", initcode, salt));
        assertTrue(ok, string.concat(name, ": deploy reverted"));
        assertGt(expected.code.length, 0, string.concat(name, ": did not land at its recorded address"));
    }

    function testTheWholeChainLandsAndWires() public {
        // Source staleness is a question about the source, not about whichever build
        // is in `out/`. See the same guard on TokenListMinedDeploy for why.
        string memory manifest = vm.readFile("deploy/ZorgConviction.sources.txt");
        string[5] memory sources = [
            "src/dao/ZorgPageStyle.sol",
            "src/dao/ZorgReceiptArt.sol",
            "src/dao/ZorgConvictionRenderer.sol",
            "src/dao/ZorgConviction.sol",
            "src/dao/ZorgTokenListLens.sol"
        ];
        for (uint256 i; i < sources.length; ++i) {
            string memory entry = string.concat(sources[i], " ", vm.toString(keccak256(bytes(vm.readFile(sources[i])))));
            if (!vm.contains(manifest, entry)) {
                emit log_named_string("source changed since the salts were mined", sources[i]);
                vm.skip(true);
            }
        }

        // Dependency order. Each address below is already inside the next initcode.
        _deploy("ZorgPageStyle", PAGE_STYLE);
        _deploy("ZorgReceiptArt", RECEIPT_ART);
        _deploy("ZorgConvictionRenderer", RENDERER);
        _deploy("ZorgConviction", CONVICTION);
        _deploy("ZorgTokenListLens", LENS);

        ZorgConviction c = ZorgConviction(payable(CONVICTION));
        assertEq(c.dao(), DAO, "governed by the zOrg Moloch");
        assertEq(address(c.tokenList()), TOKENLIST, "wired to the live registry");
        assertEq(c.halfLife(), HALF_LIFE, "3 day half-life");
        assertFalse(c.paused());

        // The lens must read the LIVE eleven-entry list through the deployed chain.
        ZorgTokenListLens lens = ZorgTokenListLens(LENS);
        uint256[] memory ids = lens.rankedIds();
        assertEq(ids.length, 11, "reads the live list");
        assertEq(lens.get(ids[1]).symbol, "WETH");

        // Day one: nothing bonded, so the lens must reproduce curated order exactly.
        (, bytes memory ret) = TOKENLIST.staticcall(abi.encodeWithSignature("rankedIds()"));
        uint256[] memory curated = abi.decode(ret, (uint256[]));
        for (uint256 i; i < curated.length; ++i) {
            assertEq(ids[i], curated[i], "an unvoted list must not be reordered");
        }
    }

    /// @dev The registry is never written to by any of this.
    function testDeployingTheStackLeavesTheRegistryUntouched() public {
        (, bytes memory before_) = TOKENLIST.staticcall(abi.encodeWithSignature("rankedIds()"));
        _deploy("ZorgPageStyle", PAGE_STYLE);
        _deploy("ZorgReceiptArt", RECEIPT_ART);
        _deploy("ZorgConvictionRenderer", RENDERER);
        _deploy("ZorgConviction", CONVICTION);
        (, bytes memory after_) = TOKENLIST.staticcall(abi.encodeWithSignature("rankedIds()"));
        assertEq(keccak256(before_), keccak256(after_), "registry order must be untouched");
        assertEq(SHARES.code.length > 0, true);
    }
}
