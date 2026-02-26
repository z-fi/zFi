// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title FundingWorksMinter - Collector DAO for FundingWorks S02
/// @notice One-tx deploy: creates a Moloch DAO via DAICO factory that crowdsales
///         ETH to mint FundingWorks S02 NFTs. This contract is both the DAICO tap
///         recipient and NFT vault. Unlimited shares, 10% of buys seed LP on
///         zAMM for a tradeable secondary market. Anyone can call mintFromTap()
///         to convert raised ETH into NFTs. Sale deadline read from FW on deploy.
///
///   Buyers --ETH--> DAICO.buy() --shares--> Buyers
///                       |
///                  10% to LP (zAMM)
///                       |
///                       v (instant tap, 90%)
///                  mintFromTap() --> FW.mint()
///                  (NFTs held here)
///                       |
///            +----------+----------+
///            v                     v
///       ragequit(ETH)     governance burnToDAO()

// -- DAICO structs --

struct Call {
    address target;
    uint256 value;
    bytes data;
}

struct SummonConfig {
    address summoner;
    address molochImpl;
    address sharesImpl;
    address lootImpl;
}

struct DAICOConfig {
    address tribTkn;
    uint256 tribAmt;
    uint256 saleSupply;
    uint256 forAmt;
    uint40 deadline;
    bool sellLoot;
    uint16 lpBps;
    uint16 maxSlipBps;
    uint256 feeOrHook;
}

struct TapConfig {
    address ops;
    uint128 ratePerSec;
    uint256 tapAllowance;
}

interface IDAICO {
    function summonDAICOWithTapCustom(
        SummonConfig calldata summonConfig,
        string calldata orgName,
        string calldata orgSymbol,
        string calldata orgURI,
        uint16 quorumBps,
        bool ragequittable,
        address renderer,
        bytes32 salt,
        address[] calldata initHolders,
        uint256[] calldata initShares,
        bool sharesLocked,
        bool lootLocked,
        DAICOConfig calldata daicoConfig,
        TapConfig calldata tapConfig,
        Call[] calldata customCalls
    ) external payable returns (address dao);

    function claimTap(address dao) external returns (uint256 claimed);
    function claimableTap(address dao) external view returns (uint256);
}

interface IFundingWorks {
    function mint(uint256 quantity) external payable returns (uint256[] memory tokenIds);
    function burn(uint256 tokenId) external;
    function MINT_PRICE() external view returns (uint256);
    function MINT_PERIOD() external view returns (uint256);
    function mintStartTime() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getRemainingLockedEth(uint256 tokenId) external view returns (uint256);
}

/// @title ShareBurner - Delegatecall target to burn unsold DAO shares
/// @notice Deployed by minter constructor. DAO executes via permit (delegatecall),
///         so address(this) == dao inside burnUnsold.
contract ShareBurner {
    function burnUnsold(address shares, address) external {
        uint256 bal = IERC20(shares).balanceOf(address(this));
        if (bal > 0) IShares(shares).burnFromMoloch(address(this), bal);
    }
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IShares {
    function burnFromMoloch(address from, uint256 amount) external;
}

interface IMoloch {
    function spendPermit(uint8 op, address to, uint256 value, bytes calldata data, bytes32 nonce) external;
}

contract FundingWorksMinter {
    /*//////////////////////////////////////////////////////////////
                           HARDCODED CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // FundingWorks S02
    address public constant FW = 0xb33d806a94B6770C9d309E0842a75f8E6edCd5A6;
    uint256 public constant MINT_PRICE = 1 ether;

    // DAICO factory + Moloch infrastructure
    address public constant DAICO = 0x000000000033e92DB97B4B3beCD2c255126C60aC;
    address public constant SUMMONER = 0x0000000000330B8df9E3bc5E553074DA58eE9138;
    address public constant MOLOCH_IMPL = 0x643A45B599D81be3f3A68F37EB3De55fF10673C1;
    address public constant SHARES_IMPL = 0x71E9b38d301b5A58cb998C1295045FE276Acf600;
    address public constant LOOT_IMPL = 0x6f1f2aF76a3aDD953277e9F369242697C87bc6A5;
    address public constant RENDERER = 0x000000000011C799980827F52d3137b4abD6E654;

    // Governance
    uint16 public constant QUORUM_BPS = 1500; // 15%
    uint64 public constant VOTING_SECS = 12 hours;
    uint64 public constant TIMELOCK_SECS = 12 hours;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable dao;
    address public immutable burner;
    address public immutable shares;
    uint256 public immutable deadline;
    bytes32 private immutable _permitNonce;

    uint256[] public nftIds;
    mapping(uint256 => uint256) internal _nftIdIndex; // tokenId => index+1

    bool private _locked;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotDAO();
    error NoFunds();
    error Reentrancy();
    error NothingToMint();
    error NotHeld();
    error SaleActive();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Swept(uint256 amount);
    event Minted(uint256[] tokenIds, uint256 ethSpent);
    event BurnedToDAO(uint256 tokenId, uint256 ethRecovered);
    event SaleClosed(uint256 sharesBurned);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyDAO() {
        if (msg.sender != dao) revert NotDAO();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    /*//////////////////////////////////////////////////////////////
                     CONSTRUCTOR - DEPLOYS THE DAO
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy the FW S02 collector DAO. Unlimited shares, 10% LP.
    ///         Sale deadline read from FW contract. Instant tap vesting.
    /// @param _orgName   DAO name
    /// @param _orgSymbol DAO token symbol
    /// @param _orgURI    DAO metadata URI
    /// @param _salt      CREATE2 salt
    constructor(
        string memory _orgName,
        string memory _orgSymbol,
        string memory _orgURI,
        bytes32 _salt
    ) {
        burner = address(new ShareBurner());
        dao = _deployDAO(_orgName, _orgSymbol, _orgURI, _salt);

        IFundingWorks fw = IFundingWorks(FW);
        deadline = fw.mintStartTime() + fw.MINT_PERIOD();
        _permitNonce = _salt;

        // Predict shares address: DAO deploys shares clone with salt = bytes32(bytes20(dao))
        shares = _predictClone(SHARES_IMPL, bytes32(bytes20(dao)), dao);
    }

    /*//////////////////////////////////////////////////////////////
                          MINT - PERMISSIONLESS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim DAICO tap and mint FW NFTs. Anyone can call.
    ///         As ETH accumulates from share purchases, this converts it to NFTs.
    /// @param quantity Number of NFTs (0 = auto-max from balance)
    function mintFromTap(uint256 quantity) external nonReentrant returns (uint256[] memory tokenIds) {
        IDAICO(DAICO).claimTap(dao);
        tokenIds = _mint(quantity);
    }

    /// @notice Mint from ETH already in this contract.
    function mintFromBalance(uint256 quantity) external nonReentrant returns (uint256[] memory tokenIds) {
        tokenIds = _mint(quantity);
    }

    /*//////////////////////////////////////////////////////////////
                       GOVERNANCE - BURN & SWEEP
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn FW NFT, recover locked ETH to DAO treasury.
    function burnToDAO(uint256 tokenId) external onlyDAO nonReentrant {
        if (IFundingWorks(FW).ownerOf(tokenId) != address(this)) revert NotHeld();

        uint256 balBefore = address(this).balance;
        IFundingWorks(FW).burn(tokenId);
        uint256 recovered = address(this).balance - balBefore;

        _removeNftId(tokenId);

        if (recovered > 0) _sendETH(dao, recovered);

        emit BurnedToDAO(tokenId, recovered);
    }

    /// @notice Sweep all ETH to DAO treasury.
    function sweep() external onlyDAO nonReentrant {
        uint256 bal = address(this).balance;
        if (bal == 0) revert NoFunds();
        _sendETH(dao, bal);
        emit Swept(bal);
    }

    /// @notice Generic execute for claiming airdrops, rescuing tokens, etc.
    function execute(address target, uint256 value, bytes calldata data)
        external onlyDAO nonReentrant returns (bytes memory)
    {
        (bool ok, bytes memory ret) = target.call{value: value}(data);
        require(ok);
        return ret;
    }

    /*//////////////////////////////////////////////////////////////
                     CLOSE SALE - BURN UNSOLD SHARES
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn unsold DAO shares after mint deadline. Permissionless, one-shot.
    ///         Uses Moloch permit (delegatecall to ShareBurner) set during init.
    function closeSale() external {
        if (block.timestamp <= deadline) revert SaleActive();
        uint256 bal = IERC20(shares).balanceOf(dao);
        bytes memory burnData = abi.encodeWithSignature(
            "burnUnsold(address,address)", shares, dao
        );
        IMoloch(dao).spendPermit(1, burner, 0, burnData, _permitNonce);
        emit SaleClosed(bal);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW
    //////////////////////////////////////////////////////////////*/

    function mintableFromTap() external view returns (uint256) {
        return (IDAICO(DAICO).claimableTap(dao) + address(this).balance) / MINT_PRICE;
    }

    function mintableFromBalance() external view returns (uint256) {
        return address(this).balance / MINT_PRICE;
    }

    function allNftIds() external view returns (uint256[] memory) { return nftIds; }
    function nftCount() external view returns (uint256) { return nftIds.length; }
    function holdsNft(uint256 tokenId) external view returns (bool) { return _nftIdIndex[tokenId] != 0; }

    function totalLockedEth() external view returns (uint256 total) {
        IFundingWorks fw = IFundingWorks(FW);
        for (uint256 i; i < nftIds.length; ++i) {
            total += fw.getRemainingLockedEth(nftIds[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _deployDAO(
        string memory _orgName,
        string memory _orgSymbol,
        string memory _orgURI,
        bytes32 _salt
    ) internal returns (address) {
        return IDAICO(DAICO).summonDAICOWithTapCustom(
            SummonConfig(SUMMONER, MOLOCH_IMPL, SHARES_IMPL, LOOT_IMPL),
            _orgName,
            _orgSymbol,
            _orgURI,
            QUORUM_BPS,
            true, // ragequittable
            RENDERER,
            _salt,
            new address[](0), // no init holders
            new uint256[](0), // no init shares
            false,
            false,
            _daicoConfig(),
            TapConfig({
                ops: address(this),
                ratePerSec: type(uint128).max,
                tapAllowance: type(uint256).max
            }),
            _govCalls(_salt)
        );
    }

    function _daicoConfig() internal view returns (DAICOConfig memory) {
        IFundingWorks fw = IFundingWorks(FW);
        return DAICOConfig({
            tribTkn: address(0),
            tribAmt: MINT_PRICE,
            saleSupply: 1_111_112 * 1e18, // 1/0.9 * 1M → 1 ETH to treasury after 10% LP
            forAmt: 1_000_000 * 1e18,
            deadline: uint40(fw.mintStartTime() + fw.MINT_PERIOD()),
            sellLoot: false,
            lpBps: 1000,
            maxSlipBps: 100,
            feeOrHook: 30 // 0.3% swap fee
        });
    }

    function _govCalls(bytes32 _salt) internal view returns (Call[] memory customCalls) {
        address predictedDAO = _predictClone(
            MOLOCH_IMPL,
            keccak256(abi.encode(new address[](0), new uint256[](0), _salt)),
            SUMMONER
        );
        address predictedShares = _predictClone(SHARES_IMPL, bytes32(bytes20(predictedDAO)), predictedDAO);

        bytes memory burnData = abi.encodeWithSignature(
            "burnUnsold(address,address)", predictedShares, predictedDAO
        );

        customCalls = new Call[](3);
        customCalls[0] = Call(predictedDAO, 0, abi.encodeWithSignature("setProposalTTL(uint64)", VOTING_SECS));
        customCalls[1] = Call(predictedDAO, 0, abi.encodeWithSignature("setTimelockDelay(uint64)", TIMELOCK_SECS));
        customCalls[2] = Call(
            predictedDAO,
            0,
            abi.encodeWithSignature(
                "setPermit(uint8,address,uint256,bytes,bytes32,address,uint256)",
                uint8(1),           // op = delegatecall
                burner,             // target = ShareBurner
                uint256(0),         // value = 0
                burnData,           // encoded burnUnsold call
                _salt,              // nonce
                address(this),      // spender = minter
                uint256(1)          // count = 1 (one-shot)
            )
        );
    }

    function _predictClone(address impl, bytes32 salt_, address deployer_) internal pure returns (address) {
        bytes memory code =
            abi.encodePacked(hex"602d5f8160095f39f35f5f365f5f37365f73", impl, hex"5af43d5f5f3e6029573d5ffd5b3d5ff3");
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer_, salt_, keccak256(code))))));
    }

    function _mint(uint256 quantity) internal returns (uint256[] memory tokenIds) {
        uint256 bal = address(this).balance;

        if (quantity == 0) quantity = bal / MINT_PRICE;
        if (quantity == 0) revert NothingToMint();
        if (bal < quantity * MINT_PRICE) revert NoFunds();

        tokenIds = IFundingWorks(FW).mint{value: quantity * MINT_PRICE}(quantity);

        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            nftIds.push(id);
            _nftIdIndex[id] = nftIds.length;
        }

        uint256 dust = address(this).balance;
        if (dust > 0) _sendETH(dao, dust);

        emit Minted(tokenIds, quantity * MINT_PRICE);
    }

    function _removeNftId(uint256 tokenId) internal {
        uint256 idx = _nftIdIndex[tokenId];
        if (idx == 0) return;
        idx--;
        uint256 last = nftIds.length - 1;
        if (idx != last) {
            uint256 moved = nftIds[last];
            nftIds[idx] = moved;
            _nftIdIndex[moved] = idx + 1;
        }
        nftIds.pop();
        delete _nftIdIndex[tokenId];
    }

    function _sendETH(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        require(ok);
    }

    /*//////////////////////////////////////////////////////////////
                             RECEIVE
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
