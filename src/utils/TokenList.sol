// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {TokenListRenderer} from "./TokenListRenderer.sol";
import {ERC721} from "../../lib/solady/src/tokens/ERC721.sol";
import {Ownable} from "../../lib/solady/src/auth/Ownable.sol";
import {Base64} from "../../lib/solady/src/utils/Base64.sol";
import {LibString} from "../../lib/solady/src/utils/LibString.sol";
import {Multicallable} from "../../lib/solady/src/utils/Multicallable.sol";
import {MetadataReaderLib} from "../../lib/solady/src/utils/MetadataReaderLib.sol";

/// @title TokenList
/// @notice An onchain token list where each listing *is* an ERC-721. The listing NFT
///         for a token on this chain is minted to the token's own address, so anyone
///         looking at that contract on Etherscan sees a card carrying its logo, symbol,
///         decimals and links. Minting lists, burning delists, re-minting relists.
/// @dev Curation is the only power the owner holds over *facts*. For tokens on this
///      chain `name`/`symbol`/`decimals` are read from the token contract itself and
///      can never be set by the owner; anyone may call `sync` to refresh them. The
///      owner authors only what has no onchain source: logo, theme, links, rank.
///
///      Foreign-chain listings have no readable source here, so their text is
///      owner-supplied and marked `synced = false`. Consumers can render that
///      distinction rather than being misled about its provenance.
contract TokenList is ERC721, Ownable, Multicallable {
    using LibString for string;

    /// @dev Address namespace. EVM addresses sit right-aligned in `account`;
    ///      Solana account keys are exactly 32 bytes and occupy it fully.
    enum Kind {
        EVM,
        SVM,
        OTHER
    }

    /// @dev `Kind` identifies an account namespace; `Standard` identifies what the
    ///      account represents. They are independent: an EVM address may name a
    ///      native asset, ERC-20, ERC-721 or ERC-1155 collection.
    enum Standard {
        UNKNOWN,
        NATIVE,
        ERC20,
        ERC721,
        ERC1155,
        // Tacit: a confidential asset whose amounts may be hidden. Keyed by its
        // 32-byte `asset_id`, which drops into `account` verbatim.
        //
        // Named for the FORMAT, not for the flagship asset. `TAC` is a ticker and
        // would sit in `symbol`; this field answers "what kind of thing is this",
        // and TAC is one TACIT asset among others.
        TACIT,
        // Runes. The canonical id is `block:tx` text, so the account word carries an
        // encoding of it and the human form belongs in an extension field.
        RUNE,
        // Ordinals. An inscription id is `<txid>i<index>`, which does NOT fit the
        // account word; key by txid or a domain-separated hash and carry the full id
        // as an extension field.
        ORDINAL,
        // BRC-20.
        BRC20
    }

    struct Token {
        bytes32 account; // token address / mint, right-aligned for EVM
        uint64 chainId; // eip155 chain id; 0 for non-EVM namespaces
        uint8 decimals;
        Kind kind;
        Standard standard;
        // False only for a reservation: it has a stable listing id and curated
        // metadata, but no account may be used in a wallet, quote, or swap yet.
        bool deployed;
        bool onchainSvg; // collection says selected token IDs resolve to data-SVG art
        bool synced; // true when name/symbol/decimals came from the token itself
        uint24 color; // 0xRRGGBB theme color
        // Sort WEIGHT, not a position: higher sorts first, 0 is unranked. Values are
        // deliberately sparse (the seeds step by 1,000) so a token can be placed
        // between two existing ones by picking a number in the gap, instead of
        // renumbering every listing below it. Position is the `rankedIds()` index.
        uint32 rank;
        bool frozen; // owner-authored fields sealed forever; see `freeze`
        string name;
        string symbol;
        string logo; // data:/https:/ipfs: URI, embedded into the card
        string url; // project link
        string audit; // optional audit/report link; hidden on the card when unset
        string description;
    }

    /// @dev A listing minus the unbounded fields — see `summariesPaged`.
    struct Summary {
        uint256 id;
        bytes32 account;
        uint64 chainId;
        uint8 decimals;
        Kind kind;
        Standard standard;
        bool deployed;
        bool onchainSvg;
        bool synced;
        uint24 color;
        uint32 rank;
        bool frozen;
        string name;
        string symbol;
    }

    uint256 internal constant NAME_MAX = 40;
    uint256 internal constant SYMBOL_MAX = 12;
    uint256 internal constant URL_MAX = 128;
    uint256 internal constant DESC_MAX = 256;
    uint256 internal constant LOGO_MAX = 24_576;
    uint256 internal constant READ_GAS = 60_000;

    /// @dev Per-listing extension limits. `EXTRA_KEYS_MAX` bounds `delist`, which
    ///      walks every key — see `setExtra`. Card layout metrics live in the
    ///      renderer, with the layout they describe.
    uint256 internal constant EXTRA_MAX = 256;
    uint256 internal constant EXTRA_KEYS_MAX = 32;

    /// @dev Foreign listings are keyed by hash, so their ids are pushed above the
    ///      2^160 address space. A local id is always literally its token address.
    uint256 internal constant FOREIGN_FLAG = 1 << 255;
    bytes32 internal constant RESERVATION_TAG = keccak256("zfi.token-list.reservation.v1");

    /// @dev Open-ended per-listing metadata. The struct above is fixed at deploy, and
    ///      the fields a token list is asked for are not: a CoinGecko id, a social
    ///      handle, a category tag, a price feed. Without somewhere to put them, each
    ///      new field means redeploying the registry and re-listing every token. This
    ///      mapping is the escape hatch that keeps those requests to a transaction.
    mapping(uint256 id => mapping(bytes32 key => string)) internal _extra;
    mapping(uint256 id => bytes32[]) internal _extraKeys;
    mapping(uint256 id => mapping(bytes32 key => uint256 indexPlusOne)) internal _extraPos;

    mapping(uint256 id => Token) internal _tokens;
    uint256[] internal _ids;
    mapping(uint256 id => uint256 indexPlusOne) internal _position;
    // Usually this is simply `idOf(account)`. A reservation keeps its hash-derived
    // id after activation, so this indirection lets `get(account)` find that same
    // card without changing the public, deterministic address-id rule.
    mapping(address account => uint256 id) internal _boundLocalId;

    /// @dev Governance-upgradeable so the card can be improved after deploy — new art,
    ///      new fields, a fixed layout — without redeploying the registry and
    ///      re-listing every token under fresh ids.
    ///
    ///      Understand what this delegates. The registry's promise is that local
    ///      name/symbol/decimals come from the token and the owner cannot forge them,
    ///      and that remains true of STORAGE. It is not true of what a wallet
    ///      DISPLAYS: a renderer is free to print any text it likes. Swapping it is
    ///      therefore a change to what every listing appears to say, and belongs
    ///      behind the same multisig and timelock as the rest of curation. Consumers
    ///      that need the unmediated facts should read `get`/`json` fields from
    ///      storage rather than parsing the card.
    TokenListRenderer public renderer;

    /// @dev One-way. See `lockRenderer`.
    bool public rendererLocked;

    event ExtraSet(uint256 indexed id, bytes32 indexed key, string value);
    /// @dev `id`, `account` and `chainId` are the three filters worth topic slots.
    ///
    ///      NOTE: this does NOT carry the whole listing, and logs alone are not enough
    ///      to reconstruct one. Kind, colour, rank, logo, links and description are all
    ///      absent here, and `Updated` names only the field that changed, not its new
    ///      value. An indexer should treat these as invalidation signals and read the
    ///      current state back through `get`/`json`. `MetadataUpdate` below is the
    ///      standard form of that signal.
    event Listed(
        uint256 indexed id,
        bytes32 indexed account,
        uint64 indexed chainId,
        string symbol,
        string name,
        uint8 decimals,
        bool synced
    );

    /// @dev `field` names what changed ("art", "text", "rank", "audit", "sync",
    ///      "freeze"), so an indexer can skip re-reading a listing it does not care
    ///      about. Note "art" covers rank too, because `setArt` writes it.
    event Updated(uint256 indexed id, bytes32 indexed field);
    event Delisted(uint256 indexed id, bytes32 indexed account);

    /// @dev ERC-4906. Every listing here is mutable — art, links, rank and a
    ///      permissionless `sync` all change what `tokenURI` renders — and wallets and
    ///      marketplaces refresh cached metadata on this event, not on a bespoke one.
    ///      Without it a corrected logo or a re-synced symbol can sit stale in every
    ///      client indefinitely, which for a token list is the failure that matters.
    event MetadataUpdate(uint256 _tokenId);
    /// @dev ERC-4906's bulk form. A renderer swap restyles every card at once, and
    ///      emitting one event per listing would not fit in a block at any real size.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    /// @dev ERC-5192. The interface id this contract advertises is the `locked`
    ///      selector alone, so `supportsInterface` answering true was never evidence
    ///      the event half existed — and it did not. An indexer that classifies
    ///      soulbound collections from logs (rather than probing every id with an
    ///      `eth_call`) saw an ordinary transferable collection, and would offer
    ///      listings for sale on a card whose transfer always reverts. Every listing
    ///      is born locked and stays locked, so this is emitted on mint and
    ///      `Unlocked` deliberately does not exist.
    event Locked(uint256 tokenId);
    event RendererSet(address indexed renderer);
    /// @dev ERC-7572. The renderer authors `contractURI` too, so a swap restates the
    ///      collection alongside every card; `BatchMetadataUpdate` only ever covered
    ///      the cards.
    event ContractURIUpdated();
    event RendererLocked();
    event Froze(uint256 indexed id);
    event Reserved(uint256 indexed id, bytes32 indexed key, string symbol);
    event Activated(uint256 indexed id, address indexed token);

    error Exists();
    error Unknown();
    error BadInput();
    error Soulbound();
    error NotSyncable();
    error NotEditable();

    /// @dev NOTE: every logo constant below carries an explicit `xmlns`. The art was
    ///      lifted from zSwap.html, where it sat inline in HTML and inherited the SVG
    ///      namespace from the parser. A logo here becomes a standalone
    ///      `data:image/svg+xml` document, and a standalone SVG without `xmlns` does
    ///      not render at all - it is a broken image in every wallet and explorer.
    ///
    /// @dev Canonical mainnet addresses for the set zSwap used to hardcode. Each is
    ///      seeded only where it actually has code, so the same deployment bytecode is
    ///      safe to ship to any chain - on an L2 the list simply starts smaller.
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    string internal constant ETH_LOGO = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 32 32"><g fill="none" fill-rule="evenodd"><circle cx="16" cy="16" r'
        '="16" fill="#627EEA"/><g fill="#FFF" fill-rule="nonzero"><path fill-opacity=".602" d="M16.498 4v8.87l7.497 3'
        '.35z"/><path d="M16.498 4L9 16.22l7.498-3.35z"/><path fill-opacity=".602" d="M16.498 21.968v6.027L24 17.616z'
        '"/><path d="M16.498 27.995v-6.028L9 17.616z"/><path fill-opacity=".2" d="M16.498 20.573l7.497-4.353-7.497-3.'
        '348z"/><path fill-opacity=".602" d="M9 16.22l7.498 4.353v-7.701z"/></g></g></svg>';

    string internal constant USDC_LOGO = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 32 32"><g fill="none"><circle fill="#2775CA" cx="16" cy="16" r="16"'
        '/><g fill="#FFF"><path d="M20.022 18.124c0-2.124-1.28-2.852-3.84-3.156-1.828-.243-2.193-.728-2.193-1.578 0-.'
        "85.61-1.396 1.828-1.396 1.097 0 1.707.364 2.011 1.275a.458.458 0 00.427.303h.975a.416.416 0 00.427-.425v-.06"
        "a3.04 3.04 0 00-2.743-2.489V9.142c0-.243-.183-.425-.487-.486h-.915c-.243 0-.426.182-.487.486v1.396c-1.829.24"
        "2-2.986 1.456-2.986 2.974 0 2.002 1.218 2.791 3.778 3.095 1.707.303 2.255.668 2.255 1.639 0 .97-.853 1.638-2"
        ".011 1.638-1.585 0-2.133-.667-2.316-1.578-.06-.242-.244-.364-.427-.364h-1.036a.416.416 0 00-.426.425v.06c.24"
        "3 1.518 1.219 2.61 3.23 2.914v1.457c0 .242.183.425.487.485h.915c.243 0 .426-.182.487-.485V21.34c1.829-.303 3"
        '.047-1.578 3.047-3.217z"/><path d="M12.892 24.497c-4.754-1.7-7.192-6.98-5.424-11.653.914-2.55 2.925-4.491 5.'
        "424-5.402.244-.121.365-.303.365-.607v-.85c0-.242-.121-.424-.365-.485-.061 0-.183 0-.244.06a10.895 10.895 0 0"
        "0-7.13 13.717c1.096 3.4 3.717 6.01 7.13 7.102.244.121.488 0 .548-.243.061-.06.061-.122.061-.243v-.85c0-.182-"
        ".182-.424-.365-.546zm6.46-18.936c-.244-.122-.488 0-.548.242-.061.061-.061.122-.061.243v.85c0 .243.182.485.36"
        "5.607 4.754 1.7 7.192 6.98 5.424 11.653-.914 2.55-2.925 4.491-5.424 5.402-.244.121-.365.303-.365.607v.85c0 ."
        '242.121.424.365.485.061 0 .183 0 .244-.06a10.895 10.895 0 007.13-13.717c-1.096-3.46-3.778-6.07-7.13-7.162z"/'
        "></g></g></svg>";

    string internal constant USDT_LOGO = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 32 32"><g fill="none" fill-rule="evenodd"><circle cx="16" cy="16" r'
        '="16" fill="#26A17B"/><path fill="#FFF" d="M17.922 17.383v-.002c-.11.008-.677.042-1.942.042-1.01 0-1.721-.03'
        "-1.971-.042v.003c-3.888-.171-6.79-.848-6.79-1.658 0-.809 2.902-1.486 6.79-1.66v2.644c.254.018.982.061 1.988."
        "061 1.207 0 1.812-.05 1.925-.06v-2.643c3.88.173 6.775.85 6.775 1.658 0 .81-2.895 1.485-6.775 1.657m0-3.59v-2"
        ".366h5.414V7.819H8.595v3.608h5.414v2.365c-4.4.202-7.709 1.074-7.709 2.118 0 1.044 3.309 1.915 7.709 2.118v7."
        '582h3.913v-7.584c4.393-.202 7.694-1.073 7.694-2.116 0-1.043-3.301-1.914-7.694-2.117"/></g></svg>';

    /// @dev The same circular mark, wrapped: the ETH octahedron sits inside four
    ///      corner brackets, so WETH reads as ETH *packaged* rather than as a second,
    ///      unrelated logo. Brackets rather than a closed frame with a seam - a full
    ///      outline plus crossing dashes reads as a rifle scope once enlarged, which
    ///      is exactly the size a marketplace renders it at.
    string internal constant WETH_LOGO = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 32 32"><circle cx="16" cy="16" r="16" fill="#627EEA"/>'
        '<g stroke="#FFF" stroke-opacity=".9" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" fill="none">'
        '<path d="M11 5.6H7.9A2.3 2.3 0 0 0 5.6 7.9V11"/><path d="M21 5.6h3.1A2.3 2.3 0 0 1 26.4 7.9V11"/>'
        '<path d="M11 26.4H7.9A2.3 2.3 0 0 1 5.6 24.1V21"/><path d="M21 26.4h3.1a2.3 2.3 0 0 0 2.3-2.3V21"/></g>'
        '<g fill="#FFF" fill-rule="nonzero" transform="translate(16 16) scale(0.56) translate(-16 -16)">'
        '<path fill-opacity=".602" d="M16.498 4v8.87l7.497 3.35z"/><path d="M16.498 4L9 16.22l7.498-3.35z"/>'
        '<path fill-opacity=".602" d="M16.498 21.968v6.027L24 17.616z"/><path d="M16.498 27.995v-6.028L9 17.616z"/>'
        '<path fill-opacity=".2" d="M16.498 20.573l7.497-4.353-7.497-3.348z"/>'
        '<path fill-opacity=".602" d="M9 16.22l7.498 4.353v-7.701z"/></g></svg>';

    /// @dev Seeds four entries in the order zSwap displayed them: id 0 native ETH,
    ///      then WETH, USDC and USDT by descending rank. The art is the same art the
    ///      dapp shipped, so those four render onchain exactly as the HTML drew them.
    ///
    ///      FOUR, NOT ELEVEN, BECAUSE OF THE PER-TRANSACTION GAS CAP. Seeding the
    ///      original set cost 19.4M gas on top of a 5.1M base — about 25.3M once the
    ///      deployment calldata is counted — against EIP-7825's 16,777,216 ceiling on
    ///      a single transaction. That is not a tuning problem: at ~1.28M per entry
    ///      plus ~625 gas per logo byte, eleven listings do not fit even with every
    ///      logo removed. So the constructor seeds the set a swap frontend cannot open
    ///      without, and wstETH, rETH, WBTC, BOLD, ZORG, zOrgz and WNS are listed by
    ///      the owner afterwards through `list` + `setLogoSVG`, where their art is
    ///      calldata rather than initcode. The ranks below deliberately keep the
    ///      original gaps — 998_000, 997_000 and 996_000 are free — so the staked-ETH
    ///      and BTC cards drop back into their old positions without renumbering.
    ///
    ///      These constants are referenced only from the constructor, so they cost
    ///      initcode once and never occupy runtime bytecode. Text still comes from each
    ///      token via `_pull`: the seed decides *what* is listed, never what it claims
    ///      to be. Every seeded entry is ordinary owner-editable state afterwards.
    ///
    ///      SEEDING IS MAINNET-ONLY, and deliberately so. Every constant below — the
    ///      three addresses, the logos, the links, and the native asset's own "Ether"
    ///      text — describes Ethereum mainnet. The previous rule seeded wherever the
    ///      address merely had code, which is not evidence of identity: on another
    ///      chain an unrelated contract sitting at USDC's address would inherit
    ///      Circle's logo, link, description and rank, and `_pull` only corrects
    ///      name/symbol/decimals, so the false project identity would stay attached to
    ///      a curated-looking listing. The native card had the same problem in plainer
    ///      form — it called BNB, POL and AVAX "Ether". One bytecode still deploys
    ///      anywhere; off mainnet it simply starts empty and the owner lists
    ///      explicitly, which is the only honest default when the constants do not
    ///      apply.
    constructor(address initialOwner, TokenListRenderer renderer_) {
        // Explicit, not incidental. This used to be caught only as a side effect of
        // minting the native card to `initialOwner` — ERC-721 rejects a mint to the
        // zero address — and that guard evaporated the moment attested listings moved
        // to the registry itself. An ownerless list can never be curated again: no
        // listing, no delisting, no correcting a bad link, forever.
        if (initialOwner == address(0)) revert BadInput();
        _initializeOwner(initialOwner);
        if (address(renderer_).code.length == 0) revert BadInput();
        renderer = renderer_;
        if (block.chainid != 1) return;

        // Native ETH has no contract to read, so its text is written here and the card
        // is flagged owner-attested rather than verified onchain.
        uint256 ethId = idOf(Kind.EVM, uint64(block.chainid), bytes32(0));
        Token storage eth = _tokens[ethId];
        eth.chainId = uint64(block.chainid);
        eth.kind = Kind.EVM;
        eth.standard = Standard.NATIVE;
        eth.deployed = true;
        eth.decimals = 18;
        eth.name = "Ether";
        eth.symbol = "ETH";
        _setArt(
            eth,
            0x627EEA,
            1_000_000,
            _dataURI("image/svg+xml", ETH_LOGO),
            "https://ethereum.org",
            "The native asset of Ethereum. Used for gas, and held at address zero."
        );
        _index(ethId);
        _mintListing(address(this), ethId);
        _emitListed(ethId, eth);

        _seed(
            WETH, 0x627EEA, 999_000, WETH_LOGO, "https://weth.io", "Ether wrapped as an ERC-20, redeemable one to one."
        );
        _seed(USDC, 0x2775CA, 995_000, USDC_LOGO, "https://circle.com/usdc", "Dollar stablecoin issued by Circle.");
        _seed(USDT, 0x26A17B, 994_000, USDT_LOGO, "https://tether.to", "Dollar stablecoin issued by Tether.");
    }

    /// @dev List a canonical token if it exists on this chain. Skipping silently is the
    ///      point: one bytecode deploys everywhere and simply seeds what is there.
    function _seed(
        address token,
        uint24 color,
        uint32 rank,
        string memory logo,
        string memory url_,
        string memory description_
    ) internal {
        if (token.code.length == 0) return;
        uint256 id = idOf(token);
        Token storage t = _tokens[id];
        t.account = bytes32(uint256(uint160(token)));
        t.chainId = uint64(block.chainid);
        t.kind = Kind.EVM;
        t.deployed = true;
        _setArt(t, color, rank, _dataURI("image/svg+xml", logo), url_, description_);
        _pull(t, token);
        _index(id);
        _boundLocalId[token] = id;
        _mintListing(token, id);
        _emitListed(id, t);
    }

    // ERC-721 --------------------------------------------------------------

    function name() public pure override returns (string memory) {
        return "Token Listing";
    }

    function symbol() public pure override returns (string memory) {
        return "TKLIST";
    }

    /// @dev Listings are bound to what they describe. A local listing is held by the
    ///      token contract itself, which has no code to move it, so transferability
    ///      would at best be inert and at worst let a listing drift away from its
    ///      subject. Mint and burn — list and delist — remain the only transitions.
    function _beforeTokenTransfer(address from, address to, uint256) internal pure override {
        if (from != address(0) && to != address(0)) revert Soulbound();
    }

    /// @dev Advertises ERC-4906 (metadata updates) and ERC-5192 (soulbound). A wallet
    ///      that cannot detect the lock renders transfer controls that always revert.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x49064906 || interfaceId == 0xb45a3c0e || super.supportsInterface(interfaceId);
    }

    /// @notice ERC-5192: every listing is permanently bound to what it describes.
    function locked(uint256 id) public view returns (bool) {
        _mustExist(id);
        return true;
    }

    // IDS ------------------------------------------------------------------

    /// @notice Token id for a token on this chain: its own address. `address(0)` is
    ///         the native asset, and resolves to the same id the namespaced overload
    ///         gives it — id 0.
    ///         An address always fits the local branch of the namespaced overload —
    ///         160 bits, this chain — so the two agree by construction, `address(0)`
    ///         included, without paying for the hash path.
    function idOf(address token) public pure returns (uint256) {
        return uint256(uint160(token));
    }

    /// @notice Token id for a listing in any namespace.
    /// @dev A local EVM listing is literally its address, INCLUDING the native asset at
    ///      id 0. The earlier rule excluded `account == 0` from the local branch, which
    ///      pushed the native asset to a hashed foreign id while `idOf(address(0))`
    ///      still answered 0 — two different ids for one asset, so `get(address(0))`
    ///      reverted `Unknown` on a listing that plainly existed. Wallets conventionally
    ///      spell the native asset `address(0)`, and an identity rule is the one part of
    ///      this schema that cannot be migrated once consumers cache it.
    ///
    ///      EVM accounts must also fit in 160 bits. Nothing else rejected the upper 96,
    ///      so a foreign EVM listing could be created whose `_account` render — a
    ///      fixed 20-byte hex conversion — reverts, leaving a listing that `get`
    ///      returns but `json`, `tokenURI` and any batched read revert on.
    function idOf(Kind kind, uint64 chainId, bytes32 account) public view returns (uint256) {
        if (kind == Kind.EVM) {
            if (uint256(account) >> 160 != 0) revert BadInput();
            if (chainId == block.chainid) return uint256(account);
        }
        return uint256(keccak256(abi.encode(kind, chainId, account))) | FOREIGN_FLAG;
    }

    /// @notice Stable id for an undeployed current-chain reservation.
    /// @dev Kept separate from `idOf`: that function is a canonical identity derived
    ///      from an account, while this is deliberately derived from a curator key.
    function reservationId(bytes32 key) public view returns (uint256) {
        if (key == bytes32(0)) revert BadInput();
        return uint256(keccak256(abi.encode(RESERVATION_TAG, block.chainid, key))) | FOREIGN_FLAG;
    }

    // WRITES ---------------------------------------------------------------

    /// @notice List a token deployed on this chain; its text is read from the token
    ///         and the listing NFT is minted to the token contract itself.
    function list(
        address token,
        uint24 color,
        uint32 rank,
        string calldata logo,
        string calldata url_,
        string calldata description_
    ) public onlyOwner returns (uint256 id) {
        // Must be a contract. A staticcall to a codeless address succeeds with empty
        // returndata, so an EOA would list with blank text yet still be flagged
        // `synced` - a card reading VERIFIED ONCHAIN with nothing behind it, which is
        // the exact provenance claim this contract exists to keep honest.
        if (token.code.length == 0) revert BadInput();
        id = idOf(token);
        if (_position[id] != 0 || _boundLocalId[token] != 0) revert Exists();

        Token storage t = _tokens[id];
        t.account = bytes32(uint256(uint160(token)));
        t.chainId = uint64(block.chainid);
        t.kind = Kind.EVM;
        t.deployed = true;
        _setArt(t, color, rank, logo, url_, description_);
        _pull(t, token);
        _index(id);
        _boundLocalId[token] = id;
        _mintListing(token, id); // deliberately not _safeMint: the subject is the holder
        _emitListed(id, t);
    }

    /// @notice List a token whose metadata cannot be read from this chain: another
    ///         chain's token, or this chain's native asset (`Kind.EVM`, `account == 0`).
    /// @dev The subject has no address here to hold the NFT, so it is minted to the
    ///      registry itself and flagged `synced = false`. Not to the owner: listings
    ///      are non-transferable, so that would freeze whoever happens to be curator
    ///      today into `ownerOf` forever.
    function listForeign(
        Kind kind,
        uint64 chainId,
        bytes32 account,
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_,
        uint24 color,
        uint32 rank,
        string calldata logo
    ) public onlyOwner returns (uint256 id) {
        // A live local token must go through `list` so its text stays derived.
        if (kind == Kind.EVM && chainId == block.chainid && account != bytes32(0)) {
            revert NotSyncable();
        }
        // The schema says a non-EVM namespace carries no eip155 chain id, and the
        // id is a hash over `(kind, chainId, account)`. Left unenforced, the same
        // Solana mint listed once with `chainId == 0` and once with any other
        // value produces two ids for one asset - the duplicate-identity failure
        // M-01 fixed for the native asset, in the namespace where nothing on this
        // chain can arbitrate which entry is the real one.
        if (kind != Kind.EVM && chainId != 0) revert BadInput();
        if (decimals_ > 36) revert BadInput();
        id = idOf(kind, chainId, account);
        if (_position[id] != 0) revert Exists();

        Token storage t = _tokens[id];
        t.account = account;
        t.chainId = chainId;
        t.kind = kind;
        t.deployed = true;
        t.decimals = decimals_;
        t.name = _clean(name_, NAME_MAX);
        t.symbol = _clean(symbol_, SYMBOL_MAX);
        _setArt(t, color, rank, logo, "", "");
        _index(id);
        // Held by the registry, not by whoever happens to be owner. Listings are
        // permanently non-transferable, so minting to the current owner freezes that
        // address into `ownerOf` forever: after an ownership handover the previous
        // curator still reads as the holder of every attested listing.
        _mintListing(address(this), id);
        _emitListed(id, t);
    }

    /// @notice Reserve a stable listing for an ERC-20 that has not been deployed.
    /// @dev `key` is a curator-chosen immutable handle (for example
    ///      `keccak256("zUSD")`), not an eventual CREATE2 prediction. The listing
    ///      keeps this id when `activateReserved` binds the real token address, so
    ///      galleries and governance references never have to migrate to a new card.
    ///      A reservation is intentionally current-chain only: its later address is
    ///      checked for code and read here, which cannot be done for another chain.
    function reserve(
        bytes32 key,
        string calldata name_,
        string calldata symbol_,
        uint8 decimals_,
        uint24 color,
        uint32 rank,
        string calldata logo,
        string calldata url_,
        string calldata description_
    ) public onlyOwner returns (uint256 id) {
        if (key == bytes32(0) || decimals_ > 36) revert BadInput();
        id = reservationId(key);
        if (_position[id] != 0) revert Exists();

        Token storage t = _tokens[id];
        t.chainId = uint64(block.chainid);
        t.kind = Kind.EVM;
        t.standard = Standard.ERC20;
        t.decimals = decimals_;
        t.name = _clean(name_, NAME_MAX);
        t.symbol = _clean(symbol_, SYMBOL_MAX);
        _setArt(t, color, rank, logo, url_, description_);
        _index(id);
        // There is no subject contract to hold this card yet. Once activated it is
        // burned and reminted to the token in the same transaction.
        _mintListing(address(this), id);
        _emitListed(id, t);
        emit Reserved(id, key, t.symbol);
    }

    /// @notice Bind a reservation to its now-deployed ERC-20 and refresh its facts.
    /// @dev This is a one-way state transition. It preserves the reservation's id,
    ///      but makes `get(token)` resolve to it and moves the soulbound card from the
    ///      registry to the token contract, restoring the normal ownership invariant.
    ///
    ///      `_mustExist`, not `_mustEdit`, for the reason `sync` is exempt too: this
    ///      copies a fact from the chain — the token now exists at this address —
    ///      rather than authoring one, and `_pull` below is the same read `sync`
    ///      performs. Under `_mustEdit` a frozen reservation could never be bound to
    ///      its deployed token, and the only exit was `delist`, which destroys the
    ///      stable id the reservation exists to preserve. Freezing seals what
    ///      governance wrote, not whether the subject shipped.
    function activateReserved(uint256 id, address token) public onlyOwner {
        Token storage t = _mustExist(id);
        if (t.deployed || t.kind != Kind.EVM || t.chainId != block.chainid || t.account != bytes32(0)) {
            revert BadInput();
        }
        if (
            token.code.length == 0 || _boundLocalId[token] != 0 || _position[idOf(token)] != 0
                || _standardOf(token) != Standard.ERC20
        ) revert BadInput();

        t.account = bytes32(uint256(uint160(token)));
        t.deployed = true;
        _pull(t, token);
        _boundLocalId[token] = id;
        _burn(id);
        _mintListing(token, id);
        _touch(id, "activate");
        emit Activated(id, token);
    }

    /// @notice Burn the listing NFT and drop the entry.
    function delist(uint256 id) public onlyOwner {
        uint256 pos = _position[id];
        if (pos == 0) revert Unknown();
        Token storage t = _tokens[id];
        bytes32 account = t.account; // read before the entry is wiped
        if (t.deployed && t.kind == Kind.EVM && t.chainId == block.chainid && account != bytes32(0)) {
            delete _boundLocalId[address(uint160(uint256(account)))];
        }
        uint256 last = _ids[_ids.length - 1];
        _ids[pos - 1] = last;
        _position[last] = pos;
        _ids.pop();
        delete _position[id];
        delete _tokens[id];
        bytes32[] storage keys = _extraKeys[id];
        for (uint256 i = keys.length; i > 0; --i) {
            bytes32 key = keys[i - 1];
            delete _extra[id][key];
            delete _extraPos[id][key];
        }
        delete _extraKeys[id];
        _burn(id);
        emit Delisted(id, account);
    }

    /// @notice Update the owner-authored presentation of a listing.
    function setArt(
        uint256 id,
        uint24 color,
        uint32 rank,
        string calldata logo,
        string calldata url_,
        string calldata description_
    ) public onlyOwner {
        _setArt(_mustEdit(id), color, rank, logo, url_, description_);
        _touch(id, "art");
    }

    /// @notice Declare what a foreign listing represents.
    /// @dev The counterpart to `setForeignText`, and gated the same way: a local
    ///      listing derives `standard` from the token through `_pull` and the owner
    ///      must not be able to overwrite a fact. A foreign listing has no source
    ///      here, so without this its standard is stuck at UNKNOWN forever — the card
    ///      cannot say what the asset is, and `setOnchainSvg` (which requires a
    ///      collection standard) can never be applied to an offchain NFT collection.
    function setStandard(uint256 id, Standard standard_) public onlyOwner {
        Token storage t = _mustEdit(id);
        if (t.synced) revert NotEditable();
        t.standard = standard_;
        // `onchainSvg` only means anything on a collection, and it has to be cleared
        // here for the same reason `_pull` clears it: `setOnchainSvg` re-runs the
        // collection gate, so a flag left behind by a walk back to a fungible standard
        // is not merely stale but IRREVERSIBLE — a fungible listing claiming per-token
        // onchain art that no owner call can take back.
        if (standard_ != Standard.ERC721 && standard_ != Standard.ERC1155) t.onchainSvg = false;
        _touch(id, "text");
    }

    /// @notice Mark an NFT collection whose selected token IDs have onchain SVG art.
    /// @dev This is a rendering hint for NFT-aware clients, not a trust bypass: a
    ///      client still reads and validates the selected token's `tokenURI` before
    ///      embedding it. It is limited to collection standards so a fungible token
    ///      cannot pose as a per-token artwork source.
    function setOnchainSvg(uint256 id, bool onchainSvg_) public onlyOwner {
        Token storage t = _mustEdit(id);
        if (t.standard != Standard.ERC721 && t.standard != Standard.ERC1155) revert BadInput();
        t.onchainSvg = onchainSvg_;
        _touch(id, "nftArt");
    }

    /// @notice Store a raw `<svg>` as the logo, base64-encoded onchain into a data URI.
    /// @dev The markup must declare `xmlns="http://www.w3.org/2000/svg"`. Inline in an
    ///      HTML page the namespace is inherited from the parser and its absence goes
    ///      unnoticed, but a logo here becomes a standalone document where a missing
    ///      `xmlns` renders as a broken image everywhere. Rejecting it costs one
    ///      substring check and turns a silent, list-wide display failure into a
    ///      failed transaction.
    function setLogoSVG(uint256 id, string calldata svg) public onlyOwner {
        // LOGO_MAX bounds the STORED string, which is what `tokenURI` has to carry.
        // Bounding the raw markup instead would let this path store a third more than
        // `setArt` accepts for the identical field, since base64 costs four bytes per
        // three: 24,576 B of SVG becomes a 32,800 B logo.
        if (!LibString.contains(svg, "http://www.w3.org/2000/svg")) revert BadInput();
        string memory uri = _dataURI("image/svg+xml", svg);
        if (bytes(uri).length > LOGO_MAX) revert BadInput();
        _mustEdit(id).logo = uri;
        _touch(id, "art");
    }

    /// @notice Point a listing at its audit or security report. Optional by design:
    ///         an empty value is the normal state and the card simply omits the line
    ///         rather than showing an empty or placeholder link.
    function setAudit(uint256 id, string calldata audit_) public onlyOwner {
        _mustEdit(id).audit = _clean(audit_, URL_MAX);
        _touch(id, "audit");
    }

    /// @notice Set, or with an empty value clear, an open-ended metadata field.
    /// @dev Values are sanitised like every other display string: they reach the same
    ///      JSON consumers as the fixed fields and must not be able to break out of
    ///      them. Clearing removes the key entirely so `extraKeys` never reports a
    ///      field that reads back empty.
    function setExtra(uint256 id, bytes32 key, string calldata value) public onlyOwner {
        _mustEdit(id);
        if (key == bytes32(0)) revert BadInput();
        string memory v = _clean(value, EXTRA_MAX);
        uint256 pos = _extraPos[id][key];
        if (bytes(v).length == 0) {
            // Clearing a key that was never set changes nothing. Returning early keeps
            // it from emitting `ExtraSet`/`MetadataUpdate` for a write that did not
            // happen, which would have every consumer re-read an unchanged listing.
            if (pos == 0) return;
            _dropExtra(id, key, pos);
        } else {
            if (pos == 0) {
                // `delist` walks every key to clear it, so an unbounded key set is an
                // unbounded loop in the only path that can remove a listing. Enough
                // keys and delisting no longer fits in a block, which would strand a
                // bad or malicious listing permanently. Bound the set instead.
                if (_extraKeys[id].length >= EXTRA_KEYS_MAX) revert BadInput();
                _extraKeys[id].push(key);
                _extraPos[id][key] = _extraKeys[id].length;
            }
            _extra[id][key] = v;
        }
        emit ExtraSet(id, key, v);
        // Every other mutation signals ERC-4906, and a renderer swap can make
        // extras visible on the card at any time. Emitting it here means clients
        // are already refreshing on extension fields when that happens, rather
        // than caching a card that silently disagrees with storage.
        _touch(id, "extra");
    }

    /// @notice Seal a listing's owner-authored fields forever.
    /// @dev Irreversible on purpose: a commitment that governance can withdraw is not
    ///      a commitment. After this the owner cannot touch art, links, rank, audit,
    ///      foreign text or extras for this id.
    ///
    ///      Three things deliberately still work. `sync` does, because it copies facts
    ///      from the token itself rather than from the owner — freezing seals what
    ///      governance authored, not what the token says. `activateReserved` does, for
    ///      the same reason: whether the subject shipped is not something governance
    ///      authored, and blocking it would strand a frozen reservation with no exit
    ///      but `delist`, which destroys its id. And `delist` does, because
    ///      a frozen listing whose project later rugs, or whose frozen link starts
    ///      serving malware, would otherwise be a permanent billboard nobody could
    ///      take down. Removing a listing is not misrepresenting it.
    ///
    ///      A freeze is only as strong as the renderer: while `setRenderer` is open,
    ///      the owner can still change what a frozen listing DISPLAYS, even though it
    ///      cannot change what the listing stores. Pair this with `lockRenderer` for
    ///      an end-to-end guarantee.
    function freeze(uint256 id) public onlyOwner {
        // `_mustEdit`, not `_mustExist`: freezing twice is a no-op that still emits
        // `Froze` and `MetadataUpdate`, telling every indexer to re-read a listing
        // that did not change. Reverting makes the event mean what it says.
        _mustEdit(id).frozen = true;
        emit Froze(id);
        _touch(id, "freeze");
    }

    /// @notice Give up the power to change the renderer, forever.
    /// @dev The registry ships with a settable renderer so the card can be improved
    ///      after deploy. That convenience is also the last route by which governance
    ///      can alter what every listing appears to say, since a renderer may print
    ///      anything regardless of storage. This closes it permanently and is the
    ///      other half of `freeze`.
    function lockRenderer() public onlyOwner {
        rendererLocked = true;
        emit RendererLocked();
    }

    /// @notice Point the list at a new card renderer.
    /// @dev Code-length checked for the same reason `list` checks it: a staticcall to a
    ///      codeless address succeeds with empty returndata, so an EOA here would make
    ///      `tokenURI` return empty for every listing rather than revert — a silent,
    ///      list-wide failure nobody notices until a marketplace shows blank cards.
    function setRenderer(TokenListRenderer renderer_) public onlyOwner {
        if (rendererLocked) revert NotEditable();
        if (address(renderer_).code.length == 0) revert BadInput();
        renderer = renderer_;
        emit RendererSet(address(renderer_));
        emit BatchMetadataUpdate(0, type(uint256).max);
        emit ContractURIUpdated();
    }

    /// @notice Set a listing's sort weight. Higher sorts first; 0 is unranked.
    /// @dev Pick a value BETWEEN the neighbours you want it to sit among rather than
    ///      renumbering — that is what the gaps in the seeded weights are for.
    function setRank(uint256 id, uint32 rank) public onlyOwner {
        _mustEdit(id).rank = rank;
        _touch(id, "rank");
    }

    /// @notice Amend the text of a foreign listing, which has no onchain source here.
    function setForeignText(uint256 id, string calldata name_, string calldata symbol_, uint8 decimals_)
        public
        onlyOwner
    {
        Token storage t = _mustEdit(id);
        if (t.synced) revert NotSyncable();
        if (decimals_ > 36) revert BadInput();
        t.name = _clean(name_, NAME_MAX);
        t.symbol = _clean(symbol_, SYMBOL_MAX);
        t.decimals = decimals_;
        _touch(id, "text");
    }

    /// @notice Re-read a local token's metadata. Permissionless: refreshing a fact
    ///         from its source is not a privilege, and keeping it that way means the
    ///         owner is never the reason a stale name persists.
    function sync(uint256 id) public {
        Token storage t = _mustExist(id);
        if (t.kind != Kind.EVM || t.chainId != block.chainid || t.account == bytes32(0)) {
            revert NotSyncable();
        }
        address token = address(uint160(uint256(t.account)));
        // The same guard `list` applies, for the same reason and at the same moment it
        // stops being true. A staticcall to a codeless address succeeds with empty
        // returndata, so once a listed token selfdestructs every read below answers
        // "nothing" — and `sync` is permissionless, so anyone could keep re-asserting
        // `synced = true` on a card whose subject no longer exists.
        if (token.code.length == 0) revert NotSyncable();
        _pull(t, token);
        _touch(id, "sync");
    }

    // READS ----------------------------------------------------------------

    function total() public view returns (uint256) {
        return _ids.length;
    }

    function idAt(uint256 index) public view returns (uint256) {
        if (index >= _ids.length) revert Unknown();
        return _ids[index];
    }

    function isListed(uint256 id) public view returns (bool) {
        return _position[id] != 0;
    }

    function getExtra(uint256 id, bytes32 key) public view returns (string memory) {
        return _extra[id][key];
    }

    /// @notice The keys set on a listing, so a consumer can discover what is there
    ///         rather than having to know them in advance, then read the values with
    ///         a batched `getExtra`. Keys only: the values are unbounded strings, so
    ///         returning them here would make one call's size a function of how much
    ///         extension data a listing happens to carry.
    function extraKeys(uint256 id) public view returns (bytes32[] memory) {
        return _extraKeys[id];
    }

    // NOTE: no `getMany(ids)`. `Multicallable` already batches `get(id)` over an
    // ARBITRARY set in one eth_call, which is strictly more flexible than any fixed
    // wrapper, and `summariesPaged` covers the contiguous case without the unbounded
    // fields.

    /// @notice A page of listings WITHOUT the heavy fields, in LISTING order.
    /// @dev The one bounded read everything else composes from, and the reason the
    ///      registry needs no sort of its own. Everything a dropdown, a token picker
    ///      or a scroll list renders, and none of what makes a whole-struct page
    ///      unsafe at scale: no logo, no description, no links. Bounded per row, so a
    ///      page has a predictable size.
    ///
    ///      LISTING ORDER, NOT RANK ORDER. Ranking, rank-paging and search moved to
    ///      `TokenListLens`, which builds all three on top of this function. They are
    ///      pure views over data this contract already exposes, so keeping them here
    ///      bought nothing and cost EIP-170 headroom the registry cannot get back —
    ///      it is not upgradeable, and it has to retain room to ship a security fix.
    ///      A lens can be redeployed; this cannot. Each row carries its own `rank`,
    ///      so a caller that wants rank order has everything it needs.
    function summariesPaged(uint256 start, uint256 count) public view returns (Summary[] memory out) {
        uint256 total_ = _ids.length;
        if (start >= total_) return out;
        uint256 rest = total_ - start;
        uint256 n = count < rest ? count : rest;
        out = new Summary[](n);
        for (uint256 i; i < n; ++i) {
            uint256 id = _ids[start + i];
            Token storage t = _tokens[id];
            out[i] = Summary(
                id,
                t.account,
                t.chainId,
                t.decimals,
                t.kind,
                t.standard,
                t.deployed,
                t.onchainSvg,
                t.synced,
                t.color,
                t.rank,
                t.frozen,
                t.name,
                t.symbol
            );
        }
    }

    function get(uint256 id) public view returns (Token memory) {
        return _mustExist(id);
    }

    function get(address token) public view returns (Token memory) {
        return _mustExist(idFor(token));
    }

    /// @notice The listing id an address actually resolves to.
    /// @dev Usually `idOf(token)`, but an activated reservation keeps its
    ///      hash-derived id. Every address-keyed read goes through here: routing
    ///      only `get` through the binding left `logoOf(address)` and
    ///      `themeOf(address)` reverting `Unknown` on a listing `get(address)`
    ///      returns, so an activated token's card was readable by struct and not by
    ///      logo or theme.
    function idFor(address token) public view returns (uint256 id) {
        id = _boundLocalId[token];
        if (id == 0) id = idOf(token);
    }

    /// @notice The logo alone, for cheap embedding in another card or an `<img src>`.
    function logoOf(uint256 id) public view returns (string memory) {
        return _mustExist(id).logo;
    }

    /// @notice Theme color as both the raw value and a ready-to-use `#rrggbb`.
    function themeOf(uint256 id) public view returns (uint24 color, string memory hexColor) {
        color = _mustExist(id).color;
        hexColor = _hexColor(color);
    }

    function logoOf(address token) public view returns (string memory) {
        return logoOf(idFor(token));
    }

    function themeOf(address token) public view returns (uint24, string memory) {
        return themeOf(idFor(token));
    }

    // NOTE: there is deliberately no `page()` returning a JSON array. `Multicallable`
    // lets a consumer batch `json(id)` for any set of ids in a single `eth_call`,
    // which is strictly more flexible, and a concatenating loop would make one call's
    // returndata the sum of every logo it touched.

    // CARD -----------------------------------------------------------------

    /// @notice One listing as compact JSON.
    function json(uint256 id) public view returns (string memory) {
        return renderer.json(id, _mustExist(id), _extrasOf(id));
    }

    /// @notice Live, self-contained listing card.
    function tokenURI(uint256 id) public view override returns (string memory) {
        return renderer.tokenURI(id, _mustExist(id), _extrasOf(id));
    }

    /// @dev Flatten the extension mapping for the renderer, which is `pure` and so
    ///      can never read it itself. Without this the escape hatch that exists so a
    ///      new field costs a transaction rather than a redeploy was invisible on the
    ///      card and in the JSON — no renderer, present or future, could reach it.
    ///      Bounded by `EXTRA_KEYS_MAX`, the same cap that keeps `delist` finite.
    function _extrasOf(uint256 id) internal view returns (TokenListRenderer.Extra[] memory out) {
        bytes32[] storage keys = _extraKeys[id];
        uint256 n = keys.length;
        out = new TokenListRenderer.Extra[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 key = keys[i];
            out[i] = TokenListRenderer.Extra(key, _extra[id][key]);
        }
    }

    /// @notice ERC-7572 collection metadata: what this list is, not what one listing is.
    /// @dev Through the renderer, like the cards, and for the same reason: this
    ///      contract is immutable, so a description baked into its bytecode could never
    ///      be revised. NOTE that this makes `contractURI()` on the renderer part of
    ///      the interface a replacement renderer must keep — a renderer without it
    ///      leaves this reverting. `tokenURI` and `json` already carried that
    ///      requirement; this adds a third member to the same set.
    ///
    ///      Forwarded in assembly rather than as `renderer.contractURI()`. The high
    ///      level form decodes a dynamic string out of returndata and re-encodes the
    ///      identical bytes to return them, and that round trip costs over 1,000 B of
    ///      runtime — which this contract, 769 B under EIP-170 at the time, did not
    ///      have. Returning the callee's returndata verbatim is the same value and a
    ///      hundred-odd bytes. A failed call bubbles the callee's revert unchanged.
    function contractURI() public view returns (string memory) {
        address r = address(renderer);
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xe8a3d485) // `contractURI()`
            let ok := staticcall(gas(), r, add(m, 0x1c), 0x04, codesize(), 0x00)
            returndatacopy(m, 0x00, returndatasize())
            if iszero(ok) { revert(m, returndatasize()) }
            return(m, returndatasize())
        }
    }

    // INTERNALS ------------------------------------------------------------

    /// @dev Existence plus "governance may still author this". Every owner-authored
    ///      setter goes through here so a new one cannot silently escape `freeze`.
    function _mustEdit(uint256 id) internal view returns (Token storage t) {
        t = _mustExist(id);
        if (t.frozen) revert NotEditable();
    }

    function _mustExist(uint256 id) internal view returns (Token storage t) {
        if (_position[id] == 0) revert Unknown();
        t = _tokens[id];
    }

    function _dropExtra(uint256 id, bytes32 key, uint256 pos) internal {
        bytes32[] storage keys = _extraKeys[id];
        bytes32 last = keys[keys.length - 1];
        keys[pos - 1] = last;
        _extraPos[id][last] = pos;
        keys.pop();
        delete _extraPos[id][key];
        delete _extra[id][key];
    }

    /// @dev One site for both the indexer-facing event and the ERC-4906 refresh, so a
    ///      new mutation cannot pick up one and forget the other.
    function _touch(uint256 id, bytes32 field) internal {
        emit Updated(id, field);
        emit MetadataUpdate(id);
    }

    /// @dev The only mint site, so a listing cannot come into existence without the
    ///      ERC-5192 lock signal. `_mint`, never `_safeMint`: the holder is the subject
    ///      contract itself, which has no receiver hook and must not be able to refuse
    ///      the card that describes it.
    function _mintListing(address to, uint256 id) internal {
        _mint(to, id);
        emit Locked(id);
    }

    function _emitListed(uint256 id, Token storage t) internal {
        emit Listed(id, t.account, t.chainId, t.symbol, t.name, t.decimals, t.synced);
    }

    function _index(uint256 id) internal {
        _ids.push(id);
        _position[id] = _ids.length;
    }

    function _setArt(
        Token storage t,
        uint24 color,
        uint32 rank,
        string memory logo,
        string memory url_,
        string memory description_
    ) internal {
        if (bytes(logo).length > LOGO_MAX) revert BadInput();
        t.color = color;
        t.rank = rank;
        t.logo = _uri(logo);
        t.url = _clean(url_, URL_MAX);
        t.description = _clean(description_, DESC_MAX);
    }

    /// @dev Read name/symbol/decimals from the token. Solady's reader is gas-capped,
    ///      handles the legacy `bytes32` shape, and returns empty rather than
    ///      reverting — a token with hostile or missing metadata still lists.
    ///
    ///      An empty read is treated as "no answer", not as "the answer is empty", so
    ///      it never overwrites what is already stored. `sync` is permissionless by
    ///      design, and without this any transient failure to answer — a proxy whose
    ///      `name()` grew past the READ_GAS cap, a token that revokes its metadata,
    ///      a selfdestructed one — would let anybody blank a good listing's text and
    ///      reset its decimals to 0, which is the one field a consumer computes with.
    ///      On a first `_pull` the struct is fresh, so an unreadable token still
    ///      lists exactly as before, with empty text.
    function _pull(Token storage t, address token) internal {
        string memory s = _clean(MetadataReaderLib.readName(token, NAME_MAX * 4, READ_GAS), NAME_MAX);
        if (bytes(s).length != 0) t.name = s;
        s = _clean(MetadataReaderLib.readSymbol(token, SYMBOL_MAX * 4, READ_GAS), SYMBOL_MAX);
        if (bytes(s).length != 0) t.symbol = s;
        // Read the FULL word and range-check it before narrowing. `readDecimals` is
        // `uint8(_uint(...))`, so it truncates: a token returning 274 (0x112) reads
        // back as 18, passes any `<= 36` test, and the card then states 18 decimals
        // on the authority of a value the token never gave. Validating before the
        // cast makes the range check mean what it says.
        uint256 d = MetadataReaderLib.readUint(token, abi.encodeWithSignature("decimals()"), READ_GAS);
        if (d != 0 && d <= 36) t.decimals = uint8(d);
        // Same "no answer is not an answer" rule as the text above. `_standardOf`
        // falls back to ERC-20, and against a codeless account that fallback is a
        // guess, not a reading — every probe it makes returns empty. Leaving the
        // stored value alone keeps a permissionless `sync` from demoting an ERC-721
        // listing to ERC-20, which would also strip `onchainSvg` of its meaning in
        // the renderer and leave `setOnchainSvg` unable to restore it.
        Standard s_ = _standardOf(token);
        if (s_ != Standard.UNKNOWN) {
            t.standard = s_;
            // `onchainSvg` only means anything on a collection, and `setOnchainSvg`
            // enforces exactly that on the way in. It has to be enforced on the way
            // out too: a reservation is unsynced, so `setStandard` accepts ERC721 on
            // it, `setOnchainSvg` then sticks, and `activateReserved` pulls the real
            // ERC-20 standard back over it. That left a fungible listing claiming
            // per-token onchain art, and IRREVERSIBLY so — clearing the flag re-runs
            // the same collection gate and reverts. Same shape for any listing whose
            // subject stops answering ERC-165.
            if (s_ != Standard.ERC721 && s_ != Standard.ERC1155) t.onchainSvg = false;
        }
        t.synced = true;
    }

    /// @dev ERC-20 has no ERC-165 interface id, so it is the local fallback only
    ///      after testing the two collection standards. The manual return-word check
    ///      keeps malformed ERC-165 implementations from bricking `list` or `sync`.
    ///      A codeless account answers nothing to either probe, so the ERC-20 fallback
    ///      would be asserting a standard it never observed; report UNKNOWN instead
    ///      and let `_pull` keep what is stored.
    function _standardOf(address token) internal view returns (Standard) {
        if (token.code.length == 0) return Standard.UNKNOWN;
        if (_supportsInterface(token, 0x80ac58cd)) return Standard.ERC721;
        if (_supportsInterface(token, 0xd9b67a26)) return Standard.ERC1155;
        return Standard.ERC20;
    }

    function _supportsInterface(address token, bytes4 interfaceId) internal view returns (bool supported) {
        (bool ok, bytes memory ret) =
            token.staticcall{gas: READ_GAS}(abi.encodeWithSignature("supportsInterface(bytes4)", interfaceId));
        if (!ok || ret.length < 32) return false;
        uint256 answer;
        assembly ("memory-safe") {
            answer := mload(add(ret, 0x20))
        }
        supported = answer == 1;
    }

    /// @dev Labels are display text, not markup. Admit a printable ASCII subset and
    ///      drop the characters that would break out of a JSON string or an SVG TEXT
    ///      NODE, so a token cannot inject either through its own `name()`.
    ///
    ///      The apostrophe is deliberately KEPT. It was dropped alongside the quote
    ///      because the renderer delimits its SVG attributes with single quotes — but
    ///      nothing this function cleans is ever interpolated into an attribute. Name,
    ///      symbol, links, description and extras all land in text nodes and in JSON
    ///      string values, and an apostrophe is legal in both. Dropping it cost every
    ///      possessive and contraction a curator writes: "Circle's stablecoin" was
    ///      stored, and rendered, as "Circles stablecoin". The one field that DOES
    ///      reach an attribute is the logo, which goes through `_uri` below and is
    ///      still checked strictly.
    function _clean(string memory input, uint256 maxLen) internal pure returns (string memory) {
        bytes memory raw = bytes(input);
        bytes memory out = new bytes(raw.length < maxLen ? raw.length : maxLen);
        uint256 kept;
        for (uint256 i; i < raw.length && kept < maxLen; ++i) {
            bytes1 c = raw[i];
            if (c < 0x20 || c > 0x7E) continue;
            if (c == '"' || c == "\\" || c == "<" || c == ">" || c == "&") continue;
            out[kept++] = c;
        }
        assembly ("memory-safe") {
            mstore(out, kept)
        }
        return string(out);
    }

    /// @dev A logo is interpolated into an `href='...'` attribute, so it must be a
    ///      URI and nothing else. Quote and angle-bracket characters would end the
    ///      attribute early and let arbitrary markup into every card that renders it.
    function _uri(string memory input) internal pure returns (string memory) {
        bytes memory raw = bytes(input);
        if (raw.length == 0) return "";
        // `data:image/`, not bare `data:`. The logo is interpolated into an
        // `<image href>` and into the `image` field of the card's JSON, both of
        // which name an image; a `data:text/html` payload accepted here is markup
        // handed to whatever renders the listing, from a governance action that
        // reads as an ordinary logo change.
        bool ok = LibString.startsWith(input, "data:image/") || LibString.startsWith(input, "https://")
            || LibString.startsWith(input, "ipfs://");
        if (!ok) revert BadInput();
        for (uint256 i; i < raw.length; ++i) {
            bytes1 c = raw[i];
            // `&` is rejected alongside the quote and bracket characters: the card
            // interpolates this into an XML attribute, where a raw ampersand is a
            // parse error, not an escape. A URI carrying one would render the whole
            // card as a broken image - the same silent, list-wide failure mode as a
            // logo missing its xmlns. Base64 data: URIs never contain one.
            //
            // `\` is rejected for the JSON side of the same interpolation. A URI
            // ending in a backslash escapes the closing quote of `"l":"…"` and of
            // the `"image"` field, so the whole document stops parsing - and unlike
            // the fixed fields a logo never passes through `_clean`, which is where
            // every other string loses its backslashes.
            if (c < 0x20 || c > 0x7E || c == '"' || c == "'" || c == "\\" || c == "<" || c == ">" || c == "&") {
                revert BadInput();
            }
        }
        return input;
    }

    function _dataURI(string memory mime, string memory body) internal pure returns (string memory) {
        return string.concat("data:", mime, ";base64,", Base64.encode(bytes(body)));
    }

    /// @dev Written out rather than `slice(toHexString(color, 3), 2)`. That form pulled
    ///      two general-purpose LibString routines into the runtime — one formatting an
    ///      arbitrary-width integer, one reslicing the result to drop a `0x` it had just
    ///      written — to produce seven fixed bytes. This contract is within a few
    ///      hundred bytes of EIP-170 and cannot be redeployed once live, so paying a
    ///      general routine's code size for a single fixed-shape output is the wrong
    ///      trade. Lowercase, matching what `toHexString` produced.
    function _hexColor(uint24 color) internal pure returns (string memory) {
        bytes memory out = new bytes(7);
        out[0] = "#";
        for (uint256 i; i < 6; ++i) {
            uint8 nib = uint8((uint256(color) >> ((5 - i) * 4)) & 0xf);
            out[i + 1] = bytes1(nib < 10 ? 48 + nib : 87 + nib);
        }
        return string(out);
    }
}
