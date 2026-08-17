// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title zSwap v0.1
/// @notice Permanently-deployed onchain HTML swap dapp for Ethereum mainnet.
/// @dev Architecture: the HTML payload (240945 B) is the runtime bytecode of
///      15 data contracts, deployed separately and passed to the constructor.
///      html() reassembles them via EXTCODECOPY with proper ABI encoding
///      (offset + length + padded data) so any RPC client decodes directly.
///      request() implements ERC-5219 for first-class web3:// gateway
///      compatibility (ERC-4804). Splitting the page across 10 data contracts
///      means EIP-170 caps each chunk, not the dapp
///      (24576 B per chunk, 4815 B headroom).
///
///      The count is a headroom decision, not a hard requirement, but it can
///      only be chosen once for a given deployment: it is fixed in the
///      constructor arity, and the deployed page is immutable. The history is
///      the argument for the size of this one. Seven was chosen at 165 KB and
///      was spent by the liquidity panel, the price tape and the V4 routing.
///      Eight replaced it and never held at all - the page passed that ceiling
///      before the count reached a deployment. Fourteen was sized to the
///      observed rate of growth instead and lasted one release. Fifteen
///      followed it, at 350 KB and 97% full.
///
///      Nine is not a continuation of that series. The page source carried its
///      own documentation - about 45% of it - and that was being deployed too;
///      stripping it took 354 KB to 198 KB, which is what makes a smaller count
///      possible at all. It costs six data-contract deployments per version.
///
///      IT ALSO SPENDS THE SLACK. Every earlier count had comments in it, so a
///      page against its ceiling could always be cut back without touching a
///      feature. That valve is gone: 198 KB is the page itself, 89% of what
///      ten chunks hold, and the next ~23 KB of growth needs a larger count -
///      which means a new wrapper, a new salt and a new address.
///
///      The count cannot simply be padded, either: every chunk must be
///      non-empty and distinct (see the constructor below), so a count far
///      above what the page needs does not deploy. That is the real bound on
///      this number - not caution, but the fact that 9 chunks require a page
///      of at least 9 bytes' worth of distinct slices and, more practically,
///      that ceil(len/9) must stay under EIP-170 while len/9 stays non-zero.
///
/// HOW TO READ THE DAPP
///   cast call <addr> "html()(string)" --rpc-url <rpc> > zSwap.html
///   # then open zSwap.html in any browser
///
/// HOW TO BROWSE THE DAPP
///   - Via an ERC-4804 web3:// HTTP gateway, e.g.:
///       https://<addr>.1.w3link.io/
///   - Via a w4eth gateway. ERC-8244 resolves any contract exposing html()
///     directly as a web page, which this contract does, so no ERC-5219
///     support is required on the gateway side:
///       https://<addr>.w4eth.io/
///     e.g. https://0x000000000000888741b254d37e1b27128afeaabc.w4eth.io/
///   - Via a wallet/browser with web3:// protocol support (e.g. the
///     Web3URL Browser Extension on Chrome/Firefox/Brave).
///   - Or via the "HOW TO READ THE DAPP" path above.
///
/// HOW TO REGENERATE FROM zSwap.html
///   node script/build-zSwap.mjs             (size natspec, READMEs, test pins)
///   node script/build-zSwap-chunks.mjs      (per-chunk deployable initcode)
///   node script/build-zSwapRegistry-call.mjs (registry calldata embeds the page)
///   node script/check-zSwap.mjs             (syntax, ids, decoder vs fixtures)
///   forge test --match-path "test/zSwap*"
///   Skipping the third step leaves script/zSwapRegistry-*.calldata.txt pinned
///   to a stale page; test/zSwapRegistry.t.sol fails on exactly that.
///
/// HOW TO USE THE DAPP (in browser)
///   1. Connect a wallet (MetaMask, Rabby, etc.) on Ethereum mainnet.
///   2. Pick "from" and "to" tokens; type an amount in either field.
///   3. Review the rate line: rate, source DEX, and Min received / Max paid.
///   4. Click Swap. ERC-20 inputs trigger an exact-amount approval first.
///   The page follows the OS light/dark setting; the toggle beside the address
///   overrides it and the choice persists in localStorage.
///
/// NAMES
///   The recipient field accepts a raw 0x address or a name. Forward resolution
///   picks the registry by suffix: .wei -> WNS, .gwei -> GNS (a WNS NameNFT
///   fork, same interface), .eth -> ENS. An unregistered name resolves to the
///   zero address and is refused rather than used, and the resolved address is
///   shown under the field so the destination is visible before signing.
///   The connected wallet is shown by reverse resolution in the order
///   WNS -> GNS -> ENS, falling back to the shortened hex address.
///
/// SEND
///   A second tab performs a plain transfer: native ETH by value, or an ERC-20
///   via transfer(to, amount). No router, no quoter, and no approval of any
///   kind is involved - the tokens move directly from the user to the
///   recipient. It shares the pay panel, balance, MAX, custom-token import and
///   name resolution with the swap tab rather than duplicating them.
///
///   A send cannot be undone, so the confirm button is labelled with the
///   amount, symbol and RESOLVED destination, and stays disabled until the
///   recipient resolves to a non-zero address. The recipient is resolved a
///   second time at click time and the send aborts if it no longer matches
///   what the button showed, in case the field was edited or the name
///   re-pointed after the last keystroke.
///
/// SLOW
///   The send tab can route through SLOW, the time-lock escrow at
///   0x000000000000888741B254d37e1b27128AfEAaBC, by picking a delay. The
///   sender may reverse the transfer at any point before it matures; after
///   maturity the recipient claims it.
///
///   Positions are listed by reading the contract directly -
///   getOutboundTransfers / getInboundTransfers give the ids, pendingTransfers
///   gives each one's state, and a zero timestamp means already settled. No
///   indexer, no backend and no event log is involved, which is what makes the
///   view possible from a page that can never be updated.
///
///   A SLOW id packs its token and delay as token | delay<<160, so rows are
///   decoded in the page rather than costing one decodeId() call each. This
///   was checked against the contract's own decodeId() before being relied on.
///
///   SLOW takes a real ERC-20 allowance; there is no permit shortcut, and the
///   temptation to add one should be resisted. Two facts from the verified
///   source rule it out. First, SLOW exposes no permit entry point, and its
///   multicall(bytes[]) is Solady's delegatecall-to-self, so every batched
///   entry must be one of SLOW's own functions - a token permit() is a call to
///   the token, so it can never be an element. (zRouter differs precisely
///   because it carries an explicit permit forwarder.) Second, the deposit path
///   calls token.safeTransferFrom, not Solady's safeTransferFrom2, so there is
///   no Permit2 fallback: a Permit2 allowance alone will not fund a deposit.
///   multicall also reverts on non-zero msg.value, so it cannot carry ETH.
///   The ERC-20 path is therefore approve(exact) then depositTo, collapsed into
///   one confirmation by EIP-5792 where the wallet supports it.
///
///   The four quoter builders are called concurrently rather than in series:
///   they are heavy multi-pool reads, and sequencing them cost four round
///   trips per quote (measured 4.6s vs 0.8s against a public RPC).
///
///   claim() pays the recipient directly, but reverse() does NOT pay the
///   sender - it only credits unlockedBalances. Verified on a mainnet fork:
///   reverse alone settles the position and returns nothing, stranding the
///   funds inside SLOW. The Reverse action therefore sends
///   multicall([reverse, withdrawFrom]) in one transaction.
///
///   Two details of depositTo are easy to get wrong and are worth stating:
///   for native ETH the amount argument MUST be zero and the value is taken
///   from msg.value, while an ERC-20 passes the amount and no value and must
///   be approved to SLOW first (exact amount, batched via EIP-5792 when the
///   wallet supports it). Keeper tips, auto-claim, guardians and the post-grace
///   clawback are deliberately not exposed here - they belong to the full dapp.
///
/// SHAREABLE LINKS
///   The page reads a hash fragment so a request can be sent as a link. It only
///   ever PREFILLS - nothing is auto-submitted, and the recipient is resolved
///   and displayed before signing exactly as if it had been typed:
///     #to=alice.wei&amount=10&token=USDC          request a payment
///     #to=alice.wei&amount=1&token=ETH&lock=1d    request it time-locked
///     #token=ETH&out=USDC&amount=500&exactOut=1   "pay me 500 USDC, spend ETH"
///   token/out take a symbol or a 0x address (imported on demand). lock takes
///   seconds or 30m/1h/1d/1w and rounds UP to an offered option, so a link can
///   never quietly produce a shorter lock than it asked for. An unparseable
///   lock is ignored rather than guessed at.
///
///   A token named by a link is imported for the session only - it is never
///   written to the saved list, because symbol() is attacker-chosen and a URL
///   must not be able to plant a permanent "USDC" entry in someone's tokens.
///   Any imported symbol that collides with one already present is suffixed
///   with its address so two entries can never look identical.
///
///   The inverse is available in the page: the link control beside the theme
///   toggle turns whatever is on screen back into one of these URLs and copies
///   it, so a request can be shared without knowing the syntax. A custom token
///   whose symbol was disambiguated carries a space, so those emit the address
///   instead of a symbol the reader could not resolve.
///
/// APPROVALS
///   ERC-20 input never asks for an unlimited allowance. The dapp walks a
///   ladder and uses the best option the token and wallet support:
///     1. EIP-2612 permit  - sign offchain, prepended to the router multicall.
///        One signature, one transaction. The EIP-712 domain version differs
///        per token (USDC is "2", wstETH and BOLD are "1") and many tokens do
///        not expose version(), so the correct one is found by matching the
///        computed domain separator against the token's DOMAIN_SEPARATOR()
///        rather than guessed.
///     2. Permit2 - when the user already approved Permit2 for this token.
///        zRouter.permit2TransferFrom pulls the funds and calls depositFor(),
///        marking the transient balance the swap legs consume, so the quoter's
///        calldata is used unchanged.
///     3. EIP-5792 - no permit available, but the wallet can batch atomically:
///        approve(exact) and swap in a single confirmation.
///     4. Otherwise approve(exact) then swap as separate transactions, with a
///        preceding approve(0) for tokens that require it.
///   Every tier approves only the amount being swapped.
///
/// QUOTING
///   The quoter exposes several builders and this dapp compares them rather
///   than taking the first that succeeds: single-hop/2-hop-hub, 3-hop, and (for
///   exact-in) the split and hybrid-split builders. Comparing matters — a 2-hop
///   route that merely succeeds can be far worse than a 3-hop one, e.g.
///   BOLD->rETH priced ~$28 through a skewed V4 pool where 3-hop gave ~$36.
contract zSwap {
    string public constant NAME = "zSwap";
    string public constant VERSION = "0.1";

    /// @dev The HTML payload lives in nine separate data contracts whose
    /// runtime bytecode IS the markup. Splitting it removes EIP-170 as a
    /// ceiling on the dapp: the 24,576-byte limit now applies per chunk, not to
    /// the page. The chunks are deployed independently and passed in, so this
    /// wrapper's own creation bytecode stays small and cheap to deploy.
    address public immutable DATA1;
    address public immutable DATA2;
    address public immutable DATA3;
    address public immutable DATA4;
    address public immutable DATA5;
    address public immutable DATA6;
    address public immutable DATA7;
    address public immutable DATA8;
    address public immutable DATA9;
    address public immutable DATA10;
    /// @dev An eleventh chunk. The page outgrew ten: stripped of comments it is
    ///      still 255,337 bytes, and ten chunks would need 25,534 each against
    ///      EIP-170's 24,576. The count is a consequence of the page's size and
    ///      the cap, nothing more.
    address public immutable DATA11;

    /// @dev A missing or duplicated data chunk would permanently serve broken HTML.
    error InvalidData();

    // ------------------------------------------------------------- LINEAGE
    //
    // `html()` is immutable and stays that way. The successor below is a CLAIM
    // ABOUT LINEAGE, never a redirect: this contract serves its own ten chunks
    // forever, whatever the DAO deploys later. Making `html()` forward to a
    // successor would have been the smaller change and it would have cost the
    // one property this design exists for - an address whose bytes cannot move
    // under an auditor, a bookmark, or a gateway cache that was told the answer
    // is `immutable`. Mutability belongs in the naming layer, where an ENS
    // contenthash can point wherever the DAO wants and everybody already
    // expects the target to change.
    //
    // A client wanting the newest build walks `successor` until it reaches
    // zero. A client wanting the bytes it audited stops where it is.
    //
    // THE PAGE IS ONE OF THOSE CLIENTS. A pointer nobody reads moves nobody:
    // for the whole of v0.1 the chain could have carried three successors and
    // every open tab would have said nothing. So the served page calls
    // `latest()` on its own address - taken from the GATEWAY HOSTNAME, which
    // is the only place it can come from: a page that writes its own address
    // into itself changes the chunks the address is derived from, and no salt
    // solves that fixpoint. So this notice exists for readers on a web3://
    // gateway, and a file opened from disk simply does not get it. If the tip
    // is not itself, the page
    // puts a "newer" link in the footer beside the address. It SAYS, it does
    // not send: no redirect, no auto-navigation, no rewriting of what is on
    // screen. The bytes stay the bytes that were audited and leaving them is
    // the reader's decision. The read is a plain `eth_call` through the
    // wallet's RPC, so it needs no account and no permission, and every
    // failure - no wallet, another chain, an RPC that will not answer - is
    // silent, because a missing notice is a smaller harm than a wrong one.

    /// @notice The DAO permitted to deploy this version's successor.
    address public immutable DAO;

    /// @notice The version that deployed this one; zero for v0.1.
    address public immutable PREVIOUS;


    /// @notice The next version, once the DAO has deployed it.
    /// @dev Write-once. A rewritable pointer is not lineage, it is a mutable
    ///      redirect wearing lineage's clothes - and history that can be
    ///      restated is not history. A successor set in error is not a dead
    ///      end either: the DAO deploys v0.3 from v0.2 and the chain moves on -
    ///      but ONLY because `deployNext` refuses to point at anything that
    ///      cannot do that. What is written once is checked first.
    address public successor;

    /// @notice When `successor` was set, as a unix timestamp; zero until then.
    /// @dev THE ONE FACT ONLY THE CHAIN KNOWS. Every reader that follows this
    ///      pointer has to decide whether to follow it YET, and none of them
    ///      can tell from the pointer alone whether it appeared a year ago or
    ///      in the block they are reading. A governance key that is stolen at
    ///      noon can name a successor at 12:01; without a clock, the name and
    ///      every predecessor's page would carry the reader there before anyone
    ///      had time to look at it. With one, readers can require a version to
    ///      have stood unchallenged for a while before they follow it, and the
    ///      DAO cannot backdate that - `block.timestamp` is written here, by
    ///      this contract, in the same transaction that sets the pointer.
    ///
    ///      It is not a second record of anything: the pointer says WHERE, this
    ///      says WHEN, and neither can be derived from the other. `uint96`
    ///      packs it into `successor`'s slot, so recording it costs nothing -
    ///      one `sstore` either way - and it overflows in the year 2.5e21.
    uint96 public succeededAt;

    error NotDAO();
    error AlreadySucceeded();
    error DeployFailed();
    error NotASuccessor();

    /// @notice Emitted once per version, by the version that created it.
    event Succeeded(address indexed successor, uint256 indexed version);

    struct KeyValue {
        string key;
        string value;
    }

    /// @param dao      Governance permitted to deploy the successor.
    /// @param previous  The version deploying this one; `address(0)` for v0.1.
    /// @dev `previous` cannot be misstated. Any non-zero value must equal
    ///      `msg.sender`, and a successor is only ever created by `deployNext`,
    ///      so the deployer IS the predecessor at construction time. No version
    ///      NUMBER is stored: it is derived by walking, so there is no counter
    ///      to pass in wrongly, skip, or repeat. The chain is the record.
    /// @dev The chunks arrive as ONE fixed-size array rather than 9 positional
    ///      parameters. Sixteen address parameters put the constructor over the
    ///      EVM's stack limit outright ("1 too deep") at the previous count of
    ///      fifteen, and the array costs
    ///      nothing to say so: a static array is ABI-encoded inline, so
    ///      `abi.encode(dao, previous, chunks)` is byte-identical to the
    ///      positional form every existing deploy artifact already appends.
    ///      It also means the next change to the count touches one number here
    ///      instead of a parameter list, a temporary array and 15 assignments.
    constructor(address dao, address previous, address[11] memory d) {
        if (previous != address(0) && msg.sender != previous) revert InvalidData();
        DAO = dao;
        PREVIOUS = previous;
        for (uint256 i; i != 11; ++i) {
            if (d[i].code.length == 0) revert InvalidData();
            for (uint256 j = i + 1; j != 11; ++j) {
                if (d[i] == d[j]) revert InvalidData();
            }
        }
        DATA1 = d[0];
        DATA2 = d[1];
        DATA3 = d[2];
        DATA4 = d[3];
        DATA5 = d[4];
        DATA6 = d[5];
        DATA7 = d[6];
        DATA8 = d[7];
        DATA9 = d[8];
        DATA10 = d[9];
        DATA11 = d[10];
    }

    /// @notice Deploy the next version, at an address known before it exists.
    /// @dev CREATE2 from THIS contract, so the successor's constructor sees
    ///      `msg.sender == address(this)` and its `previous` check passes only
    ///      for the real predecessor. That is what makes the backward pointer
    ///      unforgeable rather than merely recorded: nothing outside this
    ///      function can produce a contract that names this one as its parent.
    /// @param initcode Creation code for the successor, constructor args
    ///                 appended. Its `previous` argument must be this address.
    /// @param salt     CREATE2 salt, so the address is checkable in advance.
    /// @dev The pointer is write-once, so what it is set TO is checked before
    ///      it is set. `create2` reports success for initcode that returns no
    ///      runtime code at all, and the constructor's `previous` check is
    ///      skipped entirely when `previous` is zero - so without the two
    ///      checks below the DAO could, in one transaction, burn the only
    ///      successor slot on a codeless address (making `latest()` revert for
    ///      this contract and every predecessor, permanently) or on a second
    ///      root whose `PREVIOUS` disagrees with this contract's `successor`.
    ///      Both are unrecoverable: `AlreadySucceeded` refuses a retry.
    ///
    ///      WHAT IS CHECKED IS THE INTERFACE THE CHAIN IS WALKED BY, and that
    ///      is the whole of it: `PREVIOUS()` and `successor()`. A successor is
    ///      otherwise free to be a different contract entirely - a different
    ///      chunk count, a different reassembly, a different page - because the
    ///      initcode is the DAO's to choose. Only the two pointers are frozen,
    ///      for every version, forever: they are what `generation()`, `latest()`
    ///      and every reader outside this file depend on.
    function deployNext(bytes calldata initcode, bytes32 salt) external returns (address next) {
        if (msg.sender != DAO) revert NotDAO();
        if (successor != address(0)) revert AlreadySucceeded();
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, initcode.offset, initcode.length)
            next := create2(0, p, initcode.length, salt)
        }
        if (next == address(0)) revert DeployFailed();
        // Codeless deploy, or something that is not a zSwap naming this one as
        // its predecessor. `staticcall` rather than the typed call so a missing
        // function is a revert here and not a decode panic: an address with no
        // code answers successfully with empty returndata.
        (bool ok, bytes memory ret) = next.staticcall(abi.encodeWithSelector(bytes4(keccak256("PREVIOUS()"))));
        if (!ok || ret.length != 32 || abi.decode(ret, (address)) != address(this)) {
            revert NotASuccessor();
        }
        // THE FORWARD HALF OF THE SAME CHECK. `latest()` walks by calling
        // `successor()` on each link, so a successor that does not answer it
        // breaks the walk for THIS contract and every predecessor - the same
        // permanent failure as a codeless deploy, arrived at from the other
        // side. It must also be zero: a version that is born already succeeded
        // is not a new tip, and the walk would step straight past it.
        (ok, ret) = next.staticcall(abi.encodeWithSelector(bytes4(keccak256("successor()"))));
        if (!ok || ret.length != 32 || abi.decode(ret, (address)) != address(0)) {
            revert NotASuccessor();
        }
        successor = next;
        succeededAt = uint96(block.timestamp);
        emit Succeeded(next, generation() + 1);
    }

    /// @notice How far along the chain this contract sits: 1 for v0.1.
    /// @dev Counted by walking `PREVIOUS` to the root rather than stored. A
    ///      number held in state is a second copy of what the pointers already
    ///      say, and two records of one fact can disagree - the counter is the
    ///      one that would be wrong, and nothing on chain could tell you.
    ///      Bounded, like `latest`, so a long chain degrades to an
    ///      underestimate instead of running out of gas.
    function generation() public view returns (uint256 n) {
        // Cast to this contract's own type: a successor IS a zSwap, so no
        // separate interface is needed, and none declared in this file has to
        // survive `build-zSwap.mjs` rewriting the natspec figures above.
        address cur = address(this);
        for (n = 1; n != 33; ++n) {
            address prev = zSwap(cur).PREVIOUS();
            if (prev == address(0)) return n;
            cur = prev;
        }
    }

    /// @notice The newest version reachable from here, following `successor`.
    /// @dev Bounded: an unbounded walk is a gas bomb the DAO could arm by
    ///      accident. Callers past the bound keep walking from what they get.
    function latest() external view returns (address tip) {
        tip = address(this);
        for (uint256 i; i != 32; ++i) {
            address next = zSwap(tip).successor();
            if (next == address(0)) return tip;
            tip = next;
        }
    }

    function html() external view returns (string memory) {
        return _html();
    }

    /// @notice ERC-5219 request handler. Returns the HTML for any path with
    ///         `Content-Type: text/html` and a permanent cache hint (the
    ///         response is byte-identical forever since the bytecode is
    ///         immutable). Path/query params are ignored — the dapp is a
    ///         single-page app served from any URL on this contract.
    function request(
        string[] memory,
        /*resource*/
        KeyValue[] memory /*params*/
    )
        external
        view
        returns (uint16 statusCode, string memory body, KeyValue[] memory headers)
    {
        statusCode = 200;
        body = _html();
        headers = new KeyValue[](2);
        headers[0] = KeyValue("Content-Type", "text/html");
        headers[1] = KeyValue("Cache-Control", "public, max-age=31536000, immutable");
    }

    /// @notice ERC-4804/5219 resolution mode. Returns bytes32("5219") to
    ///         signal that web3:// gateways should call request() per the
    ///         ERC-5219 interface (rather than auto-mode URL→function-call
    ///         resolution or legacy "manual" fallback dispatch).
    function resolveMode() external pure returns (bytes32) {
        return "5219";
    }

    /// @dev Reassembles the page from all ten chunks in one pass: each chunk
    /// is copied directly after the previous one at the string body, so no
    /// intermediate copy or concatenation is needed.
    ///
    /// A RUNNING OFFSET, not a ladder of pairwise sums. The unrolled form named
    /// every prefix total (n12, n123, n1234...) as its own binding, so each
    /// added chunk cost another line AND another name that had to be threaded
    /// correctly into exactly one `extcodecopy` - the kind of edit that is
    /// mechanical until the one time it is not, and whose failure mode is a
    /// page silently served with a chunk overwritten or omitted. Here the
    /// cursor advances by construction, so the tenth chunk lands after the
    /// ninth for the same reason the second lands after the first.
    function _html() private view returns (string memory s) {
        address[11] memory d = [
            DATA1, DATA2, DATA3, DATA4, DATA5, DATA6, DATA7, DATA8, DATA9, DATA10, DATA11
        ];
        assembly ("memory-safe") {
            s := mload(0x40)
            let body := add(s, 0x20)
            let at := body
            for { let i := 0 } lt(i, 11) { i := add(i, 1) } {
                let a := mload(add(d, shl(5, i)))
                let n := extcodesize(a)
                extcodecopy(a, at, 0, n)
                at := add(at, n)
            }
            let total := sub(at, body)
            mstore(s, total) // total string length
            let padded := and(add(total, 0x1f), not(0x1f))
            mstore(0x40, add(body, padded)) // bump free memory pointer
        }
    }
}
