// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;


/// @title zSwap v0.3
/// @notice Permanently-deployed onchain HTML swap dapp for Ethereum mainnet.
/// @dev Architecture: the HTML payload (390972 B) is the runtime bytecode of
///      16 data contracts, deployed separately and passed to the constructor.
///      html() reassembles them via EXTCODECOPY with proper ABI encoding
///      (offset + length + padded data) so any RPC client decodes directly.
///      request() implements ERC-5219 for first-class web3:// gateway
///      compatibility (ERC-4804). Splitting the page across 16 data contracts
///      means EIP-170 caps each chunk, not the dapp
///      (24576 B per chunk, 2244 B headroom).
///
///      The chunk count is fixed in the constructor arity and the page is
///      immutable, so it is sized to ceil(len/16) with headroom for a release
///      of growth. It cannot be padded arbitrarily: every chunk must be
///      non-empty and distinct (see the constructor), so ceil(len/16) must
///      stay under EIP-170 while len/16 stays non-zero. The page is stored
///      stripped of comments and indentation - every byte is paid for on
///      chain, forever, by whoever deploys the next version.
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
    string public constant VERSION = "0.3";

    /// @dev The HTML payload lives in sixteen separate data contracts whose
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
    /// @dev An eleventh chunk. The count follows the page's size against
    ///      EIP-170's 24,576-byte cap, nothing more.
    address public immutable DATA11;
    /// @dev A twelfth chunk. Same arithmetic as eleven.
    address public immutable DATA12;
    /// @dev A thirteenth chunk. Same arithmetic again: ceil(len/16) must stay
    ///      under EIP-170 with headroom for a release of growth.
    address public immutable DATA13;
    /// @dev A fourteenth chunk. The launchpad's economics, the wave clock and
    ///      the score mint took the page past what thirteen hold. The count is
    ///      a consequence of the page's size against the cap, and nothing else
    ///      - but it is not free: the arity is fixed at construction, so it
    ///      moves the address this version deploys to.
    address public immutable DATA14;

    /// @dev A fifteenth chunk. The cause launcher and the burn-back line took
    ///      the page past what fourteen hold. Same arithmetic as every count
    ///      before it, and the same cost: a new arity is a new address.
    address public immutable DATA15;
    /// @dev A sixteenth. The solver lanes and the venue comparison took it past
    ///      fifteen within the same week fifteen was adopted, which is the more
    ///      useful fact: this number has moved three times and will move again.
    ///      It is not a size limit anyone chose - it is ceil(page / 24576) - so
    ///      the only real guard is that `script/build-zSwap-chunks.mjs` and
    ///      this arity are checked against each other before a deploy rather
    ///      than after one. Sixteen leaves under a kilobyte spare per chunk on
    ///      the stripped page - low four figures of total growth, not tens of
    ///      kilobytes - so `script/strip-zSwap.mjs` reports the real margin and
    ///      is worth reading before an edit that adds a screen of markup.
    address public immutable DATA16;

    /// @dev A missing or duplicated data chunk would permanently serve broken HTML.
    error InvalidData();

    /// @notice The curated public RPC list the page reads through before any
    ///         wallet is connected. Deployed on its own, verified, and named
    ///         here as a CONSTANT rather than created in the constructor or
    ///         passed into it.
    /// @dev WHY A CONSTANT AND NOT A CONSTRUCTOR ARGUMENT. Both alternatives
    ///      are worse in the same way. Creating the satellite here would put
    ///      12KB of code deposit inside every `deployNext` and give each
    ///      version a fresh, empty roster that the DAO must curate again from
    ///      nothing. Taking it as an argument would mean the address a version
    ///      points at is chosen at deploy time by whoever sends the
    ///      transaction - so a reader auditing this source could not tell
    ///      which roster the page will actually read, and a deployer could
    ///      hand it one they had already filled. A constant is the only form
    ///      where WHAT THE AUDIT READ IS WHAT THE PAGE READS. It is the same
    ///      reason zSwapResolver's DAO is a constant.
    ///
    ///      Verified at etherscan; owner is a two-step transferable address,
    ///      so the roster's CONTENTS still move - only the address does not.
    ///      Curating it is the same class of decision as curating the token
    ///      list, and a hostile entry misprices a quote rather than taking
    ///      funds.
    address public constant RPCS = 0x8C7348D039f58C4e9cfA936EF410eec759213b12;

    /// @notice The curated off-chain solver roster the page may race its own
    ///         venues against. Same reasoning as `RPCS`, same constant form.
    /// @dev The lanes here are live, but a lane being enabled on chain does
    ///      nothing on its own: the page has to ask it, apply the handicap,
    ///      and beat the on-chain best by that margin before anything is
    ///      offered. zQuoter, the precision pools and the orderbook are never
    ///      a fallback this switches to - they are a lane that always runs.
    address public constant SOLVERS = 0x1Dfbb2f41B596F72187370469074C46de60dA2e3;

    /// @notice The ONE adapter the page will execute a solver's route through.
    ///
    /// @dev THIS IS THE PIN, AND IT IS THE WHOLE REASON THE ROSTER IS SAFE TO
    ///      READ. A solver lane carries an `adapter` address, and the page
    ///      learns that address by reading `SOLVERS` over an RPC it also
    ///      learned from chain. Anyone who controls that node controls both
    ///      answers, and could name an adapter that is not the audited one -
    ///      at which point every guarantee zSolverFill makes is irrelevant,
    ///      because zSolverFill never ran.
    ///
    ///      So the roster does not get to choose. It may only SELECT among
    ///      adapters pinned in immutable source, and today that set has one
    ///      member: the page must refuse any lane whose adapter is not this
    ///      address. Curating an address is only "governing which code runs"
    ///      when the set of code that CAN run is fixed somewhere the curator
    ///      cannot reach. This is that somewhere.
    ///
    ///      zSolverFill itself has no owner, no pause and no upgrade path, and
    ///      routes every untrusted call through a stateless executor that
    ///      holds no allowance from anyone. See src/utils/zSolverFill.sol.
    address public constant SOLVER_FILL = 0x7A2f21e476cA2ADde027BC868c5a083338EEfE54;

    // ------------------------------------------------------------- LINEAGE
    //
    // `html()` is immutable and stays that way. The successor below is a CLAIM
    // ABOUT LINEAGE, never a redirect: this contract serves its own sixteen chunks
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
    /// @dev ONE ADDRESS FOR THE LIFE OF THE LINEAGE. Governance may change
    ///      inside the DAO contract - proposals, shares, whatever its own rules
    ///      evolve into - but the address must not: `deployNext` answers to
    ///      this value alone, the successor check demands the same one back,
    ///      and zSwapResolver's `DAO` constant carries the same address, not
    ///      re-pointable after deploy. A new governor at a new address is not
    ///      a rotation; it is a fork of the trust root, and no version of this
    ///      lineage will follow it.
    ///
    ///      THE ROSTERS ARE THE EXCEPTION, DELIBERATELY. zRpcList and
    ///      zSolverList are named above as constants, but each carries its own
    ///      transferable two-step `owner` - which is NOT this DAO, and is not
    ///      required to be.
    ///      Curation is an ongoing job whose holder will change hands more
    ///      than once over a page that never can - a signer set rotates, a
    ///      multisig graduates to a governor, a compromised key has to be
    ///      abandoned in an afternoon - and answering any of those with a new
    ///      deploy of the version that names the satellite is the rigidity
    ///      those satellites exist to relieve. So the LINEAGE's trust root is
    ///      immovable and the CURATION's is not, and a reader should not be
    ///      told otherwise: whoever holds a roster's owner can curate it, and
    ///      that is a different party from this one. What the lineage fixes is
    ///      WHICH rosters are read and which adapter may run; what those
    ///      owners control is the contents. Read `owner()` on each before
    ///      trusting either.
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
    ///      instead of a parameter list, a temporary array and 16 assignments.
    constructor(address dao, address previous, address[16] memory d) {
        if (previous != address(0) && msg.sender != previous) revert InvalidData();
        DAO = dao;
        PREVIOUS = previous;
        for (uint256 i; i != 16; ++i) {
            if (d[i].code.length == 0) revert InvalidData();
            for (uint256 j = i + 1; j != 16; ++j) {
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
        DATA12 = d[11];
        DATA13 = d[12];
        DATA14 = d[13];
        DATA15 = d[14];
        DATA16 = d[15];
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
        // code answers successfully with empty returndata. Every probe is
        // gas-capped: a getter over an immutable costs a few thousand gas, so
        // 30,000 is roughly ten times an honest answer and the hard ceiling on
        // what a hostile one can burn inside this check. A probe that runs out
        // answers `ok == false`, which is the same rejection as every other.
        (bool ok, bytes memory ret) = next.staticcall{gas: 30_000}(abi.encodeWithSelector(bytes4(keccak256("PREVIOUS()"))));
        if (!ok || ret.length != 32 || abi.decode(ret, (address)) != address(this)) {
            revert NotASuccessor();
        }
        // THE FORWARD HALF OF THE SAME CHECK. `latest()` walks by calling
        // `successor()` on each link, so a successor that does not answer it
        // breaks the walk for THIS contract and every predecessor - the same
        // permanent failure as a codeless deploy, arrived at from the other
        // side. It must also be zero: a version that is born already succeeded
        // is not a new tip, and the walk would step straight past it.
        (ok, ret) = next.staticcall{gas: 30_000}(abi.encodeWithSelector(bytes4(keccak256("successor()"))));
        if (!ok || ret.length != 32 || abi.decode(ret, (address)) != address(0)) {
            revert NotASuccessor();
        }
        // THE TRUST ROOT TRAVELS WHOLE. The two probes above verify the
        // successor's SHAPE; this one verifies its ALLEGIANCE. The lineage is
        // one chain of custody under one DAO - `deployNext` refused every
        // caller but this contract's DAO at the top - and a successor whose
        // `DAO()` named some new address would be a second head on that chain:
        // the walk would hand it every reader of this name while its own admin
        // answered to a governance nobody on this lineage ever chose. There is
        // exactly one DAO address governing the lineage - this contract's
        // immutable and the resolver's constant carry the same one - and it
        // stays one address for the lineage's life: governance changes happen
        // inside the DAO, never by pointing the constants somewhere new. (The
        // rosters are seeded with it but own a transferable admin of their
        // own; see the `DAO` natspec. Their curator moving is not a fork of
        // this lineage, which is precisely why they are satellites.)
        (ok, ret) = next.staticcall{gas: 30_000}(abi.encodeWithSelector(bytes4(keccak256("DAO()"))));
        if (!ok || ret.length != 32 || abi.decode(ret, (address)) != DAO) {
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

    /// @dev Reassembles the page from all sixteen chunks in one pass: each chunk
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
        address[16] memory d = [
            DATA1, DATA2, DATA3, DATA4, DATA5, DATA6, DATA7, DATA8, DATA9, DATA10, DATA11, DATA12,
            DATA13, DATA14, DATA15, DATA16
        ];
        assembly ("memory-safe") {
            s := mload(0x40)
            let body := add(s, 0x20)
            let at := body
            // The bound is the arity, and it is a LITERAL because assembly has
            // no view of `d.length` - which makes it the one place a chunk can
            // be dropped without anything failing to compile. It has happened:
            // this read 15 while the array above held 16, and `html()` served a
            // page short of its last slice. If you change the count, change it
            // here, and let the length assertions in test/zSwap.t.sol catch you
            // if you do not.
            for { let i := 0 } lt(i, 16) { i := add(i, 1) } {
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
