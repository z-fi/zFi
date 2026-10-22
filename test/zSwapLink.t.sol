// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {zSwap} from "../src/zSwap.sol";
import {zSwapLink} from "../src/zSwapLink.sol";
import {zSwapResolver, IzSwap} from "../src/utils/zSwapResolver.sol";

/// @notice The live successor of zSwap v0.2: a zSwapLink created by the DAO's
///         `deployNext`, serving the v0.3 root's page. Checked against mainnet.
contract zSwapLinkTest is Test {
    address constant TIP = 0xe686952842627A2cf81DF42CCaD54ef98046DB8D;
    address constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;
    address constant PAGE = 0x0a0Be4271Ca53f0002800a323Dee65A6B31CD507;
    address constant RESOLVER = 0x000000E7DAD6128683D1fb415e80B30c23dAb7AC;
    bytes32 constant SALT = 0x8b739954ec03c429e78265832194cc992a2aeee89def0a240000000000b7609e;
    address constant NEXT = 0x000000791BE31E1F70f2FFA9d32eE3C7bb6E8ba9;
    /// keccak256 of the calldata the DAO executed on v0.2.
    bytes32 constant PROPOSAL_DATA_HASH = 0x936d14c46b9d0be886f66f56da9a486c812baed233ec1cae800553b8111fe039;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum.publicnode.com")));
    }

    function _initcode() internal pure returns (bytes memory) {
        return bytes.concat(type(zSwapLink).creationCode, abi.encode(DAO, TIP, PAGE));
    }

    /// This source, compiled here, is what the DAO deployed: the CREATE2
    /// address of its initcode under the proposal's salt is the live link.
    function test_sourceIsTheDeployedLink() public view {
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), TIP, SALT, keccak256(_initcode())));
        assertEq(address(uint160(uint256(h))), NEXT);
        assertGt(NEXT.code.length, 0);
        assertEq(keccak256(abi.encodeCall(zSwap.deployNext, (_initcode(), SALT))), PROPOSAL_DATA_HASH);
        assertLt(abi.encodeCall(zSwap.deployNext, (_initcode(), SALT)).length, 2_400);
    }

    function test_lineage() public view {
        assertEq(zSwap(TIP).successor(), NEXT);
        assertEq(zSwapLink(NEXT).PREVIOUS(), TIP);
        assertEq(zSwapLink(NEXT).DAO(), DAO);
        assertEq(zSwapLink(NEXT).PAGE(), PAGE);
        assertEq(zSwapLink(NEXT).generation(), zSwap(TIP).generation() + 1);
        assertEq(zSwap(TIP).latest(), zSwapLink(NEXT).latest());
    }

    function test_servesTheV03Page() public view {
        bytes32 page = keccak256(vm.readFileBinary("zSwap.html"));
        assertEq(keccak256(bytes(zSwap(NEXT).html())), page);
        (uint16 code, string memory body, zSwap.KeyValue[] memory h) =
            zSwap(NEXT).request(new string[](0), new zSwap.KeyValue[](0));
        assertEq(code, 200);
        assertEq(keccak256(bytes(body)), page);
        assertEq(h[0].value, "text/html");
        assertEq(zSwap(NEXT).resolveMode(), bytes32("5219"));
        assertEq(zSwap(NEXT).VERSION(), "0.3");
    }

    /// The resolver follows the lineage on its own once a version has stood
    /// for its maturity window.
    function test_resolverServesTheLatestPage() public view {
        address cur = zSwapResolver(RESOLVER).current();
        assertEq(cur, zSwap(TIP).latest());
        if (cur == NEXT) assertEq(keccak256(bytes(zSwapResolver(RESOLVER).html())), keccak256(vm.readFileBinary("zSwap.html")));
    }

    /// The smallest gas cap each top-level eth_call succeeds under, found by
    /// bisection; every probe's answer is checked against the page.
    function _minGas(address to, bytes memory cd, bytes32 want, bool decode) internal returns (uint256 lo) {
        uint256 hi = 60_000_000;
        lo = 1_000_000;
        while (hi - lo > 10_000) {
            uint256 mid = (lo + hi) / 2;
            bool ok;
            assembly ("memory-safe") {
                let buf := mload(0x40)
                ok := staticcall(mid, to, add(cd, 0x20), mload(cd), 0, 0)
                if and(ok, decode) {
                    returndatacopy(buf, 0, returndatasize())
                    ok := eq(keccak256(add(buf, 0x40), mload(add(buf, 0x20))), want)
                }
            }
            if (ok) hi = mid;
            else lo = mid;
        }
        lo = hi;
    }

    function test_gasCapsForEachEntryPoint() public {
        bytes32 want = keccak256(vm.readFileBinary("zSwap.html"));
        bytes memory h = abi.encodeWithSignature("html()");
        bytes memory q = abi.encodeCall(zSwap.request, (new string[](0), new zSwap.KeyValue[](0)));
        uint256 a = _minGas(PAGE, h, want, true);
        uint256 b = _minGas(NEXT, h, want, true);
        uint256 c = _minGas(RESOLVER, h, want, true);
        uint256 d = _minGas(NEXT, q, 0, false);
        emit log_named_uint("root html()", a);
        emit log_named_uint("link html()", b);
        emit log_named_uint("resolver html()", c);
        emit log_named_uint("link request()", d);
        assertLt(c, 30_000_000);
        assertLt(d, 30_000_000);
    }

    function test_successorOfTheLinkStillWorks() public {
        vm.skip(zSwapLink(NEXT).successor() != address(0));
        bytes memory init2 = bytes.concat(type(zSwapLink).creationCode, abi.encode(DAO, NEXT, PAGE));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(zSwapLink.NotDAO.selector);
        zSwapLink(NEXT).deployNext(init2, bytes32(0));
        vm.prank(DAO);
        address after2 = zSwapLink(NEXT).deployNext(init2, bytes32(0));
        assertEq(zSwap(TIP).latest(), after2);
        vm.prank(DAO);
        vm.expectRevert(zSwapLink.AlreadySucceeded.selector);
        zSwapLink(NEXT).deployNext(init2, bytes32(uint256(1)));
    }

    function test_constructorRefusesAForgedPrevious() public {
        vm.expectRevert(zSwapLink.InvalidData.selector);
        new zSwapLink(DAO, TIP, PAGE);
    }

    function test_valueIsRefused() public {
        vm.deal(address(this), 1);
        (bool ok,) = NEXT.call{value: 1}(abi.encodeWithSignature("html()"));
        assertFalse(ok);
    }
}
