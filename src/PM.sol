// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title PM
/// @notice Parimutuel YES/NO markets in ETH (address(0)) or any ERC20 that holds its units.
/// Bets mint ERC6909 shares at par less a late tax ramping linearly from 0 at creation to `lateBps`
/// at close. Winners split the pot pro rata, less the resolver fee fixed at creation. With
/// `exitBps` > 0, shares sell back before close at par less the greater of `exitBps` and the late
/// tax. Taxes stay in the pot, so it always covers the shares outstanding.
/// @dev YES id = marketId (even), NO id = marketId | 1. A void (empty side at resolution, the
/// resolver at any time, or anyone after close + RESOLVE_WINDOW) splits the pot equally per share.
/// Resolvers are trusted. Deposits credit the balance that arrives. `betETH` routes through
/// zRouter with no allowance granted and refunds unspent ETH.
contract PM {
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant ZROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 public constant RESOLVE_WINDOW = 30 days;
    uint256 public constant MAX_FEE_BPS = 1_000;
    uint256 public constant MAX_TAX_BPS = 5_000;
    uint256 public constant MAX_DESCRIPTION = 1_024;

    uint256 constant LOCK_SLOT = 0x929eee149b4bd21268;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Locked();
    error NoExit();
    error Settled();
    error TooLate();
    error Slippage();
    error TooEarly();
    error BadParams();
    error AmountZero();
    error WrongAsset();
    error MarketExists();
    error Unauthorized();
    error TradingClosed();
    error MarketNotFound();
    error NothingToClaim();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Transfer(address caller, address indexed from, address indexed to, uint256 indexed id, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);
    event OperatorSet(address indexed owner, address indexed operator, bool approved);

    event Created(
        uint256 indexed marketId,
        address indexed creator,
        address indexed resolver,
        address asset,
        uint48 close,
        bool canClose,
        uint16 feeBps,
        uint16 exitBps,
        uint16 lateBps,
        string description
    );
    event Bet(uint256 indexed id, uint256 amount);
    event Exited(uint256 indexed id, uint256 amount);
    event Closed(uint256 indexed marketId);
    event Resolved(uint256 indexed marketId, bool yes, uint256 pot, uint256 fee);
    event Voided(uint256 indexed marketId);
    event Claimed(uint256 indexed marketId, address indexed to, uint256 amount);
    event ResolverFeeSet(address indexed resolver, uint16 bps);
    event FeesWithdrawn(address indexed resolver, address indexed asset, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    enum State {
        Open,
        Yes,
        No,
        Void
    }

    struct Market {
        address resolver;
        uint48 close;
        uint16 feeBps;
        uint16 exitBps;
        bool canClose;
        State state;
        address asset;
        uint48 open;
        uint16 lateBps;
        uint256 pot; // collateral held; once settled, what claimants split
        uint256 winners; // shares that split `pot` once settled
    }

    struct MarketView {
        uint256 marketId;
        address resolver;
        address asset;
        uint48 open;
        uint48 close;
        uint16 feeBps;
        uint16 exitBps;
        uint16 lateBps;
        bool canClose;
        State state;
        uint256 yes;
        uint256 no;
        uint256 pot;
        uint256 winners;
        string description;
    }

    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public allowance;
    mapping(address => mapping(address => bool)) public isOperator;
    mapping(uint256 id => uint256) public totalSupply;

    mapping(address resolver => uint16) public resolverFeeBps;
    mapping(address resolver => mapping(address asset => uint256)) public feesOwed;

    uint256[] allMarkets;
    mapping(address creator => uint256[]) marketsBy;
    mapping(uint256 marketId => Market) markets;
    mapping(uint256 marketId => string) descriptions;

    /*//////////////////////////////////////////////////////////////
                                  GUARD
    //////////////////////////////////////////////////////////////*/

    modifier lock() {
        assembly ("memory-safe") {
            if tload(LOCK_SLOT) {
                mstore(0x00, 0x0f2e5b6c) // Locked()
                revert(0x1c, 0x04)
            }
            tstore(LOCK_SLOT, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(LOCK_SLOT, 0)
        }
    }

    /// @dev Only mid-route, for zRouter refunds.
    receive() external payable {
        assembly ("memory-safe") {
            if iszero(tload(LOCK_SLOT)) { revert(0x00, 0x00) }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 MARKETS
    //////////////////////////////////////////////////////////////*/

    function getMarketId(
        address creator,
        string calldata description,
        address resolver,
        address asset,
        uint48 close,
        bool canClose,
        uint16 exitBps,
        uint16 lateBps
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(creator, description, resolver, asset, close, canClose, exitBps, lateBps)))
            & ~uint256(1);
    }

    /// @param asset address(0) for ETH.
    /// @param exitBps 0 makes bets final.
    function createMarket(
        string calldata description,
        address resolver,
        address asset,
        uint48 close,
        bool canClose,
        uint16 exitBps,
        uint16 lateBps
    ) public returns (uint256 marketId) {
        require(
            close > block.timestamp && exitBps <= MAX_TAX_BPS && lateBps <= MAX_TAX_BPS && resolver != address(0)
                && resolver != address(this) && bytes(description).length != 0
                && bytes(description).length <= MAX_DESCRIPTION,
            BadParams()
        );
        require(asset == address(0) || asset.code.length != 0, WrongAsset());

        marketId = getMarketId(msg.sender, description, resolver, asset, close, canClose, exitBps, lateBps);
        Market storage m = markets[marketId];
        require(m.resolver == address(0), MarketExists());

        uint16 feeBps = resolverFeeBps[resolver];
        m.resolver = resolver;
        m.close = close;
        m.feeBps = feeBps;
        m.exitBps = exitBps;
        m.canClose = canClose;
        m.asset = asset;
        m.open = uint48(block.timestamp);
        m.lateBps = lateBps;

        allMarkets.push(marketId);
        marketsBy[msg.sender].push(marketId);
        descriptions[marketId] = description;

        emit Created(marketId, msg.sender, resolver, asset, close, canClose, feeBps, exitBps, lateBps, description);
    }

    /// @notice Fee the caller takes as resolver on markets created from now on.
    function setResolverFeeBps(uint16 bps) public {
        require(bps <= MAX_FEE_BPS, BadParams());
        resolverFeeBps[msg.sender] = bps;
        emit ResolverFeeSet(msg.sender, bps);
    }

    /*//////////////////////////////////////////////////////////////
                                  BETS
    //////////////////////////////////////////////////////////////*/

    /// @param minShares Floor on shares minted, after late tax and any transfer fee.
    function bet(uint256 marketId, bool yes, uint256 amount, address to, uint256 minShares)
        public
        lock
        returns (uint256)
    {
        (Market storage m, address asset) = _openERC20(marketId);
        return _pull(m, marketId, asset, yes, amount, to, minShares);
    }

    /// @dev A failed permit is ignored; the allowance must then exist.
    function betWithPermit(
        uint256 marketId,
        bool yes,
        uint256 amount,
        address to,
        uint256 minShares,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public lock returns (uint256) {
        (Market storage m, address asset) = _openERC20(marketId);
        try IERC2612(asset).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        return _pull(m, marketId, asset, yes, amount, to, minShares);
    }

    function betWithPermit2(
        uint256 marketId,
        bool yes,
        uint256 amount,
        address to,
        uint256 minShares,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) public lock returns (uint256) {
        (Market storage m, address asset) = _openERC20(marketId);
        uint256 before = asset.balanceOf(address(this));
        IPermit2(PERMIT2)
            .permitTransferFrom(
                IPermit2.PermitTransferFrom(IPermit2.TokenPermissions(asset, amount), nonce, deadline),
                IPermit2.SignatureTransferDetails(address(this), amount),
                msg.sender,
                signature
            );
        return _credit(m, marketId, yes, asset.balanceOf(address(this)) - before, to, minShares);
    }

    /// @param route zRouter calldata delivering the asset here. Empty: Lido for wstETH; required for ETH.
    /// @param minShares Floor on shares minted, after route price and late tax.
    function betETH(uint256 marketId, bool yes, address to, uint256 minShares, bytes calldata route)
        public
        payable
        lock
        returns (uint256 shares)
    {
        require(msg.value != 0, AmountZero());
        Market storage m = _open(marketId);
        address asset = m.asset;
        uint256 amount = msg.value;

        if (asset == address(0)) {
            require(route.length == 0, WrongAsset());
        } else {
            uint256 ethBefore = address(this).balance - msg.value;
            uint256 before = asset.balanceOf(address(this));
            bool ok;
            bytes memory ret;
            if (route.length != 0) {
                (ok, ret) = ZROUTER.call{value: msg.value}(route);
            } else {
                require(asset == WSTETH, WrongAsset());
                (ok, ret) = ZROUTER.call{value: msg.value}(abi.encodeCall(IZRouter.exactETHToWSTETH, (address(this))));
            }
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            amount = asset.balanceOf(address(this)) - before;
            uint256 refund = address(this).balance - ethBefore;
            if (refund != 0) msg.sender.safeTransferETH(refund);
        }

        return _credit(m, marketId, yes, amount, to, minShares);
    }

    /// @notice Sells shares back before close at par less max(exitBps, late tax).
    function exit(uint256 marketId, bool yes, uint256 shares, address to) public lock returns (uint256 amount) {
        Market storage m = _open(marketId);
        uint256 exitBps = m.exitBps;
        require(exitBps != 0, NoExit());
        if (to == address(0)) to = msg.sender;

        uint256 id = yes ? marketId : marketId | 1;
        _burn(msg.sender, id, shares);
        amount = _net(m, shares, exitBps);
        require(amount != 0, AmountZero());
        m.pot -= amount;

        _send(m.asset, to, amount);
        emit Exited(id, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               RESOLUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Resolver only, on `canClose` markets.
    function closeMarket(uint256 marketId) public lock {
        Market storage m = _open(marketId);
        require(msg.sender == m.resolver && m.canClose, Unauthorized());
        m.close = uint48(block.timestamp);
        emit Closed(marketId);
    }

    /// @notice Resolver only, within RESOLVE_WINDOW after close. An empty side voids, fee-free.
    function resolve(uint256 marketId, bool yes) public lock {
        Market storage m = markets[marketId];
        require(msg.sender == m.resolver, Unauthorized());
        require(m.state == State.Open, Settled());
        uint256 close = m.close;
        require(block.timestamp >= close, TooEarly());
        require(block.timestamp < close + RESOLVE_WINDOW, TooLate());

        uint256 y = totalSupply[marketId];
        uint256 n = totalSupply[marketId | 1];
        if (y == 0 || n == 0) return _void(m, marketId);

        uint256 pot = m.pot;
        uint256 fee = pot * m.feeBps / 10_000;
        m.state = yes ? State.Yes : State.No;
        pot -= fee;
        m.pot = pot;
        m.winners = yes ? y : n;
        if (fee != 0) feesOwed[msg.sender][m.asset] += fee;

        emit Resolved(marketId, yes, pot, fee);
    }

    /// @notice Resolver any time; anyone after close + RESOLVE_WINDOW.
    function void(uint256 marketId) public lock {
        Market storage m = markets[marketId];
        require(m.resolver != address(0), MarketNotFound());
        require(m.state == State.Open, Settled());
        if (msg.sender != m.resolver) require(block.timestamp >= m.close + RESOLVE_WINDOW, TooEarly());
        _void(m, marketId);
    }

    /// @notice Winning shares take the pot pro rata; if void, every share does.
    function claim(uint256 marketId, address to) public lock returns (uint256 amount) {
        Market storage m = markets[marketId];
        State state = m.state;
        require(state != State.Open, TooEarly());
        if (to == address(0)) to = msg.sender;

        uint256 shares;
        if (state == State.Void) {
            shares = _burnAll(msg.sender, marketId) + _burnAll(msg.sender, marketId | 1);
        } else {
            shares = _burnAll(msg.sender, state == State.Yes ? marketId : marketId | 1);
        }
        require(shares != 0, NothingToClaim());

        amount = shares.fullMulDiv(m.pot, m.winners);
        require(amount != 0, NothingToClaim());
        _send(m.asset, to, amount);
        emit Claimed(marketId, to, amount);
    }

    function withdrawFees(address asset, address to) public lock returns (uint256 amount) {
        amount = feesOwed[msg.sender][asset];
        require(amount != 0, NothingToClaim());
        if (to == address(0)) to = msg.sender;
        feesOwed[msg.sender][asset] = 0;
        _send(asset, to, amount);
        emit FeesWithdrawn(msg.sender, asset, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function marketCount() public view returns (uint256) {
        return allMarkets.length;
    }

    function marketCountBy(address creator) public view returns (uint256) {
        return marketsBy[creator].length;
    }

    function getMarket(uint256 marketId) public view returns (MarketView memory v) {
        marketId &= ~uint256(1);
        Market storage m = markets[marketId];
        v.marketId = marketId;
        v.resolver = m.resolver;
        v.asset = m.asset;
        v.open = m.open;
        v.close = m.close;
        v.feeBps = m.feeBps;
        v.exitBps = m.exitBps;
        v.lateBps = m.lateBps;
        v.canClose = m.canClose;
        v.state = m.state;
        v.yes = totalSupply[marketId];
        v.no = totalSupply[marketId | 1];
        v.pot = m.pot;
        v.winners = m.winners;
        v.description = descriptions[marketId];
    }

    /// @notice Newest first; `start` counts back from the newest.
    function getMarkets(uint256 start, uint256 count) public view returns (MarketView[] memory, uint256 next) {
        return _page(allMarkets, start, count);
    }

    /// @notice One creator's markets, newest first.
    function getMarketsBy(address creator, uint256 start, uint256 count)
        public
        view
        returns (MarketView[] memory, uint256 next)
    {
        return _page(marketsBy[creator], start, count);
    }

    function positions(address user, uint256[] calldata marketIds)
        public
        view
        returns (uint256[] memory yes, uint256[] memory no, uint256[] memory claimable)
    {
        uint256 len = marketIds.length;
        yes = new uint256[](len);
        no = new uint256[](len);
        claimable = new uint256[](len);
        for (uint256 i; i != len; ++i) {
            uint256 marketId = marketIds[i] & ~uint256(1);
            Market storage m = markets[marketId];
            uint256 y = balanceOf[user][marketId];
            uint256 n = balanceOf[user][marketId | 1];
            yes[i] = y;
            no[i] = n;
            State state = m.state;
            uint256 s = state == State.Void ? y + n : state == State.Yes ? y : state == State.No ? n : 0;
            if (s != 0) claimable[i] = s.fullMulDiv(m.pot, m.winners);
        }
    }

    /// @notice Shares a bet of `amount` mints now, and its payout if `yes` wins and nothing else is bet.
    function quote(uint256 marketId, bool yes, uint256 amount) public view returns (uint256 shares, uint256 payout) {
        Market storage m = markets[marketId];
        if (m.state != State.Open || block.timestamp >= m.close) return (0, 0);
        shares = _net(m, amount, 0);
        if (shares == 0) return (0, 0);
        uint256 pot = m.pot + amount;
        payout = shares.fullMulDiv(pot - pot * m.feeBps / 10_000, totalSupply[yes ? marketId : marketId | 1] + shares);
    }

    /*//////////////////////////////////////////////////////////////
                                 ERC6909
    //////////////////////////////////////////////////////////////*/

    /// @notice Shares carry their market asset's decimals.
    function decimals(uint256 id) public view returns (uint8) {
        address asset = markets[id & ~uint256(1)].asset;
        if (asset == address(0)) return 18;
        (bool ok, bytes memory ret) = asset.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || ret.length < 32) return 18;
        uint256 d = abi.decode(ret, (uint256));
        return d > 255 ? 18 : uint8(d);
    }

    function transfer(address receiver, uint256 id, uint256 amount) public returns (bool) {
        balanceOf[msg.sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, msg.sender, receiver, id, amount);
        return true;
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) public returns (bool) {
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowance[sender][msg.sender][id];
            if (allowed != type(uint256).max) allowance[sender][msg.sender][id] = allowed - amount;
        }
        balanceOf[sender][id] -= amount;
        balanceOf[receiver][id] += amount;
        emit Transfer(msg.sender, sender, receiver, id, amount);
        return true;
    }

    function approve(address spender, uint256 id, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender][id] = amount;
        emit Approval(msg.sender, spender, id, amount);
        return true;
    }

    function setOperator(address operator, bool approved) public returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x0f632fb3;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _open(uint256 marketId) internal view returns (Market storage m) {
        m = markets[marketId];
        require(m.state == State.Open && block.timestamp < m.close, TradingClosed());
    }

    function _openERC20(uint256 marketId) internal view returns (Market storage m, address asset) {
        m = _open(marketId);
        asset = m.asset;
        require(asset != address(0), WrongAsset());
    }

    function _pull(
        Market storage m,
        uint256 marketId,
        address asset,
        bool yes,
        uint256 amount,
        address to,
        uint256 minShares
    ) internal returns (uint256) {
        uint256 before = asset.balanceOf(address(this));
        asset.safeTransferFrom(msg.sender, address(this), amount);
        return _credit(m, marketId, yes, asset.balanceOf(address(this)) - before, to, minShares);
    }

    function _credit(Market storage m, uint256 marketId, bool yes, uint256 amount, address to, uint256 minShares)
        internal
        returns (uint256 shares)
    {
        shares = _net(m, amount, 0);
        require(shares != 0, AmountZero());
        require(shares >= minShares, Slippage());
        if (to == address(0)) to = msg.sender;
        m.pot += amount;
        uint256 id = yes ? marketId : marketId | 1;
        balanceOf[to][id] += shares;
        totalSupply[id] += shares;
        emit Transfer(msg.sender, address(0), to, id, shares);
        emit Bet(id, amount);
    }

    /// @dev `amount` less the greater of `minBps` and the late tax, rounded in the pot's favor.
    /// Trading must be open, so open <= now < close.
    function _net(Market storage m, uint256 amount, uint256 minBps) internal view returns (uint256) {
        uint256 open = m.open;
        uint256 span = m.close - open;
        uint256 tax = m.lateBps * (block.timestamp - open);
        if (tax < minBps * span) tax = minBps * span;
        return amount.fullMulDiv(10_000 * span - tax, 10_000 * span);
    }

    /// @dev A pot with no shares left goes to the resolver.
    function _void(Market storage m, uint256 marketId) internal {
        uint256 shares = totalSupply[marketId] + totalSupply[marketId | 1];
        m.state = State.Void;
        m.winners = shares;
        if (shares == 0 && m.pot != 0) {
            feesOwed[m.resolver][m.asset] += m.pot;
            m.pot = 0;
        }
        emit Voided(marketId);
    }

    function _burn(address from, uint256 id, uint256 amount) internal {
        balanceOf[from][id] -= amount;
        totalSupply[id] -= amount;
        emit Transfer(msg.sender, from, address(0), id, amount);
    }

    function _burnAll(address from, uint256 id) internal returns (uint256 amount) {
        amount = balanceOf[from][id];
        if (amount != 0) _burn(from, id, amount);
    }

    function _send(address asset, address to, uint256 amount) internal {
        if (asset == address(0)) to.safeTransferETH(amount);
        else asset.safeTransfer(to, amount);
    }

    function _page(uint256[] storage list, uint256 start, uint256 count)
        internal
        view
        returns (MarketView[] memory page, uint256 next)
    {
        uint256 len = list.length;
        if (start >= len) return (page, 0);
        uint256 n = len - start;
        if (count < n) n = count;
        page = new MarketView[](n);
        for (uint256 i; i != n; ++i) {
            page[i] = getMarket(list[len - 1 - start - i]);
        }
        next = start + n < len ? start + n : 0;
    }
}

interface IERC2612 {
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}

interface IPermit2 {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

interface IZRouter {
    function exactETHToWSTETH(address to) external payable returns (uint256);
}
