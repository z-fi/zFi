// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {Test} from "../lib/forge-std/src/Test.sol";
import {Base64} from "../lib/solady/src/utils/Base64.sol";
import {LibString} from "../lib/solady/src/utils/LibString.sol";
import {ZorgConviction, IERC721Zorgz, IWeiNames, ITokenListView} from "../src/dao/ZorgConviction.sol";
import {ZorgConvictionRenderer} from "../src/dao/ZorgConvictionRenderer.sol";
import {ZorgPageStyle} from "../src/dao/ZorgPageStyle.sol";
import {ZorgReceiptArt} from "../src/dao/ZorgReceiptArt.sol";
import {ZorgTokenListLens, IConvictionScores, ITokenListSource} from "../src/dao/ZorgTokenListLens.sol";

interface IERC721ReceiverMock {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

contract MockShares {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address account, uint256 amount) external {
        balanceOf[account] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[from][msg.sender];
        if (permitted != type(uint256).max) allowance[from][msg.sender] = permitted - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockNFT is IERC721Zorgz {
    mapping(uint256 => address) internal _owner;
    mapping(uint256 => string) internal _uri;
    mapping(uint256 => string) internal _rawTokenURI;
    mapping(uint256 => address) public approved;

    function mint(address owner_, uint256 id, string calldata imageUri) external {
        _owner[id] = owner_;
        _uri[id] = imageUri;
    }

    function ownerOf(uint256 id) public view returns (address) {
        require(_owner[id] != address(0), "missing");
        return _owner[id];
    }

    function tokenURI(uint256 id) external view returns (string memory) {
        if (bytes(_rawTokenURI[id]).length != 0) return _rawTokenURI[id];
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(string.concat('{"name":"zOrgz #', _toString(id), '","image":"', _uri[id], '"}')))
        );
    }

    function setRawTokenURI(uint256 id, string calldata uri) external {
        _rawTokenURI[id] = uri;
    }

    function approve(address to, uint256 id) external {
        require(_owner[id] == msg.sender, "owner");
        approved[id] = to;
    }

    function transfer(address to, uint256 id) external {
        require(_owner[id] == msg.sender, "owner");
        _owner[id] = to;
        delete approved[id];
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        require(_owner[id] == from && (msg.sender == from || approved[id] == msg.sender), "auth");
        _owner[id] = to;
        delete approved[id];
        if (to.code.length != 0) {
            require(
                IERC721ReceiverMock(to).onERC721Received(msg.sender, from, id, "")
                    == IERC721ReceiverMock.onERC721Received.selector,
                "receiver"
            );
        }
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 length;
        for (uint256 v = value; v != 0; v /= 10) {
            ++length;
        }
        bytes memory out = new bytes(length);
        while (value != 0) {
            out[--length] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(out);
    }
}

contract MockWeiNames is IWeiNames {
    mapping(uint256 => address) internal _owner;
    mapping(uint256 => address) public resolved;
    mapping(address => uint256) public primary;
    mapping(uint256 => string) internal _name;
    mapping(uint256 => address) public approved;

    function computeId(string memory fullName) public pure returns (uint256) {
        return uint256(keccak256(bytes(fullName)));
    }

    function mint(address to, string calldata fullName) external returns (uint256 id) {
        id = computeId(fullName);
        _owner[id] = to;
        _name[id] = fullName;
    }

    function getFullName(uint256 id) external view returns (string memory) {
        return _name[id];
    }

    function ownerOf(uint256 id) public view returns (address) {
        require(_owner[id] != address(0), "missing");
        return _owner[id];
    }

    function approve(address to, uint256 id) external {
        require(_owner[id] == msg.sender, "owner");
        approved[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) external {
        require(_owner[id] == from && (msg.sender == from || approved[id] == msg.sender), "auth");
        _owner[id] = to;
        delete approved[id];
    }

    function setAddr(uint256 id, address addr_) external {
        require(_owner[id] == msg.sender, "owner");
        resolved[id] = addr_;
    }

    function setPrimaryName(uint256 id) external {
        require(_owner[id] == msg.sender, "owner");
        primary[msg.sender] = id;
    }

    function registerSubdomainFor(string calldata label, uint256 parentId, address to) external returns (uint256 id) {
        require(_owner[parentId] == msg.sender, "parent");
        id = computeId(string.concat(label, ".", _name[parentId]));
        require(_owner[id] == address(0), "exists");
        _owner[id] = to;
        _name[id] = string.concat(label, ".", _name[parentId]);
    }
}

contract MockCallTarget {
    uint256 public value;

    function set(uint256 value_) external payable {
        value = value_;
    }
}

contract MockTokenList is ITokenListView, ITokenListSource {
    mapping(uint256 => bool) public listed;
    uint256[] internal _ids;
    mapping(uint256 => ITokenListSource.Token) internal _token;

    function setListed(uint256 id, bool isListed_) external {
        if (isListed_ && !listed[id]) {
            _ids.push(id);
            _token[id] = ITokenListSource.Token({
                account: bytes32(id),
                chainId: 1,
                decimals: 18,
                kind: 0,
                standard: 2,
                deployed: true,
                onchainSvg: false,
                synced: true,
                color: 0,
                rank: 0,
                frozen: false,
                name: "Mock Token",
                symbol: "MOCK",
                logo: "",
                url: "",
                audit: "",
                description: ""
            });
        }
        listed[id] = isListed_;
    }

    function isListed(uint256 id) external view override(ITokenListView, ITokenListSource) returns (bool) {
        return listed[id];
    }

    function rankedIds() external view returns (uint256[] memory) {
        return _ids;
    }

    function get(uint256 id) external view returns (ITokenListSource.Token memory) {
        return _token[id];
    }

    function tokenURI(uint256) external pure returns (string memory) {
        return "data:application/json;base64,e30=";
    }

    function json(uint256) external pure returns (string memory) {
        return '{"n":"Mock Token","s":"MOCK"}';
    }
}

contract ZorgConvictionTest is Test {
    address dao = address(0xDA0);
    address domainOwner = address(0xD0A1);
    address proposer = address(0xB0B);
    address exec = address(0xE11C);
    address nextHolder = address(0xE12C);

    MockShares shares;
    MockNFT zorgz;
    MockWeiNames names;
    MockTokenList tokenList;
    ZorgConvictionRenderer renderer;
    ZorgConviction conviction;

    uint64 constant HALF_LIFE = 7 days;
    uint256 constant ETH_BOND = 0.1 ether;

    function setUp() public {
        shares = new MockShares();
        zorgz = new MockNFT();
        names = new MockWeiNames();
        tokenList = new MockTokenList();
        renderer = new ZorgConvictionRenderer(new ZorgPageStyle());
        names.mint(domainOwner, "zorg.wei");
        zorgz.mint(proposer, 77, "data:image/svg+xml;base64,PHN2Zy8+");
        shares.mint(proposer, 100 ether);
        vm.deal(proposer, 10 ether);
        vm.deal(nextHolder, 10 ether);
        tokenList.setListed(456, true);
        tokenList.setListed(123, true);
        conviction = new ZorgConviction(dao, address(shares), zorgz, names, address(tokenList), renderer, new ZorgReceiptArt(), HALF_LIFE);
    }

    function _approveAndBond(uint256 amount) internal {
        vm.startPrank(proposer);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), 77);
        conviction.bondZorgz{value: ETH_BOND}(77, amount);
        vm.stopPrank();
    }

    function _approveAndBond(uint256 amount, uint8 tier) internal {
        vm.startPrank(proposer);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), 77);
        conviction.bondZorgz{value: ETH_BOND}(77, amount, tier);
        vm.stopPrank();
    }

    function _claimAndInstallExec() internal {
        uint256 root = conviction.zorgWeiId();
        vm.prank(domainOwner);
        names.approve(address(conviction), root);
        vm.prank(domainOwner);
        conviction.claimZorgWei();
        vm.prank(dao);
        conviction.installExecRoleName(exec);
    }

    function testClaimsPreApprovedZorgWeiAndMintsExecCredential() public {
        _claimAndInstallExec();
        uint256 root = conviction.zorgWeiId();
        assertEq(names.ownerOf(root), address(conviction));
        assertEq(names.resolved(root), dao);
        assertEq(names.primary(address(conviction)), root);
        assertEq(names.ownerOf(conviction.execZorgWeiId()), exec);
    }

    function testBondEscrowsBothAssetsAndMintsTransferableReceipt() public {
        _approveAndBond(100 ether);
        assertEq(shares.balanceOf(proposer), 0);
        assertEq(shares.balanceOf(address(conviction)), 100 ether);
        assertEq(zorgz.ownerOf(77), address(conviction));
        assertEq(conviction.ownerOf(77), proposer);
        assertEq(conviction.bondedWeight(77), 100 ether);
        assertEq(conviction.availableBondWeight(77), 100 ether);

        vm.prank(proposer);
        conviction.transferFrom(proposer, nextHolder, 77);
        assertEq(conviction.ownerOf(77), nextHolder);
        vm.prank(nextHolder);
        conviction.allocate(77, 123, 40 ether);
        assertEq(conviction.allocationOf(77, 123), 40 ether);
    }

    function testBondWeightIsSingleSpendAndConvictionAccrues() public {
        _approveAndBond(100 ether);
        vm.prank(proposer);
        conviction.allocate(77, 123, 60 ether);
        assertEq(conviction.availableBondWeight(77), 40 ether);

        vm.prank(proposer);
        conviction.allocate(77, 456, 40 ether);
        assertEq(conviction.availableBondWeight(77), 0);
        vm.prank(proposer);
        vm.expectRevert(ZorgConviction.AllocationExceeded.selector);
        conviction.allocate(77, 456, 41 ether);

        // Half the gap to the effective live weight is closed in one half-life.
        // `convictionOf` deliberately reports that earned component alone;
        // `supportOf`, which the lens ranks, also includes live allocation.
        vm.warp(block.timestamp + HALF_LIFE);
        assertApproxEqAbs(conviction.convictionOf(123), 30 ether, 0.001 ether);
    }

    function testReceiptHolderCanPileMoreSharesIntoTheSameBond() public {
        _approveAndBond(60 ether);
        assertEq(conviction.bondedWeight(77), 60 ether);
        assertEq(shares.balanceOf(proposer), 40 ether);

        vm.prank(proposer);
        conviction.increaseBond(77, 40 ether);
        assertEq(conviction.bondedWeight(77), 100 ether);
        assertEq(shares.balanceOf(address(conviction)), 100 ether);
    }

    function testTopUpResetsEthMaturityAndCannotClaimPastExitLoyalty() public {
        _approveAndBond(60 ether);
        zorgz.mint(nextHolder, 78, "data:image/svg+xml;base64,PHN2Zy8+");
        shares.mint(nextHolder, 100 ether);
        vm.startPrank(nextHolder);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), 78);
        conviction.bondZorgz{value: ETH_BOND}(78, 100 ether);
        conviction.unbond(78); // early: its tax is paid entirely to receipt #77
        vm.stopPrank();

        // 1 wei short by construction: `_distributeEarlyExitTax` truncates the
        // reward index and sweeps the remainder to the treasury rather than
        // leaving it unclaimable.
        assertApproxEqAbs(conviction.loyaltyOf(77), 0.01 ether, 1);
        skip(7 days);
        (uint256 returnedBefore, uint256 taxBefore,) = conviction.ethExitQuote(77);
        assertEq(returnedBefore, ETH_BOND);
        assertEq(taxBefore, 0);

        vm.prank(proposer);
        conviction.topUpZorg(77, 40 ether);
        // The pre-top-up reward is exact: the new 40 zOrg receives the current
        // index, rather than retroactively taking a share of #78's exit.
        assertApproxEqAbs(conviction.loyaltyOf(77), 0.01 ether, 1);
        (uint256 returnedAfter, uint256 taxAfter,) = conviction.ethExitQuote(77);
        assertEq(returnedAfter, 0.08 ether);
        assertEq(taxAfter, 0.02 ether);
    }

    function testEthPrincipalAndLoyaltyTravelWithTheReceipt() public {
        _approveAndBond(100 ether);
        zorgz.mint(nextHolder, 78, "data:image/svg+xml;base64,PHN2Zy8+");
        shares.mint(nextHolder, 100 ether);
        vm.startPrank(nextHolder);
        shares.approve(address(conviction), type(uint256).max);
        zorgz.approve(address(conviction), 78);
        conviction.bondZorgz{value: ETH_BOND}(78, 100 ether);
        conviction.unbond(78); // 0.02 ETH tax: half treasury, half loyalty
        vm.stopPrank();

        assertEq(conviction.treasuryEth(), 0.01 ether);
        assertEq(conviction.loyaltyOf(77), 0.01 ether);
        vm.prank(proposer);
        conviction.transferFrom(proposer, nextHolder, 77);
        skip(7 days);
        vm.prank(nextHolder);
        conviction.unbond(77);
        // 0.08 from #78's own early exit (0.1 principal less the 0.02 tax),
        // plus 0.1 principal and 0.01 loyalty from the receipt it was given.
        assertEq(conviction.ethCredits(nextHolder), 0.19 ether);
        assertEq(conviction.ethCredits(proposer), 0);

        uint256 before = nextHolder.balance;
        vm.prank(nextHolder);
        conviction.withdrawEthCredit(payable(nextHolder));
        assertEq(nextHolder.balance, before + 0.19 ether);
    }

    function testDaoExecuteCannotSpendEthBondLiabilities() public {
        _approveAndBond(100 ether);
        MockCallTarget target = new MockCallTarget();
        vm.prank(dao);
        vm.expectRevert(ZorgConviction.EthEscrowReduced.selector);
        conviction.execute(address(target), ETH_BOND, abi.encodeCall(MockCallTarget.set, (7)));
        assertEq(address(conviction).balance, ETH_BOND);
        assertEq(target.value(), 0);
    }

    function testEternalBondPermanentlyEscrowsAssetsAndGetsDynamicMark() public {
        string memory image = "data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciPjxyZWN0IHdpZHRoPSI2NCIgaGVpZ2h0PSI2NCIgZmlsbD0iIzAwMCIvPjxwYXRoIGQ9Ik0wIDBINjRWNjRIMHoiLz48L3N2Zz4=";
        zorgz.setRawTokenURI(77, string.concat("data:application/json;base64,", Base64.encode(bytes(string.concat('{"image":"', image, '"}')))));
        uint256 topUp = conviction.ETERNAL_MIN_ZORG() - 100 ether;
        shares.mint(proposer, topUp);
        _approveAndBond(100 ether);
        // Read the constant BEFORE pranking: an external call in the argument
        // list consumes `vm.prank`, so `topUpZorg` would arrive from this test
        // contract and revert Unauthorized.
        vm.prank(proposer);
        conviction.topUpZorg(77, topUp);
        vm.prank(proposer);
        conviction.eternalize(77);

        assertTrue(conviction.eternalBonds(77));
        assertEq(conviction.totalEthPrincipal(), 0);
        assertEq(conviction.treasuryEth(), ETH_BOND);
        (uint256 returnedPrincipal, uint256 tax,) = conviction.ethExitQuote(77);
        assertEq(returnedPrincipal, 0);
        assertEq(tax, 0);
        vm.prank(proposer);
        vm.expectRevert(ZorgConviction.PermanentBond.selector);
        conviction.unbond(77);

        string memory metadata = string(Base64.decode(_drop(conviction.tokenURI(77), 29)));
        assertTrue(_contains(metadata, '{"trait_type":"Commitment","value":"eternal"}'));
        string memory receiptSvg = string(Base64.decode(_drop(_jsonImage(metadata), 26)));
        uint256 imageAt = LibString.indexOf(receiptSvg, "data:image/svg+xml;base64,", 0);
        uint256 imageEnd = LibString.indexOf(receiptSvg, "'", imageAt);
        string memory sourceSvg = string(Base64.decode(LibString.slice(receiptSvg, imageAt + 26, imageEnd)));
        assertTrue(_contains(sourceSvg, "#264cb5"));
    }

    function testLensReordersExistingListByBondedSupport() public {
        ZorgTokenListLens lens = new ZorgTokenListLens(tokenList, IConvictionScores(address(conviction)));
        uint256[] memory base = tokenList.rankedIds();
        assertEq(base[0], 456);
        assertTrue(lens.summariesPaged(0, 1)[0].deployed);
        _approveAndBond(100 ether);
        vm.startPrank(proposer);
        conviction.allocate(77, 123, 60 ether);
        conviction.allocate(77, 456, 40 ether);
        vm.stopPrank();

        // Direct allocation is immediately meaningful to the canonical list;
        // conviction then rewards support that stays in place.
        assertEq(lens.rankedIds()[0], 123);

        vm.warp(block.timestamp + HALF_LIFE);
        uint256[] memory ranked = lens.rankedIds();
        assertEq(ranked[0], 123);
        assertEq(ranked[1], 456);
    }

    function testLockTierBoostsSupportAndTransfersWithTheReceipt() public {
        _approveAndBond(100 ether, 3);
        (uint64 exitDelay, uint64 unlockAt, uint16 boostBps, uint8 tier) = conviction.receiptLocks(77);
        assertEq(exitDelay, 365 days);
        assertEq(unlockAt, uint64(block.timestamp + 365 days));
        assertEq(boostBps, 15_000);
        assertEq(tier, 3);

        vm.prank(proposer);
        conviction.allocate(77, 123, 100 ether);
        (uint256 immediate, uint256 effectiveActive) = conviction.listingState(123);
        assertEq(immediate, 150 ether);
        assertEq(effectiveActive, 150 ether);
        assertEq(conviction.convictionOf(123), 0);

        skip(HALF_LIFE);
        assertApproxEqAbs(conviction.convictionOf(123), 75 ether, 0.001 ether);
        assertApproxEqAbs(conviction.supportOf(123), 225 ether, 0.001 ether);

        vm.prank(proposer);
        conviction.transferFrom(proposer, nextHolder, 77);
        vm.prank(nextHolder);
        conviction.allocate(77, 123, 0);
        vm.prank(nextHolder);
        vm.expectRevert(
            abi.encodeWithSelector(ZorgConviction.ReceiptLocked.selector, unlockAt)
        );
        conviction.unbond(77);

        skip(365 days);
        vm.prank(nextHolder);
        conviction.unbond(77);
        assertEq(shares.balanceOf(nextHolder), 100 ether);
        assertEq(zorgz.ownerOf(77), nextHolder);
    }

    function testExistingNoLockReceiptCanOptIntoOneTierBeforeAllocation() public {
        _approveAndBond(100 ether);
        vm.prank(proposer);
        conviction.selectLockTier(77, 2);
        (uint64 exitDelay, uint64 unlockAt, uint16 boostBps, uint8 tier) = conviction.receiptLocks(77);
        assertEq(exitDelay, 180 days);
        assertEq(unlockAt, uint64(block.timestamp + 180 days));
        assertEq(boostBps, 12_500);
        assertEq(tier, 2);

        vm.prank(proposer);
        conviction.allocate(77, 123, 1 ether);
        vm.prank(proposer);
        vm.expectRevert(ZorgConviction.BondHasActiveAllocations.selector);
        conviction.selectLockTier(77, 3);
    }

    function testMolochControlsFutureTierMenuButNotLiveReceiptTerms() public {
        _approveAndBond(100 ether, 1);
        (uint64 originalDelay,, uint16 originalBoost,) = conviction.receiptLocks(77);
        assertEq(originalDelay, 90 days);
        assertEq(originalBoost, 11_000);

        vm.prank(dao);
        conviction.setLockTier(1, 120 days, 12_000);
        (uint64 configuredDelay, uint16 configuredBoost) = conviction.lockTiers(1);
        assertEq(configuredDelay, 120 days);
        assertEq(configuredBoost, 12_000);

        (uint64 liveDelay,, uint16 liveBoost,) = conviction.receiptLocks(77);
        assertEq(liveDelay, originalDelay);
        assertEq(liveBoost, originalBoost);

        vm.prank(dao);
        vm.expectRevert(ZorgConviction.LockTierOutOfRange.selector);
        conviction.setLockTier(3, 366 days, 15_000);
        vm.prank(dao);
        vm.expectRevert(ZorgConviction.LockTierOutOfRange.selector);
        conviction.setLockTier(0, 90 days, 11_000);
    }

    function testOnlyReceiptHolderCanUnbondAfterClearingAllocations() public {
        _approveAndBond(100 ether);
        vm.prank(proposer);
        conviction.allocate(77, 123, 100 ether);
        vm.prank(proposer);
        vm.expectRevert(ZorgConviction.BondHasActiveAllocations.selector);
        conviction.unbond(77);

        vm.prank(proposer);
        conviction.allocate(77, 123, 0);
        vm.prank(proposer);
        conviction.unbond(77);
        assertEq(shares.balanceOf(proposer), 100 ether);
        assertEq(zorgz.ownerOf(77), proposer);
        vm.expectRevert();
        conviction.ownerOf(77);
    }

    function testReceiptTokenUriIsOnchainAndDescribesTheBond() public {
        _approveAndBond(100 ether);
        string memory uri = conviction.tokenURI(77);
        string memory json = string(Base64.decode(_drop(uri, 29)));
        assertTrue(_contains(json, "zOrgz Bond #77"));
        assertTrue(_contains(json, "Bonded zOrg"));
        assertTrue(_contains(json, "ETH principal"));
        assertTrue(_contains(json, "Support boost"));
        assertTrue(_contains(json, "10000 bps"));
        assertTrue(_contains(json, "Redeemable"));
        assertTrue(_contains(json, '"value":"yes"'));
        assertTrue(_contains(json, "data:image/svg+xml;base64,"));

        vm.prank(proposer);
        conviction.allocate(77, 123, 1 ether);
        json = string(Base64.decode(_drop(conviction.tokenURI(77), 29)));
        assertTrue(_contains(json, "clear allocations first"));
    }

    function testReceiptTokenUriHandlesWhitespaceAndUnsafeUnderlyingImage() public {
        _approveAndBond(100 ether);
        string memory image = "data:image/svg+xml;base64,PHN2Zy8+";
        string memory spaced = string.concat('{ "name" : "zOrgz #77", "image" : "', image, '" }');
        zorgz.setRawTokenURI(77, string.concat("data:application/json;base64,", Base64.encode(bytes(spaced))));

        string memory metadata = string(Base64.decode(_drop(conviction.tokenURI(77), 29)));
        string memory svg = string(Base64.decode(_drop(_jsonImage(metadata), 26)));
        assertTrue(_contains(svg, image));

        zorgz.setRawTokenURI(77, image);
        metadata = string(Base64.decode(_drop(conviction.tokenURI(77), 29)));
        svg = string(Base64.decode(_drop(_jsonImage(metadata), 26)));
        assertTrue(_contains(svg, image));

        string memory unsafe = '{"image":"https://example.invalid/not-svg.png"}';
        zorgz.setRawTokenURI(77, string.concat("data:application/json;base64,", Base64.encode(bytes(unsafe))));
        metadata = string(Base64.decode(_drop(conviction.tokenURI(77), 29)));
        svg = string(Base64.decode(_drop(_jsonImage(metadata), 26)));
        assertFalse(_contains(svg, "example.invalid"));
    }

    function testRoleNameTransferAndPausedExecRecovery() public {
        _claimAndInstallExec();
        uint256 execId = conviction.execZorgWeiId();
        vm.prank(exec);
        names.transferFrom(exec, nextHolder, execId);
        vm.prank(exec);
        vm.expectRevert(ZorgConviction.Unauthorized.selector);
        conviction.emergencyPause();
        vm.prank(nextHolder);
        conviction.emergencyPause();

        MockCallTarget target = new MockCallTarget();
        vm.prank(nextHolder);
        conviction.emergencyExecute(address(target), 0, abi.encodeCall(MockCallTarget.set, (12)));
        assertEq(target.value(), 12);
        vm.prank(dao);
        conviction.resume();
    }

    function testExecCannotMoveUserEscrowAssets() public {
        _approveAndBond(100 ether);
        _claimAndInstallExec();
        vm.prank(dao);
        vm.expectRevert(ZorgConviction.ProtectedAsset.selector);
        conviction.execute(address(shares), 0, abi.encodeCall(MockShares.transfer, (dao, 1 ether)));
        vm.prank(exec);
        conviction.emergencyPause();
        vm.prank(exec);
        vm.expectRevert(ZorgConviction.ProtectedAsset.selector);
        conviction.emergencyExecute(address(zorgz), 0, abi.encodeCall(MockNFT.transfer, (dao, 77)));
        assertEq(shares.balanceOf(address(conviction)), 100 ether);
        assertEq(zorgz.ownerOf(77), address(conviction));
    }

    function testRendererReturnsOnchainDashboard() public view {
        string memory page = conviction.html();
        assertGt(bytes(page).length, 4_000);
        assertTrue(_contains(page, "TokenList: 100% onchain token data"));

        // The registry is a public good: with no wallet and no bonded weight the
        // page must be a token list and nothing else. `ON` is that gate, and the
        // top-nine card grid that duplicated the list is gone.
        assertTrue(_contains(page, "ON=!!(A&&ME.w)"));
        // Status messages must not live in the receipt strip: routing them there
        // made any message - including one an unconnected visitor sees - reveal
        // an empty panel with a blank avatar tile.
        assertTrue(_contains(page, "say=m=>{$('msg').textContent=m}"));
        // Connecting answers "do you hold one?" before asking for an id, and an
        // empty wallet gets a link rather than a dead input. The collection URL
        // is derived from the governor's own zorgz address.
        assertTrue(_contains(page, "0x70a08231")); // balanceOf(address)
        assertTrue(_contains(page, "No zOrgz in this wallet"));
        assertTrue(_contains(page, 'opensea.io/assets/ethereum/"+ZA'));
        assertTrue(_contains(page, "peek=async"));
        // Rank is encoded as a share bar, not only as a number in a column.
        assertTrue(_contains(page, "--s:"));
        assertFalse(_contains(page, "class=card"));
        assertFalse(_contains(page, "Top nine"));

        // Rows open a record dialog, and an onchain-SVG registry hands the art
        // over rather than only painting it.
        assertTrue(_contains(page, "openToken("));
        assertTrue(_contains(page, "svgOf"));
        // `onchainSvg` is a per-token-id COLLECTION flag, false for every ERC-20.
        // Presenting it as "Onchain SVG" read as a claim about the logo - which
        // is stored onchain for nearly every listing - so an ERC-20 appeared to
        // deny art it has. The logo reports its own storage instead.
        assertTrue(_contains(page, "onchain SVG"));
        assertTrue(_contains(page, "Token art"));
        // Copying is a subtle inline SVG icon on the field it copies, not a row
        // of footer buttons four columns away from the value they act on.
        assertTrue(_contains(page, "class=ic"));
        assertTrue(_contains(page, "<svg width=12 height=12"));
        assertTrue(_contains(page, "Data URI"));
        assertFalse(_contains(page, "dl('Onchain SVG'"));
        assertTrue(_contains(page, "navigator.clipboard.writeText"));
        // `navigator.clipboard` rejects in an insecure context and is blocked by
        // permissions policy inside an iframe. Without a caught fallback the copy
        // buttons silently do nothing, so both the fallback and the failure
        // report are the property under test.
        assertTrue(_contains(page, "execCommand"));
        assertTrue(_contains(page, "'blocked'"));

        // A listing is an ERC-721 on the registry, so its marketplace page is
        // derived from the address the page was rendered with, never hardcoded.
        assertTrue(_contains(page, "opensea.io/assets/ethereum/"));
        assertFalse(_contains(page, "opensea.io/assets/ethereum/0x"));
        assertTrue(_contains(page, "bond zOrgz"));
        assertTrue(_contains(page, "approve zOrgz"));
        assertTrue(_contains(page, "approve zOrg"));
        assertTrue(_contains(page, "add zOrg"));
        assertTrue(_contains(page, "hard lock"));
        // The lock-tier menu is DAO-governed, so the page must read `lockTiers`
        // rather than describe the tiers in fixed copy that `setLockTier`
        // silently invalidates.
        assertTrue(_contains(page, "tierMenu"));
        assertTrue(_contains(page, "0x322ee5de")); // lockTiers(uint8)
        assertFalse(_contains(page, "90 days"));
        assertFalse(_contains(page, "1-3 hard commitment"));
        assertTrue(_contains(page, "earlier is taxed"));

        // Irreversible and state-invalid actions must be gated in the page, not
        // discovered by signing a doomed transaction.
        assertTrue(_contains(page, "Eternal bonds are never redeemable."));
        assertTrue(_contains(page, "Set every allocation to 0 first."));
        assertTrue(_contains(page, "Needs 10,000 zOrg."));
        assertTrue(_contains(page, "syncActions"));
        assertTrue(_contains(page, "eternalize"));
        assertTrue(_contains(page, "claim loyalty"));
        assertTrue(_contains(page, "redeem receipt"));
        assertTrue(_contains(page, "window.ethereum"));
        assertTrue(_contains(page, "eth_chainId"));
        assertFalse(_contains(page, "ethereum.publicnode.com"));

        // Allocation must stay an inline, pre-fillable field. Chained
        // `window.prompt` boxes cannot show the value being replaced and cannot
        // validate before signing, so their absence is the property under test,
        // not the presence of any particular button.
        assertFalse(_contains(page, "prompt("));
        assertTrue(_contains(page, "setWeight("));
        assertTrue(_contains(page, "<input id=a_"));
        assertTrue(_contains(page, "<dialog"));

        // An eth_call to an address with no code succeeds with empty
        // returndata. The governor's TokenList address is immutable, so a
        // misconfigured one is permanent and has to name itself rather than
        // failing as "Cannot convert 0x to a BigInt" inside a decoder.
        assertTrue(_contains(page, "No contract responded at"));

        // Every selector the page dispatches on is a pinned literal; a wrong
        // one is a silent no-op in a wallet.
        assertTrue(_contains(page, "0xdf7ca268")); // rankedIds()
        assertTrue(_contains(page, "0x1ba8024c")); // listingState(uint256)
        assertTrue(_contains(page, "0x1a0ffd57")); // allocate(uint256,uint256,uint256)
        assertTrue(_contains(page, "0xa86e18ca")); // bondZorgz(uint256,uint256,uint8)
        assertTrue(_contains(page, "0xe0fb17b2")); // bondedWeight(uint256)
        assertTrue(_contains(page, "0x53e45ba5")); // allocationOf(uint256,uint256)
    }

    function _drop(string memory value, uint256 start) internal pure returns (string memory) {
        bytes memory source = bytes(value);
        bytes memory out = new bytes(source.length - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = source[start + i];
        }
        return string(out);
    }

    function _jsonImage(string memory json) internal pure returns (string memory) {
        bytes memory source = bytes(json);
        bytes memory needle = bytes('"image":"');
        for (uint256 i; i + needle.length <= source.length; ++i) {
            bool match_ = true;
            for (uint256 j; j < needle.length; ++j) {
                if (source[i + j] != needle[j]) {
                    match_ = false;
                    break;
                }
            }
            if (!match_) continue;
            uint256 start = i + needle.length;
            for (uint256 end = start; end < source.length; ++end) {
                if (source[end] != '"') continue;
                bytes memory out = new bytes(end - start);
                for (uint256 k; k < out.length; ++k) {
                    out[k] = source[start + k];
                }
                return string(out);
            }
        }
        revert("missing image");
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || h.length < n.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool found = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
