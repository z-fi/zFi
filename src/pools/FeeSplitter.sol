// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Ownable} from "../../lib/solady/src/auth/Ownable.sol";
import {SafeTransferLib} from "../../lib/solady/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "../../lib/solady/src/utils/ReentrancyGuard.sol";

/// @notice A payable address that can be split among several recipients later.
///
/// @dev THE POINT IS THE ADDRESS, NOT THE ARITHMETIC. `PrecisionLauncher` takes
///      its `treasury` as an IMMUTABLE constructor argument, so whatever address
///      is named at deployment is the one it pays forever. Naming a multisig
///      directly would work and would also be final: sharing protocol fees with
///      anyone later - a partner, a contributor, a second DAO - would mean
///      redeploying the launcher and abandoning every market it had already
///      created. Naming this instead keeps that decision open without giving
///      anything up today, because a one-entry split is just a forwarding
///      address.
///
///      PUSH, AND UNBRICKABLE. `release` pays everyone in a loop, so a
///      recipient that reverts on receipt would otherwise freeze the contract
///      for everybody else - and the owner is expected to add addresses it does
///      not control, which is exactly where such a recipient comes from.
///      `forceSafeTransferETH` cannot be refused, so one bad payee cannot hold
///      the others' funds hostage. That is why this is not a pull-payment
///      contract despite pull being the usual advice: the usual advice assumes
///      the payees were chosen by the person being paid.
///
///      IT TAKES TWO THINGS TO MEAN THAT, NOT ONE. Forcing the transfer only
///      answers a payee that REFUSES ether. A payee that CALLS BACK defeated
///      the same claim by a different route, and the first version of this file
///      shipped the claim without the defence: `release` snapshots the balance
///      and pays the last payee the remainder, so a reentrant payee could drain
///      the balance through an inner `release` and leave the outer one trying
///      to pay a remainder that no longer existed. Every call reverted from
///      then on, recoverable only by an owner `setSplit` - and not at all if
///      ownership had been renounced. Hence `nonReentrant`, and hence the split
///      is copied to memory before the loop so a payee that can reach the owner
///      cannot resize the arrays underneath it either.
///
///      PERMISSIONLESS TO RELEASE. Anyone may call it. There is nothing to
///      steal - the funds can only go where the owner already said they go -
///      and requiring the owner would mean a multisig ceremony per payout.
///
///      NO PENDING-BALANCE ACCOUNTING. The split applies to whatever is here
///      when `release` runs, not to what was here when it arrived. So changing
///      the split changes how the UNRELEASED balance is divided, and the owner
///      should `release` before `setSplit` if that matters. Tracking per-deposit
///      entitlement would need a claim ledger and a share-checkpoint per payee,
///      which is a different and much larger contract; this one is deliberately
///      small enough to read in a sitting.
contract FeeSplitter is Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    error Bad();

    event SplitSet(address[] payees, uint256[] shares);
    event Released(uint256 amount);
    event ReleasedERC20(address indexed token, uint256 amount);

    /// @notice Recipients, in payout order.
    address[] public payees;

    /// @notice Weights, parallel to `payees`. Relative, not percentages - the
    ///         denominator is their sum, so a two-way even split is `[1,1]` and
    ///         nothing has to add up to a magic number.
    uint256[] public shares;

    /// @notice Sum of `shares`, cached so `release` does not re-add it.
    uint256 public totalShares;

    constructor(address owner_) {
        if (owner_ == address(0)) revert Bad();
        _initializeOwner(owner_);
    }

    /// @notice Fees arrive here.
    receive() external payable {}

    /// @notice Replace the split wholesale.
    /// @dev Wholesale rather than add/remove/edit: three entry points to keep
    ///      consistent with `totalShares`, versus one that recomputes it. The
    ///      caller is a multisig assembling a transaction either way.
    function setSplit(address[] calldata payees_, uint256[] calldata shares_) external onlyOwner {
        if (payees_.length == 0 || payees_.length != shares_.length) revert Bad();
        uint256 total;
        for (uint256 i; i < payees_.length; ++i) {
            // A zero weight is a payee that would be paid nothing, and a zero
            // address is ether burned. Both are far more likely to be a
            // malformed transaction than an intention.
            if (payees_[i] == address(0) || shares_[i] == 0) revert Bad();
            total += shares_[i];
        }
        payees = payees_;
        shares = shares_;
        totalShares = total;
        emit SplitSet(payees_, shares_);
    }

    /// @notice Pay out the whole ether balance, pro rata.
    function release() external nonReentrant {
        uint256 amount = address(this).balance;
        // Read once, into memory. The loop makes external calls, and a payee
        // that can reach the owner could otherwise `setSplit` mid-payout -
        // shrinking the array into an out-of-bounds panic, or moving
        // `totalShares` so the remainder no longer matches what was paid.
        address[] memory to = payees;
        uint256[] memory w = shares;
        uint256 n = to.length;
        // Refusing here rather than paying the owner by default: an unset split
        // means nobody has said where this goes, and guessing is worse than
        // waiting. The ether stays put and the call can be repeated.
        if (n == 0) revert Bad();
        if (amount == 0) return;

        uint256 total = totalShares;
        uint256 paid;
        for (uint256 i; i < n - 1; ++i) {
            uint256 cut = (amount * w[i]) / total;
            paid += cut;
            to[i].forceSafeTransferETH(cut);
        }
        // The last payee takes the remainder rather than its own quotient, so
        // integer-division dust is paid out instead of accumulating here. With
        // a single payee this is the whole balance and the loop never runs.
        to[n - 1].forceSafeTransferETH(amount - paid);
        emit Released(amount);
    }

    /// @notice The same split, applied to an ERC-20 balance.
    /// @dev Not because the launcher pays tokens - it pays ether - but because
    ///      this address will be handed out, and an address that can receive a
    ///      token it cannot send is an address that strands it.
    function releaseERC20(address token) external nonReentrant {
        uint256 amount = token.balanceOf(address(this));
        address[] memory to = payees;
        uint256[] memory w = shares;
        uint256 n = to.length;
        if (n == 0) revert Bad();
        if (amount == 0) return;

        uint256 total = totalShares;
        uint256 paid;
        for (uint256 i; i < n - 1; ++i) {
            uint256 cut = (amount * w[i]) / total;
            paid += cut;
            // Not `force`: there is no ether-equivalent fallback for a token,
            // and a token that reverts on transfer cannot be worked around
            // here. It reverts, which is the honest outcome.
            token.safeTransfer(to[i], cut);
        }
        token.safeTransfer(to[n - 1], amount - paid);
        emit ReleasedERC20(token, amount);
    }

    /// @notice How many recipients the split has.
    /// @dev `payees` is a public array, so callers can read entries but cannot
    ///      ask how many there are without this.
    function payeeCount() external view returns (uint256) {
        return payees.length;
    }

    /// @notice The whole split in one call, for a UI.
    function split() external view returns (address[] memory, uint256[] memory) {
        return (payees, shares);
    }
}
