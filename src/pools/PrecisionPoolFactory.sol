// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";
import {PrecisionPool} from "./PrecisionPool.sol";

/// @title PrecisionPoolFactory
/// @notice Deploys PrecisionPool, one per (pair, range, fee), at an address
///         derived from those parameters.
///
/// @dev    RANGES ARE MEANT TO BE CURATED, AND THAT IS AN ARCHITECTURAL CHOICE
///         RATHER THAN A POLICY ONE. Here a range is a whole pool, not a
///         position inside one, so two bands over the same pair are two
///         separate books that cannot lend each other depth. A market split
///         across many narrow bands is worse for everyone than the same
///         capital in one: no band is the best price, and takers route past
///         all of them. Fee tiers are few for the same reason. Nothing here
///         enforces a list - anyone may deploy any band - but the frontend
///         should offer a small set and concentrate liquidity into it.
///
///         That choice is what makes full deployment the right shape. A clone
///         would cost ~45k gas instead of ~1.6M, but it charges every future
///         swap a delegatecall and a read out of the proxy's own code. With
///         pools few and deep, the deployer paying once beats every taker
///         paying forever; the crossover is around 2,300 swaps. If freeform
///         ranges ever become the product, this is the file to revisit. A
///         market that names a fee recipient is an exception: only that
///         recipient may create and initialize it, so nobody can front-run a
///         creator-branded market with immutable terms they did not choose.
///
///         ADDRESSES ARE DERIVED, AND ALSO RECORDED. Constructor arguments are
///         part of the init code, so a market's address already depends on its
///         parameters and `poolFor` computes it without touching storage. That
///         is enough to *check* a market you can already name, and useless for
///         *finding* one - derivation cannot enumerate. A dapp offering search
///         needs the list, so creation appends to one, globally and per pair.
///         The extra storage is paid once by whoever opens the market, which
///         is the same party already paying for the deployment.
///
///         The list holds addresses only. Every parameter is a public
///         immutable on the pool itself, so a reader takes the addresses from
///         here and the details from there, and the two cannot disagree.
///
///         TOKEN ORDER IS CANONICAL. token0 < token1 by address, so native ETH
///         - address(0) - is always token0. Without this the same market could
///         exist twice under two orderings, splitting its liquidity, and the
///         two would quote reciprocal prices.
///
///         WHAT IS NOT CHECKED. Prices are raw token1 per raw token0, with
///         decimals already folded into the bounds. That convention cannot be
///         verified from here, which is why the event reports the tuple back:
///         a wrong bound produces a live pool quoting a nonsense price, and it
///         should be caught by review before anyone funds it.
contract PrecisionPoolFactory {
    using SafeTransferLib for address;

    /// @notice Everything that defines a market, and therefore its address.
    /// @dev Passed as a struct rather than positionally. The tuple carries two
    ///      adjacent addresses whose meanings are unrelated and whose values
    ///      are immutable once deployed; transposing them in a long argument
    ///      list would be silent, permanent, and easy.
    struct Market {
        address token0;
        address token1;
        uint256 sqrtPLow;
        uint256 sqrtPHigh;
        uint256 fee;
        address hook;
        address feeRecipient;
        uint256 creatorFeeBps;
    }

    /// @dev A hook is another axis on which the same market can be split into
    ///      pools that do not share depth, exactly as a band is. Most pools
    ///      should pass address(0); a curated set is the point.
    ///
    /// @dev Pips, as the pool's swap math expects. 10% is past any real market
    ///      and exists to catch a units mistake - basis points where pips were
    ///      meant - rather than to express a view on fees.
    uint256 constant MAX_FEE = 100_000;
    uint256 constant MAX_CREATOR_SHARE = 5_000;
    uint256 constant MAX_PAGE_SIZE = 128;

    error Bad();
    error Exists();
    error NoPool();
    error NotCreator();
    error NotExecutor();

    /// @notice The sole router permitted to use the transfer-first execution
    ///         path. address(0) deliberately disables that optional path.
    /// @dev ERC-20 transfers do not carry a transaction-scoped provenance
    ///      signal. Without this bound, anyone could exchange an unsolicited
    ///      token balance sent to the factory for a pool's other asset.
    address public immutable trustedExecutor;

    /// @dev Every pool ever created, in creation order.
    address[] public allPools;
    mapping(address pool => bool) public isPool;

    /// @dev Pools per canonical pair, for the common "what bands exist on this
    ///      market" query without walking the global list.
    mapping(address token0 => mapping(address token1 => address[])) internal _byPair;

    /// @dev Markets touching one token, in either position. A pair lookup needs
    ///      both sides and the canonical order; search needs neither.
    mapping(address token => address[]) internal _byToken;

    /// @dev Markets a creator is named on, so a creator's own dashboard is one
    ///      call rather than a scan of everything ever deployed.
    mapping(address creator => address[]) internal _byCreator;

    /// @dev Deliberately lean. Discovery does not run on logs here: a market's
    ///      address is derived from its parameters and its state is read from
    ///      the registry and the lens, so an event large enough to reconstruct
    ///      a pool would duplicate what is already queryable.
    event PoolCreated(address indexed pool, address indexed token0, address indexed token1, uint256 fee);

    /// @param trustedExecutor_ Router allowed to call `executePrefundedSwap`.
    ///        Set to address(0) when only direct exact-input swaps are wanted.
    constructor(address trustedExecutor_) {
        trustedExecutor = trustedExecutor_;
    }

    /// @notice Deploy the pool for this market.
    /// @param m Bounds are sqrt prices in raw token1 per raw token0 scaled
    ///        1e18, `fee` is in pips (500 = 0.05%), and `creatorFeeBps` is a
    ///        share OF that fee rather than an addition to it.
    function createPool(Market calldata m) public returns (address pool) {
        _check(m);
        _checkCreator(m);
        address predicted = poolFor(m);
        if (predicted.code.length != 0) revert Exists();

        pool = address(
            new PrecisionPool{salt: keccak256(abi.encode(m))}(
                address(this),
                m.token0,
                m.token1,
                m.sqrtPLow,
                m.sqrtPHigh,
                m.fee,
                m.hook,
                m.feeRecipient,
                m.creatorFeeBps
            )
        );

        _index(pool, m);
        emit PoolCreated(pool, m.token0, m.token1, m.fee);
    }

    /// @dev Indexed at creation because this registry is not redeployable: an
    ///      index that does not exist at launch cannot be backfilled later
    ///      without losing every market created before it.
    function _index(address pool, Market calldata m) internal {
        allPools.push(pool);
        isPool[pool] = true;
        _byPair[m.token0][m.token1].push(pool);
        _byToken[m.token0].push(pool);
        _byToken[m.token1].push(pool);
        if (m.feeRecipient != address(0)) _byCreator[m.feeRecipient].push(pool);
    }

    // -------------------------------------------------------------- DISCOVERY

    function poolCount() external view returns (uint256) {
        return allPools.length;
    }

    function poolsForPairCount(address token0, address token1) external view returns (uint256) {
        return _byPair[token0][token1].length;
    }

    function poolsForTokenCount(address token) external view returns (uint256) {
        return _byToken[token].length;
    }

    function poolsForCreatorCount(address creator) external view returns (uint256) {
        return _byCreator[creator].length;
    }

    /// @notice A window into the global list.
    /// @dev Paginated because the list only grows, and a frontend should never
    ///      be forced into an unbounded read to show its first page. A `start`
    ///      past the end returns empty rather than reverting, so a caller can
    ///      walk to exhaustion without knowing the length first.
    function poolsSlice(uint256 start, uint256 count) external view returns (address[] memory out) {
        return _slice(allPools, start, count);
    }

    /// @notice A bounded page of bands over a canonical pair.
    function poolsForPairSlice(address token0, address token1, uint256 start, uint256 count)
        external
        view
        returns (address[] memory)
    {
        return _slice(_byPair[token0][token1], start, count);
    }

    /// @notice A bounded page of markets touching one token.
    function poolsForTokenSlice(address token, uint256 start, uint256 count) external view returns (address[] memory) {
        return _slice(_byToken[token], start, count);
    }

    /// @notice A bounded page of markets whose recipient explicitly created
    ///         the market. This cannot be spoofed because named markets require
    ///         the recipient to submit the creation transaction.
    function poolsForCreatorSlice(address creator, uint256 start, uint256 count)
        external
        view
        returns (address[] memory)
    {
        return _slice(_byCreator[creator], start, count);
    }

    function _slice(address[] storage pools, uint256 start, uint256 count)
        internal
        view
        returns (address[] memory out)
    {
        if (count > MAX_PAGE_SIZE) revert Bad();
        uint256 total = pools.length;
        if (start >= total || count == 0) return out;
        uint256 size = count;
        uint256 remaining = total - start;
        if (size > remaining) size = remaining;
        out = new address[](size);
        for (uint256 i; i < size; ++i) {
            out[i] = pools[start + i];
        }
    }

    /// @notice Create the market and seed it in one transaction.
    /// @dev An unseeded pool quotes nothing and its first depositor sets the
    ///      price, so leaving a gap between creation and seeding publishes an
    ///      empty pool that anyone else may price. Doing both here closes that
    ///      window.
    ///
    ///      Funds go straight from the caller to the pool - the factory never
    ///      takes custody - and the pool refunds the unused side directly to
    ///      the caller through `refundTo`. Sweeping a factory balance instead
    ///      would misreport the refund for any token that skims on transfer,
    ///      and would let a seeder collect anything previously left here.
    ///
    ///      `amount0` is msg.value when token0 is native ETH, and an ERC-20
    ///      pull otherwise; the two are mutually exclusive so value cannot be
    ///      sent to a pool that has no use for it.
    function createAndSeed(
        Market calldata m,
        uint256 sqrtPriceInit,
        uint256 amount0,
        uint256 amount1,
        uint256 minLP,
        address to
    ) external payable returns (address pool, uint256 lp, uint256 used0, uint256 used1) {
        pool = createPool(m);
        (lp, used0, used1) = _fund(pool, m.token0, m.token1, amount0, amount1, sqrtPriceInit, minLP, to);
    }

    /// @notice Add liquidity to a market that already exists.
    /// @dev The router-facing half of the pair above: a caller that only knows
    ///      the market tuple does not have to resolve the address itself, and
    ///      gets the same funding and refund handling. Deliberately separate
    ///      from `createAndSeed` rather than create-if-absent, so a mistyped
    ///      bound fails here instead of quietly opening a second, empty market
    ///      beside the one that was meant.
    ///
    ///      `sqrtPriceInit` is still forwarded, since a pool can exist while
    ///      unseeded; once the supply is nonzero the pool ignores it.
    function seed(Market calldata m, uint256 sqrtPriceInit, uint256 amount0, uint256 amount1, uint256 minLP, address to)
        external
        payable
        returns (address pool, uint256 lp, uint256 used0, uint256 used1)
    {
        pool = poolFor(m);
        if (pool.code.length == 0) revert NoPool();
        // A branded market can only be initialized by the recipient named in
        // its immutable terms. Subsequent liquidity remains permissionless.
        if (PrecisionPool(payable(pool)).totalSupply() == 0) _checkCreator(m);
        (lp, used0, used1) = _fund(pool, m.token0, m.token1, amount0, amount1, sqrtPriceInit, minLP, to);
    }

    /// @dev Moves both sides from the caller straight to the pool, then mints.
    ///      The factory is never a custodian and never an approval target for
    ///      the pool: it forwards, and the pool refunds the unused remainder
    ///      to the caller directly.
    function _fund(
        address pool,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1,
        uint256 sqrtPriceInit,
        uint256 minLP,
        address to
    ) internal returns (uint256 lp, uint256 used0, uint256 used1) {
        if (token0 == address(0)) {
            if (msg.value != amount0) revert Bad();
        } else {
            if (msg.value != 0) revert Bad();
            _pullExact(token0, msg.sender, pool, amount0);
        }
        _pullExact(token1, msg.sender, pool, amount1);

        return PrecisionPool(payable(pool)).addLiquidityFromFactory{value: token0 == address(0) ? amount0 : 0}(
            sqrtPriceInit, amount0, amount1, minLP, to, msg.sender
        );
    }

    /// @notice Direct, exact-input swap path. Pulls ERC-20s in the same call
    ///         and therefore never relies on an observable prefund.
    function swapExactIn(address pool, address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        payable
        returns (uint256 amountOut)
    {
        if (!isPool[pool]) revert NoPool();
        PrecisionPool p = PrecisionPool(payable(pool));
        if (tokenIn != p.token0() && tokenIn != p.token1()) revert Bad();
        bool nativeIn = tokenIn == address(0) && p.token0() == address(0);
        if (nativeIn) {
            if (msg.value != amountIn) revert Bad();
            return p.swapFromFactory{value: amountIn}(tokenIn, amountIn, minOut, to);
        }
        if (msg.value != 0) revert Bad();
        _pullExact(tokenIn, msg.sender, pool, amountIn);
        return p.swapFromFactory(tokenIn, amountIn, minOut, to);
    }

    /// @notice Exact settlement for an atomic executor that has already funded
    ///         this factory in the current transaction (for example zRouter's
    ///         `snwap`). The specified amount, rather than this contract's
    ///         total balance, is forwarded to the pool.
    function executePrefundedSwap(address pool, address tokenIn, uint256 amountIn, uint256 minOut, address to)
        external
        payable
        returns (uint256 amountOut)
    {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (!isPool[pool]) revert NoPool();
        PrecisionPool p = PrecisionPool(payable(pool));
        if (tokenIn != p.token0() && tokenIn != p.token1()) revert Bad();
        bool nativeIn = tokenIn == address(0) && p.token0() == address(0);
        if (nativeIn) {
            if (msg.value != amountIn) revert Bad();
            return p.swapFromFactory{value: amountIn}(tokenIn, amountIn, minOut, to);
        }
        if (msg.value != 0) revert Bad();
        _transferExact(tokenIn, pool, amountIn);
        return p.swapFromFactory(tokenIn, amountIn, minOut, to);
    }

    function _pullExact(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(to);
        SafeTransferLib.safeTransferFrom(token, from, to, amount);
        uint256 afterBalance = token.balanceOf(to);
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert Bad();
    }

    function _transferExact(address token, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 senderBefore = token.balanceOf(address(this));
        uint256 recipientBefore = token.balanceOf(to);
        SafeTransferLib.safeTransfer(token, to, amount);
        uint256 senderAfter = token.balanceOf(address(this));
        uint256 recipientAfter = token.balanceOf(to);
        if (
            senderAfter > senderBefore || senderBefore - senderAfter != amount || recipientAfter < recipientBefore
                || recipientAfter - recipientBefore != amount
        ) revert Bad();
    }

    /// @notice The address this market's pool has, or would have.
    /// @dev Callers can enumerate candidate markets and test `code.length`
    ///      rather than reading a registry. Hashing the init code is only paid
    ///      by view callers; the factory has to carry that code regardless, in
    ///      order to deploy at all.
    function poolFor(Market calldata m) public view returns (address) {
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(PrecisionPool).creationCode,
                abi.encode(
                    address(this),
                    m.token0,
                    m.token1,
                    m.sqrtPLow,
                    m.sqrtPHigh,
                    m.fee,
                    m.hook,
                    m.feeRecipient,
                    m.creatorFeeBps
                )
            )
        );
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), keccak256(abi.encode(m)), initHash)))
            )
        );
    }

    function _check(Market calldata m) internal pure {
        // Canonical ordering; address(0) is native ETH and sorts first, which
        // is what makes it always token0.
        if (m.token0 >= m.token1) revert Bad();
        if (m.token1 == address(0)) revert Bad();
        // sqrtPLow divides the virtual reserve, and an empty or inverted range
        // leaves the seed with nothing to divide by.
        if (m.sqrtPLow == 0 || m.sqrtPHigh <= m.sqrtPLow) revert Bad();
        if (m.fee >= MAX_FEE) revert Bad();
        if (m.creatorFeeBps > MAX_CREATOR_SHARE) revert Bad();
        if (m.creatorFeeBps != 0 && m.feeRecipient == address(0)) revert Bad();
    }

    function _checkCreator(Market calldata m) internal view {
        if (m.feeRecipient != address(0) && msg.sender != m.feeRecipient) revert NotCreator();
    }
}
