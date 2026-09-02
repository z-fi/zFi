// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {LibString} from "../../lib/solady/src/utils/LibString.sol";

/// @dev The lineage a name needs to read. `zSwap` itself is not imported: this
///      contract must be deployable, and its address publishable, before any
///      zSwap exists, so it depends on the SHAPE of one and nothing more.
interface IzSwap {
    function latest() external view returns (address);
    function PREVIOUS() external view returns (address);
    function successor() external view returns (address);
    function succeededAt() external view returns (uint96);
    function html() external view returns (string memory);
}

/// @title zSwapResolver
/// @notice An ENS resolver that answers with whatever zSwap is CURRENT, by
///         walking the successor chain instead of storing an address.
///
/// WHY THIS EXISTS
///   zSwap's page is immutable and its `successor` pointer is write-once, so
///   the chain always knows which version is newest. A name does not - unless
///   somebody remembers to re-point it after every upgrade. That second
///   transaction is the one that gets forgotten, and when it is, the chain says
///   v0.3 while the name still serves v0.1: two records of one fact, disagreeing.
///
///   So this resolver stores no address. It COMPUTES the answer from the chain
///   at read time, which means the DAO's `deployNext` call IS the name update -
///   same transaction, nothing to remember, and no window where the two differ.
///
/// WHAT IT DOES NOT DO
///   It does not move anyone. `html()` still serves its own bytes at its own
///   address forever, and a reader who bookmarked a version keeps that version.
///   Indirection belongs to the name, which everybody already expects to move,
///   and stops there.
///
/// HOW A GATEWAY USES IT
///   `web3://` gateways resolve a name to a CONTRACT: ERC-6821 reads the
///   `contentcontract` text record, falling back to the address record. Both
///   are served here, from the same walk, so a gateway on either path lands on
///   the tip. Contenthash is deliberately absent - it names a blob, and there
///   is no blob here.
contract zSwapResolver {
    using LibString for address;

    /// @notice Governance. The same DAO that deploys successors, so no new
    ///         trusted party is introduced. It cannot change what this resolver
    ///         answers - `ROOT` is immutable and the walk is derived - only
    ///         maintain the name held here, via `manage`.
    address public constant DAO = 0x5E58BA0e06ED0F5558f83bE732a4b899a674053E;

    /// @notice zSwap v0.1 - the ROOT of the lineage, not merely some version.
    /// @dev IMMUTABLE, AND CHECKED AT CONSTRUCTION. An earlier draft set this
    ///      after deployment so this contract's address would not depend on
    ///      zSwap's - but nothing needs that address earlier. The name cannot
    ///      point here until this resolves to something, and this resolves to
    ///      nothing until the root exists, so the ordering freedom bought a
    ///      storage slot, a second transaction, a window in which the name
    ///      answers zero, and one more thing that can be set wrong. A
    ///      constructor argument costs a redeploy to change, which is the
    ///      correct price for "which lineage is this name".
    IzSwap public immutable ROOT;

    error NotDAO();
    error NotTheRoot();

    /// @param v1 zSwap v0.1. Checked to BE the root, not merely a zSwap:
    ///        starting mid-chain would resolve to the tip of a lineage whose
    ///        earlier links this name never named. `successor()` is called for
    ///        its side effect of reverting - a contract that answers
    ///        `PREVIOUS()` but not `successor()` cannot be walked forward, and
    ///        would make every later resolution useless.
    constructor(IzSwap v1) {
        if (v1.PREVIOUS() != address(0)) revert NotTheRoot();
        v1.successor();
        ROOT = v1;
    }

    /// @notice How long a version must have existed before this name serves it.
    /// @dev THE POINT OF A DELAY IS NOT DISTRUST, IT IS TIME. Everything else
    ///      here is derived from the chain the moment the chain changes, which
    ///      is the property that makes the name honest - and, on the one day
    ///      governance is compromised, the property that would carry every
    ///      reader to a hostile page in a single transaction. A version that
    ///      has to stand unchallenged for three days before the NAME carries
    ///      anyone to it is still recorded instantly, still auditable
    ///      instantly, and still reachable instantly by its own address. Only
    ///      the automatic promotion waits, and waiting is exactly what the DAO
    ///      cannot buy back after the fact.
    ///
    ///      Three days, not thirty: a delay long enough to be noticed but short
    ///      enough that shipping a fix stays realistic. It is a constant, so
    ///      changing it means a new resolver and a visible re-point.
    ///
    ///      THE BYPASS, SAID PLAINLY: `manage` can move the name record itself,
    ///      so the DAO can always serve what it likes - MATURITY governs only
    ///      this resolver's automatic answer, a rule the DAO imposes on itself.
    uint256 public constant MATURITY = 3 days;

    /// @notice The newest zSwap this name will serve: the tip of the chain, or
    ///         its predecessor while the tip is still within `MATURITY`.
    /// @dev NEVER REVERTS. A resolver that throws does not fail politely - the
    ///      name stops resolving and the dapp is unreachable through it. If any
    ///      step of the walk fails, the answer is the last version that did
    ///      answer, and the root always does: this contract could not have been
    ///      deployed against a root that did not.
    ///
    ///      WALKED TO A FIXPOINT, not once. `latest()` is bounded at 32 hops on
    ///      purpose - an unbounded walk is a gas bomb the DAO could arm by
    ///      accident - so a single call answers with an INTERMEDIATE version
    ///      once the chain passes 32 links, and a name that quietly serves
    ///      version 32 forever is exactly the silent staleness this contract
    ///      exists to rule out. Asking again from wherever the last answer
    ///      landed costs one `staticcall` per 32 versions and terminates when
    ///      the answer stops moving: 256 versions here, and the bound is on
    ///      THIS side, where it can be redeployed, rather than in the chain.
    ///
    ///      Then it steps BACK over anything too young. A version's age is held
    ///      by its predecessor - `succeededAt` is written by the contract that
    ///      deployed it - so maturity is read one link behind the tip. The
    ///      loop is bounded too: several versions can be young at once if the
    ///      DAO ships in a burst, and the answer walks back through all of
    ///      them to the newest one that has stood long enough.
    ///
    ///      EVERY HOP IS CHECKED FOR CODE FIRST, and that is not belt-and-
    ///      braces. `try/catch` does not catch a call to a codeless address:
    ///      the compiler's own `extcodesize` check reverts BEFORE the call, so
    ///      the `catch` never runs and the whole read path throws. `deployNext`
    ///      refuses to set a codeless successor, so no chain built by it can
    ///      contain one - but that guarantee lives in another contract, and a
    ///      resolver whose name stops resolving should not depend on a check it
    ///      does not make. A link with no code is treated as the end of the
    ///      chain, which is what it is.
    ///
    ///      A version whose predecessor answers zero is treated as MATURE. That
    ///      is deliberate: zero is what a chain deployed before this field
    ///      existed reports, and refusing to serve those would break the name
    ///      rather than protect it.
    function current() public view returns (address tip) {
        IzSwap r = ROOT;
        tip = address(r);
        for (uint256 i; i != 8; ++i) {
            address next;
            try IzSwap(tip).latest() returns (address t) {
                next = t;
            } catch {
                return tip;
            }
            if (next == address(0) || next == tip || next.code.length == 0) break;
            tip = next;
        }
        for (uint256 i; i != 32; ++i) {
            if (tip == address(r)) return tip; // the root is never too young
            address prev;
            try IzSwap(tip).PREVIOUS() returns (address p) {
                prev = p;
            } catch {
                return tip;
            }
            if (prev == address(0) || prev.code.length == 0) return tip;
            uint256 born;
            try IzSwap(prev).succeededAt() returns (uint96 t) {
                born = t;
            } catch {
                return tip; // not a chain that dates its links
            }
            if (born == 0 || block.timestamp >= born + MATURITY) return tip;
            tip = prev;
        }
    }

    /// @notice Every version, oldest first, from the root to the tip.
    /// @dev THE PRIMITIVE A VERSION PICKER NEEDS, and the reason it lives here
    ///      rather than in the page: a page served through the NAME cannot tell
    ///      which version it is - the hostname carries a name, not an address -
    ///      so it has to ask. Asking hop by hop would cost one round trip per
    ///      version; this answers in one.
    ///
    ///      Note what it does NOT do: it lists the tip even when the tip is too
    ///      young for `current()` to serve. A picker should show a reader
    ///      everything that exists, including the version the name is still
    ///      waiting on - hiding it would be the same silence this contract was
    ///      built to remove. Which one is being SERVED is `current()`'s answer,
    ///      and a page can show both facts because it can read both.
    ///
    ///      Bounded at 64, and it stops early on any link that will not answer,
    ///      so a long or damaged chain returns a short list instead of running
    ///      out of gas. The list is therefore a floor, never a claim of
    ///      completeness.
    function versions() external view returns (address[] memory list) {
        address[] memory buf = new address[](64);
        uint256 n;
        address walk = address(ROOT);
        while (n != 64 && walk != address(0)) {
            buf[n++] = walk;
            try IzSwap(walk).successor() returns (address next) {
                if (next.code.length == 0) break; // codeless: not a link, and uncatchable if called
                walk = next;
            } catch {
                break;
            }
        }
        list = new address[](n);
        for (uint256 i; i != n; ++i) {
            list[i] = buf[i];
        }
    }

    /// @notice ENS `addr(bytes32)`. The node is ignored: this resolver is set on
    ///         one name and answers for that name.
    function addr(bytes32) external view returns (address payable) {
        return payable(current());
    }

    /// @notice ENSIP-9 `addr(bytes32,uint256)`. Only coin type 60 (Ethereum)
    ///         has an answer; anything else is empty, per the spec's "no
    ///         address for this coin" rather than a revert.
    function addr(bytes32, uint256 coinType) external view returns (bytes memory) {
        if (coinType != 60) return "";
        address a = current();
        return a == address(0) ? bytes("") : abi.encodePacked(a);
    }

    /// @notice ENS `text(bytes32,string)`. Serves ERC-6821's `contentcontract`,
    ///         which is how a `web3://` gateway is told to render a CONTRACT
    ///         rather than fetch a blob. ERC-3770 form, mainnet-scoped.
    function text(bytes32, string calldata key) external view returns (string memory) {
        if (keccak256(bytes(key)) != keccak256("contentcontract")) return "";
        address a = current();
        if (a == address(0)) return "";
        return string.concat("eip155:1:", a.toHexStringChecksummed());
    }

    /// @dev addr(bytes32) | addr(bytes32,uint256) | text(bytes32,string) | ERC-165.
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x3b3b57de || id == 0xf1cb7e06 || id == 0x59d1d43c || id == 0x01ffc9a7;
    }

    // ------------------------------------------------------- THE LIVE PAGE
    //
    // A name that resolves to an ADDRESS - as a `.wei` name does, via
    // id-then-resolve - only helps if something at that address serves a page.
    // So this contract serves one: `html()` and ERC-5219 `request()`, answered
    // by asking whatever version the chain currently calls newest.
    //
    // THIS IS THE MUTABLE SURFACE, AND IT IS THE ONLY ONE. Every zSwap keeps
    // serving its own chunks at its own address forever; nothing here
    // reaches into one and changes it. What changes is only WHICH version this
    // address relays, and it changes exactly when `deployNext` lands. That is
    // the whole trade the design makes - immutable fixtures, one moving name -
    // stated in code rather than in a README.
    //
    // A reader who wants the moving target uses the name. A reader who wants
    // the bytes they audited uses the version's own address, which this
    // contract cannot affect. Both are one call away from the other:
    // `current()` names the tip, and the tip's `PREVIOUS()` walks back.

    struct KeyValue {
        string key;
        string value;
    }

    /// @notice The current version's page, relayed.
    /// @dev There is no "nothing to serve" case: `ROOT` is set at construction
    ///      and every version serves a page, so the walk always lands on one.
    function html() external view returns (string memory) {
        return IzSwap(current()).html();
    }

    /// @notice ERC-5219, so a `web3://` gateway can serve this address directly.
    /// @dev THE CACHE HEADER IS THE OPPOSITE OF A VERSION'S. Each zSwap answers
    ///      `immutable, max-age=31536000` and means it - its bytes cannot
    ///      change. This address CAN change, on the DAO's next upgrade, so it
    ///      must never be cached as permanent: a gateway that pinned this for a
    ///      year would serve a stale version long after the chain moved, which
    ///      is precisely the failure this contract exists to prevent. Five
    ///      minutes keeps the gateway's load sane without outliving a release.
    function request(string[] memory, KeyValue[] memory)
        external
        view
        returns (uint16 statusCode, string memory body, KeyValue[] memory headers)
    {
        statusCode = 200;
        body = IzSwap(current()).html();
        headers = new KeyValue[](2);
        headers[0] = KeyValue("Content-Type", "text/html");
        headers[1] = KeyValue("Cache-Control", "public, max-age=300");
    }

    /// @notice ERC-4804/5219 resolution mode, matching the versions themselves.
    function resolveMode() external pure returns (bytes32) {
        return "5219";
    }

    // --------------------------------------------------------- HOLDING A NAME
    //
    // A `.wei` name is an NFT, and WNS resolves a name to an ADDRESS - id, then
    // resolve - so pointing the name at THIS contract is what makes the gateway
    // serve the current version. The name can be held anywhere that can point
    // it here; holding it HERE is the version with no key to lose.
    //
    // Two things are needed for that to be safe rather than clever, and both
    // are the kind that are only obvious after they have gone wrong.

    /// @notice WNS, the `.wei` registry. The only contract `manage` can call.
    address public constant WNS = 0x0000000000696760E15f265e828DB644A0c242EB;

    /// @dev ERC-721 acceptance. Without it a `safeTransferFrom` of the name to
    ///      this contract REVERTS, and the plan fails at the last step for a
    ///      reason that has nothing to do with the design.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @notice DAO-gated call into WNS, and nowhere else.
    /// @dev THE NAME MUST STAY MAINTAINABLE. A name held by a contract that
    ///      cannot renew it, re-point it or hand it back is a name with an
    ///      expiry date and no way to reach it - the asset is not safe in here,
    ///      it is buried. So the DAO keeps exactly the reach a registrant
    ///      needs, and no more: one target, hardcoded, no value, no
    ///      delegatecall. It cannot touch `ROOT`, cannot alter what this
    ///      contract serves, and cannot move funds, because there is no path
    ///      from here to any of those.
    function manage(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != DAO) revert NotDAO();
        (bool ok, bytes memory ret) = WNS.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }
}
