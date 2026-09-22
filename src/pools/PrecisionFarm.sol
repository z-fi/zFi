// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {PrecisionPool} from "./PrecisionPool.sol";
import {PrecisionPoolFactory} from "./PrecisionPoolFactory.sol";
import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "../../lib/solady/src/utils/FixedPointMathLib.sol";

interface IERC20Permit {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

/// @title PrecisionFarm
/// @notice Streams a reward token to stakers of one ETH/ERC-20 PrecisionPool's
///         LP shares. Zaps turn ETH, the pool's token, or both into staked
///         shares in one transaction, with EIP-2612 permits standing in for
///         approvals on the token and on the LP shares.
/// @dev Rewards follow the StakingRewards accumulator, with the schedule
///      split in two: the owner sets only the RATE, and the balance sets the
///      runway. Reward tokens sent to the farm are streamed by `sync` at the
///      current rate, extending the finish, so funding is a plain transfer.
///      `reserved` is every reward unit the farm has scheduled or owes, so
///      only balance above it is free to stream or recover. Emission that
///      falls in a stretch with nothing staked is released back out of
///      `reserved` and streams again on the next sync.
///
///      Every amount the farm moves for a caller is taken from the pool's own
///      return values, never from `balanceOf`: the reward token may also be the
///      pool's token, and the farm's balance of it is mostly other people's
///      rewards.
contract PrecisionFarm {
    using SafeTransferLib for address;

    uint256 constant WAD = 1e18;
    uint256 constant FEE_DENOM = 1_000_000;
    uint256 constant REENTRANCY_SLOT = 0x5f1a2c3e;
    /// @dev A rate change may not bring a running window's end closer than this
    ///      (or than its current end, if that is sooner).
    uint256 constant MIN_RUNWAY = 7 days;

    PrecisionPool public immutable pool;
    /// @notice The pool's ERC-20 side (token1). Token0 is native ETH.
    address public immutable token;
    address public immutable rewardToken;

    address public owner;
    address public pendingOwner;

    /// @notice Reward units per second while a window is running.
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdate;
    uint256 public rewardPerShareStored;
    uint256 public reserved;

    uint256 public totalStaked;
    mapping(address => uint256) public staked;
    mapping(address => uint256) public rewardPerSharePaid;
    mapping(address => uint256) public rewards;

    error Bad();
    error Expired();
    error NotOwner();
    error Reentrancy();
    error Underfunded();
    error NoLiquidity();
    error Slippage();

    event Staked(address indexed user, uint256 shares);
    event Withdrawn(address indexed user, uint256 shares);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward, uint256 finish);
    event RateSet(uint256 rate, uint256 finish);
    event Zapped(address indexed user, uint256 ethIn, uint256 tokenIn, uint256 shares);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    constructor(PrecisionPool pool_, address rewardToken_, address owner_, uint256 rate) {
        if (owner_ == address(0) || rewardToken_.code.length == 0 || rewardToken_ == address(pool_) || rate == 0) {
            revert Bad();
        }
        if (!PrecisionPoolFactory(pool_.factory()).isPool(address(pool_))) revert Bad();
        // The zap's swap sizing assumes the whole input stays in reserves,
        // which holds only with no hook surcharge and no creator cut.
        if (pool_.token0() != address(0) || pool_.hook() != address(0) || pool_.creatorFeeBps() != 0) revert Bad();
        (pool, token, rewardToken, owner, rewardRate) = (pool_, pool_.token1(), rewardToken_, owner_, rate);
        emit OwnershipTransferred(address(0), owner_);
        emit RateSet(rate, 0);
    }

    modifier nonReentrant() {
        uint256 slot = REENTRANCY_SLOT;
        uint256 active;
        assembly ("memory-safe") {
            active := tload(slot)
            tstore(slot, 1)
        }
        if (active != 0) revert Reentrancy();
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier before(uint256 deadline) {
        if (block.timestamp > deadline) revert Expired();
        _;
    }

    /// @dev ETH arrives only as swap output or an unused-deposit refund.
    receive() external payable {
        if (msg.sender != address(pool)) revert Bad();
    }

    // ----------------------------------------------------------------- VIEWS

    function lastTimeRewardApplicable() public view returns (uint256) {
        return FixedPointMathLib.min(block.timestamp, periodFinish);
    }

    function rewardPerShare() public view returns (uint256) {
        uint256 supply = totalStaked;
        if (supply == 0) return rewardPerShareStored;
        return rewardPerShareStored
            + FixedPointMathLib.fullMulDiv((lastTimeRewardApplicable() - lastUpdate) * rewardRate, WAD, supply);
    }

    function earned(address user) public view returns (uint256) {
        return rewards[user]
            + FixedPointMathLib.fullMulDiv(staked[user], rewardPerShare() - rewardPerSharePaid[user], WAD);
    }

    /// @notice How much of `amountIn` a single-sided zap swaps so the two
    ///         halves land in the pool's reserve ratio.
    /// @dev Swapping `s` of the input side leaves the caller holding
    ///      `(a - s, out)` against real reserves `(rIn + s, rOut - out)`, where
    ///      `out = g·s·Y / (X + g·s)` over virtual-plus-real reserves X, Y and
    ///      fee factor g. Equating the two ratios and dividing through by rOut:
    ///
    ///        g·s² + (a·g·vOut/rOut + X + g·Y·rIn/rOut)·s - a·X = 0
    ///
    ///      scaled here by FEE_DENOM so g stays integral. The pool's own
    ///      rounding differs from this by dust, which the deposit refunds.
    function swapAmountFor(bool ethIn, uint256 amountIn) public view returns (uint256 s) {
        uint256 supply = pool.totalSupply();
        uint256 r0 = pool.reserve0();
        uint256 r1 = pool.reserve1();
        if (supply == 0 || r0 == 0 || r1 == 0) revert NoLiquidity();
        uint256 v0 = supply * WAD / pool.sqrtPHigh();
        uint256 v1 = supply * pool.sqrtPLow() / WAD;
        (uint256 rIn, uint256 rOut, uint256 vIn, uint256 vOut) = ethIn ? (r0, r1, v0, v1) : (r1, r0, v1, v0);
        uint256 x = rIn + vIn;
        uint256 y = rOut + vOut;
        uint256 g = FEE_DENOM - pool.fee();
        uint256 b = FixedPointMathLib.fullMulDiv(amountIn * g, vOut, rOut) + FEE_DENOM * x
            + FixedPointMathLib.fullMulDiv(y * g, rIn, rOut);
        uint256 disc = b * b + 4 * g * FEE_DENOM * amountIn * x;
        s = (FixedPointMathLib.sqrt(disc) - b) / (2 * g);
        if (s >= amountIn) s = amountIn - 1;
    }

    // --------------------------------------------------------------- STAKING

    /// @notice Stake LP shares already held.
    function stake(uint256 shares) public nonReentrant {
        address(pool).safeTransferFrom(msg.sender, address(this), shares);
        _stake(msg.sender, shares);
    }

    function stakeWithPermit(uint256 shares, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        _permit(address(pool), shares, deadline, v, r, s);
        stake(shares);
    }

    function withdraw(uint256 shares) public nonReentrant {
        _unstake(msg.sender, shares);
        address(pool).safeTransfer(msg.sender, shares);
    }

    function claim() public nonReentrant {
        _claim(msg.sender);
    }

    /// @notice Withdraw every staked share and claim.
    function exit() external {
        withdraw(staked[msg.sender]);
        claim();
    }

    /// @notice Unstake and redeem straight to ETH and the token.
    function withdrawAndRemove(uint256 shares, uint256 min0, uint256 min1, uint256 deadline)
        public
        nonReentrant
        before(deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        _unstake(msg.sender, shares);
        (amount0, amount1) = pool.removeLiquidity(shares, min0, min1, msg.sender);
    }

    /// @notice Unstake everything, redeem it, and claim.
    function exitAndRemove(uint256 min0, uint256 min1, uint256 deadline)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = withdrawAndRemove(staked[msg.sender], min0, min1, deadline);
        claim();
    }

    /// @notice Unstake, redeem, and swap one side into the other, so the
    ///         caller receives only ETH (`toETH`) or only the token.
    /// @dev A leg the pool cannot fill - dust that prices to nothing, or a
    ///      size that would leave the band - is paid out as it is instead.
    /// @param minOut Floor on the total of the chosen asset received.
    function withdrawTo(bool toETH, uint256 shares, uint256 minOut, uint256 deadline)
        public
        nonReentrant
        before(deadline)
        returns (uint256 out)
    {
        _unstake(msg.sender, shares);
        (uint256 amount0, uint256 amount1) = pool.removeLiquidity(shares, 0, 0, address(this));
        if (toETH) {
            if (_fills(token, amount1)) {
                token.safeApprove(address(pool), amount1);
                out = pool.swapExactIn(token, amount1, 0, address(this));
            } else if (amount1 != 0) {
                token.safeTransfer(msg.sender, amount1);
            }
            out += amount0;
            if (out < minOut) revert Slippage();
            msg.sender.safeTransferETH(out);
        } else {
            if (_fills(address(0), amount0)) {
                out = pool.swapExactIn{value: amount0}(address(0), amount0, 0, address(this));
            } else if (amount0 != 0) {
                msg.sender.safeTransferETH(amount0);
            }
            out += amount1;
            if (out < minOut) revert Slippage();
            token.safeTransfer(msg.sender, out);
        }
    }

    /// @notice Unstake everything into one asset, and claim.
    function exitTo(bool toETH, uint256 minOut, uint256 deadline) external returns (uint256 out) {
        out = withdrawTo(toETH, staked[msg.sender], minOut, deadline);
        claim();
    }

    // ------------------------------------------------------------------ ZAPS

    /// @notice Deposit ETH and the token in the pool's ratio and stake the
    ///         shares. Whatever the pool does not use is returned.
    function addAndStake(uint256 amount, uint256 minShares, uint256 deadline)
        public
        payable
        nonReentrant
        before(deadline)
        returns (uint256 shares)
    {
        token.safeTransferFrom(msg.sender, address(this), amount);
        shares = _provide(msg.value, amount, minShares);
        emit Zapped(msg.sender, msg.value, amount, shares);
    }

    function addAndStakeWithPermit(uint256 amount, uint256 minShares, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        payable
        returns (uint256)
    {
        _permit(token, amount, deadline, v, r, s);
        return addAndStake(amount, minShares, deadline);
    }

    /// @notice Provide from ETH alone: swap part of it for the token, deposit
    ///         both, stake.
    /// @param minOut Floor on the swap leg's token output.
    function zapETH(uint256 minOut, uint256 minShares, uint256 deadline)
        external
        payable
        nonReentrant
        before(deadline)
        returns (uint256 shares)
    {
        if (msg.value < 2) revert Bad();
        uint256 s = swapAmountFor(true, msg.value);
        uint256 out = pool.swapExactIn{value: s}(address(0), s, minOut, address(this));
        shares = _provide(msg.value - s, out, minShares);
        emit Zapped(msg.sender, msg.value, 0, shares);
    }

    /// @notice Provide from the token alone: swap part of it for ETH, deposit
    ///         both, stake.
    /// @param minOut Floor on the swap leg's ETH output.
    function zapToken(uint256 amount, uint256 minOut, uint256 minShares, uint256 deadline)
        public
        nonReentrant
        before(deadline)
        returns (uint256 shares)
    {
        if (amount < 2) revert Bad();
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 s = swapAmountFor(false, amount);
        token.safeApprove(address(pool), s);
        uint256 out = pool.swapExactIn(token, s, minOut, address(this));
        shares = _provide(out, amount - s, minShares);
        emit Zapped(msg.sender, 0, amount, shares);
    }

    function zapTokenWithPermit(
        uint256 amount,
        uint256 minOut,
        uint256 minShares,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256) {
        _permit(token, amount, deadline, v, r, s);
        return zapToken(amount, minOut, minShares, deadline);
    }

    // ----------------------------------------------------------------- OWNER

    /// @notice Stream reward-token balance that has arrived since the last
    ///         sync, at the current rate. Permissionless: a top-up is a plain
    ///         transfer followed by this, by anyone.
    /// @dev The runway extends from the current finish, or restarts from now
    ///      if the window has ended. Only whole seconds are scheduled; a
    ///      remainder below one second of emission stays free for the next
    ///      top-up.
    function sync() public nonReentrant returns (uint256 added) {
        _update(address(0));
        uint256 rate = rewardRate;
        uint256 secs = (rewardToken.balanceOf(address(this)) - reserved) / rate;
        if (secs == 0) return 0;
        added = secs * rate;
        reserved += added;
        uint256 finish = periodFinish;
        if (block.timestamp >= finish) {
            finish = block.timestamp;
            lastUpdate = block.timestamp;
        }
        periodFinish = finish + secs;
        emit RewardAdded(added, finish + secs);
    }

    /// @notice Pull `amount` of the reward token from the caller and stream it.
    function fund(uint256 amount) external returns (uint256) {
        rewardToken.safeTransferFrom(msg.sender, address(this), amount);
        return sync();
    }

    /// @notice Change the emission rate. What is still scheduled is re-timed
    ///         at the new rate, not added to or taken from.
    /// @dev Only the sub-second remainder of the re-timed schedule is
    ///      released. A raise may not pull a running window's end in below
    ///      `MIN_RUNWAY`, so scheduled rewards cannot be collapsed into a
    ///      moment and handed to whoever is staked then.
    function setRate(uint256 rate) external onlyOwner nonReentrant {
        if (rate == 0) revert Bad();
        _update(address(0));
        uint256 finish = periodFinish;
        if (block.timestamp < finish) {
            uint256 left = (finish - block.timestamp) * rewardRate;
            uint256 secs = left / rate;
            if (secs < FixedPointMathLib.min(finish - block.timestamp, MIN_RUNWAY)) revert Bad();
            reserved -= left - secs * rate;
            periodFinish = block.timestamp + secs;
        }
        rewardRate = rate;
        emit RateSet(rate, periodFinish);
    }

    /// @notice Return stray tokens or ETH. Staked shares and reserved rewards
    ///         are not reachable.
    function recover(address asset, address to, uint256 amount) external onlyOwner nonReentrant {
        if (asset == address(pool)) revert Bad();
        if (asset == address(0)) return to.safeTransferETH(amount);
        if (asset == rewardToken) {
            _update(address(0));
            if (amount > rewardToken.balanceOf(address(this)) - reserved) revert Underfunded();
        }
        asset.safeTransfer(to, amount);
    }

    function transferOwnership(address to) external onlyOwner {
        emit OwnershipTransferStarted(owner, pendingOwner = to);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, msg.sender);
        (owner, pendingOwner) = (msg.sender, address(0));
    }

    // -------------------------------------------------------------- INTERNAL

    function _update(address user) internal {
        uint256 applicable = lastTimeRewardApplicable();
        if (totalStaked == 0 && applicable > lastUpdate) reserved -= (applicable - lastUpdate) * rewardRate;
        rewardPerShareStored = rewardPerShare();
        lastUpdate = applicable;
        if (user != address(0)) {
            rewards[user] = earned(user);
            rewardPerSharePaid[user] = rewardPerShareStored;
        }
    }

    function _stake(address user, uint256 shares) internal {
        if (shares == 0) revert Bad();
        _update(user);
        totalStaked += shares;
        staked[user] += shares;
        emit Staked(user, shares);
    }

    function _unstake(address user, uint256 shares) internal {
        if (shares == 0) revert Bad();
        _update(user);
        staked[user] -= shares;
        totalStaked -= shares;
        emit Withdrawn(user, shares);
    }

    function _claim(address user) internal {
        _update(user);
        uint256 reward = rewards[user];
        if (reward == 0) return;
        rewards[user] = 0;
        reserved -= reward;
        rewardToken.safeTransfer(user, reward);
        emit RewardPaid(user, reward);
    }

    /// @dev Deposits `eth` and `amount` held by the farm, stakes the shares
    ///      for the caller and returns what the pool left unused.
    function _provide(uint256 eth, uint256 amount, uint256 minShares) internal returns (uint256 shares) {
        token.safeApprove(address(pool), amount);
        uint256 used0;
        uint256 used1;
        (shares, used0, used1) = pool.addLiquidityExact{value: eth}(0, eth, amount, minShares, address(this));
        _stake(msg.sender, shares);
        if (amount > used1) token.safeTransfer(msg.sender, amount - used1);
        if (eth > used0) msg.sender.safeTransferETH(eth - used0);
    }

    function _fills(address tokenIn, uint256 amount) internal view returns (bool fits) {
        if (amount != 0) (, fits) = pool.quoteExactIn(address(this), tokenIn, amount);
    }

    /// @dev A permit that was already spent - front-run from the mempool, say -
    ///      is not a failure if the allowance it granted is still there.
    function _permit(address asset, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) internal {
        try IERC20Permit(asset).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
    }
}
