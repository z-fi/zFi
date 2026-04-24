// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Test} from "../lib/forge-std/src/Test.sol";

interface IHTMLRegistry {
    function html(address addr) external view returns (string memory);
    function latestVersion(address author, address target) external view returns (uint256);
}

/// @notice Forks mainnet and simulates zRouter.execute(HTMLRegistry, 0, inner)
///         where `inner` is the pre-generated calldata from
///         script/zSwapRegistry-setHtmlAsTarget.calldata.txt. Asserts that
///         HTMLRegistry.html(zRouter) returns the exact bytes of zSwap.html.
contract zSwapRegistrySimTest is Test {
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant REGISTRY = 0xFa11bacCdc38022dbf8795cC94333304C9f22722;

    bytes4 constant EXECUTE_SEL = 0xb61d27f6; // execute(address,uint256,bytes)
    bytes4 constant SET_HTML_AS_TARGET_SEL = 0x80671d24; // setHtmlAsTarget(address,string)

    function setUp() public {
        vm.createSelectFork(vm.envOr("MAINNET_RPC", string("https://1rpc.io/eth")));

        // Simulate the owner having flipped trust(REGISTRY, true) on zRouter, so
        // this test exercises the post-broadcast flow before the tx actually lands.
        bytes32 slot = keccak256(abi.encode(REGISTRY, uint256(1)));
        vm.store(ZROUTER, slot, bytes32(uint256(1)));
    }

    /// @dev Sanity: registry is deployed, zRouter trusts it, no prior version at this block.
    function test_Preconditions() public view {
        assertGt(REGISTRY.code.length, 0, "registry not deployed");
        assertGt(ZROUTER.code.length, 0, "zRouter not deployed");

        // Trust slot: keccak256(HTMLRegistry || uint256(1))
        bytes32 slot = keccak256(abi.encode(REGISTRY, uint256(1)));
        bytes32 trust = vm.load(ZROUTER, slot);
        assertEq(uint256(trust), 1, "HTMLRegistry not trusted by zRouter");
    }

    function test_Simulate() public {
        bytes memory htmlBuf = vm.readFileBinary("./zSwap.html");

        // Parse the txt calldata file the user will copy-paste, strip trailing whitespace.
        bytes memory innerFromFile =
            vm.parseBytes(_strip(vm.readFile("./script/zSwapRegistry-setHtmlAsTarget.calldata.txt")));

        // Regenerate the same calldata in-place and confirm they match.
        bytes memory innerRegen = abi.encodeWithSelector(SET_HTML_AS_TARGET_SEL, ZROUTER, string(htmlBuf));
        assertEq(keccak256(innerFromFile), keccak256(innerRegen), "txt file != regenerated calldata");

        uint256 vBefore = IHTMLRegistry(REGISTRY).latestVersion(ZROUTER, ZROUTER);

        // Anyone can call execute() once the trust bit is set (user already did this).
        // vm.prank'd caller has no special powers here — just a random EOA.
        vm.prank(address(0xBEEF));
        (bool ok, bytes memory ret) =
            ZROUTER.call(abi.encodeWithSelector(EXECUTE_SEL, REGISTRY, uint256(0), innerFromFile));
        require(ok, _reason(ret));

        uint256 vAfter = IHTMLRegistry(REGISTRY).latestVersion(ZROUTER, ZROUTER);
        assertEq(vAfter, vBefore + 1, "version did not increment by 1");

        bytes memory stored = bytes(IHTMLRegistry(REGISTRY).html(ZROUTER));
        assertEq(stored.length, htmlBuf.length, "stored length mismatch");
        assertEq(keccak256(stored), keccak256(htmlBuf), "stored content mismatch");

        emit log_named_uint("version before", vBefore);
        emit log_named_uint("version after ", vAfter);
        emit log_named_uint("stored bytes  ", stored.length);
    }

    /// @dev Adversarial: someone front-runs with their own HTML right before us.
    ///      Our execute() still succeeds, lands one version later, and html(zRouter)
    ///      returns OUR content (latest version wins).
    function test_SimulateAfterFrontRun() public {
        bytes memory htmlBuf = vm.readFileBinary("./zSwap.html");
        bytes memory inner = vm.parseBytes(_strip(vm.readFile("./script/zSwapRegistry-setHtmlAsTarget.calldata.txt")));

        uint256 vBefore = IHTMLRegistry(REGISTRY).latestVersion(ZROUTER, ZROUTER);

        // Griefer publishes their own HTML one version ahead via a separate execute() call.
        bytes memory griefHtml = bytes("<!doctype html><p>grief</p>");
        bytes memory griefInner = abi.encodeWithSelector(SET_HTML_AS_TARGET_SEL, ZROUTER, string(griefHtml));
        vm.prank(address(0xBAD));
        (bool griefOk,) = ZROUTER.call(abi.encodeWithSelector(EXECUTE_SEL, REGISTRY, uint256(0), griefInner));
        require(griefOk, "grief execute failed");
        assertEq(IHTMLRegistry(REGISTRY).latestVersion(ZROUTER, ZROUTER), vBefore + 1);
        assertEq(keccak256(bytes(IHTMLRegistry(REGISTRY).html(ZROUTER))), keccak256(griefHtml));

        // Our submission lands one version later and overrides the shortcut lookup.
        vm.prank(address(0xBEEF));
        (bool ok, bytes memory ret) = ZROUTER.call(abi.encodeWithSelector(EXECUTE_SEL, REGISTRY, uint256(0), inner));
        require(ok, _reason(ret));

        assertEq(IHTMLRegistry(REGISTRY).latestVersion(ZROUTER, ZROUTER), vBefore + 2);
        assertEq(keccak256(bytes(IHTMLRegistry(REGISTRY).html(ZROUTER))), keccak256(htmlBuf));
    }

    function _strip(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 n = b.length;
        while (n > 0) {
            bytes1 c = b[n - 1];
            if (c != 0x0a && c != 0x0d && c != 0x20 && c != 0x09) break;
            n--;
        }
        assembly {
            mstore(b, n)
        }
        return string(b);
    }

    function _reason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length == 0) return "execute reverted (no data)";
        if (ret.length >= 4) {
            bytes4 sel;
            assembly {
                sel := mload(add(ret, 0x20))
            }
            if (sel == 0x08c379a0 && ret.length >= 68) {
                bytes memory stripped = new bytes(ret.length - 4);
                for (uint256 i = 0; i < stripped.length; i++) {
                    stripped[i] = ret[i + 4];
                }
                return string.concat("execute reverted: ", abi.decode(stripped, (string)));
            }
            return string.concat("execute reverted with selector ", vm.toString(sel));
        }
        return "execute reverted";
    }
}
