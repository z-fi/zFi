// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {CollectorVault} from "./CollectorVault.sol";

/*//////////////////////////////////////////////////////////////
                      DAICO STRUCTS
//////////////////////////////////////////////////////////////*/

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

/*//////////////////////////////////////////////////////////////
                      INTERFACES
//////////////////////////////////////////////////////////////*/

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
}

interface ISummoner {
    function summon(
        string calldata orgName,
        string calldata orgSymbol,
        string calldata orgURI,
        uint16 quorumBps,
        bool ragequittable,
        address renderer,
        bytes32 salt,
        address[] calldata initHolders,
        uint256[] calldata initShares,
        Call[] calldata initCalls
    ) external payable returns (address dao);
}

interface IShares {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IMoloch {
    function setPermit(
        uint8 op,
        address to,
        uint256 value,
        bytes calldata data,
        bytes32 nonce,
        address spender,
        uint256 count
    ) external;
    function setAllowance(address who, address token, uint256 amount) external;
    function setProposalTTL(uint64 secs) external;
    function setTimelockDelay(uint64 secs) external;
}

interface IShareBurner {
    function burnUnsold(address shares, uint256 deadline) external payable;
}

/// @title CollectorVaultFactory
/// @notice Deploys CollectorVault clones with ShareBurner permit wiring for DAICO integration.
///
///   Usage (two calls, batchable via multicall):
///     1. factory.deploy(mp, salt, deadline) → vault (CREATE2 clone)
///     2. DAICO.summonDAICOWithTapCustom(..., tapConfig(vault), [..., factory.permitCall(...)])
///
///   Or use deployAndSummon() for opinionated single-tx atomic deploy with DAICO/bare DAO.
///   Or use deployAndSummonRaw() for custom calldata escape hatch.
contract CollectorVaultFactory {
    /*//////////////////////////////////////////////////////////////
                         INFRASTRUCTURE
    //////////////////////////////////////////////////////////////*/

    address public constant DAICO = 0x000000000033e92DB97B4B3beCD2c255126C60aC;
    address public constant SUMMONER = 0x0000000000330B8df9E3bc5E553074DA58eE9138;

    address public constant MOLOCH_IMPL = 0x643A45B599D81be3f3A68F37EB3De55fF10673C1;
    address public constant SHARES_IMPL = 0x71E9b38d301b5A58cb998C1295045FE276Acf600;
    address public constant LOOT_IMPL = 0x6f1f2aF76a3aDD953277e9F369242697C87bc6A5;
    address public constant RENDERER = 0x000000000011C799980827F52d3137b4abD6E654;
    address public constant BURNER = 0x000000000040084694F7B6fb2846D067B4c3Aa9f;

    /*//////////////////////////////////////////////////////////////
                              STATE
    //////////////////////////////////////////////////////////////*/

    address public immutable vaultImpl;

    /*//////////////////////////////////////////////////////////////
                             EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deployed(address indexed dao, address indexed vault, uint8 mode);

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() payable {
        vaultImpl = address(new CollectorVault());
    }

    /*//////////////////////////////////////////////////////////////
                              STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct VaultParams {
        uint8 mode;
        address target;
        uint256 ethPerCall;
        uint256 maxCalls;
        bytes payload;
        address token;
        uint256 minBalance;
        bool specificId;
    }

    struct DAICOParams {
        // Sale economics
        address tribTkn; // address(0) for ETH
        uint256 tribAmt; // price per share unit
        uint256 saleSupply; // total shares for sale
        uint256 forAmt; // shares per tribAmt
        uint40 deadline; // sale deadline
        bool sellLoot;
        uint16 lpBps; // >0 = DAICO sale + LP, 0 = allowance-based vault sale
        uint16 maxSlipBps;
        uint256 feeOrHook;
        // Tap (ignored when lpBps == 0)
        uint128 ratePerSec;
        uint256 tapAllowance;
        // Governance
        uint16 quorumBps;
        uint64 votingSecs; // 0 = skip
        uint64 timelockSecs; // 0 = skip
        // Org
        string orgName;
        string orgSymbol;
        string orgURI;
    }

    /*//////////////////////////////////////////////////////////////
                      DEPLOY — VAULT ONLY
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a CollectorVault clone for a predicted (or existing) DAO.
    ///         Caller is responsible for summoning the DAICO with the vault
    ///         as tap recipient and including the permit call from permitCall().
    /// @param vp       Vault configuration
    /// @param salt     CREATE2 salt (also used as permit nonce). Must match DAICO salt.
    /// @param deadline Sale deadline (uint40 from DAICOConfig, cast to uint256)
    /// @return vault  The deployed CollectorVault clone
    function deploy(VaultParams calldata vp, bytes32 salt, uint40 deadline) public returns (address vault) {
        address predictedDAO = _predictDAO(salt);
        address predictedShares = _predictShares(predictedDAO);

        vault = _clone(vaultImpl, salt);
        CollectorVault(payable(vault))
            .init(
                vp.mode,
                predictedDAO,
                uint256(deadline),
                vp.target,
                vp.ethPerCall,
                vp.maxCalls,
                vp.payload,
                vp.token,
                vp.minBalance,
                vp.specificId,
                predictedShares,
                0 // shareRate = 0 (buy disabled)
            );

        emit Deployed(predictedDAO, vault, vp.mode);
    }

    /*//////////////////////////////////////////////////////////////
          DEPLOY + SUMMON — OPINIONATED SINGLE-TX
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy vault + summon DAO atomically. Branches on lpBps:
    ///         lpBps != 0: Full DAICO sale + LP + tap (vault as tap ops).
    ///         lpBps == 0: Bare Moloch DAO, allowance-based sale via vault.buy().
    function deployAndSummon(VaultParams calldata vp, DAICOParams calldata dp, bytes32 salt)
        public
        returns (address dao, address vault)
    {
        address predictedDAO = _predictDAO(salt);
        address predictedShares = _predictShares(predictedDAO);

        vault = _clone(vaultImpl, salt);

        if (dp.lpBps != 0) {
            // --- DAICO path: full sale + LP + tap ---
            CollectorVault(payable(vault))
                .init(
                    vp.mode,
                    predictedDAO,
                    uint256(dp.deadline),
                    vp.target,
                    vp.ethPerCall,
                    vp.maxCalls,
                    vp.payload,
                    vp.token,
                    vp.minBalance,
                    vp.specificId,
                    predictedShares,
                    0 // shareRate = 0 (DAICO handles sale)
                );

            dao = IDAICO(DAICO)
                .summonDAICOWithTapCustom(
                    SummonConfig(SUMMONER, MOLOCH_IMPL, SHARES_IMPL, LOOT_IMPL),
                    dp.orgName,
                    dp.orgSymbol,
                    dp.orgURI,
                    dp.quorumBps,
                    true, // ragequittable
                    RENDERER,
                    salt,
                    new address[](0),
                    new uint256[](0),
                    false,
                    false,
                    DAICOConfig({
                        tribTkn: dp.tribTkn,
                        tribAmt: dp.tribAmt,
                        saleSupply: dp.saleSupply,
                        forAmt: dp.forAmt,
                        deadline: dp.deadline,
                        sellLoot: dp.sellLoot,
                        lpBps: dp.lpBps,
                        maxSlipBps: dp.maxSlipBps,
                        feeOrHook: dp.feeOrHook
                    }),
                    TapConfig({ops: vault, ratePerSec: dp.ratePerSec, tapAllowance: dp.tapAllowance}),
                    _buildCustomCalls(predictedDAO, predictedShares, vault, salt, dp)
                );
        } else {
            // --- Bare Moloch path: allowance-based sale via vault.buy() ---
            uint256 _shareRate = dp.forAmt * 1e18 / dp.tribAmt;

            CollectorVault(payable(vault))
                .init(
                    vp.mode,
                    predictedDAO,
                    uint256(dp.deadline),
                    vp.target,
                    vp.ethPerCall,
                    vp.maxCalls,
                    vp.payload,
                    vp.token,
                    vp.minBalance,
                    vp.specificId,
                    predictedShares,
                    _shareRate // buy enabled
                );

            Call[] memory initCalls = _buildCustomCalls(predictedDAO, predictedShares, vault, salt, dp);

            dao = abi.decode(_callSummoner(dp, salt, initCalls), (address));
        }

        require(dao == predictedDAO);
        emit Deployed(dao, vault, vp.mode);
    }

    /*//////////////////////////////////////////////////////////////
          DEPLOY + SUMMON — RAW CALLDATA ESCAPE HATCH
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy vault clone + summon DAICO atomically. Caller provides the
    ///         fully-encoded DAICO summon calldata.
    function deployAndSummonRaw(VaultParams calldata vp, bytes32 salt, uint40 deadline, bytes calldata summonCalldata)
        public
        returns (address dao, address vault)
    {
        address predictedDAO = _predictDAO(salt);
        address predictedShares = _predictShares(predictedDAO);

        vault = _clone(vaultImpl, salt);
        CollectorVault(payable(vault))
            .init(
                vp.mode,
                predictedDAO,
                uint256(deadline),
                vp.target,
                vp.ethPerCall,
                vp.maxCalls,
                vp.payload,
                vp.token,
                vp.minBalance,
                vp.specificId,
                predictedShares,
                0 // shareRate = 0
            );

        // Forward the pre-encoded summon call to the DAICO factory
        (bool ok, bytes memory ret) = DAICO.call(summonCalldata);
        require(ok);
        dao = abi.decode(ret, (address));
        require(dao == predictedDAO);

        emit Deployed(dao, vault, vp.mode);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Predict the DAO address for a given salt.
    function predictDAO(bytes32 salt) public pure returns (address) {
        return _predictDAO(salt);
    }

    /// @notice Predict the shares token address for a given salt.
    function predictShares(bytes32 salt) public pure returns (address) {
        return _predictShares(_predictDAO(salt));
    }

    /// @notice Predict the vault clone address for a given salt.
    function predictVault(bytes32 salt) public view returns (address) {
        return _predictClone(vaultImpl, salt, address(this));
    }

    /// @notice Generate the permit Call for inclusion in DAICO customCalls.
    ///         Sets up a one-shot permit: ShareBurner singleton is both
    ///         delegatecall target and spender. Anyone can trigger burn via
    ///         ShareBurner.closeSale(dao, shares, deadline, nonce).
    /// @param salt     Must match deploy salt (also used as permit nonce)
    /// @param deadline Sale deadline (encoded into burnUnsold data for on-chain enforcement)
    /// @return target  The DAO address the call targets
    /// @return value   Always 0
    /// @return data    Encoded setPermit call
    function permitCall(bytes32 salt, uint256 deadline)
        public
        pure
        returns (address target, uint256 value, bytes memory data)
    {
        address predictedDAO = _predictDAO(salt);
        address predictedShares = _predictShares(predictedDAO);

        bytes memory burnData = abi.encodeWithSelector(IShareBurner.burnUnsold.selector, predictedShares, deadline);

        target = predictedDAO;
        value = 0;
        data = abi.encodeWithSelector(
            IMoloch.setPermit.selector,
            uint8(1), // op = delegatecall
            BURNER, // target = ShareBurner singleton
            uint256(0), // value = 0
            burnData, // encoded burnUnsold call
            salt, // nonce
            BURNER, // spender = ShareBurner singleton
            uint256(1) // count = 1 (one-shot)
        );
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Build the custom init calls array for DAO setup.
    function _buildCustomCalls(
        address predictedDAO,
        address predictedShares,
        address vault,
        bytes32 salt,
        DAICOParams calldata dp
    ) internal pure returns (Call[] memory calls) {
        unchecked {
            // Count calls: gov setup (0-2) + permit (0-1, DAICO only) + allowance (0-1, bare only)
            uint256 n;
            if (dp.votingSecs != 0) ++n;
            if (dp.timelockSecs != 0) ++n;

            if (dp.lpBps == 0) {
                ++n; // setAllowance (spendAllowance mints on demand, no pre-mint needed)
            } else {
                ++n; // ShareBurner permit (DAICO path only — pre-minted supply needs burn)
            }

            calls = new Call[](n);
            uint256 i;

            // Governance setup
            if (dp.votingSecs != 0) {
                calls[i++] =
                    Call(predictedDAO, 0, abi.encodeWithSelector(IMoloch.setProposalTTL.selector, dp.votingSecs));
            }
            if (dp.timelockSecs != 0) {
                calls[i++] =
                    Call(predictedDAO, 0, abi.encodeWithSelector(IMoloch.setTimelockDelay.selector, dp.timelockSecs));
            }

            if (dp.lpBps == 0) {
                // Bare Moloch path: set allowance cap for vault (spendAllowance mints via _payout)
                calls[i] = Call(
                    predictedDAO,
                    0,
                    abi.encodeWithSelector(IMoloch.setAllowance.selector, vault, predictedDAO, dp.saleSupply)
                );
            } else {
                // DAICO path: ShareBurner permit — singleton is both target and spender
                bytes memory burnData =
                    abi.encodeWithSelector(IShareBurner.burnUnsold.selector, predictedShares, uint256(dp.deadline));
                calls[i] = Call(
                    predictedDAO,
                    0,
                    abi.encodeWithSelector(
                        IMoloch.setPermit.selector, uint8(1), BURNER, uint256(0), burnData, salt, BURNER, uint256(1)
                    )
                );
            }
        }
    }

    /// @dev Call the bare Moloch summoner (lpBps == 0 path).
    function _callSummoner(DAICOParams calldata dp, bytes32 salt, Call[] memory initCalls)
        internal
        returns (bytes memory)
    {
        // We need to ABI-encode and call ISummoner.summon() manually
        // because initCalls is memory, not calldata
        bytes memory data = abi.encodeWithSelector(
            ISummoner.summon.selector,
            dp.orgName,
            dp.orgSymbol,
            dp.orgURI,
            dp.quorumBps,
            true, // ragequittable
            RENDERER,
            salt,
            new address[](0),
            new uint256[](0),
            initCalls
        );
        (bool ok, bytes memory ret) = SUMMONER.call(data);
        require(ok);
        return ret;
    }

    /// @dev Deploy a PUSH0 minimal proxy clone via CREATE2.
    function _clone(address impl, bytes32 salt) internal returns (address clone) {
        assembly ("memory-safe") {
            mstore(0x24, 0x5af43d5f5f3e6029573d5ffd5b3d5ff3)
            mstore(0x14, impl)
            mstore(0x00, 0x602d5f8160095f39f35f5f365f5f37365f73)
            clone := create2(0, 0x0e, 0x36, salt)
            if iszero(clone) {
                mstore(0x00, 0x30116425) // DeploymentFailed()
                revert(0x1c, 0x04)
            }
            mstore(0x24, 0)
        }
    }

    /*//////////////////////////////////////////////////////////////
                          PURE HELPERS
    //////////////////////////////////////////////////////////////*/

    function _predictDAO(bytes32 salt) internal pure returns (address) {
        return _predictClone(MOLOCH_IMPL, keccak256(abi.encode(new address[](0), new uint256[](0), salt)), SUMMONER);
    }

    function _predictShares(address dao_) internal pure returns (address) {
        return _predictClone(SHARES_IMPL, bytes32(bytes20(dao_)), dao_);
    }

    function _predictClone(address impl, bytes32 salt_, address deployer_) internal pure returns (address) {
        bytes memory code =
            abi.encodePacked(hex"602d5f8160095f39f35f5f365f5f37365f73", impl, hex"5af43d5f5f3e6029573d5ffd5b3d5ff3");
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer_, salt_, keccak256(code))))));
    }
}
