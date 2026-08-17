// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PrecisionPool} from "./PrecisionPool.sol";
import {SSTORE2} from "../../lib/solady/src/utils/SSTORE2.sol";
import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";

/// @title PrecisionPoolFactory
/// @notice Deploys one PrecisionPool for each complete immutable market tuple.
/// @dev CREATE2 derives each pool address from the factory, market tuple, and
///      pool init code. Pools are indexed globally and by pair, token, and
///      creator. Token order is canonical (`token0 < token1`), and price bounds
///      use raw token units with decimals already included.
contract PrecisionPoolFactory {
    using SafeTransferLib for address;

    /// @notice Everything that defines a market and its CREATE2 address.
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

    /// @notice The complete settlement a prefunded route commits to up front.
    /// @dev Every field the settlement can act on lives here, so `checkpoint`
    ///      commits to the whole intent and not merely to a balance delta.
    ///      `refundTo` is the only address any input can come back to: it
    ///      receives the whole funding from `abortCheckpoint`, and the
    ///      unconsumed remainder from `executePrefundedSwapUpTo`. Nowhere else
    ///      is reachable, which is what stops an abort or a partial fill from
    ///      being a redirection primitive.
    struct Route {
        address pool;
        address originator;
        address tokenIn;
        uint256 amountIn;
        uint256 minOut;
        address to;
        address refundTo;
    }

    /// @dev `fee` is in pips; hook and creator-fee settings are also immutable.
    ///      The cap is EXCLUSIVE, so the highest admissible fee is one pip
    ///      under 10%.
    uint256 constant MAX_FEE = 100_000; // 10%, in pips
    uint256 constant MAX_CREATOR_SHARE = 5_000; // 50% of the base fee
    uint256 constant MAX_PAGE_SIZE = 128;
    uint256 constant MAX_SQRT_PRICE = 1e36;
    uint256 constant CHECKPOINT_NAMESPACE = 1 << 255;

    /// @dev Encoded size of `Route`: seven static words. Pinned in the
    ///      constructor, because `_routeHash` reads calldata against it.
    uint256 constant _ROUTE_BYTES = 0xe0;

    /// @dev Transient slot guarding the prefunded route.
    uint256 constant _ROUTE_SLOT = 0x9e7d1a3c;

    /// @dev Transient slot holding the open route's committed intent hash.
    ///      One slot suffices because at most one route is ever open.
    uint256 constant _INTENT_SLOT = 0x9e7d1a3d;

    error Bad();
    error Exists();
    error NoPool();
    error NotCreator();
    error Reentrancy();
    error NotExecutor();
    error BadCheckpoint();
    error IntentMismatch();

    /// @notice Executor allowed to use the checkpointed prefunded route.
    ///         Address(0) disables that route.
    /// @dev ERC-20 settlement also checks a transient balance checkpoint, so
    ///      pre-existing factory balances cannot be spent by a route.
    address public immutable trustedExecutor;

    /// @notice Data contract whose runtime IS the pool's creation code.
    /// @dev The factory used to hold `type(PrecisionPool).creationCode` inline,
    ///      which put the whole pool inside the factory's own deployed code: at
    ///      ~24 KB of pool against a 24,576 B contract limit, the factory was
    ///      1,528 B over EIP-170 and could not be deployed at all, and every
    ///      byte the pool gained came straight off the factory's margin from a
    ///      different file. Writing those bytes to a data contract in the
    ///      constructor - from an argument, which never becomes runtime code -
    ///      leaves the factory holding only its own logic - ~7.6 KB at the time
    ///      of writing, against a pool whose creation code alone is ~22.8 KB and
    ///      would not have fitted beside it under any arrangement. Nothing
    ///      about deployment changes: `createPool` copies the blob back out and
    ///      CREATE2s the identical initcode, so addresses are still derived from
    ///      the market tuple alone.
    ///
    ///      The factory cannot check that the blob really is a PrecisionPool -
    ///      it no longer has a copy to compare against - so `poolInitCodeHash`
    ///      is published for anyone verifying a deployment against the compiled
    ///      artifact. A factory built over the wrong blob produces pools that
    ///      are not pools, and `isPool` is what the zap, route and policy trust,
    ///      so that hash is the thing to check before using a deployment.
    address public immutable poolCode;

    /// @notice keccak256 of the pool creation code this factory deploys.
    bytes32 public immutable poolInitCodeHash;

    /// @dev Every pool ever created, in creation order.
    address[] public allPools;
    mapping(address pool => bool) public isPool;

    /// @dev Pools per canonical pair.
    mapping(address token0 => mapping(address token1 => address[])) internal _byPair;

    /// @dev Pools containing a token, in either position.
    mapping(address token => address[]) internal _byToken;

    /// @dev Pools with a nonzero fee recipient.
    mapping(address creator => address[]) internal _byCreator;

    event PoolCreated(address indexed pool, address indexed token0, address indexed token1, uint256 fee);

    /// @dev Route states. The lock spans the whole route rather than each call
    ///      within it, because the dangerous interval is the one BETWEEN the
    ///      calls: the executor takes a checkpoint, then moves the payer's
    ///      tokens in, then settles. A lock that clears when `checkpoint`
    ///      returns leaves the factory unlocked for exactly the transfer that
    ///      funds it, and a callback-capable input token gets control there. If
    ///      the executor ever holds a second live checkpoint, that callback can
    ///      re-enter it and settle the OTHER route against a pool, recipient,
    ///      slippage, and originator of the attacker's choosing.
    ///
    ///      Holding `_ROUTE_OPEN` from `checkpoint` until settlement makes a
    ///      SECOND route unrepresentable: at most one exists at a time, so a
    ///      reentrant `checkpoint` is rejected outright. That alone is not
    ///      enough, because the open route is itself callable during the
    ///      funding transfer - a callback that re-enters the public executor
    ///      could settle or abort THIS route with a pool, recipient, slippage,
    ///      originator, or refund address of its own choosing, and the lock
    ///      would not notice: the checkpoint committed only to a balance delta.
    ///
    ///      So the checkpoint commits to the whole `Route`. Settlement and
    ///      abortion must present the identical intent, which leaves a
    ///      reentrant caller nothing to substitute: it can only perform the
    ///      swap that was already authorized, to the recipient that was already
    ///      named. Doing so early makes the outer settlement fail on a consumed
    ///      checkpoint, which is a revert rather than a theft. The factory
    ///      therefore does not depend on the executor being well behaved to be
    ///      safe, only to be useful. Routes are never legitimately concurrent -
    ///      hops are sequential calls, each opening and closing its own route.
    ///
    ///      For the record, what the canonical executor actually is (zRouter's
    ///      SafeExecutor, 0x25Fc36455aa30D012bbFB86f283975440D7Ee8Db, 206 bytes
    ///      of runtime read on-chain): ONE function, `execute(address,bytes)`,
    ///      with no caller check, no storage and no guard - so it is public,
    ///      and a token callback firing during the funding transfer can re-enter
    ///      it and reach this contract while the route is open. What saves that
    ///      arrangement is not the executor's restraint but its rigidity: it
    ///      bubbles every downstream revert (`returndatacopy; revert`), and
    ///      zRouter's `multicall` and `snwap` bubble too, so there is no
    ///      catch-and-continue anywhere on the path. A substituted settlement
    ///      would therefore strand the outer one on a consumed checkpoint and
    ///      take the whole transaction down with it.
    ///
    ///      That makes `trustedExecutor` a call-path label rather than
    ///      authentication - anyone can drive this route through the public
    ///      executor - and it makes the intent commitment the thing that holds
    ///      the property locally, instead of inheriting it from a router that
    ///      can be replaced without this immutable contract noticing.
    uint256 constant _ROUTE_IDLE = 0;
    uint256 constant _ROUTE_OPEN = 1;
    uint256 constant _ROUTE_SETTLING = 2;

    function _routeState() internal view returns (uint256 state) {
        assembly ("memory-safe") {
            state := tload(_ROUTE_SLOT)
        }
    }

    /// @dev Claims the factory for the body of a call and releases it after.
    ///
    ///      SEEDING NEEDS THIS AND USED NOT TO HAVE IT. `createAndSeed` and
    ///      `seed` read `totalSupply() == 0` to decide a pool is unseeded, then
    ///      make two external `_pullExact` transfers, then let the pool pick
    ///      the seed or the proportional branch. A token that hands control to
    ///      the payer during transfer - a hook, a callback, anything
    ///      attacker-reachable - can re-enter on the SAME market inside that
    ///      window and seed it first, at a price of its choosing. The outer
    ///      call then finds a pool with supply and silently takes the
    ///      proportional path: `sqrtPriceInit` is ignored, `minLP` bounds
    ///      shares but not price, and the honest depositor lands in whichever
    ///      corner of the band the attacker picked. That is the mempool squat
    ///      the pool documents, compressed into one transaction, and
    ///      `_checkCreator` only closes it for named markets.
    ///
    ///      It shares the route's slot rather than adding a second one, which
    ///      also means a deposit cannot run inside an open prefunded route -
    ///      the other half of the same window.
    modifier locked() {
        if (_routeState() != _ROUTE_IDLE) revert Reentrancy();
        _setRouteState(_ROUTE_SETTLING);
        _;
        _setRouteState(_ROUTE_IDLE);
    }

    function _setRouteState(uint256 state) internal {
        assembly ("memory-safe") {
            tstore(_ROUTE_SLOT, state)
        }
    }

    /// @param trustedExecutor_ Router allowed to drive a prefunded route:
    ///        `checkpoint`, `abortCheckpoint`, and either settlement.
    ///        Set to address(0) when only direct exact-input swaps are wanted.
    /// @param poolInitCode `type(PrecisionPool).creationCode`, passed in rather
    ///        than embedded. See `poolCode`.
    constructor(address trustedExecutor_, bytes memory poolInitCode) {
        if (trustedExecutor_ != address(0) && trustedExecutor_.code.length == 0) revert Bad();
        trustedExecutor = trustedExecutor_;
        if (poolInitCode.length == 0) revert Bad();
        // `_routeHash` hashes the raw calldata after the selector on the
        // assumption that `Route` is `_ROUTE_BYTES` of static words. If a field
        // is ever added, or a static one turned dynamic, that assumption breaks
        // SILENTLY - the hash would cover an offset instead of the value, and
        // the intent commitment would stop committing to it. Deploying is the
        // last moment anything can notice, so notice here.
        Route memory probe;
        if (abi.encode(probe).length != _ROUTE_BYTES) revert Bad();
        poolCode = SSTORE2.write(poolInitCode);
        poolInitCodeHash = keccak256(poolInitCode);
    }

    /// @notice Deploy the pool for this market.
    /// @param m Bounds are sqrt prices in raw token1 per raw token0 scaled
    ///        1e18, `fee` is in pips (500 = 0.05%), and `creatorFeeBps` is a
    ///        share of that fee rather than an addition to it.
    /// @dev If `feeRecipient` is nonzero, it must create the pool.
    function createPool(Market calldata m) public returns (address pool) {
        bytes memory initCode = _poolInitCode(m);
        bytes32 salt = _marketSalt(m);
        return _create(m, initCode, salt, _poolAddress(salt, keccak256(initCode)));
    }

    /// @dev Deploy and index, given work a caller has already done. The init
    ///      code is the ~20 KB pool blob copied out of the data contract and
    ///      hashed, which is not free: `createAndSeed` has to derive the
    ///      address before it can tell whether the pool exists, and would
    ///      otherwise pay for the whole thing a second time to deploy it.
    function _create(Market calldata m, bytes memory initCode, bytes32 salt, address predicted)
        internal
        returns (address pool)
    {
        _check(m);
        _checkCreator(m);
        if (predicted.code.length != 0) revert Exists();

        assembly ("memory-safe") {
            pool := create2(0, add(initCode, 0x20), mload(initCode), salt)
            if iszero(pool) {
                let size := returndatasize()
                // Empty returndata from a failed CREATE2 is ambiguous: it is
                // what an address-already-occupied collision produces, and also
                // what an out-of-gas constructor produces. `predicted.code.length`
                // was checked a few lines up, so the collision case is already
                // excluded by the time control reaches here and this is almost
                // always the gas case - but the two are genuinely
                // indistinguishable from inside, and `Exists()` is the more
                // useful of the two names to surface for a caller who did race
                // someone to the address.
                if iszero(size) {
                    mstore(0x00, 0x846ec056) // `Exists()`.
                    revert(0x1c, 0x04)
                }
                // Bubble the constructor's own revert, copied ABOVE the free
                // memory pointer rather than over offset 0. Writing to 0 would
                // clobber the FMP at 0x40 for any `size` past 0x40, which is
                // not `memory-safe` however the block is annotated - and the
                // annotation is a promise to the via-IR optimiser, not a
                // comment. It happens to be unobservable here because `revert`
                // is the very next opcode, but an assumption that only holds
                // because of instruction order is exactly the kind the
                // optimiser is entitled to break.
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, size)
                revert(ptr, size)
            }
        }

        _index(pool, m);
        emit PoolCreated(pool, m.token0, m.token1, m.fee);
    }

    /// @dev Indexing at creation keeps these lists complete; they cannot be
    ///      backfilled from this contract later.
    function _index(address pool, Market calldata m) internal {
        allPools.push(pool);
        isPool[pool] = true;
        _byPair[m.token0][m.token1].push(pool);
        _byToken[m.token0].push(pool);
        _byToken[m.token1].push(pool);
        if (m.feeRecipient != address(0)) _byCreator[m.feeRecipient].push(pool);
    }

    // -------------------------------------------------------------- DISCOVERY

    /// @notice Number of pools created by this factory.
    function poolCount() external view returns (uint256) {
        return allPools.length;
    }

    /// @notice Number of pools for a canonical token pair.
    function poolsForPairCount(address token0, address token1) external view returns (uint256) {
        return _byPair[token0][token1].length;
    }

    /// @notice Number of pools containing `token`.
    function poolsForTokenCount(address token) external view returns (uint256) {
        return _byToken[token].length;
    }

    /// @notice Number of pools indexed for `creator`.
    function poolsForCreatorCount(address creator) external view returns (uint256) {
        return _byCreator[creator].length;
    }

    /// @notice Return a bounded page of all pools in creation order.
    /// @dev A start beyond the end returns an empty array.
    function poolsSlice(uint256 start, uint256 count) external view returns (address[] memory out) {
        return _slice(allPools, start, count);
    }

    /// @notice Return a bounded page of pools for a canonical pair.
    function poolsForPairSlice(address token0, address token1, uint256 start, uint256 count)
        external
        view
        returns (address[] memory)
    {
        return _slice(_byPair[token0][token1], start, count);
    }

    /// @notice Return a bounded page of pools containing `token`.
    function poolsForTokenSlice(address token, uint256 start, uint256 count) external view returns (address[] memory) {
        return _slice(_byToken[token], start, count);
    }

    /// @notice Return a bounded page of pools created by `creator`.
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
            unchecked {
                out[i] = pools[start + i];
            }
        }
    }

    /// @notice Create and seed a market in one transaction.
    /// @dev Assets are forwarded directly to the pool. The pool refunds any
    ///      unused amount to the caller.
    /// @param m Market configuration.
    /// @param sqrtPriceInit Initial sqrt price; used only for an empty pool.
    /// @param amount0 Maximum token0 amount, or `msg.value` for native token0.
    /// @param amount1 Maximum token1 amount.
    /// @param minLP Minimum LP shares to mint.
    /// @param to LP share recipient.
    function createAndSeed(
        Market calldata m,
        uint256 sqrtPriceInit,
        uint256 amount0,
        uint256 amount1,
        uint256 minLP,
        address to
    ) external payable locked returns (address pool, uint256 lp, uint256 used0, uint256 used1) {
        // Deploying and seeding are separate powers, and anyone may deploy an
        // unnamed market. Reverting here when the pool merely exists but has
        // never been seeded would let a griefer squat a tuple by creating it
        // and walking away: the address is CREATE2-derived, so the market
        // cannot be redeployed, and the caller's create-and-seed would fail
        // permanently even though the pool is empty and unclaimed. An empty
        // pool is indistinguishable from one that does not exist yet, so seed
        // it instead. A pool that already holds liquidity still reverts, and a
        // named market still admits only its own creator.
        bytes memory initCode = _poolInitCode(m);
        bytes32 salt = _marketSalt(m);
        address existing = _poolAddress(salt, keccak256(initCode));
        if (isPool[existing] && PrecisionPool(payable(existing)).totalSupply() == 0) {
            _checkCreator(m);
            pool = existing;
        } else {
            pool = _create(m, initCode, salt, existing);
        }
        (lp, used0, used1) = _fund(pool, m.token0, m.token1, amount0, amount1, sqrtPriceInit, minLP, to);
    }

    /// @notice Add liquidity to an existing market.
    /// @dev The pool is resolved from the complete market tuple. If it is
    ///      empty, `sqrtPriceInit` sets its initial price; otherwise it is ignored.
    /// @param m Market configuration.
    /// @param sqrtPriceInit Initial sqrt price for an empty pool.
    /// @param amount0 Maximum token0 amount, or `msg.value` for native token0.
    /// @param amount1 Maximum token1 amount.
    /// @param minLP Minimum LP shares to mint.
    /// @param to LP share recipient.
    function seed(Market calldata m, uint256 sqrtPriceInit, uint256 amount0, uint256 amount1, uint256 minLP, address to)
        external
        payable
        locked
        returns (address pool, uint256 lp, uint256 used0, uint256 used1)
    {
        pool = poolFor(m);
        if (!isPool[pool]) revert NoPool();
        if (PrecisionPool(payable(pool)).totalSupply() == 0) {
            // A named market can only be initialized by its fee recipient.
            _checkCreator(m);
        } else if (sqrtPriceInit != 0) {
            // A NONZERO PRICE IS A STATED INTENT TO SEED, so refuse to quietly
            // do something else with it. This function doubles as "initialize"
            // and "top up", and the branch is chosen by state rather than by
            // the caller - so a seed that loses a race does not fail, it turns
            // into a proportional deposit at whoever won the race's price.
            // `sqrtPriceInit` is ignored, and `minLP` bounds shares rather than
            // price, so nothing the caller passed constrains what they buy.
            //
            // `createAndSeed` never had this hole - a seeded market sends it to
            // `_create`, which reverts `Exists()` - and the in-transaction
            // version is closed by the lock on both entry points. This is the
            // mempool version, and it is the one that lands silently.
            //
            // No new parameter: the price argument is already documented as
            // "used only for an empty pool", so a caller topping up a live pool
            // passes zero and is unaffected, while a caller who passed a price
            // is telling us which branch they meant.
            revert Bad();
        }
        (lp, used0, used1) = _fund(pool, m.token0, m.token1, amount0, amount1, sqrtPriceInit, minLP, to);
    }

    /// @dev Moves both sides from the caller to the pool, then mints and
    ///      refunds any unused amount to the caller.
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

    /// @dev Hash of the settlement a route commits to. The executor passes the
    ///      same `Route` to every call of a route - `checkpoint`, then either
    ///      settlement or `abortCheckpoint`; this is what ties them together,
    ///      so nothing off-chain ever needs to reproduce it.
    ///
    ///      `Route` is seven static words and is the only argument of all four
    ///      entry points, so the calldata after the selector IS its canonical
    ///      encoding - hashing it directly avoids copying the struct back out
    ///      to memory on every call. The constructor pins that `Route` really
    ///      does encode to `_ROUTE_BYTES`, so a later field addition fails the
    ///      deployment instead of quietly dropping out of the commitment.
    function _routeHash() internal pure returns (bytes32 h) {
        assembly ("memory-safe") {
            let m := mload(0x40)
            calldatacopy(m, 0x04, _ROUTE_BYTES)
            h := keccak256(m, _ROUTE_BYTES)
        }
    }

    /// @notice Snapshot an ERC-20 balance and open a prefunded route for `r`.
    /// @dev Must be followed in the same transaction by a settlement -
    ///      `executePrefundedSwap` or `executePrefundedSwapUpTo` - or by
    ///      `abortCheckpoint`, each carrying the SAME route. The transient
    ///      checkpoint binds settlement to the newly funded amount, the
    ///      committed intent binds it to this pool, recipient, slippage and
    ///      refund address, and the route stays LOCKED across the funding
    ///      transfer in between, so only one route can be in flight at a time.
    function checkpoint(Route calldata r) external {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (_routeState() != _ROUTE_IDLE) revert Reentrancy();
        address token = r.tokenIn;
        // Native input needs no checkpoint: it arrives with the settling call.
        if (token == address(0) || token.code.length == 0) revert Bad();
        _checkRoute(r);

        bytes32 slot = _checkpointSlot(token);
        uint256 encoded;
        assembly ("memory-safe") {
            encoded := tload(slot)
        }
        if (encoded != 0) revert BadCheckpoint();

        uint256 checkpointBalance = token.balanceOf(address(this));
        if (checkpointBalance == type(uint256).max) revert BadCheckpoint();
        unchecked {
            encoded = checkpointBalance + 1;
        }
        bytes32 intent = _routeHash();
        assembly ("memory-safe") {
            tstore(slot, encoded)
            tstore(_INTENT_SLOT, intent)
        }
        _setRouteState(_ROUTE_OPEN);
    }

    /// @dev Shared validation for a committed route.
    function _checkRoute(Route calldata r) internal view {
        if (!isPool[r.pool]) revert NoPool();
        if (r.amountIn == 0) revert Bad();
        if (r.to == address(0) || r.to == address(this)) revert Bad();
        if (r.refundTo == address(0) || r.refundTo == address(this)) revert Bad();
    }

    /// @dev Consume the open route's intent, requiring it to be the one that
    ///      was committed. Cleared before any external call so the same route
    ///      cannot be settled twice.
    function _consumeIntent() internal {
        bytes32 want = _routeHash();
        bytes32 have;
        assembly ("memory-safe") {
            have := tload(_INTENT_SLOT)
            tstore(_INTENT_SLOT, 0)
        }
        if (have != want) revert IntentMismatch();
    }

    /// @notice Close an open route without settling it, returning the funding.
    /// @dev The counterpart to a failed settlement. Without it, an executor
    ///      that funds the factory and then cannot settle - a reverting pool, a
    ///      failed slippage check it wants to handle rather than bubble - has
    ///      no way to give the tokens back: the transient checkpoint disappears
    ///      at the end of the transaction and the balance simply stays here,
    ///      with no authenticated recovery path. This refunds exactly the
    ///      balance delta observed since the checkpoint, so it can return the
    ///      route's own funding and nothing else - pre-existing factory
    ///      balances are not reachable through it.
    ///
    ///      The refund goes to the `refundTo` COMMITTED AT CHECKPOINT, not to
    ///      an address supplied here. An abort is therefore not a redirection
    ///      primitive: whoever triggers it, including a token callback
    ///      re-entering the executor mid-funding, can only hand the funding
    ///      back to the party the route already named.
    /// @param r The route opened by `checkpoint`; must match it exactly.
    function abortCheckpoint(Route calldata r) external returns (uint256 refunded) {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        if (_routeState() != _ROUTE_OPEN) revert BadCheckpoint();
        _setRouteState(_ROUTE_SETTLING);
        _consumeIntent();
        (address token, address to) = (r.tokenIn, r.refundTo);

        bytes32 slot = _checkpointSlot(token);
        uint256 encoded;
        assembly ("memory-safe") {
            encoded := tload(slot)
            tstore(slot, 0)
        }
        if (encoded == 0) revert BadCheckpoint();

        uint256 base;
        unchecked {
            base = encoded - 1;
        }
        uint256 current = token.balanceOf(address(this));
        if (current < base) revert BadCheckpoint();
        unchecked {
            refunded = current - base;
        }
        if (refunded != 0) _transferExact(token, to, refunded, current);
        _setRouteState(_ROUTE_IDLE);
    }

    /// @notice Settle a swap after the trusted executor has funded this factory.
    /// @dev ERC-20 input requires a same-transaction `checkpoint`; native input
    ///      is authenticated by `msg.value`.
    ///      `r.originator` is reported to the pool's hook as the trader. NOT
    ///      authenticated: snwap reaches this contract through a public
    ///      executor that does not forward the payer, so no party on this
    ///      path can prove who is trading. It exists so a hook sees something
    ///      other than this factory on every routed swap, which would
    ///      otherwise make sender-keyed hook logic uniformly wrong. Hooks
    ///      must treat it as a label, never as authority. It is committed at
    ///      checkpoint like every other field, so it cannot be swapped out at
    ///      settlement time - but a committed label is still only a label.
    /// @param r The route; for ERC-20 input it must match the one `checkpoint`
    ///        committed to, field for field.
    function executePrefundedSwap(Route calldata r) external payable returns (uint256 amountOut) {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        _checkRoute(r);
        PrecisionPool p = PrecisionPool(payable(r.pool));
        if (r.tokenIn == address(0)) {
            // Native input is authenticated by `msg.value` and arrives with the
            // call, so it has no funding interval to guard and opens no route.
            // Nothing is prefunded, so there is no intent to check either.
            if (_routeState() != _ROUTE_IDLE) revert Reentrancy();
            _setRouteState(_ROUTE_SETTLING);
            if (msg.value != r.amountIn) revert Bad();
            amountOut = p.swapFromFactory{value: r.amountIn}(r.originator, r.tokenIn, r.amountIn, r.minOut, r.to);
            _setRouteState(_ROUTE_IDLE);
            return amountOut;
        }
        // Settles the route this executor opened with `checkpoint`, which has
        // held the lock across the funding transfer in between.
        if (_routeState() != _ROUTE_OPEN) revert BadCheckpoint();
        _setRouteState(_ROUTE_SETTLING);
        _consumeIntent();
        if (msg.value != 0) revert Bad();
        uint256 senderBefore = _consumeCheckpoint(r.tokenIn, r.amountIn);
        _transferExact(r.tokenIn, r.pool, r.amountIn, senderBefore);
        amountOut = p.swapFromFactory(r.originator, r.tokenIn, r.amountIn, r.minOut, r.to);
        _setRouteState(_ROUTE_IDLE);
    }

    /// @notice Settle a PARTIAL-FILL swap after the trusted executor has funded
    ///         this factory, returning the unconsumed input to `r.refundTo`.
    /// @dev The routed counterpart to the pool's `swapUpTo`, and the reason that
    ///      function has a factory-facing form at all. `executePrefundedSwap` is
    ///      all-or-nothing: a leg sized from a quote taken two blocks ago reverts
    ///      when the band has moved under it, which is precisely the failure
    ///      partial fill exists to remove — and a revert on hop `i` of a route
    ///      takes the whole route down. This fills what the band can take and
    ///      hands the rest back, so a stale-quoted leg degrades to a smaller fill
    ///      at a price the caller already accepted.
    ///
    ///      `r.minOut` still applies to the output actually produced, so an
    ///      executor wanting all-or-nothing keeps it by setting `minOut` — this
    ///      entry point does not weaken slippage protection, it only changes what
    ///      happens to the input that did not fit. Callers chaining hops must
    ///      read `consumed`: the leftover is returned in the INPUT token, so a
    ///      router that ignores it strands funds at `refundTo` rather than
    ///      carrying them forward.
    ///
    ///      NOT AVAILABLE ON A HOOKED POOL — the pool reverts
    ///      `HookedNoPartialFill()`, because the surcharge is sampled once at the
    ///      requested size and would be wrong at the clamped one. Hooked pools
    ///      stay on `executePrefundedSwap` and are sized from the lens
    ///      (`PoolInfo.clampable`, which is exactly `hook == address(0)`).
    ///
    ///      That error name is load-bearing for anyone debugging a revert here,
    ///      and this line named `UnsupportedToken` until an audit pass caught it.
    ///      They are unrelated: `UnsupportedToken` is the pool's TOKEN-BEHAVIOUR
    ///      error, raised when a transfer does not move exactly what was asked.
    ///      Chasing it sends an integrator hunting a fee-on-transfer or rebasing
    ///      token that is not there, when the real cause is a routing choice —
    ///      this pool has a hook and cannot partial-fill, so screen it out of
    ///      `UpTo` paths rather than looking at the token at all.
    ///
    ///      Authentication, locking, and the committed intent are identical to
    ///      `executePrefundedSwap`, and deliberately share the same checkpoint:
    ///      `_routeHash` covers the `Route` calldata and NOT the selector, so one
    ///      checkpoint admits either settlement. That is safe rather than an
    ///      oversight — both entry points act only on the committed pool,
    ///      recipient, slippage, originator and refund address, so substituting
    ///      one for the other changes nothing an attacker controls, and doing it
    ///      reentrantly still strands the outer settlement on a consumed
    ///      checkpoint and reverts the transaction.
    /// @param r The route; for ERC-20 input it must match the one `checkpoint`
    ///        committed to, field for field.
    /// @return amountOut Output produced by the portion that filled.
    /// @return consumed Input actually swapped; `r.amountIn - consumed` went back
    ///         to `r.refundTo`.
    function executePrefundedSwapUpTo(Route calldata r)
        external
        payable
        returns (uint256 amountOut, uint256 consumed)
    {
        if (msg.sender != trustedExecutor) revert NotExecutor();
        _checkRoute(r);
        PrecisionPool p = PrecisionPool(payable(r.pool));
        if (r.tokenIn == address(0)) {
            // Native input is authenticated by `msg.value` and arrives with the
            // call, so it has no funding interval to guard and opens no route.
            // The pool returns the unconsumed remainder as ETH to `refundTo`.
            if (_routeState() != _ROUTE_IDLE) revert Reentrancy();
            _setRouteState(_ROUTE_SETTLING);
            if (msg.value != r.amountIn) revert Bad();
            (amountOut, consumed) = p.swapUpToFromFactory{value: r.amountIn}(
                r.originator, r.tokenIn, r.amountIn, r.minOut, r.to, r.refundTo
            );
            _setRouteState(_ROUTE_IDLE);
            return (amountOut, consumed);
        }
        if (_routeState() != _ROUTE_OPEN) revert BadCheckpoint();
        _setRouteState(_ROUTE_SETTLING);
        _consumeIntent();
        if (msg.value != 0) revert Bad();
        uint256 senderBefore = _consumeCheckpoint(r.tokenIn, r.amountIn);
        _transferExact(r.tokenIn, r.pool, r.amountIn, senderBefore);
        (amountOut, consumed) =
            p.swapUpToFromFactory(r.originator, r.tokenIn, r.amountIn, r.minOut, r.to, r.refundTo);
        _setRouteState(_ROUTE_IDLE);
    }

    function _consumeCheckpoint(address token, uint256 amount) internal returns (uint256 current) {
        bytes32 slot = _checkpointSlot(token);
        uint256 encoded;
        assembly ("memory-safe") {
            encoded := tload(slot)
            // Clear before the token receives control. A reentrant call cannot
            // consume the same route funding twice.
            tstore(slot, 0)
        }
        if (encoded == 0) revert BadCheckpoint();

        uint256 base;
        unchecked {
            base = encoded - 1;
        }
        current = token.balanceOf(address(this));
        if (current < base || current - base != amount) revert BadCheckpoint();
    }

    function _checkpointSlot(address token) internal pure returns (bytes32) {
        return bytes32(CHECKPOINT_NAMESPACE | uint256(uint160(token)));
    }

    function _pullExact(address token, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(to);
        SafeTransferLib.safeTransferFrom(token, from, to, amount);
        uint256 afterBalance = token.balanceOf(to);
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert Bad();
    }

    function _transferExact(address token, address to, uint256 amount, uint256 senderBefore) internal {
        if (amount == 0) return;
        uint256 recipientBefore = token.balanceOf(to);
        SafeTransferLib.safeTransfer(token, to, amount);
        uint256 senderAfter = token.balanceOf(address(this));
        uint256 recipientAfter = token.balanceOf(to);
        if (
            senderAfter > senderBefore || senderBefore - senderAfter != amount || recipientAfter < recipientBefore
                || recipientAfter - recipientBefore != amount
        ) revert Bad();
    }

    /// @notice Return the pool address for a market, whether deployed or not.
    function poolFor(Market calldata m) public view returns (address) {
        return _poolAddress(_marketSalt(m), keccak256(_poolInitCode(m)));
    }

    function _poolInitCode(Market calldata m) internal view returns (bytes memory) {
        return abi.encodePacked(
            SSTORE2.read(poolCode),
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
        );
    }

    function _marketSalt(Market calldata m) internal pure returns (bytes32) {
        return keccak256(abi.encode(m));
    }

    function _poolAddress(bytes32 salt, bytes32 initHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initHash)))));
    }

    function _check(Market calldata m) internal view {
        // Canonical ordering; address(0) is native ETH and sorts first, which
        // is what makes it always token0.
        if (m.token0 >= m.token1) revert Bad();
        if (m.token1.code.length == 0 || (m.token0 != address(0) && m.token0.code.length == 0)) revert Bad();
        // Bounds must be nonzero and ordered. The upper bound combines with the
        // pool's liquidity cap to keep virtual-reserve arithmetic in range.
        if (m.sqrtPLow == 0 || m.sqrtPHigh <= m.sqrtPLow || m.sqrtPHigh > MAX_SQRT_PRICE) revert Bad();
        if (m.fee >= MAX_FEE) revert Bad();
        if (m.creatorFeeBps > MAX_CREATOR_SHARE) revert Bad();
        if (m.creatorFeeBps != 0 && m.feeRecipient == address(0)) revert Bad();
        if (m.hook != address(0) && m.hook.code.length == 0) revert Bad();
    }

    function _checkCreator(Market calldata m) internal view {
        if (m.feeRecipient != address(0) && msg.sender != m.feeRecipient) revert NotCreator();
    }
}
