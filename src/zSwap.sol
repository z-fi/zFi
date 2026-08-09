// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title zSwap v0.2
/// @notice Permanently-deployed onchain HTML swap dapp for Ethereum mainnet.
/// @dev Architecture: the HTML payload (124796 B) is the runtime bytecode of
///      6 data contracts, deployed separately and passed to the constructor.
///      html() reassembles them via EXTCODECOPY with proper ABI encoding
///      (offset + length + padded data) so any RPC client decodes directly.
///      request() implements ERC-5219 for first-class web3:// gateway
///      compatibility (ERC-4804). Splitting the page across 6 data contracts
///      means EIP-170 caps each chunk, not the dapp
///      (24576 B per chunk, 22660 B headroom).
///
///      The count is a headroom decision, not a hard requirement: the page
///      still fits in 5 (2148 B spare, 1.8%), but a chunk count can only be
///      chosen once - it is fixed in the constructor arity, and the deployed
///      page is immutable. Six leaves room to keep editing the dapp without
///      the next feature forcing a redeploy of the whole stack.
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
///   node script/build-zSwap.mjs             (source comment, sizes, READMEs)
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
    string public constant VERSION = "0.2";

    /// @dev The HTML payload lives in six separate data contracts whose runtime
    /// bytecode IS the markup. Splitting it removes EIP-170 as a ceiling on the
    /// dapp: the 24,576-byte limit now applies per chunk, not to the page. The
    /// chunks are deployed independently and passed in, so this wrapper's own
    /// creation bytecode stays small and cheap to deploy.
    address public immutable DATA1;
    address public immutable DATA2;
    address public immutable DATA3;
    address public immutable DATA4;
    address public immutable DATA5;
    address public immutable DATA6;

    /// @dev A missing or duplicated data chunk would permanently serve broken HTML.
    error InvalidData();

    struct KeyValue {
        string key;
        string value;
    }

    constructor(
        address data1,
        address data2,
        address data3,
        address data4,
        address data5,
        address data6
    ) {
        address[6] memory d = [data1, data2, data3, data4, data5, data6];
        for (uint256 i; i != 6; ++i) {
            if (d[i].code.length == 0) revert InvalidData();
            for (uint256 j = i + 1; j != 6; ++j) {
                if (d[i] == d[j]) revert InvalidData();
            }
        }
        DATA1 = data1;
        DATA2 = data2;
        DATA3 = data3;
        DATA4 = data4;
        DATA5 = data5;
        DATA6 = data6;
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

    /// @dev Reassembles the page from all six chunks in one pass: each chunk is
    /// copied directly after the previous one at the string body, so no
    /// intermediate copy or concatenation is needed.
    function _html() private view returns (string memory s) {
        address d1 = DATA1;
        address d2 = DATA2;
        address d3 = DATA3;
        address d4 = DATA4;
        address d5 = DATA5;
        address d6 = DATA6;
        assembly ("memory-safe") {
            let n1 := extcodesize(d1)
            let n2 := extcodesize(d2)
            let n3 := extcodesize(d3)
            let n4 := extcodesize(d4)
            let n5 := extcodesize(d5)
            let n6 := extcodesize(d6)
            let n12 := add(n1, n2)
            let n123 := add(n12, n3)
            let n1234 := add(n123, n4)
            let n12345 := add(n1234, n5)
            let total := add(n12345, n6)
            s := mload(0x40)
            mstore(s, total) // total string length
            let body := add(s, 0x20)
            extcodecopy(d1, body, 0, n1)
            extcodecopy(d2, add(body, n1), 0, n2)
            extcodecopy(d3, add(body, n12), 0, n3)
            extcodecopy(d4, add(body, n123), 0, n4)
            extcodecopy(d5, add(body, n1234), 0, n5)
            extcodecopy(d6, add(body, n12345), 0, n6)
            let padded := and(add(total, 0x1f), not(0x1f))
            mstore(0x40, add(body, padded)) // bump free memory pointer
        }
    }
}

/* ===== zSwap.html source (canonical, byte-for-byte equivalent of the deployed chunks) =====

<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>zSwap</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 400 400' width='400' height='400'%3E%3Crect width='400' height='400' fill='%23000'/%3E%3CclipPath id='frame'%3E%3Crect width='400' height='400'/%3E%3C/clipPath%3E%3Cg clip-path='url(%23frame)'%3E%3Cpath d='M-60-20L460-20L460 90L80 310L460 310L460 420L-60 420L-60 310L320 90L-60 90Z' fill='white'/%3E%3C/g%3E%3C/svg%3E" type="image/svg+xml">
<style>
:root{color-scheme:light;--b:#fafafa;--c:#fff;--p:#f6f6f6;--f:#000;--m:#888;--n:#666;--e:#ddd;--k:#000;--kf:#fff;--kh:#333;--fh:#ebebeb;--s:0 1px 3px #0000000a,0 8px 24px #0000000f}
.d{color-scheme:dark;--b:#101010;--c:#181818;--p:#242424;--f:#eee;--m:#999;--n:#999;--e:#3d3d3d;--k:#fff;--kf:#000;--kh:#ddd;--fh:#303030;--s:none}
:focus-visible{outline:2px solid var(--m);outline-offset:2px}
@media(prefers-reduced-motion:reduce){*{transition:none!important}.flip:hover{transform:none}}
body{background:var(--b);color:var(--f);font-family:system-ui,sans-serif;min-height:100vh;margin:0;padding:1em .85em;display:flex;flex-direction:column;box-sizing:border-box}
.card{border:1px solid var(--e);border-radius:.5em;padding:.9em;background:var(--c);max-width:22em;width:100%;margin:auto;box-shadow:var(--s);box-sizing:border-box}
#addr{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#addr.on{cursor:pointer}
#addr.on:hover{color:var(--f);text-decoration:line-through}
.meta{display:grid;grid-template-columns:minmax(0,1fr) auto auto auto;align-items:center;gap:.5em;font-size:.85em;color:var(--n);margin-bottom:.75em}
.meta input{width:3em;font-size:.9em;padding:.15em .1em;border:0;border-bottom:1px solid var(--e);border-radius:0;background:transparent;text-align:right;outline:0;color:var(--f);-moz-appearance:textfield}
.meta input::-webkit-outer-spin-button,.meta input::-webkit-inner-spin-button{-webkit-appearance:none;margin:0}
#th,#lk{border:0;border-radius:.4em;background:transparent;cursor:pointer;font-size:1.05em;color:var(--n);width:1.8em;height:1.8em;line-height:1}
#th:hover{background:var(--p);color:var(--f)}
.meta input:hover{border-bottom-color:var(--m)}
.meta input:focus{border-bottom-color:currentcolor}
.panel{background:var(--p);border:1px solid transparent;border-radius:.5em;padding:.82em .85em;margin:.32em 0}
.panel:focus-within{border-color:var(--m)}
.panel small{color:var(--m);font-size:.8em}
.hdr small{text-transform:uppercase;letter-spacing:.08em;font-size:.7em}
.row{display:flex;gap:.4em;align-items:center;margin-top:.35em}
.panel input{font-size:1.4em;border:0;background:transparent;color:var(--f);outline:none;padding:0;flex:1;min-width:0;width:100%;font-variant-numeric:tabular-nums;transition:font-size .1s}
.pill{display:inline-flex;align-items:center;gap:.4em;cursor:pointer;transition:opacity .15s}
.pill:hover,.pill:focus-within{opacity:.6}
.panel select,.dly select{appearance:none;-webkit-appearance:none;border:0;background:transparent url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='8' height='5' viewBox='0 0 8 5'%3E%3Cpath d='M0 0h8L4 5z' fill='%23999'/%3E%3C/svg%3E") no-repeat right 0 center;padding:0 .85em 0 0;max-width:8em;font-size:.9em;font-weight:600;color:var(--f);letter-spacing:.02em;cursor:pointer;text-overflow:ellipsis}
.panel select:focus{outline:0}
svg{vertical-align:middle;flex-shrink:0}
.flip{display:flex;align-items:center;justify-content:center;margin:-.62em auto;width:2em;height:2em;border-radius:50%;border:3px solid var(--c);background:var(--c);cursor:pointer;color:var(--m);padding:0;box-shadow:0 1px 2px #0000000f;transition:all .25s}
.flip:hover{background:var(--fh);color:var(--f);transform:rotate(180deg)}
.primary{width:100%;min-height:3.1em;padding:.9em;overflow-wrap:anywhere;line-height:1.3;font-size:1em;border-radius:.5em;background:var(--k);color:var(--kf);border:0;cursor:pointer;margin-top:.75em;font-weight:600;text-transform:uppercase;letter-spacing:.08em;transition:background .15s}
.primary:hover:not(:disabled){background:var(--kh)}
.primary:disabled{background:var(--e);color:var(--m);cursor:not-allowed}
.rcpt{width:100%;box-sizing:border-box;margin-top:.6em;padding:.62em .8em;border:1px solid var(--e);border-radius:.45em;background:transparent;color:var(--f);font-size:.75em;outline:0;font-family:inherit}
.rcpt:focus{border-color:var(--m)}
.rcpt.bad{border-color:#c33}
#rcvEl{display:block;font-size:.7em;color:var(--m);margin-top:.35em;word-break:break-all;text-align:center}
#rcvEl:empty{display:none}
#stat{font-size:.8em;color:var(--n);word-break:break-all;margin-top:.75em;text-align:center}
#stat:not(:empty){margin-bottom:.5em}
#stat a{color:var(--f);text-decoration:underline}
.hdr{display:flex;justify-content:space-between;align-items:center;gap:.5em}
.tabs{display:flex;gap:.18em;margin-bottom:.75em;background:var(--p);padding:.18em;border-radius:.5em}
.tabs button{flex:1;padding:.5em;font-size:.75em;font-weight:600;text-transform:uppercase;letter-spacing:.08em;border:0;border-radius:.35em;background:transparent;color:var(--m);cursor:pointer;transition:background .15s,color .15s}
.tabs button.on{background:var(--k);color:var(--kf)}
.tabs button:hover:not(.on),.tabs button:focus-visible:not(.on){background:var(--fh);color:var(--f)}
.tabs button.on:hover,.tabs button.on:focus-visible{background:var(--kh)}
.hide{display:none!important}
#book{margin-top:.4em;max-height:17em;overflow-y:auto;overscroll-behavior:contain}
#book:empty{display:none}
#book h6{font-size:.7em;text-transform:uppercase;letter-spacing:.08em;color:var(--m);margin:.6em 0 .3em;font-weight:600;display:flex;justify-content:space-between}
.o{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:.5em;padding:.5em .7em;background:var(--p);border-radius:.6em;margin-bottom:.3em;font-size:.75em}
.o .l{display:flex;align-items:center;gap:.45em;min-width:0}
.o svg{flex-shrink:0}
.o svg+svg{margin-left:-.5em}
.o b{font-weight:600;font-variant-numeric:tabular-nums;display:block}
.o i{font-style:normal;color:var(--m);display:block;font-size:.9em;word-break:break-all}
.o a{color:var(--m)}
.o button{border:0;border-radius:.5em;padding:.4em .7em;font-size:.95em;font-weight:600;background:var(--k);color:var(--kf);cursor:pointer}
.o button:disabled{background:transparent;color:var(--m);cursor:default;font-weight:400}
.tg{display:inline-block;font-size:.85em;padding:.05em .35em;border-radius:.35em;background:var(--e);color:var(--n);margin-left:.3em}
.tg.w{background:#c33;color:#fff}
.dly{display:flex;justify-content:space-between;align-items:center;font-size:.75em;color:var(--n);margin-top:.55em;padding:.55em .8em;background:var(--p);border:1px solid var(--e);border-radius:.45em}
.dly select{font-size:1em}
.dly input{width:9em;border:0;border-bottom:1px solid var(--e);background:transparent;color:var(--f);text-align:right;outline:0;font:inherit;font-variant-numeric:tabular-nums}
#pos{margin-top:.4em}
#pos:empty{display:none}
.ph{margin:.9em 0 .45em;font-size:.9em;color:var(--f);font-weight:700}
.p{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:.5em;padding:.55em .7em;border:1px solid var(--e);border-radius:.45em;margin-bottom:.35em;font-size:.75em}
.p span{flex:1;min-width:8em}
.p b{display:block;font-weight:600;font-variant-numeric:tabular-nums;word-break:break-word}
.p i{font-style:normal;color:var(--m);display:block;font-size:.9em}
.p button{border:0;border-radius:.35em;padding:.4em .7em;font-size:.95em;font-weight:600;background:var(--k);color:var(--kf);cursor:pointer;margin-left:auto}
.p button:hover:not(:disabled),.p button:focus-visible:not(:disabled){background:var(--kh)}
.p button:disabled{background:transparent;color:var(--m);cursor:default;font-weight:400}
#rate{text-wrap:balance}
#bal,#rate{display:block;font-size:.75em;line-height:1.35;margin-top:.5em;text-align:right}
#bal:empty,#rate:empty{display:none}
#bal a{color:var(--f);cursor:pointer;text-decoration:underline;font-weight:600}
.meta input.warn{color:#c33;border-bottom-color:#c33}
#th:focus-visible,#lk:focus-visible{background:var(--p);color:var(--f)}
.chtog{width:100%;margin-top:.55em;padding:.5em;border:1px solid var(--e);border-radius:.45em;background:transparent;color:var(--n);cursor:pointer;font:inherit;font-size:.7em;font-weight:600;text-transform:uppercase;letter-spacing:.08em}
.chtog:hover{color:var(--f);border-color:var(--m)}
.chtog span{display:inline-block;transition:transform .2s}
.chtog[aria-expanded=true] span{transform:rotate(180deg)}
#chBox{margin-top:.4em}
.chtf{display:flex;gap:.18em;background:var(--p);padding:.18em;border-radius:.4em;margin-bottom:.4em}
.chtf button{flex:1;padding:.35em;font:inherit;font-size:.65em;font-weight:600;text-transform:uppercase;letter-spacing:.06em;border:0;border-radius:.3em;background:transparent;color:var(--m);cursor:pointer}
.chtf button.on{background:var(--k);color:var(--kf)}
.chtf .chk{flex:0 0 auto;padding:.35em .6em;border-left:1px solid var(--e);border-radius:0 .3em .3em 0;margin-left:.15em}
.chtf .chk:hover{color:var(--f)}
#chArt{position:relative;border:1px solid var(--e);border-radius:.45em;overflow:hidden;background:var(--p)}
#chArt svg{display:block;width:100%;height:auto}
#chArt .hd{position:absolute;top:.4em;left:.55em;font-size:.7em;color:var(--m);font-variant-numeric:tabular-nums;pointer-events:none}
#chArt .hd b{color:var(--f);font-size:1.25em;font-weight:600}
#chArt .hd .ohlc{display:block;font-size:.9em;opacity:.85}
#chArt{touch-action:pan-y}
#chArt .msg{padding:2.2em .8em;text-align:center;font-size:.72em;color:var(--m);line-height:1.6}
#chNote{display:block;font-size:.65em;color:var(--m);margin-top:.35em;text-align:right;font-variant-numeric:tabular-nums}
@media(pointer:coarse){.rcpt,.meta input{font-size:16px}.p button,.tabs button{padding:.6em .8em}.chtf button{padding:.5em}}
</style>
<script>const H=document.documentElement;let LS;try{LS=localStorage}catch{LS={}}if(LS.t?LS.t=='d':matchMedia('(prefers-color-scheme:dark)').matches)H.className='d'</script>
<div class="card">
<div class="meta"><span id="addr">Not connected</span><label id="slipL">Slippage <input id="slip" type="number" value="0.5" min="0.01" max="10" step="0.1">%</label><button id="lk" title="Copy shareable link" aria-label="Copy shareable link">⧉</button><button id="th" title="Toggle theme" aria-label="Toggle theme">☾</button></div>
<div class="tabs" role="tablist"><button id="tabSwap" class="on" role="tab" aria-selected="true">Swap</button><button id="tabSend" role="tab" aria-selected="false">Send</button><button id="tabBook" role="tab" aria-selected="false">Orders</button></div>
<div class="panel"><div class="hdr"><small id="payL">You pay</small><span class="pill"><span id="fromIcon"></span><select id="fromSel"></select></span></div><div class="row"><input id="amt" type="text" inputmode="decimal" placeholder="0.0" aria-label="Amount to pay" autocomplete="off" spellcheck="false"></div><small id="bal"></small></div>
<button id="flip" class="flip" title="Flip tokens" aria-label="Flip tokens"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14m-5-5 5 5 5-5"/></svg></button>
<div class="panel" id="rcvPanel"><div class="hdr"><small id="rcvHdr">You receive</small><span class="pill"><span id="toIcon"></span><select id="toSel"></select></span></div><div class="row"><input id="outAmt" type="text" inputmode="decimal" placeholder="0.0" aria-label="Amount to receive" autocomplete="off" spellcheck="false"></div><small id="rate"></small></div>
<input id="rc" class="rcpt" placeholder="Recipient (optional) — 0x or .eth/.(g)wei" spellcheck="false" autocomplete="off">
<small id="rcvEl"></small>
<label class="dly hide" id="kindL">Order type<select id="kind"><option value="fixed">Fixed limit</option><option value="dutch">Dutch decay</option></select></label>
<label class="dly hide" id="dlyL">SLOW<select id="dly"><option value="0">Instant</option><option value="3600">1 hour</option><option value="86400">1 day</option><option value="259200">3 days</option><option value="604800">7 days</option></select></label>
<label class="dly hide" id="fillL">Fill<select id="fill"><option value="1">Any amount</option><option value="0">All or nothing</option></select></label>
<label class="dly hide" id="floorL">Floor total<input id="floorAmt" inputmode="decimal" placeholder="0.0"></label>
<label class="dly hide" id="nftIdL">Token ID<input id="nftId" inputmode="numeric" placeholder="Any from collection" spellcheck="false" autocomplete="off"></label>
<button id="swap" class="primary">Connect Wallet</button>
<div id="stat" role="status" aria-live="polite"></div>
<button id="chTog" class="chtog hide" aria-expanded="false">Chart <span>▾</span></button>
<div id="chBox" class="hide"><div class="chtf" id="chTf"></div><div id="chArt"></div><small id="chNote"></small></div>
<div id="pos"></div>
<button id="bkTog" class="chtog hide" aria-expanded="true">Orderbook <span>▾</span></button>
<div id="book"></div>
</div>
<script>
const ic=()=>th.textContent=H.className=='d'?'☀︎':'☾';ic();
th.onclick=()=>{H.classList.toggle('d');LS.t=H.className=='d'?'d':'l';ic()};
const ZQUOTER="0x0000002d9a651b729e3aFBE57Fc84FFDa4a98a13";
const WNS="0x0000000000696760E15f265e828DB644A0c242EB";
const GNS="0x9D51D507BC7264d4fE8Ad1cf7Fe191933A0a81d6";
const ENSREG="0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e";
const ZROUTER="0x000000000000FB114709235f1ccBFfb925F600e4";
const CHAIN_ID=1;
const ZERO="0x0000000000000000000000000000000000000000";
const WETH="0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";
// Onchain token list (src/utils/TokenList.sol), Ethereum mainnet. The built-in
// TOKENS below remain the fallback: any failure - wrong chain, RPC hiccup, an
// empty or malformed list - leaves them in place rather than presenting an empty
// or half-populated picker. See `loadTokenList`.
const TOKENLIST="0x0000006013dF75A31678B786061C2B54bf531524";
const SEL_RANKEDIDS="df7ca268";
const SEL_JSON="74e18e96";
const SEL_CID="fb021939",SEL_RES="4f896d4f",SEL_REV="9af8b7aa";
const SEL_RSLV="0178b8bf",SEL_EADDR="3b3b57de",SEL_ENAME="691f3431";
const SEL_ALLOWANCE="dd62ed3e";
const SEL_DS="3644e515",SEL_NONCES="7ecebe00",SEL_NAME="06fdde03";
const SEL_RPERMIT="7ac2ff7b",SEL_MULTICALL="ac9650d8",SEL_SWEEP="cb019b84";
const PERMIT2="0x000000000022D473030F116dDEE9F6B43aC78BA3";
const SEL_P2TF="09d31579";
const EIP712DOM="EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
const SEL_APPROVE="095ea7b3";
const SEL_BALANCEOF="70a08231";
const C="eth_call",S="eth_sendTransaction",L="latest",I="eth_chainId";
const SOURCES=["UniV2","Sushi","zAMM","UniV3","UniV4","Curve","Lido"];
const ETH_ICON=`<svg width="20" height="20" viewBox="0 0 32 32"><g fill="none" fill-rule="evenodd"><circle cx="16" cy="16" r="16" fill="#627EEA"/><g fill="#FFF" fill-rule="nonzero"><path fill-opacity=".602" d="M16.498 4v8.87l7.497 3.35z"/><path d="M16.498 4L9 16.22l7.498-3.35z"/><path fill-opacity=".602" d="M16.498 21.968v6.027L24 17.616z"/><path d="M16.498 27.995v-6.028L9 17.616z"/><path fill-opacity=".2" d="M16.498 20.573l7.497-4.353-7.497-3.348z"/><path fill-opacity=".602" d="M9 16.22l7.498 4.353v-7.701z"/></g></g></svg>`;
const USDC_ICON=`<svg width="20" height="20" viewBox="0 0 32 32"><g fill="none"><circle fill="#2775CA" cx="16" cy="16" r="16"/><g fill="#FFF"><path d="M20.022 18.124c0-2.124-1.28-2.852-3.84-3.156-1.828-.243-2.193-.728-2.193-1.578 0-.85.61-1.396 1.828-1.396 1.097 0 1.707.364 2.011 1.275a.458.458 0 00.427.303h.975a.416.416 0 00.427-.425v-.06a3.04 3.04 0 00-2.743-2.489V9.142c0-.243-.183-.425-.487-.486h-.915c-.243 0-.426.182-.487.486v1.396c-1.829.242-2.986 1.456-2.986 2.974 0 2.002 1.218 2.791 3.778 3.095 1.707.303 2.255.668 2.255 1.639 0 .97-.853 1.638-2.011 1.638-1.585 0-2.133-.667-2.316-1.578-.06-.242-.244-.364-.427-.364h-1.036a.416.416 0 00-.426.425v.06c.243 1.518 1.219 2.61 3.23 2.914v1.457c0 .242.183.425.487.485h.915c.243 0 .426-.182.487-.485V21.34c1.829-.303 3.047-1.578 3.047-3.217z"/><path d="M12.892 24.497c-4.754-1.7-7.192-6.98-5.424-11.653.914-2.55 2.925-4.491 5.424-5.402.244-.121.365-.303.365-.607v-.85c0-.242-.121-.424-.365-.485-.061 0-.183 0-.244.06a10.895 10.895 0 00-7.13 13.717c1.096 3.4 3.717 6.01 7.13 7.102.244.121.488 0 .548-.243.061-.06.061-.122.061-.243v-.85c0-.182-.182-.424-.365-.546zm6.46-18.936c-.244-.122-.488 0-.548.242-.061.061-.061.122-.061.243v.85c0 .243.182.485.365.607 4.754 1.7 7.192 6.98 5.424 11.653-.914 2.55-2.925 4.491-5.424 5.402-.244.121-.365.303-.365.607v.85c0 .242.121.424.365.485.061 0 .183 0 .244-.06a10.895 10.895 0 007.13-13.717c-1.096-3.46-3.778-6.07-7.13-7.162z"/></g></g></svg>`;
const USDT_ICON=`<svg width="20" height="20" viewBox="0 0 32 32"><g fill="none" fill-rule="evenodd"><circle cx="16" cy="16" r="16" fill="#26A17B"/><path fill="#FFF" d="M17.922 17.383v-.002c-.11.008-.677.042-1.942.042-1.01 0-1.721-.03-1.971-.042v.003c-3.888-.171-6.79-.848-6.79-1.658 0-.809 2.902-1.486 6.79-1.66v2.644c.254.018.982.061 1.988.061 1.207 0 1.812-.05 1.925-.06v-2.643c3.88.173 6.775.85 6.775 1.658 0 .81-2.895 1.485-6.775 1.657m0-3.59v-2.366h5.414V7.819H8.595v3.608h5.414v2.365c-4.4.202-7.709 1.074-7.709 2.118 0 1.044 3.309 1.915 7.709 2.118v7.582h3.913v-7.584c4.393-.202 7.694-1.073 7.694-2.116 0-1.043-3.301-1.914-7.694-2.117"/></g></svg>`;
const WBTC_ICON=`<svg width="20" height="20" viewBox="0 0 32 32"><g fill="none" fill-rule="evenodd"><circle cx="16" cy="16" r="16" fill="#F7931A"/><path fill="#FFF" fill-rule="nonzero" d="M23.189 14.02c.314-2.096-1.283-3.223-3.465-3.975l.708-2.84-1.728-.43-.69 2.765c-.454-.114-.92-.22-1.385-.326l.695-2.783L15.596 6l-.708 2.839c-.376-.086-.746-.17-1.104-.26l.002-.009-2.384-.595-.46 1.846s1.283.294 1.256.312c.7.175.826.638.805 1.006l-.806 3.235c.048.012.11.03.18.057l-.183-.045-1.13 4.532c-.086.212-.303.531-.793.41.018.025-1.256-.313-1.256-.313l-.858 1.978 2.25.561c.418.105.828.215 1.231.318l-.715 2.872 1.727.43.708-2.84c.472.127.93.245 1.378.357l-.706 2.828 1.728.43.715-2.866c2.948.558 5.164.333 6.097-2.333.752-2.146-.037-3.385-1.588-4.192 1.13-.26 1.98-1.003 2.207-2.538zm-3.95 5.538c-.533 2.147-4.148.986-5.32.695l.95-3.805c1.172.293 4.929.872 4.37 3.11zm.535-5.569c-.487 1.953-3.495.96-4.47.717l.86-3.45c.975.243 4.118.696 3.61 2.733z"/></g></svg>`;
const WSTETH_ICON=`<svg width="20" height="20" viewBox="0 0 32 32"><g fill="none"><circle fill="#00A3FF" cx="16" cy="16" r="16"/><path d="M9.437 14.864l-.181.275c-2.048 3.097-1.603 7.253 1.034 9.824 1.561 1.521 3.622 2.353 5.683 2.353 0 0 0 0-6.536-12.452z" fill="#FFF"/><path opacity=".6" d="M15.997 18.611l-6.56-3.747c6.56 12.452 6.56 12.452 6.56 12.452 0-2.683 0-5.623 0-8.705z" fill="#FFF"/><path opacity=".6" d="M22.563 14.864l.181.275c2.048 3.097 1.603 7.253-1.034 9.824-1.561 1.521-3.622 2.353-5.683 2.353 0 0 0 0 6.536-12.452z" fill="#FFF"/><path opacity=".2" d="M16.003 18.611l6.56-3.747c-6.56 12.452-6.56 12.452-6.56 12.452 0-2.683 0-5.623 0-8.705z" fill="#FFF"/><path opacity=".2" d="M16.004 10.239v6.459l5.654-3.23-5.654-3.229z" fill="#FFF"/><path opacity=".6" d="M16.005 10.239l-5.655 3.229 5.655 3.23v-6.46z" fill="#FFF"/><path d="M16.005 4.805l-5.655 8.668 5.655-3.233V4.805z" fill="#FFF"/><path opacity=".6" d="M16.004 10.238l5.658 3.23-5.658-8.674v5.444z" fill="#FFF"/></g></svg>`;
const RETH_ICON=`<svg width="20" height="20" viewBox="0 0 32 32"><circle cx="16" cy="16" r="16" fill="#ED5A37"/><path d="M16 5.75L9.89 15.85 16 19.45l6.08-3.6z" fill="#FFF"/><path d="M16 20.6l-6.11-3.59L16 25.58l6.08-8.57z" fill="#FFF"/></svg>`;
const BOLD_ICON=`<svg width="20" height="20" viewBox="0 0 32 32" fill="none"><circle cx="16" cy="16" r="16" fill="#63D77D"/><path fill-rule="evenodd" clip-rule="evenodd" d="M12.1719 4.56641H8.58203V26.1016H15.7617V25.2422C16.8398 25.793 18.0586 26.1055 19.3555 26.1055C23.7148 26.1055 27.25 22.5703 27.25 18.207C27.25 13.8438 23.7148 10.3086 19.3555 10.3086C18.0586 10.3086 16.8398 10.6211 15.7617 11.1719V4.56641H12.1719ZM15.7617 11.1719C13.207 12.4805 11.457 15.1406 11.457 18.207C11.457 21.2734 13.207 23.9336 15.7617 25.2422V11.1719Z" fill="#1C1D4F"/></svg>`;
const TOKENS=[
{sym:"ETH",   addr:ZERO, dec:18, icon:ETH_ICON},
{sym:"WETH",  addr:WETH, dec:18, icon:ETH_ICON},
{sym:"wstETH",addr:"0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0",dec:18,icon:WSTETH_ICON},
{sym:"rETH",  addr:"0xae78736Cd615f374D3085123A210448E74Fc6393",dec:18,icon:RETH_ICON},
{sym:"WBTC",  addr:"0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599",dec:8, icon:WBTC_ICON},
{sym:"USDC",  addr:"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",dec:6, icon:USDC_ICON},
{sym:"USDT",  addr:"0xdAC17F958D2ee523a2206206994597C13D831ec7",dec:6, icon:USDT_ICON},
{sym:"BOLD",  addr:"0x6440f144b7e50D6a8439336510312d2F54beB01D",dec:18,icon:BOLD_ICON},
];
// The hardcoded TOKENS above are the fallback, not the source of truth: once
// TOKENLIST points at a deployment, the list is read from chain so tokens can be
// added or re-themed without shipping new HTML. Any failure - not deployed, wrong
// chain, RPC hiccup, malformed entry - leaves the built-in list in place rather
// than presenting an empty or half-populated token picker.
async function loadTokenList(){
if(TOKENLIST===ZERO)return;
try{
const ids=decUintArr(await rpc(C,[{to:TOKENLIST,data:"0x"+SEL_RANKEDIDS},L]));
if(!ids.length)return;
const rows=await Promise.all(ids.slice(0,64).map(id=>
rpc(C,[{to:TOKENLIST,data:"0x"+SEL_JSON+encUint(id)},L]).then(decStr).catch(()=>null)));
const next=[];
for(const row of rows){
if(!row)continue;
let t;try{t=JSON.parse(row)}catch{continue}
// Trust nothing: a bad entry is skipped, it does not take the list down.
// The registry is a CURATED list, not a routing table: it carries assets this
// dapp cannot act on at all. Two filters, for two different reasons.
//
// 1. Namespace. A non-EVM listing (Bitcoin, Solana) has no address here — the
//    registry renders those accounts as 32 bytes, so the shape test below
//    already rejects them, but say it outright rather than relying on a
//    length coincidence to keep a Bitcoin asset out of an Ethereum picker.
if(t.k!=="eip155")continue;
// 2. Standard. ERC-20 and the native asset are swappable; ERC-721 is not, but
//    IS auctionable through Swapboard/Dutchboard and needs to resolve in
//    `known()` so orderbook NFT legs render with a symbol and icon. Anything
//    else — UNKNOWN, or a standard added after this page was chunked — is
//    something this dapp has no path for, so it is left out.
const std=t.p==="Native"||t.p==="ERC-20"?"ft":t.p==="ERC-721"?"nft":"";
if(!std)continue;
if(!/^0x[0-9a-f]{40}$/i.test(t.a||""))continue;
if(!Number.isInteger(t.d)||t.d<0||t.d>36)continue;
if(next.some(x=>x.addr.toLowerCase()===t.a.toLowerCase()))continue;
const sym=String(t.s||"").slice(0,12)||"?";
next.push({sym,addr:t.a,dec:t.d,std,icon:t.l?`<img src="${t.l}" width="20" height="20">`:genIcon(sym)});
}
// Fungibles first, NFTs after, each keeping the registry's curation order. The
// picker's default selections are indexes, so a stable partition matters: it
// keeps a swappable token at index 0 no matter how many collections are listed.
next.sort((a,b)=>(a.std==="nft")-(b.std==="nft"));
if(next.some(t=>t.std==="ft"))TOKENS.splice(0,TOKENS.length,...next);
}catch{}
}
const strip0x=h=>h.startsWith("0x")?h.slice(2):h;
const pad32=h=>strip0x(h).padStart(64,"0");
const encUint=v=>pad32(BigInt(v).toString(16));
const encAddr=a=>pad32(a.toLowerCase());
// Head is the offset (always 32 for a lone dynamic return), then the length.
const decStr=hex=>{const h=strip0x(hex);const n=parseInt(h.slice(64,128),16);let s="";
for(let i=0;i<n;i++)s+=String.fromCharCode(parseInt(h.substr(128+i*2,2),16));return s};
const decUintArr=hex=>{const h=strip0x(hex);const n=parseInt(h.slice(64,128),16);const o=[];
for(let i=0;i<n;i++)o.push(BigInt("0x"+h.substr(128+i*64,64)));return o};
const encBool=b=>pad32(b?"1":"0");
const toHex=v=>"0x"+BigInt(v).toString(16);
const parseUnits=(s,dec)=>{
const t=s.trim().replace(/,/g,"");
if(!/^(?:\d+|\d*\.\d+|\d+\.)$/.test(t))throw Error("invalid amount");
const[ip,fp=""]=t.split(".");
if(fp.length>dec)throw Error("too many decimals");
return BigInt((ip||"0")+fp.padEnd(dec,"0"));
};
const formatUnits=(v,dec)=>{
if(!dec)return BigInt(v).toString();
const s=BigInt(v).toString().padStart(dec+1,"0");
const ip=s.slice(0,-dec);
const fp=s.slice(-dec).replace(/0+$/,"");
return fp?`${ip}.${fp}`:ip;
};
const trimAmt=(v,dec)=>{const s=formatUnits(v,dec),i=s.indexOf(".");if(i<0)return s;const r=s.slice(0,i+7).replace(/\.?0+$/,"");return r==="0"&&v?s:r};
// A displayed maximum must never round down below the amount the calldata can
// spend. Keep the compact six-decimal presentation, but round it toward +∞;
// the exact base-unit value is also exposed in the rate element's title.
const maxAmt=(v,dec)=>{v=BigInt(v);if(dec<=6)return formatUnits(v,dec);
const u=10n**BigInt(dec-6);return formatUnits((v+u-1n)/u,6)};
const fitFont=el=>{
const l=el.value.length;
el.style.fontSize=l>18?".9em":l>14?"1.1em":l>10?"1.25em":"1.4em";
};
const decQ=(hex,slip,eo,u,v,S)=>{
const h=strip0x(hex),num=i=>BigInt("0x"+h.slice(i*64,(i+1)*64)),E=()=>{throw Error("bad quote")};
if(h.length<(v+2)*64)E();
const o=Number(num(v))*2;if(o+64>h.length)E();
const n=Number(BigInt("0x"+h.slice(o,o+64)));if(!n||o+64+n*2>h.length)E();
const g=num(u+3),t=g>0n,k=S?(num(3)>0n?0:u):t?u:0,B=10000n,ai=S?num(2)+num(u+2):num(2),ao=S?num(3)+g:t?g:num(3),q=eo?ai:ao;
return{best:{source:Number(num(k)),feeBps:num(k+1),amountIn:ai,amountOut:ao},callData:"0x"+h.slice(o+64,o+64+n*2),amountLimit:eo?(q*(B+slip)+B-1n)/B:q*(B-slip)/B,msgValue:num(v+1)};
};
// `est` is the zero-bound quote used for apples-to-apples route comparison.
// `exe` owns the calldata and its real per-leg slippage budget. Recomputing one
// global bound from `est` can overstate an exact-in Min or understate an
// exact-out Max on multihop routes, so only replace the displayed estimate.
const merge=(est,exe)=>{if(!est)return exe;if(!exe)return null;return{...exe,best:est.best}};
const rpc=(method,params)=>window.ethereum.request({method,params});
const okRet=h=>{h=strip0x(h);if(h&&BigInt("0x"+h)===0n)throw Error("token returned false")};
const waitTx=async hash=>{
const end=Date.now()+600000;
while(Date.now()<end){
const r=await rpc("eth_getTransactionReceipt",[hash]);
if(r){
if(r.status!=="0x1")throw Error("tx reverted: "+hash);
return r;
}
await new Promise(res=>setTimeout(res,1500));
}
throw Error("tx not mined in time");
};
const checkWallet=async()=>{const[c,a]=await Promise.all([rpc(I,[]),rpc("eth_accounts",[])]);if(+c!==1||a[0]?.toLowerCase()!==account.toLowerCase())throw Error("wallet changed")};
const hexToBytes=h=>{const s=strip0x(h);const o=new Uint8Array(s.length/2);for(let i=0;i<o.length;i++)o[i]=parseInt(s.slice(i*2,i*2+2),16);return o};
const KRC=[1n,0x8082n,0x800000000000808an,0x8000000080008000n,0x808bn,0x80000001n,0x8000000080008081n,0x8000000000008009n,0x8an,0x88n,0x80008009n,0x8000000an,0x8000808bn,0x800000000000008bn,0x8000000000008089n,0x8000000000008003n,0x8000000000008002n,0x8000000000000080n,0x800an,0x800000008000000an,0x8000000080008081n,0x8000000000008080n,0x80000001n,0x8000000080008008n];
const KR=[0,1,62,28,27,36,44,6,55,20,3,10,43,25,39,41,45,15,21,8,18,2,61,56,14];
const KM=(1n<<64n)-1n;
const krol=(x,n)=>n?((x<<BigInt(n))|(x>>BigInt(64-n)))&KM:x;
const keccak=b=>{const A=new Array(25).fill(0n),rate=136;
const pad=rate-(b.length%rate),buf=new Uint8Array(b.length+pad);buf.set(b);
buf[b.length]|=1;buf[buf.length-1]|=0x80;
for(let o=0;o<buf.length;o+=rate){
for(let i=0;i<17;i++){let v=0n;for(let j=7;j>=0;j--)v=(v<<8n)|BigInt(buf[o+i*8+j]);A[i]^=v}
for(let r=0;r<24;r++){
const Cc=[];for(let x=0;x<5;x++)Cc[x]=A[x]^A[x+5]^A[x+10]^A[x+15]^A[x+20];
for(let x=0;x<5;x++){const D=Cc[(x+4)%5]^krol(Cc[(x+1)%5],1);for(let y=0;y<25;y+=5)A[x+y]^=D}
const B=[];for(let x=0;x<5;x++)for(let y=0;y<5;y++)B[y+5*((2*x+3*y)%5)]=krol(A[x+5*y],KR[x+5*y]);
for(let x=0;x<5;x++)for(let y=0;y<5;y++)A[x+5*y]=B[x+5*y]^((~B[(x+1)%5+5*y]&KM)&B[(x+2)%5+5*y]);
A[0]^=KRC[r]}}
let out="";for(let i=0;i<4;i++){let v=A[i];for(let j=0;j<8;j++){out+=Number(v&0xffn).toString(16).padStart(2,"0");v>>=8n}}
return "0x"+out};
const namehash=n=>{let nd="0x"+"0".repeat(64);
if(n)for(const l of n.split(".").reverse())nd=keccak(new Uint8Array([...hexToBytes(nd),...hexToBytes(keccak(new TextEncoder().encode(l)))]));
return nd};
const encStr=v=>{const b=new TextEncoder().encode(v);let h="";
for(const x of b)h+=x.toString(16).padStart(2,"0");
return pad32("20")+encUint(b.length)+h.padEnd(Math.ceil(h.length/64)*64,"0")};
const nsFwd=async(reg,n)=>{const id=await rpc(C,[{to:reg,data:"0x"+SEL_CID+encStr(n)},L]);
const a=await rpc(C,[{to:reg,data:"0x"+SEL_RES+strip0x(id)},L]);
return "0x"+strip0x(a).slice(-40)};
const nsRev=async(reg,a)=>{try{return decodeString(await rpc(C,[{to:reg,data:"0x"+SEL_REV+encAddr(a)},L])).trim()}catch{return""}};
const ensRslv=async nd=>"0x"+strip0x(await rpc(C,[{to:ENSREG,data:"0x"+SEL_RSLV+pad32(nd)},L])).slice(-40);
const ensFwd=async n=>{const nd=namehash(n),r=await ensRslv(nd);
if(/^0x0{40}$/i.test(r))return"";
return "0x"+strip0x(await rpc(C,[{to:r,data:"0x"+SEL_EADDR+pad32(nd)},L])).slice(-40)};
const ensRev=async a=>{const nd=namehash(strip0x(a).toLowerCase()+".addr.reverse"),r=await ensRslv(nd);
if(/^0x0{40}$/i.test(r))return"";
try{return decodeString(await rpc(C,[{to:r,data:"0x"+SEL_ENAME+pad32(nd)},L])).trim()}catch{return""}};
const nameFwd=n=>/\.gwei$/i.test(n)?nsFwd(GNS,n):/\.wei$/i.test(n)?nsFwd(WNS,n):/\.eth$/i.test(n)?ensFwd(n):Promise.resolve("");
const nameRev=async a=>await nsRev(WNS,a)||await nsRev(GNS,a)||await ensRev(a)||"";
const decodeString=hex=>{
const h=strip0x(hex);
if(h.length<=64)return new TextDecoder().decode(hexToBytes(h)).replace(/\0+$/,"");
const off=Number(BigInt("0x"+h.slice(0,64)))*2;
const len=Number(BigInt("0x"+h.slice(off,off+64)))*2;
return new TextDecoder().decode(hexToBytes(h.slice(off+64,off+64+len)));
};

const kecStr=v=>keccak(new TextEncoder().encode(v));
const domainSep=(name,ver,tok)=>keccak(hexToBytes(
kecStr(EIP712DOM)+pad32(kecStr(name))+pad32(kecStr(ver))+encUint(CHAIN_ID)+encAddr(tok)));
const permitInfo=async(tok,owner)=>{
try{
const ds=await rpc(C,[{to:tok,data:"0x"+SEL_DS},L]);
if(!ds||ds==="0x")return null;
const nonce=BigInt(await rpc(C,[{to:tok,data:"0x"+SEL_NONCES+encAddr(owner)},L]));
const name=decodeString(await rpc(C,[{to:tok,data:"0x"+SEL_NAME},L]));
for(const ver of ["1","2"])if(domainSep(name,ver,tok).toLowerCase()===ds.toLowerCase())
return{name,ver,nonce};
}catch{}
return null};
const signPermit=async(tok,info,owner,value,deadline)=>{
const td={types:{EIP712Domain:[{name:"name",type:"string"},{name:"version",type:"string"},
{name:"chainId",type:"uint256"},{name:"verifyingContract",type:"address"}],
Permit:[{name:"owner",type:"address"},{name:"spender",type:"address"},
{name:"value",type:"uint256"},{name:"nonce",type:"uint256"},{name:"deadline",type:"uint256"}]},
primaryType:"Permit",domain:{name:info.name,version:info.ver,chainId:CHAIN_ID,verifyingContract:tok},
message:{owner,spender:ZROUTER,value:value.toString(),nonce:info.nonce.toString(),deadline:deadline.toString()}};
const sig=strip0x(await rpc("eth_signTypedData_v4",[owner,JSON.stringify(td)]));
if(sig.length!==130)throw Error("bad signature");
let v=parseInt(sig.slice(128,130),16);if(v<27)v+=27;
return"0x"+SEL_RPERMIT+encAddr(tok)+encUint(value)+encUint(deadline)+encUint(v)+sig.slice(0,64)+sig.slice(64,128)};

const P2DOM={name:"Permit2",chainId:CHAIN_ID,verifyingContract:PERMIT2};
const p2Ready=async(tok,owner)=>{
try{return BigInt(await rpc(C,[{to:tok,data:"0x"+SEL_ALLOWANCE+encAddr(owner)+encAddr(PERMIT2)},L]))}catch{return 0n}};
const signPermit2=async(tok,owner,amount,deadline)=>{
const nonce=BigInt("0x"+[...crypto.getRandomValues(new Uint8Array(31))].map(b=>b.toString(16).padStart(2,"0")).join(""));
const td={types:{EIP712Domain:[{name:"name",type:"string"},{name:"chainId",type:"uint256"},
{name:"verifyingContract",type:"address"}],
TokenPermissions:[{name:"token",type:"address"},{name:"amount",type:"uint256"}],
PermitTransferFrom:[{name:"permitted",type:"TokenPermissions"},{name:"spender",type:"address"},
{name:"nonce",type:"uint256"},{name:"deadline",type:"uint256"}]},
primaryType:"PermitTransferFrom",domain:P2DOM,
message:{permitted:{token:tok,amount:amount.toString()},spender:ZROUTER,
nonce:nonce.toString(),deadline:deadline.toString()}};
const sig=strip0x(await rpc("eth_signTypedData_v4",[owner,JSON.stringify(td)]));
// Permit2 verifies ERC-1271 contract signatures as arbitrary bytes; EOAs still
// return the usual compact/full 64/65-byte form.
const n=sig.length/2;if(!Number.isInteger(n)||n===0||n>4096)throw Error("bad signature");
const tail=encUint(n)+sig.padEnd(Math.ceil(sig.length/64)*64,"0");
return"0x"+SEL_P2TF+encAddr(tok)+encUint(amount)+encUint(nonce)+encUint(deadline)+pad32("a0")+tail};

const hasAtomicBatch=c=>{const k=c&&(c["0x1"]||c[1]||c["1"]||c["0x0"]||c[0]||c["0"]);
return!!(k&&k.atomic&&(k.atomic.status==="supported"||k.atomic.status==="ready"))};
const canBatch=async owner=>{
try{const c=await rpc("wallet_getCapabilities",[owner]);
return hasAtomicBatch(c)}catch{return false}};
const sendBatch=async(owner,calls)=>{
const res=await rpc("wallet_sendCalls",[{version:"2.0.0",chainId:"0x1",from:owner,atomicRequired:true,calls}]);
const id=typeof res==="string"?res:res.id;
for(let i=0;i<600;i++){
try{const st=await rpc("wallet_getCallsStatus",[id]);
const rc=st&&st.receipts&&st.receipts[0],x=rc&&(rc.transactionHash||rc.hash);
if(rc&&rc.status==="0x0")throw Error("batch reverted");
if(x)return x;
const q=String(st&&st.status);
if(q==="500"||/fail|revert|reject/i.test(q))throw Error("batch failed");
if(q==="200"||/CONFIRMED|SUCCESS/i.test(q))throw Error("batch missing tx");
}catch(e){if(/^batch /.test(e.message))throw e}
await new Promise(r=>setTimeout(r,1000))}
throw Error("batch timed out")};
const encCalls=cs=>{const n=cs.length;let head="",tail="";let off=n*32;
for(const c of cs){const d=strip0x(c),len=d.length/2;
head+=encUint(off);const body=encUint(len)+d.padEnd(Math.ceil(d.length/64)*64,"0");
tail+=body;off+=body.length/2}
return"0x"+SEL_MULTICALL+pad32("20")+encUint(n)+head+tail};
const MC3="0xcA11bde05977b3631167028862bE2a173976CA11";
// aggregate3((address,bool,bytes)[]) -> (bool,bytes)[]. Not just fewer
// round-trips: separate eth_calls each resolve at whatever block they land on,
// so routes were being compared across different chain states. One call, one block.
const encAgg3=cs=>{const n=cs.length;let head="",tail="",off=n*32;
for(const c of cs){const d=strip0x(c.data),len=d.length/2;
const body=encAddr(c.to)+encBool(true)+encUint(96)+encUint(len)+d.padEnd(Math.ceil(d.length/64)*64,"0");
head+=encUint(off);tail+=body;off+=body.length/2}
return"0x82ad56cb"+pad32("20")+encUint(n)+head+tail};
const decAgg3=hex=>{const h=strip0x(hex),at=i=>h.slice(i*64,(i+1)*64);
const n=Number(BigInt("0x"+at(1))),out=[];
for(let i=0;i<n;i++){const rel=Number(BigInt("0x"+at(2+i)))/32,w=2+rel;
const ok=BigInt("0x"+at(w))===1n,bo=Number(BigInt("0x"+at(w+1)))/32,lw=w+bo;
const len=Number(BigInt("0x"+at(lw)));
out.push(ok?"0x"+h.slice((lw+1)*64,(lw+1)*64+len*2):null)}
return out};
const mc3=async(cs,tag=L)=>cs.length?decAgg3(await rpc(C,[{to:MC3,data:encAgg3(cs)},tag])):[];
// Impact, no oracle: quote amt and amt/REF_N; with zero impact output scales
// linearly, so the shortfall IS the impact. The reference carries ~1/N of it, so
// this understates - right direction for a warning. Mainnet: ETH/USDC reads
// 0-10 bps at 1-100 ETH, 29 at 1k, 444 at 10k, 8106 at 100k.
const REF_N=100n;
const IMPACT_HIDE=50n, IMPACT_WARN=500n, IMPACT_CONFIRM=1500n, IMPACT_TYPED=3000n;
// eo flips the sense: on exactIn, impact is LESS out than linear; on exactOut it
// is MORE in. Comparing one way on both made exactOut always read 0.
const impactBps=(v,ref,eo)=>{if(!v||!ref)return null;const lin=ref*REF_N;
if(lin===0n)return 0n;
return eo?(v<=lin?0n:(v-lin)*10000n/lin):(v>=lin?0n:(lin-v)*10000n/lin)};
const genIcon=sym=>`<svg width="20" height="20" viewBox="0 0 32 32"><circle cx="16" cy="16" r="16" fill="#999"/><text x="16" y="21" text-anchor="middle" fill="#fff" font-size="13" font-weight="600" font-family="system-ui">${(sym[0]||"?").toUpperCase()}</text></svg>`;
const STORE="zswap:custom";
async function addCustomToken(a,keep=1){
a=a.toLowerCase();
if(!/^0x[0-9a-f]{40}$/.test(a))throw Error("invalid address");
const i=TOKENS.findIndex(t=>t.addr.toLowerCase()===a);
if(i>=0)return i;
const[symRet,decRet]=await Promise.all([
rpc(C,[{to:a,data:"0x95d89b41"},L]),
rpc(C,[{to:a,data:"0x313ce567"},L]),
]);
let sym=decodeString(symRet).trim().replace(/[<>&"'`]/g,"").slice(0,16)||"?";
if(TOKENS.some(t=>t.sym.toLowerCase()===sym.toLowerCase()))sym+=" "+a.slice(0,6)+"\u2026";
const dec=Number(BigInt(decRet));
if(!Number.isInteger(dec)||dec<0||dec>36)throw Error("unsupported decimals");
TOKENS.push({sym,addr:a,dec,std:"ft",icon:genIcon(sym)});
if(keep)try{const arr=JSON.parse(localStorage.getItem(STORE)||"[]");arr.push({sym,addr:a,dec});localStorage.setItem(STORE,JSON.stringify(arr))}catch{}
return TOKENS.length-1;
}
try{for(const t of JSON.parse(localStorage.getItem(STORE)||"[]")){
const addr=(t?.addr||"").toLowerCase();
const dec=+t?.dec;
if(/^0x[0-9a-f]{40}$/.test(addr)&&Number.isInteger(dec)&&dec>=0&&dec<=36&&!TOKENS.some(x=>x.addr.toLowerCase()===addr)){
const sym=String(t.sym||"?").replace(/[<>&"'`]/g,"").slice(0,16)||"?";
TOKENS.push({sym,addr,dec,std:"ft",icon:genIcon(sym)});
}
}}catch{}
const QUOTE_TTL=45000;
let account=null,last=null,fromBalance=0n,mode="in",bSeq=0,tab="swap",sendReady=null,sSeq=0,sendD="0",bookD="86400";
async function refreshBalance(){
const f=TOKENS[fromSel.value];
// fromSel transiently reads "__custom" while the token prompt is open.
if(!account||!f){bal.textContent="";fromBalance=0n;render();return}
const my=++bSeq;
try{
const hex=f.addr===ZERO
?await rpc("eth_getBalance",[account,L])
:await rpc(C,[{to:f.addr,data:"0x"+SEL_BALANCEOF+encAddr(account)},L]);
if(my!==bSeq)return;
fromBalance=BigInt(hex);
const n=+formatUnits(fromBalance,f.dec);
const pretty=n>=1?n.toLocaleString("en-US",{maximumFractionDigits:4}):n.toPrecision(4);
bal.innerHTML=`Balance: ${pretty} <a href="#" title="Use maximum (leaves gas for ETH)">Max</a>`;
}catch{if(my===bSeq){bal.textContent="";fromBalance=0n}}
render();
}
// NFTs stay in the picker — Swapboard and Dutchboard auction them — but they are
// not swappable, so they sit under their own heading instead of being interleaved
// with tokens the router can actually quote. `select.options` still enumerates
// options inside an optgroup, so `syncDisabled` is unaffected.
const optsHtml=()=>{
const opt=(t,i)=>`<option value="${i}">${t.sym}</option>`;
const ft=TOKENS.map((t,i)=>[t,i]).filter(([t])=>t.std!=="nft");
const nft=TOKENS.map((t,i)=>[t,i]).filter(([t])=>t.std==="nft");
return ft.map(([t,i])=>opt(t,i)).join("")
+(nft.length?`<optgroup label="NFT collections — auction only">${nft.map(([t,i])=>opt(t,i)).join("")}</optgroup>`:"")
+`<option value="__custom">+ Custom token…</option>`;
};
const rebuild=()=>{for(const s of[fromSel,toSel]){const v=s.value;s.innerHTML=optsHtml();s.value=v}};
// Each swap side excludes the other's pick. Send has no output token, and
// leaving the hidden pick disabled made that token impossible to send.
const isNft=v=>TOKENS[v]?.std==="nft";
// A collection is listed on every tab so the picker does not reshuffle underneath
// the user, but it is only SELECTABLE where something can act on it. Swapboard and
// Dutchboard take NFT lots; the router cannot quote one and `send` prices its
// transfer in decimals a collection does not have. Gating here rather than in the
// quote path means the disabled state is visible before the click, instead of a
// failed quote after it.
const syncDisabled=()=>{
const pair=tab!=="send";
const nftOk=tab==="book";
for(const[sel,other]of[[fromSel,toSel],[toSel,fromSel]])
for(const opt of sel.options)
opt.disabled=opt.value!=="__custom"&&((pair&&opt.value===other.value)||(!nftOk&&isNft(opt.value)));
};
fromSel.innerHTML=optsHtml();fromSel.value=0;
toSel.innerHTML=optsHtml();toSel.value=5;
syncDisabled();
const syncIcons=()=>{fromIcon.innerHTML=TOKENS[fromSel.value]?.icon||"";toIcon.innerHTML=TOKENS[toSel.value]?.icon||""};
const render=()=>{
if(!account){swap.textContent="Connect Wallet";swap.disabled=false;return}
if(tab==="book"){
// Fixed: both amounts are the limit price. Dutch: `want` is the
// starting total ask and floorAmt is the ending total ask.
const f=TOKENS[fromSel.value],t=TOKENS[toSel.value];
if(!f||!t){swap.textContent="Place order";swap.disabled=true;return}
const dutch=kind.value==="dutch";
let sell=0n,want=0n,floor=0n,badOrderAmount=false;
// An untouched field is not a typo: parsing "" as an amount made a freshly
// opened tab accuse the user of an invalid amount they had not yet entered.
try{if(amt.value.trim())sell=parseUnits(amt.value.trim(),f.dec);
  if(outAmt.value.trim())want=parseUnits(outAmt.value.trim(),t.dec);
  if(dutch&&floorAmt.value.trim())floor=parseUnits(floorAmt.value.trim(),t.dec)}
catch{badOrderAmount=true}
if(badOrderAmount){swap.textContent="Invalid order amount";swap.disabled=true;return}
if(!sell||!want){swap.textContent="Place order";swap.disabled=true;return}
if(f.addr===ZERO&&t.addr===WETH){swap.textContent="Pick different token";swap.disabled=true;return}
if(!dutch&&f.addr===WETH&&t.addr===ZERO){swap.textContent="Pick different token";swap.disabled=true;return}
if(dutch&&floor>want){swap.textContent="Floor exceeds start";swap.disabled=true;return}
if(dutch&&+dly.value===0){swap.textContent="Choose decay duration";swap.disabled=true;return}
if(sell>fromBalance){swap.textContent="Insufficient balance";swap.disabled=true;return}
swap.textContent=dutch
  ?`Dutch ${trimAmt(sell,f.dec)} ${f.sym} · ${trimAmt(want,t.dec)} → ${trimAmt(floor,t.dec)} ${t.sym}`
  :`Place ${fill.value==="1"?"":"all-or-nothing "}order \u2014 ${trimAmt(sell,f.dec)} ${f.sym} \u2192 ${trimAmt(want,t.dec)} ${t.addr===ZERO?"WETH":t.sym}`;
swap.disabled=false;return;
}
if(tab==="send"){
if(!sendReady){swap.textContent="Send";swap.disabled=true;return}
if(sendReady.amount>fromBalance){swap.textContent="Insufficient balance";swap.disabled=true;return}
const a=`${trimAmt(sendReady.amount,sendReady.token.dec)} ${sendReady.token.sym}`,dv=+dly.value;
swap.textContent=(dv?`Lock ${a} for ${rel(dv)}`:`Send ${a}`)+` \u2192 ${sendReady.label}`;
swap.disabled=false;return;
}
if(!last){swap.textContent="Swap";swap.disabled=true;return}
if(last.amountIn>fromBalance){swap.textContent="Insufficient balance";swap.disabled=true;return}
swap.textContent="Swap";swap.disabled=false;
};
syncIcons(); render();
const isRejection=e=>e?.code===4001||/user\s+reject|user\s+denied/i.test(e?.message||"");
async function connect(){
if(!window.ethereum){stat.textContent="No wallet detected.";return}
sessionStorage.removeItem("dc");
let accs;
try{accs=await rpc("eth_requestAccounts",[])}
catch(e){err(e);return}
let chainId=await rpc(I,[]);
if(+chainId!==1){
try{await rpc("wallet_switchEthereumChain",[{chainId:"0x1"}])}
catch(e){stat.textContent=isRejection(e)?"":"Switch to Ethereum mainnet.";return}
}
if(!accs[0])return;
account=accs[0];
// Mainnet-only: TOKENLIST is a mainnet address, and the chain was just enforced.
await loadTokenList();
rebuild();
// rebuild() re-creates the <option> nodes, dropping the disabled flags, and an
// onchain list shorter than the built-in one can leave a selection pointing past
// its end. Restore both before anything reads the pair.
if(!TOKENS[fromSel.value])fromSel.value=0;
if(!TOKENS[toSel.value]||toSel.value===fromSel.value)toSel.value=TOKENS[1]?1:0;
syncDisabled();syncIcons();
showAddr();
refreshBalance();
update();
loadPos();
syncChart();
}
bal.addEventListener("click",async e=>{
if(e.target.tagName!=="A")return;
e.preventDefault();
const f=TOKENS[fromSel.value];
if(!f)return;
let reserve=0n;
if(f.addr===ZERO){
try{reserve=BigInt(await rpc("eth_gasPrice",[]))*(tab!=="send"?900000n:+dly.value?200000n:30000n)}catch{}
}
const max=fromBalance>reserve?fromBalance-reserve:0n;
amt.value=formatUnits(max,f.dec);
setMode("in");fitFont(amt);
update();
});
let seq=0;
const err=e=>stat.textContent=isRejection(e)?"":"Error: "+String(e.message||e).slice(0,110);
const settle=async tx=>{
if(!tx){stat.textContent="Done";return}
if(!/^0x[0-9a-f]{64}$/i.test(tx))throw Error("bad tx");
stat.innerHTML=txLink(tx,"Sent");await waitTx(tx);stat.innerHTML=txLink(tx,"Done")};
const txLink=(h,label)=>`${label} <a href="https://etherscan.io/tx/${h}" target="_blank" rel="noreferrer">${h.slice(0,10)}…${h.slice(-6)}</a>`;
async function update(){
syncIcons();
if(tab==="book")return render();
if(tab==="send")return updateSend();
const my=++seq;
last=null; rate.textContent=""; render();
const f=TOKENS[fromSel.value], t=TOKENS[toSel.value];
if(!f||!t)return;
if(f.addr===t.addr){stat.textContent="Pick different tokens.";return}
stat.textContent="";
const isIn=mode==="in";
const inEl=isIn?amt:outAmt, outEl=isIn?outAmt:amt, inTok=isIn?f:t;
outEl.value=""; fitFont(outEl);
if(!inEl.value.trim())return;
let swapAmt;
try{swapAmt=parseUnits(inEl.value.trim(),inTok.dec)}
catch(e){const q=inEl.value.trim();
if(q&&!/\.$/.test(q))stat.textContent=/decimals/.test(e.message)?`${inTok.sym} has ${inTok.dec} decimals`:"Invalid amount";
return}
if(swapAmt<=0n)return;
const rv=rc.value.trim();
let rcv="";
if(rv){
if(/^0x[0-9a-fA-F]{40}$/.test(rv)){
if(/^0x0{40}$/i.test(rv)){rc.classList.add("bad");rcvEl.textContent="";
outEl.value="";fitFont(outEl);stat.textContent="Recipient cannot be the zero address";return}
rcv=rv;rcvEl.textContent=""}
else if(/\.(g?wei|eth)$/i.test(rv)){
rcvEl.textContent="resolving...";
try{rcv=await nameFwd(rv.toLowerCase())}catch{rcv=""}
if(my!==seq)return;
if(!rcv||/^0x0{40}$/i.test(rcv)){rc.classList.add("bad");rcvEl.textContent="";
outEl.value="";fitFont(outEl);stat.textContent="Name not registered";return}
rcvEl.textContent=rcv}
else{rc.classList.add("bad");rcvEl.textContent="";
outEl.value="";fitFont(outEl);stat.textContent="Recipient must be an address or a .wei / .gwei / .eth name";return}
}else rcvEl.textContent="";
rc.classList.remove("bad");
if(!rv&&f.addr===WETH&&t.addr===ZERO){
outEl.value=inEl.value;fitFont(outEl);
rate.textContent=`1 ${f.sym} = 1 ${t.sym}`;
last={callData:"0x2e1a7d4d"+encUint(swapAmt),msgValue:0n,amountIn:swapAmt,from:f,to:WETH,exp:Date.now()+QUOTE_TTL};
render();return;
}
const pct=Math.min(10,Math.max(.01,+slip.value||.5));
const slipBps=BigInt(Math.round(pct*100));
const deadline=BigInt(Math.floor(Date.now()/1e3)+1800);
outEl.value="...";fitFont(outEl);
const acct=account;
try{
const a=encAddr(rcv||acct||ZERO),rf=encAddr(acct||ZERO),tl=encBool(!isIn)+encAddr(f.addr)+encAddr(t.addr)+encUint(swapAmt)+encUint(slipBps)+encUint(deadline);
const _rq=[];
// collect now, resolve as one batched eth_call below
const Q=(x,d,u,v,S,sb)=>{_rq.push({to:ZQUOTER,data:"0x"+x+d,u,v,S,sb});return _rq.length-1};
let r=null;
const candKey=f.addr.toLowerCase()+":"+t.addr.toLowerCase();
const cachedCandidates=candCache[candKey];
// Pin AMM and book reads to one state snapshot.
const quoteBlock=cachedCandidates&&Date.now()-cachedCandidates.at<15000
  ?cachedCandidates.block:await rpc("eth_blockNumber",[]);
const candJob=acct?swapCandidates(f.addr,t.addr,quoteBlock).catch(()=>{
  const x=[];x.unavailable=true;return x
}):Promise.resolve([]);
const gasPriceJob=acct?rpc("eth_gasPrice",[]).then(BigInt).catch(()=>0n):Promise.resolve(0n);
const pick=y=>{if(!y)return;const v=isIn?y.best.amountOut:y.best.amountIn;if(!v)return;
if(!r||(isIn?v>r.best.amountOut:v<r.best.amountIn))r=y};
// Earlier jobs win ties, keeping the simpler route.
const tl0=encBool(!isIn)+encAddr(f.addr)+encAddr(t.addr)+encUint(swapAmt)+encUint(0n)+encUint(deadline);
// Zero-bound quotes compare estimates; bounded twins supply executable calldata.
const jobs=[
[Q("e453166e",a+rf+tl0,4,9),Q("e453166e",a+rf+tl,4,9)],
[Q("4c464f59",a+tl0,8,13),Q("4c464f59",a+tl,8,13)]];
let splitSlip=0n;
if(isIn){
const w=slipBps*3n,SS=w<150n?150n:w>500n?500n:w;
splitSlip=SS;
const ps=encAddr(f.addr)+encAddr(t.addr)+encUint(swapAmt)+encUint(SS)+encUint(deadline);
// Split calldata enforces SS, so derive its displayed minimum from SS.
for(const x of["892af013","85f86a90"])jobs.push([Q(x,a+ps,4,8,1,SS)]);
}
// Seed planning from the AMM's 99% tail rate, then re-quote the remainder.
const tailStep=swapAmt/100n||1n,tailAmt=swapAmt>tailStep?swapAmt-tailStep:0n;
const tailJobs=[];
if(tailAmt){
  const z=encBool(!isIn)+encAddr(f.addr)+encAddr(t.addr)+encUint(tailAmt)+encUint(0n)+encUint(deadline);
  tailJobs.push(Q("e453166e",a+rf+z,4,9),Q("4c464f59",a+z,8,13));
  if(isIn)for(const x of["892af013","85f86a90"]){
    const ps=encAddr(f.addr)+encAddr(t.addr)+encUint(tailAmt)+encUint(splitSlip)+encUint(deadline);
    tailJobs.push(Q(x,a+ps,4,8,1,splitSlip));
  }
}
// Same-block 1/REF_N quote is the impact reference.
const refAmt=swapAmt/REF_N;
const iRef=refAmt>0n
  ?Q("e453166e",a+rf+encBool(!isIn)+encAddr(f.addr)+encAddr(t.addr)+encUint(refAmt)+encUint(0n)+encUint(deadline),4,9)
  :-1;
// One allow-failure multicall for all quotes.
const mcRaw=await mc3(_rq.map(q=>({to:q.to,data:q.data})),quoteBlock);
if(my!==seq)return;
const dec=_rq.map((q,i)=>{try{return mcRaw[i]?decQ(mcRaw[i],q.sb||slipBps,!isIn,q.u,q.v,q.S):null}catch{return null}});
for(const g of jobs)pick(g.length>1?merge(dec[g[0]],dec[g[1]]):dec[g[0]]);
let tail=null;
for(const i of tailJobs){const y=dec[i];if(!y)continue;
  const v=isIn?y.best.amountOut:y.best.amountIn;
  if(v&&(!tail||(isIn?v>tail.best.amountOut:v<tail.best.amountIn)))tail=y;
}
if(my!==seq)return;
if(!r)throw Error("bad quote");
if(r.best.amountIn<=0n||r.best.amountOut<=0n||(!isIn&&r.amountLimit<r.best.amountIn))throw Error("bad quote");
let hybrid=null,bookIncomplete=false,bookUnavailable=false,plannerBounded=false;
if(acct){
  const candidates=await candJob;
  bookIncomplete=!!candidates.incomplete;
  bookUnavailable=!!candidates.unavailable;
  if(my!==seq)return;
  const quoteRem=async(x,eo)=>{
    const qs=[],groups=[],add=(sel,data,u,v,S,sb)=>{
      qs.push({data:"0x"+sel+data,u,v,S,sb});return qs.length-1};
    const z0=encBool(eo)+encAddr(f.addr)+encAddr(t.addr)+encUint(x)+encUint(0n)+encUint(deadline);
    const zs=encBool(eo)+encAddr(f.addr)+encAddr(t.addr)+encUint(x)+encUint(slipBps)+encUint(deadline);
    groups.push([add("e453166e",a+rf+z0,4,9),add("e453166e",a+rf+zs,4,9)]);
    groups.push([add("4c464f59",a+z0,8,13),add("4c464f59",a+zs,8,13)]);
    if(!eo){
      const w=slipBps*3n,ss=w<150n?150n:w>500n?500n:w;
      const ps=encAddr(f.addr)+encAddr(t.addr)+encUint(x)+encUint(ss)+encUint(deadline);
      for(const sel of["892af013","85f86a90"])groups.push([add(sel,a+ps,4,8,1,ss)]);
    }
    const raw=await mc3(qs.map(q=>({to:ZQUOTER,data:q.data})),quoteBlock);
    const ds=qs.map((q,i)=>{try{return raw[i]?decQ(raw[i],q.sb||slipBps,eo,q.u,q.v,q.S):null}catch{return null}});
    let best=null;
    for(const g of groups){
      const y=g.length>1?merge(ds[g[0]],ds[g[1]]):ds[g[0]];
      if(!y)continue;const v=eo?y.best.amountIn:y.best.amountOut;
      if(v&&(!best||(eo?v<best.best.amountIn:v>best.best.amountOut)))best=y;
    }
    return best;
  };
  const gasValue=async wei=>{
    const token=isIn?t.addr:f.addr;
    if(token===ZERO||token.toLowerCase()===WETH.toLowerCase())return wei;
    const eo=!isIn,ti=isIn?ZERO:token,to=isIn?token:ZERO;
    const z=encBool(eo)+encAddr(ti)+encAddr(to)+encUint(wei)+encUint(0n)+encUint(deadline);
    try{
      const raw=await rpc(C,[{to:ZQUOTER,data:"0xe453166e"+a+rf+z},quoteBlock]);
      const q=decQ(raw,0n,eo,4,9);
      return isIn?q.best.amountOut:q.best.amountIn;
    }catch{return null}
  };
  const tailDelta=swapAmt-tailAmt;
  const seedOut=isIn&&tail&&r.best.amountOut>tail.best.amountOut
    ?r.best.amountOut-tail.best.amountOut:r.best.amountOut;
  const seedIn=!isIn&&tail&&r.best.amountIn>tail.best.amountIn
    ?r.best.amountIn-tail.best.amountIn:r.best.amountIn;
  let p=isIn
    ?planBookExactIn(candidates,swapAmt,seedOut,tail&&seedOut!==r.best.amountOut?tailDelta:r.best.amountIn)
    :planBookExactOut(candidates,swapAmt,seedIn,tail&&seedIn!==r.best.amountIn?tailDelta:r.best.amountOut);
  plannerBounded=!!(p&&p.bounded);
  let amm=null;
  for(let round=0;p&&(isIn?p.ammIn:p.ammOut)&&round<2;round++){
    const rem=isIn?p.ammIn:p.ammOut;
    amm=await quoteRem(rem,!isIn).catch(()=>null);
    if(!amm)break;
    const next=isIn
      ?planBookExactIn(candidates,swapAmt,amm.best.amountOut,rem)
      :planBookExactOut(candidates,swapAmt,amm.best.amountIn,rem);
    if(!next){p=null;break}
    const stable=(isIn?next.ammIn===p.ammIn:next.ammOut===p.ammOut);
    p=next;plannerBounded=plannerBounded||!!p.bounded;if(stable)break;
  }
  if(p){
    const rem=isIn?p.ammIn:p.ammOut;
    amm=rem?await quoteRem(rem,!isIn).catch(()=>null):null;
    if(!rem||amm){
      const recipient=rcv||acct;
      const ammBudget=amm?(isIn?rem:amm.amountLimit):0n;
      const totalBudget=p.bookIn+ammBudget;
      const expectedIn=p.bookIn+(amm?amm.best.amountIn:0n);
      const expectedOut=p.bookOut+(amm?amm.best.amountOut:0n);
      const saving=isIn
        ?(expectedOut>r.best.amountOut?expectedOut-r.best.amountOut:0n)
        :(expectedIn<r.best.amountIn?r.best.amountIn-expectedIn:0n);
      let gasFloor=null;
      if(saving){
        const gasPrice=await gasPriceJob;
        if(gasPrice){
          // Conservative incremental executor + settlement gas.
          const extraWei=gasPrice*(120000n+105000n*BigInt(p.fills.length));
          gasFloor=await gasValue(extraWei);
        }
      }
      const edgeBps=5n+2n*BigInt(p.fills.length);
      const fallbackWin=isIn
        ?expectedOut*10000n>r.best.amountOut*(10000n+edgeBps)
        :expectedIn*(10000n+edgeBps)<r.best.amountIn*10000n;
      const wins=saving>0n&&(gasFloor===null?fallbackWin:saving*10n>gasFloor*12n);
      if(my!==seq)return;
      if(wins){
        const fp=encFillPlanAndSwap(
          p.fills,f.addr,t.addr,recipient,acct,deadline,ammBudget,amm?amm.callData:"0x"
        );
        const minOut=isIn?p.bookOut+(amm?amm.amountLimit:0n):swapAmt;
        // A free full Dutch fill must not sweep unrelated router token dust.
        const snwapIn=totalBudget===0n?ZERO:f.addr;
        const planCall=encSnwap(snwapIn,totalBudget,recipient,t.addr,minOut,SWAPBOL,fp);
        const callData=f.addr===ZERO?planCall:encCalls([
          encCheckpoint(SWAPBOL,f.addr,acct),planCall
        ]);
        let fundedCallData=null;
        if(f.addr!==ZERO){
          fundedCallData=encPermit2Hybrid(
            amm?amm.callData:"0x",p.fills,f.addr,t.addr,recipient,acct,deadline,p.bookIn,p.bookOut
          );
        }
        r={...r,best:{...r.best,amountIn:expectedIn,amountOut:expectedOut},callData,
          fundedCallData,amountLimit:isIn?minOut:totalBudget,msgValue:f.addr===ZERO?totalBudget:0n};
        hybrid=isIn
          ?{bookIn:p.bookIn,bookOut:p.bookOut,ammIn:p.ammIn}
          :{bookIn:p.bookIn,bookOut:p.bookOut,ammOut:p.ammOut};
        plannerBounded=plannerBounded||!!p.bounded;
      }
    }
  }
}
const finalIn=r.best.amountIn;
const finalOut=r.best.amountOut;
if(isIn){outAmt.value=trimAmt(finalOut,t.dec);fitFont(outAmt)}
else{amt.value=trimAmt(finalIn,f.dec);fitFont(amt)}
const rx=(+formatUnits(finalOut,t.dec))/(+formatUnits(finalIn,f.dec));
const s=r.best.source,raw=SOURCES[s]||"?";
const src=hybrid?"Orderbook + AMM":(s===3||s===4)&&r.best.feeBps?`${raw} ${Number(r.best.feeBps)/100}%`:raw;
rate.textContent=isFinite(rx)?`1 ${f.sym} ≈ ${rx>=1?rx.toLocaleString("en-US",{maximumFractionDigits:4}):rx.toPrecision(4)} ${t.sym} · ${src}`:"";
rate.title="";
if(isIn)rate.textContent+=` · Min ${trimAmt(r.amountLimit,t.dec)} ${t.sym}`;
else{
const exactMax=formatUnits(r.amountLimit,f.dec);
rate.textContent+=` · Max ${maxAmt(r.amountLimit,f.dec)} ${f.sym}`;
rate.title=`Exact maximum: ${exactMax} ${f.sym}`;
}
if(bookIncomplete)rate.textContent+=" · Book scan capped";
if(plannerBounded)rate.textContent+=" · Planner heuristic/capped";
if(bookUnavailable)rate.textContent+=" · AMM only (books offline)";
// Hidden below IMPACT_HIDE: deep pairs read a few bps and always showing that
// teaches people to ignore it. Slippage bounds the QUOTE, not a fair rate, so a
// ruinous trade passes a tight slippage check untouched.
const refQ=iRef>=0&&dec[iRef]?dec[iRef].best:null;
const imp=refQ?impactBps(isIn?finalOut:finalIn,isIn?refQ.amountOut:refQ.amountIn,!isIn):null;
// The reference leg priced 1/REF_N of this trade, so scaling it up is what the
// market would have paid. A percentage is abstract under pressure; the amount
// you are giving up is not, so carry it through to the confirm.
const mkt=refQ?(isIn?refQ.amountOut:refQ.amountIn)*REF_N:0n;
const lossTok=imp!==null&&mkt?(isIn?(mkt>finalOut?mkt-finalOut:0n):(finalIn>mkt?finalIn-mkt:0n)):0n;
if(imp!==null&&imp>=IMPACT_HIDE){
const pctTxt=(Number(imp)/100).toFixed(2);
rate.textContent+=` · Impact ${pctTxt}%`;
if(imp>=IMPACT_WARN)stat.textContent=`High price impact: ${pctTxt}% — about ${trimAmt(lossTok,isIn?t.dec:f.dec)} ${isIn?t.sym:f.sym} worse than the market rate.`;
}
const inApprove=isIn?swapAmt:r.msgValue||r.amountLimit;
if(acct)last={callData:r.callData,fundedCallData:r.fundedCallData,msgValue:r.msgValue,
amountIn:inApprove,from:f,exp:Date.now()+QUOTE_TTL,impact:imp,
lossTok,lossSym:isIn?t.sym:f.sym,lossDec:isIn?t.dec:f.dec,
mkt,got:isIn?finalOut:finalIn,isIn};
render();
}catch(e){if(my===seq){outEl.value="";fitFont(outEl);stat.textContent="No route: "+(e.message||e)}}
}
let debounceT;
const showAddr=async()=>{const a=account,short=a.slice(0,6)+"..."+a.slice(-4);
addr.textContent=short;addr.title=a+" - click to disconnect";addr.classList.add("on");
const n=await nameRev(a);if(n&&a===account)addr.textContent=n};
async function disconnect(){
sessionStorage.setItem("dc","1");
try{await rpc("wallet_revokePermissions",[{eth_accounts:{}}])}catch{}
location.reload();
}
addr.onclick=()=>{if(account)disconnect()};
const updateSoon=()=>{clearTimeout(debounceT);debounceT=setTimeout(update,250)};
const setMode=m=>{mode=m;const o=m==="in"?outAmt:amt;o.value="";fitFont(o);last=null;sendReady=null;render()};
amt.addEventListener("input",()=>{if(tab==="book"){fitFont(amt);render();return}setMode("in");fitFont(amt);updateSoon()});
outAmt.addEventListener("input",()=>{if(tab==="book"){fitFont(outAmt);render();return}setMode("out");fitFont(outAmt);updateSoon()});
// A slippage far from the default is the single easiest way to get sandwiched,
// so it is worth colouring rather than leaving as a silent number.
const slipWarn=()=>slip.classList.toggle("warn",+slip.value>=3);
if(LS.slip&&+LS.slip>=.01&&+LS.slip<=10)slip.value=LS.slip;
slipWarn();
slip.addEventListener("input",()=>{last=null;slipWarn();render();updateSoon()});
rc.addEventListener("input",()=>{last=null;sendReady=null;render();updateSoon()});
slip.addEventListener("change",()=>{slip.value=Math.min(10,Math.max(.01,+slip.value||.5));slipWarn();LS.slip=slip.value});
for(const sel of [fromSel,toSel]){
sel.dataset.prev=sel.value;
sel.addEventListener("change",async()=>{
if(sel.value!=="__custom"){
sel.dataset.prev=sel.value;
syncDisabled();
if(sel===fromSel)refreshBalance();
loadChart();
update();
return;
}
last=null;render();
const prev=sel.dataset.prev;
const a=(prompt("Paste token address:")||"").trim();
if(!a){sel.value=prev;update();return}
stat.textContent="Loading token...";
try{
const idx=await addCustomToken(a);
rebuild();
const otherSel=sel===fromSel?toSel:fromSel;
if(String(idx)===otherSel.value){otherSel.value=prev;otherSel.dataset.prev=prev}
sel.value=String(idx);
sel.dataset.prev=sel.value;
stat.textContent="";
syncDisabled();
refreshBalance();
update();
}catch(e){
const msg="Couldn't load token: "+(e.message||e);
sel.value=prev;
// Restore the previous pair, then re-quote it; otherwise the form stays on a
// cleared quote with a disabled button until the user touches something else.
syncDisabled();refreshBalance();update();
stat.textContent=msg;
}
});
}
flip.onclick=()=>{const a=fromSel.value,b=toSel.value,v=outAmt.value.replace(/,/g,"");fromSel.value=b;toSel.value=a;if(v&&!isNaN(+v))amt.value=v;setMode("in");fitFont(amt);syncDisabled();refreshBalance();loadChart();update()};
window.ethereum?.on?.("chainChanged",()=>location.reload());
window.ethereum?.on?.("accountsChanged",()=>location.reload());
(async()=>{
if(!window.ethereum||sessionStorage.getItem("dc"))return;
try{
const accs=await rpc("eth_accounts",[]);
const cid=await rpc(I,[]);
if(accs[0]&&+cid===1){
account=accs[0];
showAddr();
refreshBalance();update();syncChart();
}
}catch{}
})();
const SEL_TRANSFER="a9059cbb";
// -------------------------------------------------------------- ORDERBOOK
// Current Swapboard + legacy v1. The deprecated 0x..85B831 board is excluded.
const SB2="0x000000dA7bb4B2A9E3e80e9A4D4157E26CA6189b";
const SB1="0x000000fF3D7A2d373615141d7489Ca66683DbecF";
const SBVIEW="0x000000E0b25449F32f7D9259aC449bA88E78dFCE";
const SWAPBOL="0x0000003069053df109F47acac630e03C77804AD8";
const DUTCH="0x000000a213b430D14Bae6062c176289B05e04489";
const ORDERBOL="0x000000fADa565c5608570a4F66Fb5E0bD08ef91B";
// Floorboard: the standing-BID book. The mirror of every other book here -
// the bidder is buying, so whoever acts on a bid is SELLING into it. Its lens
// is separate from SBVIEW because an OrderView row cannot say "any id from
// this collection", and that is the whole point of a floor bid.
const FLOOR="0x00000080198137F790DA4C52bb902cf87c276748";
const FLOORVIEW="0x0000004E376e9dB5D9EC28E6711E1a64997C6ba7";
const SEL_NEXTID="2a58b330",SEL_GETORDERS="03652027",SEL_CANCELORD="514fcac7";
const SEL_FILL1="c37dfc5b",SEL_FILL2="9d136c7f",SEL_FILL2_UNWRAP="3987baf4",SEL_FILL2_ETH="6f608bab";
const SEL_RECENT="6a9849c1",SEL_RECENT_DUTCH="98035c9a",SEL_DUTCH_FILL="ae7a8260",SEL_DUTCH_CANCEL="40e58ee5";
const SEL_CANCEL_UNWRAP="21dd76f9",SEL_DUTCH_CANCEL_UNWRAP="8382de65";
const SEL_DUTCH_LISTING="de74e57b";
const SEL_CANDS="5f452988",SEL_DUTCH_CANDS="eb33e466",SEL_FILLPLAN="c277f67c";
const SEL_FILLPLAN_SWAP="9090c8e5",SEL_SNWAP="5f3bd1c8";
// collectionBids(address,address,address,uint256,uint256,uint256) and
// hitNFT(uint256,uint256[],uint256,bool).
const SEL_COLL_BIDS="16bb24eb",SEL_HIT_NFT="d001810f";
const SEL_ORDER_FIXED="bcdb7936",SEL_ORDER_DUTCH="fb910431",SEL_CHECKPOINT="a972985e";
const BOARDS=[{a:SB2,v2:1},{a:SB1,v2:0}];
const WORDS=b=>b?11:6;   // static struct width, so decoding is positional
let bookSeq=0,bookRows=[],candCache={},bkOpen=LS.bk!=="0";

const known=a=>TOKENS.find(t=>t.addr.toLowerCase()===a.toLowerCase());
const sm=i=>i.replace('width="20" height="20"','width="15" height="15"');
// Token metadata is attacker-controlled. Rows are rendered with innerHTML, so
// normalize every lens-provided symbol before it reaches text or an SVG.
const safeSym=s=>String(s??"").replace(/[<>&"'`]/g,"")
  .replace(/[\u0000-\u001f\u007f]/g,"").trim().slice(0,16)||"?";
const escan=(a,id)=>`<a href="https://etherscan.io/${id!=null?`nft/${a}/${id}`:`token/${a}`}" target="_blank" rel="noreferrer">${a.slice(0,6)}…${a.slice(-4)} ↗</a>`;

async function leg(addr,amt,isNft,meta){
  const k=known(addr);
  if(isNft)return{ic:genIcon("#"),txt:`#${amt}`,ok:0,link:escan(addr,amt)};
  const raw=meta&&meta.sym?meta:await tokMeta(addr),m={...raw,sym:safeSym(raw.sym)};
  return{ic:k?sm(k.icon):genIcon(m.sym),txt:`${trimAmt(amt,m.dec)} ${k?safeSym(k.sym):'“'+m.sym+'”'}`,ok:!!k,link:addr===ZERO?"ETH":escan(addr)};
}

// Collection-wide floor bids for `collection`, from the Floorboard lens.
//
// A BidRow carries dynamic members (`ids` and two symbols), so each element of
// the returned array is itself offset-encoded — the row head is a pointer, not
// the row. Getting that wrong reads `bidder` out of an ABI offset, which
// decodes to a plausible-looking address, so the walk below is written against
// the pointer indirection explicitly and refuses anything inconsistent.
//
// Every failure returns [] rather than throwing: an unreachable lens should
// read as "no floor liquidity" and leave the rest of the quote intact.
function decBidRows(hex){
  try{
    const h=strip0x(hex),bytes=h.length/2;
    const word=b=>{if(b<0||b+32>bytes)throw 0;return BigInt("0x"+h.slice(b*2,(b+32)*2))};
    const num=b=>{const v=word(b);if(v>0xffffffffffffffffn)throw 0;return Number(v)};
    const arr=num(0);                       // offset to rows[]
    if(arr<64||arr+32>bytes)throw 0;
    const n=num(arr),base=arr+32;
    if(n>256||base+n*32>bytes)throw 0;
    const out=[];
    for(let i=0;i<n;i++){
      const row=base+num(base+i*32);        // element pointer, then the row
      if(row+17*32>bytes)throw 0;
      const f=k=>word(row+k*32);
      out.push({
        id:f(0),
        bidder:"0x"+h.slice((row+1*32+12)*2,(row+2*32)*2),
        token:"0x"+h.slice((row+2*32+12)*2,(row+3*32)*2),
        quote:"0x"+h.slice((row+3*32+12)*2,(row+4*32)*2),
        isNFT:f(4)!==0n,
        anyId:f(5)!==0n,
        remaining:f(7),
        initial:f(8),
        price:f(9),
        proceeds:f(10),
        expiry:f(12),
      });
    }
    return out;
  }catch{return[]}
}

// What the collection-wide bids on `collection` will pay, right now. Backs the
// blank Token ID: the user names a collection and no id, and this answers with
// the standing bids that will take ANY of them. Paying asset unconstrained —
// address(0) accepts whatever the bid escrowed.
async function collectionFloor(collection){
  if(FLOORVIEW===ZERO||FLOOR===ZERO)return[];
  const data="0x"+SEL_COLL_BIDS+encAddr(FLOOR)+encAddr(collection)+encAddr(ZERO)
    +encUint(0)+encUint(16)+encUint(256);
  const raw=await rpc(C,[{to:FLOORVIEW,data},L]).catch(()=>null);
  if(!raw)return[];
  const rows=decBidRows(raw);
  // Best unit price first. Cross-multiplied for the same reason the lens does
  // it: proceeds and remaining are routinely twelve decimals apart, so a
  // division truncates every row to zero and the sort becomes a no-op.
  return rows.filter(r=>r.anyId&&r.remaining>0n)
    .sort((a,b)=>{const l=b.proceeds*a.remaining,r=a.proceeds*b.remaining;return l>r?1:l<r?-1:0});
}

function decViewPage(hex){
  const h=strip0x(hex),bytes=h.length/2;
  const word=b=>{if(b<0||b+32>bytes)throw Error("bad lens page");return BigInt("0x"+h.slice(b*2,(b+32)*2))};
  const addr=(b)=>"0x"+h.slice((b+12)*2,(b+32)*2);
  const arr=Number(word(0)),next=word(32);
  if(!Number.isSafeInteger(arr)||arr<64||arr+32>bytes)throw Error("bad lens offset");
  const n=Number(word(arr)),head=arr+32;
  if(!Number.isSafeInteger(n)||n>256||head+n*32>bytes)throw Error("bad lens length");
  const text=(base,k)=>{const off=Number(word(base+k*32)),p=base+off,len=Number(word(p));
    if(!Number.isSafeInteger(off)||!Number.isSafeInteger(len)||len>64||p+32+len>bytes)throw Error("bad lens string");
    const a=new Uint8Array(len);for(let i=0;i<len;i++)a[i]=parseInt(h.slice((p+32+i)*2,(p+33+i)*2),16);
    return new TextDecoder().decode(a)};
  const rows=[];
  for(let i=0;i<n;i++){
    const off=Number(word(head+i*32)),b=head+off;
    if(!Number.isSafeInteger(off)||b+16*32>bytes)throw Error("bad lens row");
    rows.push({id:word(b),maker:addr(b+32),pf:word(b+64)===1n,exp:word(b+96),
      nA:word(b+128)===1n,nB:word(b+160)===1n,cp:addr(b+192),
      tA:addr(b+224),aA:word(b+256),sA:safeSym(text(b,9)),dA:Number(word(b+320)),
      tB:addr(b+352),aB:word(b+384),sB:safeSym(text(b,13)),dB:Number(word(b+448)),board:addr(b+480)});
  }
  return{rows,next};
}

const betterRate=(a,b)=>a.aA*b.aB>b.aA*a.aB;
const MAX_BOOK_LEGS=32,AON_PAIR_SEEDS=24;
function planBookExactIn(rows,amountIn,ammOut,ammIn){
  if(!amountIn||!ammIn)return null;
  let c=rows.filter(o=>!o.nA&&!o.nB&&o.aA&&(o.aB||o.dutch)&&(o.pf||o.aB<=amountIn));
  const candidateCapped=c.length>256;
  const aonCount=c.reduce((n,o)=>n+!o.pf,0);
  const aonBounded=aonCount>=3;
  c.sort((a,b)=>betterRate(a,b)?-1:betterRate(b,a)?1:0);
  if(c.length>256)c.length=256;
  const build=(seed=-1,seed2=-1)=>{
    let rem=amountIn,bin=0n,bout=0n,fills=[],legCapped=false;
    const take=o=>{
      if(o.aA*ammIn<=ammOut*o.aB)return;
      if(!o.pf&&o.aB>rem)return;
      if(fills.length>=MAX_BOOK_LEGS){legCapped=true;return}
      if(o.aB===0n){
        fills.push({id:o.id,board:o.board,pay:0n,get:o.aA,part:false});
        bout+=o.aA;return;
      }
      const pay=o.aB<rem?o.aB:rem;
      if(!pay)return;
      const get=o.pf?o.aA*pay/o.aB:o.aA;
      if(!get)return;
      fills.push({id:o.id,board:o.board,pay,get,part:o.pf&&pay<o.aB});
      rem-=pay;bin+=pay;bout+=get;
    };
    if(seed>=0)take(c[seed]);
    if(seed2>=0)take(c[seed2]);
    for(let i=0;i<c.length;i++)if(i!==seed&&i!==seed2)take(c[i]);
    return{fills,bookIn:bin,bookOut:bout,ammIn:rem,score:bout+rem*ammOut/ammIn,
      bounded:candidateCapped||aonBounded||legCapped};
  };
  let best=build(-1);
  for(let i=0;i<c.length;i++)if(!c[i].pf){
    const p=build(i);if(p.score>best.score)best=p;
  }
  const aon=[];for(let i=0;i<c.length&&aon.length<AON_PAIR_SEEDS;i++)if(!c[i].pf)aon.push(i);
  for(let i=0;i<aon.length;i++)for(let j=i+1;j<aon.length;j++){
    const p=build(aon[i],aon[j]);if(p.score>best.score)best=p;
  }
  return best.fills.length?best:null;
}

const cheaperRate=(a,b)=>a.aB*b.aA<b.aB*a.aA;
function planBookExactOut(rows,amountOut,ammIn,ammOut){
  if(!amountOut||!ammOut)return null;
  let c=rows.filter(o=>!o.nA&&!o.nB&&o.aA&&(o.aB||o.dutch)&&(o.pf||o.aA<=amountOut));
  const candidateCapped=c.length>256;
  const aonCount=c.reduce((n,o)=>n+!o.pf,0);
  const aonBounded=aonCount>=3;
  c.sort((a,b)=>cheaperRate(a,b)?-1:cheaperRate(b,a)?1:0);
  if(c.length>256)c.length=256;
  const build=(seed=-1,seed2=-1)=>{
    let left=amountOut,bin=0n,bout=0n,fills=[],legCapped=false;
    const take=o=>{
      if(o.aB*ammOut>=ammIn*o.aA)return;
      if(!o.pf&&o.aA>left)return;
      if(fills.length>=MAX_BOOK_LEGS){legCapped=true;return}
      const want=o.aA<left?o.aA:left;
      let pay,get;
      if(o.aB===0n){pay=0n;get=want}
      else if(want===o.aA){pay=o.aB;get=o.aA}
      else{
        pay=(want*o.aB+o.aA-1n)/o.aA;
        if(pay>o.aB)pay=o.aB;
        get=pay*o.aA/o.aB;
      }
      if(!get)return;
      fills.push({id:o.id,board:o.board,pay,get,part:want!==o.aA});
      bin+=pay;bout+=get;left-=get<left?get:left;
    };
    if(seed>=0)take(c[seed]);
    if(seed2>=0)take(c[seed2]);
    for(let i=0;i<c.length&&left;i++)if(i!==seed&&i!==seed2)take(c[i]);
    return{fills,bookIn:bin,bookOut:bout,ammOut:left,score:bin+left*ammIn/ammOut,
      bounded:candidateCapped||aonBounded||legCapped};
  };
  let best=build(-1);
  for(let i=0;i<c.length;i++)if(!c[i].pf){
    const p=build(i);if(p.score<best.score)best=p;
  }
  const aon=[];for(let i=0;i<c.length&&aon.length<AON_PAIR_SEEDS;i++)if(!c[i].pf)aon.push(i);
  for(let i=0;i<aon.length;i++)for(let j=i+1;j<aon.length;j++){
    const p=build(aon[i],aon[j]);if(p.score<best.score)best=p;
  }
  return best.fills.length?best:null;
}

function encFillPlan(fills,tokenIn,tokenOut,recipient,refundTo,deadline){
  let tail=encUint(fills.length);
  for(const f of fills)tail+=encUint(f.id)+encAddr(f.board)+encUint(f.pay)+encUint(f.get)+encBool(f.part);
  return"0x"+SEL_FILLPLAN+encAddr(tokenIn)+encAddr(tokenOut)+encAddr(recipient)+encAddr(refundTo)
    +encUint(deadline)+encUint(192)+tail;
}

function encFillPlanAndSwap(fills,tokenIn,tokenOut,recipient,refundTo,deadline,ammIn,ammData){
  let ft=encUint(fills.length);
  for(const f of fills)ft+=encUint(f.id)+encAddr(f.board)+encUint(f.pay)+encUint(f.get)+encBool(f.part);
  const d=strip0x(ammData||"0x"),dt=encUint(d.length/2)+d.padEnd(Math.ceil(d.length/64)*64,"0");
  return"0x"+SEL_FILLPLAN_SWAP+encAddr(tokenIn)+encAddr(tokenOut)+encAddr(recipient)+encAddr(refundTo)
    +encUint(deadline)+encUint(256)+encUint(ammIn)+encUint(256+ft.length/2)+ft+dt;
}

function encSnwap(tokenIn,amountIn,recipient,tokenOut,minOut,executor,data){
  const d=strip0x(data),body=encUint(d.length/2)+d.padEnd(Math.ceil(d.length/64)*64,"0");
  return"0x"+SEL_SNWAP+encAddr(tokenIn)+encUint(amountIn)+encAddr(recipient)+encAddr(tokenOut)
    +encUint(minOut)+encAddr(executor)+encUint(224)+body;
}
const encCheckpoint=(executor,token,recipient)=>encSnwap(
  ZERO,0n,recipient,ZERO,0n,executor,"0x"+SEL_CHECKPOINT+encAddr(token)
);
const encSweep=(token,amount,to)=>"0x"+SEL_SWEEP+encAddr(token)+encUint(0)+encUint(amount)+encAddr(to);
function encPermit2Hybrid(ammData,fills,tokenIn,tokenOut,recipient,refundTo,deadline,bookIn,bookOut){
  const bookData=encFillPlan(fills,tokenIn,tokenOut,recipient,refundTo,deadline);
  // Isolate the exact book budget before an exact-out AMM has a chance to
  // sweep/refund zRouter's whole token balance. The book executor is already
  // prefunded, so the protecting outer snwap uses a zero token input.
  const steps=[encCheckpoint(SWAPBOL,tokenIn,refundTo)];
  if(bookIn)steps.push(encSweep(tokenIn,bookIn,SWAPBOL));
  steps.push(encSnwap(ZERO,0n,recipient,tokenOut,bookOut,SWAPBOL,bookData));
  if(ammData&&ammData!=="0x")steps.push(ammData);
  // Exact-out AMMs can spend less than their maximum. Return anything still
  // physically held by zRouter to the payer, never the output recipient.
  steps.push(encSweep(tokenIn,0n,refundTo));
  return encCalls(steps);
}

async function swapCandidates(tokenIn,tokenOut,block){
  const key=tokenIn.toLowerCase()+":"+tokenOut.toLowerCase(),old=candCache[key];
  if(old&&Date.now()-old.at<15000&&old.block===block){
    old.rows.incomplete=old.incomplete;return old.rows;
  }
  const snapshotAt=Date.now();
  const boardIn=tokenIn===ZERO?WETH:tokenIn;
  const boardOut=tokenOut===ZERO?WETH:tokenOut;
  const [lc,le]=await Promise.all([
    rpc("eth_getCode",[SBVIEW,block]),rpc("eth_getCode",[SWAPBOL,block])
  ]);
  if(lc.length<5||le.length<5){
    const rows=[];rows.unavailable=true;return rows;
  }
  const specs=[...BOARDS];
  if(DUTCH!==ZERO&&(await rpc("eth_getCode",[DUTCH,block])).length>4){
    specs.push({a:DUTCH,dutch:1,ti:tokenIn});
    // Swapbol can wrap the native route budget per Dutch leg, so ETH users
    // compete against both literal-ETH and WETH-quoted Dutch liquidity.
    if(tokenIn===ZERO)specs.push({a:DUTCH,dutch:1,ti:WETH});
  }
  const groups=await Promise.all(specs.map(async b=>{
    let cursor=0n,out=[],turns=0,incomplete=false,failed=false;
    try{do{
      // Swapboards are WETH books at the native boundary. Dutchboard can take
      // native quote payment directly, but its sold lot is always ERC-20, so
      // native output is represented by a WETH lot and unwrapped by Swapbol.
      const ti=b.dutch?b.ti:boardIn,to=boardOut;
      const data="0x"+(b.dutch?SEL_DUTCH_CANDS:SEL_CANDS)+encAddr(b.a)
        +(b.dutch?"":encBool(b.v2))+encAddr(ti)+encAddr(to)+encAddr(SWAPBOL)
        +encUint(cursor)+encUint(512);
      const p=decViewPage(await rpc(C,[{to:SBVIEW,data},block]));
      out.push(...p.rows.map(r=>({...r,v2:b.v2||0,dutch:b.dutch||0})));
      cursor=p.next;
      ++turns;
    }while(cursor&&turns<64)}catch{failed=true;incomplete=true}
    incomplete=incomplete||!!cursor;
    return{out,incomplete,failed};
  }));
  let rows=groups.flatMap(g=>g.out);
  if(tokenIn===ZERO&&tokenOut.toLowerCase()===WETH.toLowerCase()){
    rows=rows.filter(r=>r.dutch&&r.tA.toLowerCase()===WETH.toLowerCase()&&r.tB===ZERO);
  }
  const incomplete=groups.some(g=>g.incomplete);
  rows.incomplete=incomplete;
  rows.unavailable=groups.every(g=>g.failed&&!g.out.length);
  // A slow older request must not make a later block look freshly cached.
  const current=candCache[key],bn=BigInt(block),cn=current?BigInt(current.block):-1n;
  if(!current||bn>cn||(bn===cn&&snapshotAt>=current.at)){
    candCache[key]={at:snapshotAt,block,rows,incomplete};
  }
  // Entries are only fresh for 15s; drop the rest so a long session that touches
  // many pairs does not pin every page of every book it ever quoted.
  for(const k in candCache)if(k!==key&&snapshotAt-candCache[k].at>60000)delete candCache[k];
  return rows;
}

async function lensBookRows(my){
  if((await rpc("eth_getCode",[SBVIEW,L])).length<5)return null;
  const specs=[...BOARDS];
  if(DUTCH!==ZERO&&(await rpc("eth_getCode",[DUTCH,L])).length>4)specs.push({a:DUTCH,dutch:1});
  const pages=await Promise.all(specs.map(async b=>{
    let cursor=0n,out=[],turns=0;
    do{
      const data="0x"+(b.dutch?SEL_RECENT_DUTCH:SEL_RECENT)+encAddr(b.a)
        +(b.dutch?"":encBool(b.v2))+encUint(cursor)+encUint(80)+encUint(256);
      const p=decViewPage(await rpc(C,[{to:SBVIEW,data},L]));
      out.push(...p.rows.map(r=>({...r,v2:b.v2||0,dutch:b.dutch||0})));
      cursor=p.next;
    }while(cursor&&out.length<160&&++turns<64&&my===bookSeq);
    return out;
  }));
  return pages.flat();
}

async function loadBook(){
  if(!account||tab!=="book"){book.innerHTML="";bookRows=[];syncBook(0);return}
  const my=++bookSeq;
  const live=[];
  for(const b of BOARDS){
    let code="0x";
    try{code=await rpc("eth_getCode",[b.a,L])}catch{}
    if(code.length>4)live.push(b);
  }
  if(my!==bookSeq)return;
  if(!live.length){book.innerHTML='<h6><span>Orderbook</span></h6><div class="o"><span class="l"><i>No Swapboard deployed on this network yet.</i></span></div>';return}
  let rows=null;
  try{rows=await lensBookRows(my)}catch{rows=null}
  if(my!==bookSeq)return;
  if(!rows)rows=[];
  for(const b of rows.length?[]:live){
    let total=0;
    try{total=Number(BigInt(await rpc(C,[{to:b.a,data:"0x"+SEL_NEXTID},L])))}catch{continue}
    if(!total)continue;
    // newest first: low ids are overwhelmingly filled or cancelled
    const hi=total,lo=Math.max(0,hi-40);
    const ids=[];for(let i=hi-1;i>=lo;--i)ids.push(i);
    let raw="";
    try{raw=await rpc(C,[{to:b.a,data:"0x"+SEL_GETORDERS+encUint(32)+encUint(ids.length)+ids.map(i=>encUint(i)).join("")},L])}catch{continue}
    if(my!==bookSeq)return;
    const h=strip0x(raw);if(!h)continue;
    const w=WORDS(b.v2),n=Number(BigInt("0x"+h.slice(64,128)));
    const at=(r,k)=>BigInt("0x"+h.slice(128+(r*w+k)*64,128+(r*w+k+1)*64));
    const ad=(r,k)=>"0x"+h.slice(128+(r*w+k)*64+24,128+(r*w+k+1)*64);
    for(let r=0;r<n&&r<ids.length;++r){
      if(at(r,1)!==1n)continue;                       // not active
      const o=b.v2
        ?{id:ids[r],board:b.a,v2:1,maker:ad(r,0),pf:at(r,2)===1n,exp:at(r,3),
          nA:at(r,4)===1n,nB:at(r,5)===1n,cp:ad(r,6),
          tA:ad(r,7),aA:at(r,8),tB:ad(r,9),aB:at(r,10)}
        :{id:ids[r],board:b.a,v2:0,maker:ad(r,0),pf:0,exp:0n,nA:0,nB:0,
          cp:ZERO,tA:ad(r,2),aA:at(r,3),tB:ad(r,4),aB:at(r,5)};
      if(o.exp&&BigInt(Math.floor(Date.now()/1e3))>o.exp)continue;   // expired
      if(o.cp!==ZERO
        &&o.cp.toLowerCase()!==account.toLowerCase()
        &&o.maker.toLowerCase()!==account.toLowerCase())continue; // neither maker nor permitted taker
      rows.push(o);
    }
  }
  if(my!==bookSeq)return;
  rows=rows.filter(o=>{
    if(o.exp&&BigInt(Math.floor(Date.now()/1e3))>o.exp)return false;
    return o.cp===ZERO
      ||o.cp.toLowerCase()===account.toLowerCase()
      ||o.maker.toLowerCase()===account.toLowerCase();
  });
  const dutchRows=rows.filter(r=>r.dutch);
  if(dutchRows.length){
    const raw=await mc3(dutchRows.map(r=>({to:DUTCH,data:"0x"+SEL_DUTCH_LISTING+encUint(r.id)})));
    raw.forEach((x,i)=>{if(!x)return;const h=strip0x(x),w=n=>BigInt("0x"+h.slice(n*64,(n+1)*64));
      if(h.length>=640)Object.assign(dutchRows[i],{
        start:w(2),duration:w(3),startPrice:w(5),endPrice:w(7),initial:w(8),remaining:w(9)
      });
    });
  }
  bookRows=rows;
  if(!rows.length){book.innerHTML="";syncBook(0);return}
  const legs=await Promise.all(rows.map(r=>Promise.all([
    leg(r.tA,r.aA,r.nA,r.sA!=null?{sym:r.sA,dec:r.dA}:null),
    leg(r.tB,r.aB,r.nB,r.sB!=null?{sym:r.sB,dec:r.dB}:null)
  ])));
  if(my!==bookSeq)return;
  let own="",rest="",nOwn=0,nRest=0;
  rows.forEach((r,i)=>{
    const[a,bg]=legs[i];
    const mine=r.maker.toLowerCase()===account.toLowerCase();
    const tags=(r.nA||r.nB?'<span class="tg">NFT</span>':"")
      +(r.v2&&!r.pf&&!r.nA&&!r.nB?'<span class="tg">AON</span>':"")
      +(r.dutch?'<span class="tg">Dutch</span>':"")
      +(r.cp!==ZERO?'<span class="tg">private</span>':"")
      +(!a.ok||!bg.ok?'<span class="tg w">unverified</span>':"");
    const now=BigInt(Math.floor(Date.now()/1e3));
    let when=r.exp?" · "+rel(Number(r.exp-now))+" left":"";
    if(r.dutch&&r.duration){
      const end=r.start+r.duration;
      const floor=r.initial?(r.endPrice*r.remaining+r.initial-1n)/r.initial:0n;
      when=now>=end?` · floor reached: ${trimAmt(floor,r.dB)} ${r.sB}`
        :` · floor ${trimAmt(floor,r.dB)} ${r.sB} in ${rel(Number(end-now))}`;
    }
    const act=mine?`<button data-x="c" data-i="${r.id}" data-b="${r.board}" data-v="${r.v2}" data-d="${r.dutch||0}">Cancel</button>`
                  :`<button data-x="f" data-i="${r.id}" data-b="${r.board}" data-v="${r.v2}" data-d="${r.dutch||0}">Fill</button>`;
    const row=`<div class="o"><span class="l">${a.ic}${bg.ic}<span><b>${a.txt} → ${bg.txt}</b>`
      +`<i>${a.link}${tags}${when}</i></span></span>${act}</div>`;
    if(mine){own+=row;++nOwn}else{rest+=row;++nRest}
  });
  let html="";
  if(nOwn)html+=`<h6><span>Your orders</span><span>${nOwn}</span></h6>`+own;
  if(nRest)html+=`<h6><span>Orderbook</span><span>${nRest}</span></h6>`+rest;
  book.innerHTML=html;
  syncBook(nOwn+nRest);
}
// The book can run long, so it collapses to a caret and scrolls when open. With
// nothing in it there is no control at all, the same rule the chart follows.
function syncBook(n){
  const on=tab==="book"&&n>0;
  bkTog.classList.toggle("hide",!on);
  bkTog.firstChild.nodeValue=n?`Orderbook (${n}) `:"Orderbook ";
  bkTog.setAttribute("aria-expanded",on&&bkOpen?"true":"false");
  book.classList.toggle("hide",!on||!bkOpen);
}
bkTog.onclick=()=>{bkOpen=!bkOpen;LS.bk=bkOpen?"1":"0";syncBook(bookRows.length)};

book.addEventListener("click",async e=>{
  const b=e.target.closest("button[data-i]");
  if(!b)return;
  b.disabled=true;
  try{
    await checkWallet();
    const id=BigInt(b.dataset.i),to=b.dataset.b,dl=BigInt(Math.floor(Date.now()/1e3)+1800);
    const row=bookRows.find(x=>String(x.id)===b.dataset.i&&x.board.toLowerCase()===to.toLowerCase());
    if(!row)throw Error("order changed — refresh and retry");
    // The token selects can transiently read "__custom", so never index blind.
    const selFrom=TOKENS[fromSel.value],selTo=TOKENS[toSel.value];
    if(b.dataset.x==="c"){
      const native=selFrom?.addr===ZERO&&!row.nA
        &&row.tA.toLowerCase()===WETH.toLowerCase();
      const sel=b.dataset.d==="1"
        ?(native?SEL_DUTCH_CANCEL_UNWRAP:SEL_DUTCH_CANCEL)
        :(native&&b.dataset.v==="1"?SEL_CANCEL_UNWRAP:SEL_CANCELORD);
      const data="0x"+sel+encUint(id);
      stat.textContent=`Cancelling — the unfilled remainder returns as ${native&&(b.dataset.d==="1"||b.dataset.v==="1")?"ETH":"its escrow token"}`;
      const tx={from:account,to,data,value:"0x0"};
      await rpc(C,[tx,L]);
      await settle(await rpc(S,[tx]));
      loadBook();refreshBalance();return;
    }

    const r=row;

    // Public fungible orders can use the same zRouter funding waterfall as a
    // swap. Swapbol remains msg.sender at the board, so private orders must
    // stay on the direct-wallet path below or their counterparty guard would
    // be weakened. NFTs likewise keep their native approval semantics.
    const nativeOut=selTo?.addr===ZERO&&!r.nA
      &&r.tA.toLowerCase()===WETH.toLowerCase();
    const nativeIn=selFrom?.addr===ZERO&&!r.nB
      &&r.tB.toLowerCase()===WETH.toLowerCase();
    const routeIn=nativeIn?ZERO:r.tB;
    const routeOut=nativeOut?ZERO:r.tA;
    const canonicalNative=routeIn.toLowerCase()===routeOut.toLowerCase()
      ||(routeOut===ZERO&&routeIn.toLowerCase()===WETH.toLowerCase());
    if(!r.nA&&!r.nB&&r.cp===ZERO&&!canonicalNative){
      if((await rpc("eth_getCode",[SWAPBOL,L])).length<5)throw Error("orderbook executor not deployed yet");
      const pay=r.aB,fillPlan=encFillPlan([
        {id:r.id,board:r.board,pay,get:r.aA,part:false}
      ],routeIn,routeOut,account,account,dl);
      // amount == 0 means "sweep all" to zRouter, so a free Dutch fill must
      // name native input on the protecting snwap even when its quote is ERC20.
      const planCall=encSnwap(pay?routeIn:ZERO,pay,account,routeOut,r.aA,SWAPBOL,fillPlan);
      const checkpoint=routeIn===ZERO?null:encCheckpoint(SWAPBOL,routeIn,account);
      const direct=checkpoint?encCalls([checkpoint,planCall]):planCall;
      const funded=routeIn===ZERO||!pay?direct:encCalls([
        checkpoint,
        encSweep(routeIn,pay,SWAPBOL),
        encSnwap(ZERO,0n,account,routeOut,r.aA,SWAPBOL,fillPlan)
      ]);
      const meta=known(routeIn)||{addr:routeIn,sym:r.sB||"TOKEN",dec:r.dB||18};
      await sendRouterFunded(direct,funded,meta,pay,routeIn===ZERO?pay:0n,"Filling order...");
      loadBook();refreshBalance();return;
    }

    const data=r.dutch
      ?"0x"+SEL_DUTCH_FILL+encUint(id)+encUint(r.nA?0n:r.aA)+encAddr(account)+encUint(r.aB)
      :r.v2
        ?"0x"+(nativeIn?SEL_FILL2_ETH:nativeOut?SEL_FILL2_UNWRAP:SEL_FILL2)
          +encUint(id)+encUint(dl)+(nativeIn?"":encUint(0n))+encUint(0n)+encAddr(ZERO)
          // fillAmountB 0 = full fill (omitted by the ETH entry point, which
          // takes the amount as msg.value), then minAmountA 0 = no floor, then
          // recipient 0 = the caller. The fills gained the middle two words when
          // the board grew a slippage floor; the encoding still wrote four.
        :"0x"+SEL_FILL1+encUint(id)+encUint(dl);
    // Swapboard has a native prepaid fill. Dutch NFT lots are not routed
    // through snwap's ERC20 balance guard, so wrap + approve + fill them with
    // wallet batching when available (and as recoverable legacy steps otherwise).
    const wrap=nativeIn&&r.dutch&&r.aB
      ?{to:WETH,data:"0xd0e30db0",value:toHex(r.aB)}:null;
    // Only Swapboard v2 has a payable ETH fill. A v1 order quoted in WETH still
    // reads as `nativeIn`, but it must be paid by approval, not by msg.value.
    const payNative=(nativeIn&&!r.dutch&&r.v2)||(r.dutch&&r.tB===ZERO);
    const tx={from:account,to,data,value:payNative?toHex(r.aB):"0x0"};
    const approvals=[];
    if(r.nB){
      let ap=ZERO;
      try{ap="0x"+strip0x(await rpc(C,[{to:r.tB,data:"0x081812fc"+encUint(r.aB)},L])).slice(-40)}catch{}
      if(ap.toLowerCase()!==to.toLowerCase()){
        approvals.push({to:r.tB,data:"0x"+SEL_APPROVE+encAddr(to)+encUint(r.aB),value:"0x0"});
      }
    }else if(r.tB!==ZERO&&r.aB&&!(nativeIn&&!r.dutch&&r.v2)){
      const al=BigInt(await rpc(C,[{to:r.tB,data:"0x"+SEL_ALLOWANCE+encAddr(account)+encAddr(to)},L]));
      if(al<r.aB){
        // Clear a stale non-zero allowance for USDT-style tokens.
        if(al)approvals.push({to:r.tB,data:"0x"+SEL_APPROVE+encAddr(to)+encUint(0n),value:"0x0"});
        approvals.push({to:r.tB,data:"0x"+SEL_APPROVE+encAddr(to)+encUint(r.aB),value:"0x0"});
      }
    }
    const revoke=r.dutch&&!r.nB&&r.tB!==ZERO
      ?{to:r.tB,data:"0x"+SEL_APPROVE+encAddr(to)+encUint(0n),value:"0x0"}:null;
    if((wrap||approvals.length||revoke)&&await canBatch(account)){
      stat.textContent="Preparing and filling atomically...";
      await settle(await sendBatch(account,[
        ...(wrap?[wrap]:[]),...approvals,{to,data,value:tx.value},...(revoke?[revoke]:[])
      ]));
      loadBook();refreshBalance();return;
    }
    if(wrap){
      stat.textContent="Wrapping ETH...";
      await waitTx(await rpc(S,[{from:account,...wrap}]));
    }
    for(let i=0;i<approvals.length;i++){
      stat.textContent=`Approve${r.nB?" NFT":""}${approvals.length>1?` (${i+1}/${approvals.length})`:""}...`;
      await waitTx(await rpc(S,[{from:account,...approvals[i]}]));
    }
    await rpc(C,[tx,L]);
    await settle(await rpc(S,[tx]));
    if(revoke)try{
      stat.textContent="Filled · revoking quote allowance...";
      await waitTx(await rpc(S,[{from:account,...revoke}]));
      stat.textContent="Done";
    }catch{stat.textContent="Filled · quote allowance remains; revoke it in your wallet"}
    loadBook();refreshBalance();
  }catch(x){err(x);b.disabled=false}
});

const SLOW="0x000000000000888741B254d37e1b27128AfEAaBC";
const SEL_DEPOSITTO="94eeaec9",SEL_CLAIM="379607f5",SEL_REVERSE="97d15425",SEL_WITHDRAWFROM="d4fdc309";
const SEL_OUT="d40d4bc6",SEL_IN="e3993ee7",SEL_PENDING="6577b86a";
const idTok=i=>"0x"+(i&((1n<<160n)-1n)).toString(16).padStart(40,"0");
const idDelay=i=>i>>160n;
const w=(h,n)=>BigInt("0x"+(strip0x(h).slice(n*64,n*64+64)||"0"));
const decArr=h=>{h=strip0x(h);const n=Number(BigInt("0x"+h.slice(64,128)));const o=[];
for(let i=0;i<n;i++)o.push(BigInt("0x"+h.slice(128+i*64,192+i*64)));return o};
const metaCache=new Map();
async function tokMeta(a){
a=a.toLowerCase();
if(a===ZERO)return{sym:"ETH",dec:18};
const k=TOKENS.find(t=>t.addr.toLowerCase()===a);
if(k)return k;
if(metaCache.has(a))return metaCache.get(a);
let m={sym:a.slice(0,6)+"…",dec:18};
try{const[sr,dr]=await Promise.all([rpc(C,[{to:a,data:"0x95d89b41"},L]),rpc(C,[{to:a,data:"0x313ce567"},L])]);
const d=Number(BigInt(dr));
if(Number.isInteger(d)&&d>=0&&d<=36)m={sym:decodeString(sr).trim().replace(/[<>&"'`]/g,"").slice(0,10)||m.sym,dec:d};
}catch{}
metaCache.set(a,m);return m;
}
const rel=s=>{const a=Math.abs(s),u=[[86400,"d"],[3600,"h"],[60,"m"]];
for(const[n,l]of u)if(a>=n)return Math.floor(a/n)+l;return a+"s"};
let posSeq=0,posShown=25;
const POSPAGE=25;
async function loadPos(){
if(!account){pos.innerHTML="";tabSend.textContent="Send";return}
const my=++posSeq;
let outIds=[],inIds=[];
try{
const[oh,ih]=await Promise.all([
rpc(C,[{to:SLOW,data:"0x"+SEL_OUT+encAddr(account)},L]),
rpc(C,[{to:SLOW,data:"0x"+SEL_IN+encAddr(account)},L])]);
outIds=decArr(oh);inIds=decArr(ih);
}catch{return}
if(my!==posSeq)return;
const dirs=new Map();
for(const[t,d]of[...outIds.map(i=>[i,"out"]),...inIds.map(i=>[i,"in"])]){
const k=t.toString();dirs.set(k,(dirs.get(k)||"")+d)}
// newest first: ids climb, so the tail is the most recent
const allKeys=[...dirs.keys()].sort((a,b)=>a.length-b.length||(a<b?1:-1));
const keys=allKeys.slice(0,posShown);
const more=allKeys.length-keys.length;
const ps=[];
for(let i=0;i<keys.length;i+=10){
ps.push(...await Promise.all(keys.slice(i,i+10).map(k=>
rpc(C,[{to:SLOW,data:"0x"+SEL_PENDING+encUint(BigInt(k))},L]).catch(()=>0))));
if(my!==posSeq)return;
}
if(my!==posSeq)return;
const rows=[];
keys.forEach((k,i)=>{const p=ps[i];if(!p)return;
const ts=w(p,0);
if(ts===0n)return;
rows.push({tid:BigInt(k),dir:dirs.get(k),ts,id:w(p,3),amount:w(p,4)})});
const now=BigInt(Math.floor(Date.now()/1e3));
const ready=rows.filter(r=>r.dir.includes("in")&&now>=r.ts+idDelay(r.id)).length;
// the badge counts what has been loaded; a trailing + means there is more
tabSend.textContent=ready?`Send (${ready}${more?"+":""})`:"Send";
if(tab!=="send"||!rows.length){pos.innerHTML="";return}
rows.sort((a,b)=>Number((a.ts+idDelay(a.id))-(b.ts+idDelay(b.id))));
const metas=await Promise.all(rows.map(r=>tokMeta(idTok(r.id))));
if(my!==posSeq)return;
let html=`<div class="ph">Time-locked</div>`;
rows.forEach((r,n)=>{
const m=metas[n],exp=r.ts+idDelay(r.id),left=Number(exp-now);
const ripe=now>=exp;
const amt=`${trimAmt(r.amount,m.dec)} ${m.sym}`;
const io=r.dir.includes("in"),oo=r.dir.includes("out");
let act,note;
if(ripe)note=io?"Ready to claim":"Matured · recipient can claim";
else note=(io&&!oo?"Arrives in ":"Reversible · sends in ")+rel(left);
if(io&&ripe)act=`<button data-a="c" data-t="${r.tid}">Claim</button>`;
else if(oo&&!ripe)act=`<button data-a="r" data-t="${r.tid}" data-i="${r.id}" data-m="${r.amount}">Reverse</button>`;
else act=`<button disabled>${io?"In":"Out"}</button>`;
html+=`<div class="p"><span><b>${oo&&io?"↺":oo?"→":"←"} ${amt}</b><i>${note}</i></span>${act}</div>`;
});
if(more)html+=`<div class="p" style="justify-content:center"><button data-a="m">Show ${Math.min(more,POSPAGE)} more of ${more}</button></div>`;
pos.innerHTML=html;
}
pos.addEventListener("click",async e=>{
const m=e.target.closest('button[data-a="m"]');
if(m){posShown+=POSPAGE;m.disabled=true;loadPos();return}
const b=e.target.closest("button[data-t]");
if(!b)return;
b.disabled=true;
try{
await checkWallet();
// claim() pays the recipient directly, but reverse() only credits the
// sender's unlockedBalances - on its own it settles the position and returns
// nothing, so it must be paired with withdrawFrom in one multicall.
const rv=b.dataset.a==="r";
let data="0x"+(rv?SEL_REVERSE:SEL_CLAIM)+encUint(BigInt(b.dataset.t));
if(rv)data=encCalls([data,"0x"+SEL_WITHDRAWFROM+encAddr(account)+encAddr(account)
+encUint(BigInt(b.dataset.i))+encUint(BigInt(b.dataset.m))]);
const txReq={from:account,to:SLOW,data,value:"0x0"};
await rpc(C,[txReq,L]);
await settle(await rpc(S,[txReq]));
refreshBalance();loadPos();
}catch(x){err(x);b.disabled=false}
});

const rcvOf=async v=>{
if(/^0x[0-9a-fA-F]{40}$/.test(v))return /^0x0{40}$/i.test(v)?"":v;
if(!/\.(g?wei|eth)$/i.test(v))return "";
let a="";try{a=await nameFwd(v.toLowerCase())}catch{}
return !a||/^0x0{40}$/i.test(a)?"":a;
};
async function updateSend(){
const my=++sSeq;
sendReady=null;
const f=TOKENS[fromSel.value];
const v=rc.value.trim();
let amount=0n,amtErr="";
const q=amt.value.trim();
try{amount=parseUnits(q,f.dec)}
catch(e){if(q&&!/\.$/.test(q))amtErr=/decimals/.test(e.message)?`${f.sym} has ${f.dec} decimals`:"Invalid amount"}
if(!v){rc.classList.remove("bad");rcvEl.textContent="";stat.textContent=amtErr;render();return}
if(/^0x[0-9a-fA-F]{40}$/.test(v)===false&&/\.(g?wei|eth)$/i.test(v)===false){
rc.classList.add("bad");rcvEl.textContent="";
stat.textContent="Recipient must be an address or a .wei / .gwei / .eth name";render();return}
if(!/^0x/.test(v))rcvEl.textContent="resolving...";
const to=await rcvOf(v);
if(my!==sSeq)return;
if(!to){rc.classList.add("bad");rcvEl.textContent="";stat.textContent="Name not registered";render();return}
rc.classList.remove("bad");
rcvEl.textContent=to;
stat.textContent=amtErr;
if(amount>0n)sendReady={to,amount,token:f,label:/^0x/.test(v)?to.slice(0,6)+"\u2026"+to.slice(-4):v};
render();
}
const setTab=t=>{
if(tab==="send")sendD=dly.value;else if(tab==="book")bookD=dly.value;
tab=t;last=null;sendReady=null;stat.textContent="";posShown=POSPAGE;
const send=t==="send",bk=t==="book";
tabSwap.classList.toggle("on",t==="swap");
tabSend.classList.toggle("on",send);
tabBook.classList.toggle("on",bk);
for(const[el,on]of[[tabSwap,t==="swap"],[tabSend,send],[tabBook,bk]])el.setAttribute("aria-selected",on?"true":"false");
// the pay/receive panels already describe a limit order, so the orders tab
// reuses them: sell this, want that. Only the labels and the slippage change.
for(const el of[rcvPanel,flip])el.classList.toggle("hide",send);
// Leaving the orderbook with a collection selected would strand that side on an
// option `syncDisabled` is about to disable — visibly greyed out, and every read
// of the pair downstream would price an NFT as a fungible. Move it back to
// something quotable first; the equal-sides fix below then resolves any collision
// the move creates.
if(!bk)for(const[sel,other]of[[fromSel,toSel],[toSel,fromSel]]){
if(!isNft(sel.value))continue;
const alt=TOKENS.findIndex((t,i)=>t.std!=="nft"&&String(i)!==other.value);
if(alt>=0)sel.value=String(alt);
}
// Send lets the pay side hold whatever the receive side holds. Coming back to a
// pair-based tab with both sides equal would dead-end on "Pick different
// tokens", so move the side the user was not just looking at.
if(!send&&fromSel.value===toSel.value){
// Off the orderbook this must not land on a collection, or it re-strands the
// side the eviction above just rescued.
const alt=TOKENS.findIndex((t,i)=>String(i)!==fromSel.value&&(bk||t.std!=="nft"));
if(alt>=0)toSel.value=String(alt);
}
syncDisabled();
// The Token ID field belongs to whichever side is holding a collection.
// Blank means ANY id, which Floorboard models natively as an empty `ids`
// set - so the placeholder is the feature, not a hint to fill something in.
const anyNft=bk&&(isNft(fromSel.value)||isNft(toSel.value));
nftIdL.classList.toggle("hide",!anyNft);
if(!anyNft)nftId.value="";
slipL.classList.toggle("hide",t!=="swap");
dlyL.classList.toggle("hide",t==="swap");
kindL.classList.toggle("hide",!bk);
dlyL.firstChild.nodeValue=bk?"Expires":"Time lock";
dly.options[0].textContent=bk?"Never":"Instant";
if(send)dly.value=sendD;else if(bk)dly.value=bookD;
payL.textContent=send?"Amount":bk?"You sell":"You pay";
rcvHdr.textContent=bk&&kind.value==="dutch"?"Start ask total":bk?"You want":"You receive";
rc.placeholder=send?"Recipient \u2014 0x or .eth/.(g)wei"
:bk?"Private to (optional) \u2014 0x or .eth/.(g)wei"
:"Recipient (optional) \u2014 0x or .eth/.(g)wei";
syncOrderType();syncChart();
loadPos();loadBook();
outAmt.value="";mode="in";
update();
};
dly.onchange=()=>{if(tab==="book")bookD=dly.value;else sendD=dly.value;render()};
fill.onchange=render;
const syncOrderType=()=>{
  const dutch=tab==="book"&&kind.value==="dutch";
  floorL.classList.toggle("hide",!dutch);
  fillL.classList.toggle("hide",tab!=="book"||dutch);
  rc.classList.toggle("hide",dutch);
  rcvEl.classList.toggle("hide",dutch);
  // Persist the forced default too, or leaving and re-entering the tab restores
  // "Never" and the button silently reverts to "Choose decay duration".
  if(dutch&&+dly.value===0){dly.value="86400";if(tab==="book")bookD=dly.value}
  if(tab==="book")rcvHdr.textContent=dutch?"Start ask total":"You want";
};
kind.onchange=()=>{syncOrderType();render()};
floorAmt.addEventListener("input",()=>{fitFont(floorAmt);render()});
tabBook.onclick=()=>setTab("book");
setInterval(()=>{if(account&&!document.hidden){loadPos();if(tab==="book")loadBook()}},3e4);
// Re-quote before QUOTE_TTL expires, never while a tx is in flight or hidden.
setInterval(()=>{
if(tab!=="swap"||!account||document.hidden||!last||swap.disabled)return;
if(Date.now()>=last.exp-5000)update();
},5e3);
// ------------------------------------------------------------- PRICE TAPE
// Candles read straight out of PrecisionPool storage: no indexer, no subgraph,
// no server. One aggregate3 finds the pools for the pair and reads their tapes,
// so opening the drawer costs a single round trip. Closed by default, and it
// costs nothing at all until opened.
const PPLENS="0x0000000000000000000000000000000000000000"; // set at deploy
const SEL_MARKETS="29c21083",SEL_TAPE="29a65241";
const FINE=300,COARSE=14400,TFS=[["5m",300],["1h",3600],["1d",86400]];
// The fine ring only spans ~21h, so a daily candle built from it is a stub.
// The pool also keeps a four-hour tape covering weeks; read both and pick the
// one whose resolution the timeframe actually needs.
const srcFor=tf=>tf>=COARSE?COARSE:FINE;
// PoolInfo is a static struct, so the lens returns rows of 18 flat words.
const PI_WORDS=18,PI_POOL=0,PI_LIQ=9,PI_HOOK=10;
let chKind=LS.ck==="line"?"line":"candle",chPeriod=300,chBars=null,chSeq=0,chPools=0,chOpen=LS.ch==="1",chCache={};
// value = mantissa << exponent, matching PriceTape.pack
const unf=p=>(p&0xffffff)*2**(p>>>24);
const decBar=w=>{if(!w)return null;const f=s=>Number((w>>BigInt(s))&0xffffffffn);
return{b:Number(w&0xffffffffn),o:unf(f(32)),h:unf(f(64)),l:unf(f(96)),c:unf(f(128)),v:unf(f(160)),n:Number((w>>192n)&0xffffn)}};
// Exact: a bar built from N sub-bars is the bar the trades would have produced.
const rollUp=(bars,src,dst)=>{if(dst<=src)return bars.filter(Boolean);
const out=[];let g=null,k=null;
for(let i=bars.length-1;i>=0;i--){const b=bars[i];if(!b)continue;
const key=Math.floor(b.b*src/dst);
if(key!==k){if(g)out.push(g);k=key;g={b:key,o:b.o,h:b.h,l:b.l,c:b.c,v:b.v,n:b.n}}
else{g.h=Math.max(g.h,b.h);g.l=Math.min(g.l,b.l);g.c=b.c;g.v+=b.v;g.n+=b.n}}
if(g)out.push(g);return out.reverse()};
// One pair can have several pools at different fee tiers. Arbitrage keeps them
// on the same price, so the honest aggregate is the market: extremes are the
// union, volume sums, and open/close are volume-weighted - which also means a
// thin pool cannot drag the print away from where size actually traded.
const mergeTapes=tapes=>{const m=new Map();
for(const bars of tapes)for(const b of bars||[]){if(!b)continue;
const e=m.get(b.b);
if(!e)m.set(b.b,{b:b.b,o:b.o*b.v,h:b.h,l:b.l,c:b.c*b.v,v:b.v,n:b.n,w:b.v,fo:b.o,fc:b.c});
else{e.h=Math.max(e.h,b.h);e.l=Math.min(e.l,b.l);e.o+=b.o*b.v;e.c+=b.c*b.v;e.v+=b.v;e.n+=b.n;e.w+=b.v}}
const out=[...m.values()].sort((x,y)=>y.b-x.b);
for(const e of out){if(e.w>0){e.o/=e.w;e.c/=e.w}else{e.o=e.fo;e.c=e.fc}delete e.w;delete e.fo;delete e.fc}
return out};
const chPair=()=>{const f=TOKENS[fromSel.value],t=TOKENS[toSel.value];
if(!f||!t||f.addr===t.addr)return null;
return f.addr.toLowerCase()<t.addr.toLowerCase()?[f,t]:[t,f]};
async function loadChart(){
chBars=null;chPools=0;
const p=chPair();
if(tab!=="swap"||!account||!p){syncChartUI();return}
const my=++chSeq,[t0,t1]=p,key=t0.addr+":"+t1.addr;
const hit=chCache[key];
if(hit&&Date.now()-hit.at<30000){chBars=hit.bars;chPools=hit.pools;syncChartUI();return}
try{
if(PPLENS===ZERO||(await rpc("eth_getCode",[PPLENS,L])).length<5)return syncChartUI();
// One lens call discovers every registered pool for the pair AND returns the
// hook and liquidity needed to decide which of them may speak for its price.
const [raw]=await mc3([{to:PPLENS,data:"0x"+SEL_MARKETS+encAddr(t0.addr)+encAddr(t1.addr)
  +encAddr(account)+encUint(0)+encUint(8)+encUint(0)}]);
if(my!==chSeq)return;
const pools=[];
if(raw){const h=strip0x(raw),n=Number(BigInt("0x"+h.slice(64,128))),base=128;
for(let i=0;i<n&&i<8;i++){const at=k=>BigInt("0x"+h.slice(base+(i*PI_WORDS+k)*64,base+(i*PI_WORDS+k+1)*64));
// A hooked pool can charge a surcharge on top of the base fee, so its executed
// prices are not the pair's market price - and the hook is free to make them
// anything at all. Empty pools have no price to contribute either.
if(at(PI_HOOK)!==0n||at(PI_LIQ)===0n)continue;
pools.push("0x"+h.slice(base+(i*PI_WORDS+PI_POOL)*64+24,base+(i*PI_WORDS+PI_POOL+1)*64))}}
if(!pools.length){chCache[key]={at:Date.now(),bars:null,pools:0};return syncChartUI()}
const reqs=[];
for(const a of pools)reqs.push({to:a,data:"0x"+SEL_TAPE+encUint(FINE)+encUint(256)},
  {to:a,data:"0x"+SEL_TAPE+encUint(COARSE)+encUint(256)});
const tapes=await mc3(reqs);
if(my!==chSeq)return;
const dec1Tape=hex=>{if(!hex)return null;
const h=strip0x(hex),n=Number(BigInt("0x"+h.slice(64,128))),bars=[];
for(let j=0;j<n;j++)bars.push(decBar(BigInt("0x"+h.slice(128+j*64,128+(j+1)*64))));
return bars};
const decoded=tapes.map(dec1Tape);
const fine=[],coarse=[];
for(let i=0;i<pools.length;i++){fine.push(decoded[i*2]);coarse.push(decoded[i*2+1])}
// The tape stores the pool's RAW convention: token1 per token0, 1e18-scaled,
// with token decimals unnormalised. Undo both here so the axis reads in the
// units a person trades in rather than in wei-per-wei.
const sc=10**(t0.dec-t1.dec)/1e18;
const build=set=>{const m=mergeTapes(set);
for(const b of m){b.o*=sc;b.h*=sc;b.l*=sc;b.c*=sc}return m.length?m:null};
const f=build(fine),c=build(coarse);
chBars=f||c?{[FINE]:f,[COARSE]:c}:null;
chPools=chBars?fine.filter(d=>d&&d.some(Boolean)).length:0;
chCache[key]={at:Date.now(),bars:chBars,pools:chPools};
}catch{chBars=null;chPools=0}
if(my===chSeq)syncChartUI();
}
// Nothing to chart means no control at all - an empty drawer is worse than none.
function syncChartUI(){
const on=tab==="swap"&&!!account&&!!chBars;
chTog.classList.toggle("hide",!on);
chBox.classList.toggle("hide",!on||!chOpen);
chTog.setAttribute("aria-expanded",on&&chOpen?"true":"false");
if(!on||!chOpen)return;
const p=chPair();
chNote.textContent=p?`${p[1].sym} per ${p[0].sym} · ${chPools} pool${chPools===1?"":"s"}`:"";
drawChart();
}
// Reading a single candle off a 340px strip is guesswork, so pointing at one
// spells it out. Index -1 means "the latest", which is the resting state.
const hudFor=i=>{
if(!chDraw)return;
const{pts,num,UP,DN,ch}=chDraw,hd=chArt.querySelector(".hd");
if(!hd)return;
if(i<0){const b=pts[pts.length-1];
hd.innerHTML=`<b>${num(b.c)}</b> <span style="color:${ch>=0?UP:DN}">${ch>=0?"+":""}${ch.toFixed(2)}%</span>`;
return}
const b=pts[i],up=b.c>=b.o,d=new Date(b.b*chPeriod*1e3);
const when=chPeriod>=86400
  ?d.toLocaleDateString("en-US",{month:"short",day:"numeric"})
  :d.toLocaleTimeString("en-US",{hour:"2-digit",minute:"2-digit",hour12:false});
hd.innerHTML=`<b style="color:${up?UP:DN}">${num(b.c)}</b> <span>${when}</span>`
+`<span class="ohlc">H ${num(b.h)} L ${num(b.l)} · ${b.n} trade${b.n===1?"":"s"}</span>`;
};
const chPoint=e=>{
if(!chDraw)return;
const r=chArt.getBoundingClientRect();
if(!r.width)return;
const{pts,W,PL,st}=chDraw;
const x=(e.clientX-r.left)/r.width*W;
const i=Math.max(0,Math.min(pts.length-1,Math.round((x-PL)/st-.5)));
hudFor(i);
const cur=chArt.querySelector(".cross");
if(cur)cur.remove();
const svg=chArt.querySelector("svg");
if(!svg)return;
const el=document.createElementNS("http://www.w3.org/2000/svg","line");
el.setAttribute("class","cross");
el.setAttribute("x1",chDraw.X(i).toFixed(1));el.setAttribute("x2",chDraw.X(i).toFixed(1));
el.setAttribute("y1","0");el.setAttribute("y2","150");
el.setAttribute("stroke","currentColor");el.setAttribute("stroke-opacity",".35");
el.setAttribute("stroke-width",".8");
svg.appendChild(el);
};
chArt.addEventListener("pointermove",chPoint);
chArt.addEventListener("pointerdown",chPoint);
chArt.addEventListener("pointerleave",()=>{const c=chArt.querySelector(".cross");if(c)c.remove();hudFor(-1)});

function drawChart(){
if(!chBars)return;
const W=340,H=150,PL=2,PR=42,PT=10,PB=14,VH=22;
const pw=W-PL-PR,ph=H-PT-PB-VH;
// The tape is stored newest-first. A chart that runs right-to-left is worse
// than no chart, so flip it before anything is measured or drawn.
const src=srcFor(chPeriod),base=chBars[src]||chBars[FINE]||chBars[COARSE];
if(!base){chArt.innerHTML='<div class="msg">No trades in this window.</div>';return}
const step=chBars[src]?src:(chBars[FINE]?FINE:COARSE);
let pts=(chPeriod===step?base.filter(Boolean):rollUp(base,step,chPeriod)).slice().reverse();
// Draw only what the width can resolve, keeping the most recent bars. Packing
// 250 candles into 300px produces a smear, not information.
const cap=Math.floor(pw/3);
const clipped=pts.length>cap;
if(clipped)pts=pts.slice(-cap);
if(!pts.length){chArt.innerHTML='<div class="msg">No trades in this window.</div>';return}
let hi=-Infinity,lo=Infinity,vm=0;
for(const b of pts){if(b.h>hi)hi=b.h;if(b.l<lo)lo=b.l;if(b.v>vm)vm=b.v}
if(hi===lo){hi*=1.001;lo*=0.999}
let sp=hi-lo;hi+=sp*.09;lo-=sp*.09;sp=hi-lo;
const n=pts.length,st=pw/n,bw=Math.max(1,Math.min(9,st*.68));
const X=i=>PL+st*(i+.5),Y=p=>PT+ph*(1-(p-lo)/sp),vt=PT+ph+6,VY=v=>vt+(VH-6)*(1-(vm?v/vm:0));
const num=v=>v>=1000?v.toLocaleString("en-US",{maximumFractionDigits:2}):v>=1?v.toFixed(3):v.toPrecision(3);
const UP="#16a34a",DN="#c33";
const p0=chPair(),lbl=p0?`${p0[1].sym} per ${p0[0].sym}`:"Price";
let s=`<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="${lbl}, ${n} bars, ${num(pts[n-1].c)} now, range ${num(lo)} to ${num(hi)}">`;
for(let g=0;g<=3;g++){const p=lo+sp*g/3,y=Y(p).toFixed(1);
s+=`<line x1="${PL}" y1="${y}" x2="${W-PR}" y2="${y}" stroke="currentColor" stroke-opacity=".1"/>`
+`<text x="${W-PR+4}" y="${(Y(p)+2.5).toFixed(1)}" font-size="7" fill="currentColor" fill-opacity=".5">${num(p)}</text>`}
for(let i=0;i<n;i++){const b=pts[i],y=VY(b.v);
s+=`<rect x="${(X(i)-bw/2).toFixed(1)}" y="${y.toFixed(1)}" width="${bw.toFixed(1)}" height="${Math.max(.4,vt+VH-y).toFixed(1)}" fill="currentColor" fill-opacity=".18"/>`}
const rise=pts[n-1].c>=pts[0].o;
if(chKind==="line"){
const d=pts.map((b,i)=>`${i?"L":"M"}${X(i).toFixed(1)} ${Y(b.c).toFixed(1)}`).join(" ");
const col=rise?UP:DN;
s+=`<path d="${d} L${X(n-1).toFixed(1)} ${(PT+ph).toFixed(1)} L${X(0).toFixed(1)} ${(PT+ph).toFixed(1)} Z" fill="${col}" fill-opacity=".1"/>`
+`<path d="${d}" fill="none" stroke="${col}" stroke-width="1.2" stroke-linejoin="round"/>`
+`<circle cx="${X(n-1).toFixed(1)}" cy="${Y(pts[n-1].c).toFixed(1)}" r="1.8" fill="${col}"/>`;
}else{
for(let i=0;i<n;i++){const b=pts[i],col=b.c>=b.o?UP:DN,x=X(i);
const t=Y(Math.max(b.o,b.c)),bo=Y(Math.min(b.o,b.c));
s+=`<line x1="${x.toFixed(1)}" y1="${Y(b.h).toFixed(1)}" x2="${x.toFixed(1)}" y2="${Y(b.l).toFixed(1)}" stroke="${col}" stroke-width=".8"/>`
+`<rect x="${(x-bw/2).toFixed(1)}" y="${t.toFixed(1)}" width="${bw.toFixed(1)}" height="${Math.max(.8,bo-t).toFixed(1)}" fill="${col}"/>`}
}
s+="</svg>";
const last=pts[n-1],first=pts[0],ch=((last.c-first.o)/first.o)*100;
chArt.innerHTML=s+'<div class="hd"></div>';
chDraw={pts,X,W,PL,st,num,UP,DN,ch};
hudFor(-1);
const p=chPair();
const span=rel((last.b-first.b+1)*chPeriod);
chNote.textContent=p?`${p[1].sym} per ${p[0].sym} · ${chPools} pool${chPools===1?"":"s"} · ${clipped?"last ":""}${span}`:"";
}
for(const[label,secs]of TFS){const b=document.createElement("button");
b.textContent=label;if(secs===chPeriod)b.className="on";
b.onclick=()=>{chPeriod=secs;for(const c of chTf.children)if(c!==kindBtn)c.classList.toggle("on",c===b);drawChart()};
chTf.appendChild(b)}
// Labelled with the action, not the state: at this width a glyph would be a guess.
const kindBtn=document.createElement("button");
kindBtn.className="chk";
const syncKind=()=>{kindBtn.textContent=chKind==="candle"?"Line":"Candle";
kindBtn.title=`Switch to ${kindBtn.textContent.toLowerCase()} chart`};
syncKind();
kindBtn.onclick=()=>{chKind=chKind==="candle"?"line":"candle";LS.ck=chKind;syncKind();drawChart()};
chTf.appendChild(kindBtn);
const syncChart=()=>{loadChart()};
chTog.onclick=()=>{chOpen=!chOpen;LS.ch=chOpen?"1":"0";syncChartUI()};
// SHAREABLE LINKS  (prefill only - nothing is ever auto-submitted)
//   #to=alice.wei&amount=10&token=USDC            request a payment
//   #to=alice.wei&amount=1&token=ETH&lock=1d      request it time-locked via SLOW
//   #token=ETH&out=USDC&amount=500&exactOut=1     "pay me 500 USDC, spend ETH"
// token/out accept a symbol or a 0x address (imported on demand); lock accepts
// seconds or 1h/1d/1w and snaps to the nearest offered option. The recipient is
// still resolved and shown before signing, exactly as if it had been typed.
const lsecs=v=>{const m=/^(\d+)([mhdw]?)$/.exec((v||"").trim());
return m?+m[1]*(m[2]=="d"?86400:m[2]=="h"?3600:m[2]=="w"?604800:m[2]=="m"?60:1):NaN};
async function applyLink(){
const q=new URLSearchParams(location.hash.slice(1));
if(![...q.keys()].length)return;
const tok=async v=>{if(!v)return -1;const x=v.trim().toLowerCase();
let i=TOKENS.findIndex(t=>t.sym.toLowerCase()===x||t.addr.toLowerCase()===x);
if(i<0&&/^0x[0-9a-f]{40}$/.test(x)){try{i=await addCustomToken(x,0)}catch{}}
return i};
const fi=await tok(q.get("token")),oi=await tok(q.get("out"));
rebuild();
if(fi>=0)fromSel.value=fi;
if(oi>=0&&oi!==fi)toSel.value=oi;
// A link naming only one side can collide with whatever the other side already
// held (e.g. #token=USDC against the default USDC output). Move the side the
// link did not ask for rather than dead-ending on "Pick different tokens".
if(fromSel.value===toSel.value){
const alt=String(TOKENS.findIndex((t,i)=>String(i)!==fromSel.value));
if(alt!=="-1"){if(oi>=0)fromSel.value=alt;else toSel.value=alt}
}
syncDisabled();
const to=q.get("to");if(to)rc.value=to;
const lk=lsecs(q.get("lock"));
// setTab restores the tab's remembered duration, so writing only dly.value here
// left `lock=` silently discarded: the link switched to Send and immediately
// overwrote the choice with the default "Instant".
if(!isNaN(lk)){const os=[...dly.options].map(x=>+x.value).sort((a,b)=>a-b);
sendD=String(os.find(v=>v>=lk)??os[os.length-1]);dly.value=sendD}
setTab(q.get("out")?"swap":(to||!isNaN(lk))?"send":tab);
const n=q.get("amount");
if(n&&/^\d*\.?\d+$/.test(n)){
if(q.get("exactOut")==="1"&&q.get("out")){outAmt.value=n;setMode("out");fitFont(outAmt)}
else{amt.value=n;setMode("in");fitFont(amt)}
}
refreshBalance();update();
}
addEventListener("hashchange",applyLink);
// the inverse of applyLink: turn the current form into a shareable request.
// A disambiguated custom symbol carries a space, so those fall back to the
// address rather than emitting something applyLink could not resolve.
const tname=t=>/\s/.test(t.sym)?t.addr:t.sym;
lk.onclick=async()=>{
const f=TOKENS[fromSel.value],t=TOKENS[toSel.value],p=new URLSearchParams();
p.set("token",tname(f));
if(tab==="send"){
const r=rc.value.trim();if(r)p.set("to",r);
if(amt.value.trim())p.set("amount",amt.value.trim());
if(+dly.value)p.set("lock",dly.value);
}else{
p.set("out",tname(t));
if(mode==="out"&&outAmt.value.trim()){p.set("amount",outAmt.value.trim());p.set("exactOut","1")}
else if(amt.value.trim())p.set("amount",amt.value.trim());
}
const u=location.origin+location.pathname+"#"+p;
try{await navigator.clipboard.writeText(u);stat.textContent="Link copied"}
catch{stat.textContent=u}
};
tabSwap.onclick=()=>setTab("swap");
tabSend.onclick=()=>setTab("send");
applyLink();
async function doSend(){
if(!sendReady)return;
swap.disabled=true;
try{
const{to,amount,token}=sendReady;
const fresh=await rcvOf(rc.value.trim());
if(fresh.toLowerCase()!==to.toLowerCase())throw Error("recipient changed \u2014 check and retry");
if(amount>fromBalance)throw Error("insufficient balance");
await checkWallet();
const dsec=BigInt(dly.value||0);
let txReq,batch=null;
if(dsec>0n){
const isE=token.addr===ZERO;
const dep="0x"+SEL_DEPOSITTO+encAddr(isE?ZERO:token.addr)+encAddr(to)
+encUint(isE?0n:amount)+encUint(dsec)+encUint(160n)+encUint(0n);
txReq={from:account,to:SLOW,data:dep,value:isE?toHex(amount):"0x0"};
if(!isE){
const aHex=await rpc(C,[{to:token.addr,data:"0x"+SEL_ALLOWANCE+encAddr(account)+encAddr(SLOW)},L]);
const cur=BigInt(aHex);
if(cur<amount){
// USDT and friends revert on a non-zero -> non-zero approve, so clear first.
const pre=cur>0n?[{to:token.addr,data:"0x"+SEL_APPROVE+encAddr(SLOW)+encUint(0),value:"0x0"}]:[];
const ap={to:token.addr,data:"0x"+SEL_APPROVE+encAddr(SLOW)+encUint(amount),value:"0x0"};
if(await canBatch(account))batch=[...pre,ap,{to:SLOW,data:dep,value:"0x0"}];
else{stat.textContent="Approve "+token.sym+"...";
for(const c of[...pre,ap]){const at=await rpc(S,[{from:account,...c}]);await waitTx(at)}}
}}
}else{
txReq=token.addr===ZERO
?{from:account,to,value:toHex(amount)}
:{from:account,to:token.addr,data:"0x"+SEL_TRANSFER+encAddr(to)+encUint(amount),value:"0x0"};
}
let tx;
if(batch){await checkWallet();tx=await sendBatch(account,batch)}
else{const ret=await rpc(C,[txReq,L]);if(dsec===0n&&token.addr!==ZERO)okRet(ret);tx=await rpc(S,[txReq])}
await settle(tx);
amt.value="";fitFont(amt);sendReady=null;
refreshBalance();render();loadPos();
}catch(e){err(e);render()}
}

async function sendRouterFunded(callData,fundedCallData,token,amount,msgValue,verb){
  await checkWallet();
  let data=callData,batch=null;
  if(token.addr!==ZERO){
    const allowData="0x"+SEL_ALLOWANCE+encAddr(account)+encAddr(ZROUTER);
    const allowance=BigInt(await rpc(C,[{to:token.addr,data:allowData},L]));
    if(allowance<amount){
      let ready=false;
      const pi=await permitInfo(token.addr,account);
      if(pi)try{
        stat.textContent="Sign approval...";
        const pd=BigInt(Math.floor(Date.now()/1e3)+1800);
        data=encCalls([await signPermit(token.addr,pi,account,amount,pd),callData]);
        ready=true;
      }catch(e){if(isRejection(e))throw e}
      const selected=TOKENS[fromSel.value];
      const walletBal=selected&&selected.addr.toLowerCase()===token.addr.toLowerCase()
        ?fromBalance:BigInt(await rpc(C,[{to:token.addr,data:"0x"+SEL_BALANCEOF+encAddr(account)},L]));
      if(!ready&&walletBal>=amount&&await p2Ready(token.addr,account)>=amount)try{
        stat.textContent="Sign approval...";
        const pd=BigInt(Math.floor(Date.now()/1e3)+1800);
        data=encCalls([await signPermit2(token.addr,account,amount,pd),fundedCallData||callData]);
        ready=true;
      }catch(e){if(isRejection(e))throw e}
      if(!ready&&await canBatch(account)){
        const pre=allowance>0n
          ?[{to:token.addr,data:"0x"+SEL_APPROVE+encAddr(ZROUTER)+encUint(0n),value:"0x0"}]:[];
        batch=[...pre,
          {to:token.addr,data:"0x"+SEL_APPROVE+encAddr(ZROUTER)+encUint(amount),value:"0x0"},
          {to:ZROUTER,data:callData,value:toHex(msgValue)}];
        ready=true;
      }
      if(!ready){
        const approvals=allowance>0n?[0n,amount]:[amount];
        for(let i=0;i<approvals.length;i++){
          stat.textContent=`Approve ${token.sym}${approvals.length>1?` (${i+1}/${approvals.length})`:""}...`;
          const h=await rpc(S,[{from:account,to:token.addr,
            data:"0x"+SEL_APPROVE+encAddr(ZROUTER)+encUint(approvals[i]),value:"0x0"}]);
          await waitTx(h);
        }
        const fresh=BigInt(await rpc(C,[{to:token.addr,data:allowData},L]));
        if(fresh<amount)throw Error("approval failed");
      }
    }
  }
  stat.textContent=verb;
  let tx;
  if(batch){await checkWallet();tx=await sendBatch(account,batch)}
  else{
    const req={from:account,to:ZROUTER,data,value:toHex(msgValue)};
    await rpc(C,[req,L]);await checkWallet();tx=await rpc(S,[req]);
  }
  await settle(tx);
}

async function placeOrder(){
const f=TOKENS[fromSel.value],t=TOKENS[toSel.value];
swap.disabled=true;
try{
const sell=parseUnits(amt.value.trim(),f.dec),want=parseUnits(outAmt.value.trim(),t.dec);
const dutch=kind.value==="dutch";
const floor=dutch&&floorAmt.value.trim()?parseUnits(floorAmt.value.trim(),t.dec):0n;
const board=dutch?DUTCH:SB2;
const quoteToken=!dutch&&t.addr===ZERO?WETH:t.addr;
const [bc,oc]=await Promise.all([rpc("eth_getCode",[board,L]),rpc("eth_getCode",[ORDERBOL,L])]);
if(bc.length<5)throw Error(`${dutch?"Dutch":"fixed"} orderbook not deployed yet`);
if(oc.length<5)throw Error("routed order adapter not deployed yet");
if(f.addr===ZERO&&t.addr===WETH)throw Error("pick a non-WETH quote token");
if(!dutch&&(f.addr===WETH||f.addr===ZERO)&&quoteToken===WETH)throw Error("pick different tokens");
if(dutch&&floor>want)throw Error("floor exceeds start price");
let cp=ZERO;
const v=rc.value.trim();
if(!dutch&&v){cp=await rcvOf(v);if(!cp)throw Error("Private recipient not resolved")}
const pf=fill.value==="1"?1n:0n;
const placementDeadline=BigInt(Math.floor(Date.now()/1e3)+300);
let orderData;
if(dutch){
  const duration=BigInt(dly.value||0);
  if(!duration)throw Error("choose a decay duration");
  if(sell>(1n<<128n)-1n||want>(1n<<96n)-1n||floor>(1n<<96n)-1n)throw Error("Dutch amount too large");
  orderData="0x"+SEL_ORDER_DUTCH+encAddr(DUTCH)+encAddr(account)+encAddr(account)
    +encAddr(f.addr)+encAddr(t.addr)+encUint(sell)+encUint(want)+encUint(floor)
    +encUint(0n)+encUint(duration)+encUint(placementDeadline);
}else{
  const exp=+dly.value?BigInt(Math.floor(Date.now()/1e3)+ +dly.value):0n;
  orderData="0x"+SEL_ORDER_FIXED+encAddr(SB2)+encAddr(account)+encAddr(account)
    +encAddr(f.addr)+encUint(sell)+encAddr(quoteToken)+encUint(want)+encUint(pf)
    +encUint(exp)+encAddr(cp)+encUint(placementDeadline);
}
let direct,funded;
if(f.addr===ZERO){
  direct=funded=encSnwap(ZERO,0n,account,ZERO,0n,ORDERBOL,orderData);
}else{
  // Snapshot Orderbol before either transfer path funds it. The transient,
  // single-use checkpoint prevents old donated balances from becoming this
  // caller's order while keeping every approval option at zRouter.
  const checkpoint=encCheckpoint(ORDERBOL,f.addr,account);
  direct=encCalls([
    checkpoint,
    encSnwap(f.addr,sell,account,ZERO,0n,ORDERBOL,orderData)
  ]);
  funded=encCalls([
    checkpoint,
    encSweep(f.addr,sell,ORDERBOL),
    encSnwap(ZERO,0n,account,ZERO,0n,ORDERBOL,orderData)
  ]);
}
await sendRouterFunded(direct,funded,f,sell,f.addr===ZERO?sell:0n,
  dutch?"Placing Dutch order...":t.addr===ZERO?"Placing limit order (ETH quote settles as WETH)...":"Placing limit order...");
amt.value="";outAmt.value="";floorAmt.value="";
fitFont(amt);fitFont(outAmt);fitFont(floorAmt);
loadBook();refreshBalance();render();
}catch(e){err(e);render()}
}
swap.onclick=async()=>{
if(tab==="book"){if(!account)return connect();return placeOrder()}
if(tab==="send"){if(!account)return connect();return doSend()}
if(!account) return connect();
if(!last)return;
if(Date.now()>last.exp){stat.textContent="Quote expired — refreshing...";updateSoon();return}
// Slippage cannot catch this - it bounds the QUOTE, not a fair rate - so this is
// the only thing standing between a fat-fingered size, or an illiquid pool, and
// a ruinous fill. Two identical dialogs would not help: people click through
// both, and it teaches them to dismiss the first. So the severe tier asks for
// something that cannot be done without reading - typing the loss back.
if(last.impact!==null&&last.impact!==undefined&&last.impact>=IMPACT_CONFIRM){
const pct=(Number(last.impact)/100).toFixed(2);
const worse=`about ${trimAmt(last.lossTok,last.lossDec)} ${last.lossSym} ${last.isIn?"less than":"more than"} the market rate`;
if(last.impact>=IMPACT_TYPED){
const need=String(Math.floor(Number(last.impact)/100));
if(prompt(`STOP — this trade is priced ${pct}% away from the market.\n\nYou would ${last.isIn?"receive":"pay"} ${worse}.\n\nUsually this means the pool is illiquid or the amount is wrong.\n\nType ${need} to accept this loss:`)!==need)return;
}else if(!confirm(`Price impact ${pct}%.\n\nYou will ${last.isIn?"receive":"pay"} ${worse}.\n\nContinue?`))return;
}
swap.disabled=true;
try{
const {callData,fundedCallData,msgValue,amountIn,from,to}=last;
if(msgValue!==(from.addr===ZERO?amountIn:0n))throw Error("bad value");
await checkWallet();
let cd2=callData,batchCalls=null;
if(from.addr!==ZERO&&!to){
const allowData="0x"+SEL_ALLOWANCE+encAddr(account)+encAddr(ZROUTER);
const aHex=await rpc(C,[{to:from.addr,data:allowData},L]);
const a=BigInt(aHex);
if(a<amountIn){
let permitted=false;
const pi=await permitInfo(from.addr,account);
if(pi){try{
stat.textContent="Sign approval...";
const pd=BigInt(Math.floor(Date.now()/1e3)+1800);
cd2=encCalls([await signPermit(from.addr,pi,account,amountIn,pd),callData]);
permitted=true;
}catch(e){if(isRejection(e)){stat.textContent="";swap.disabled=false;return}}}
// Permit2 deposits into zRouter. Its prepared route checkpoints and funds the
// book executor first, executes those legs, then spends the AMM remainder and
// returns any input change. Both floors are enforced atomically in one multicall.
const p2Amount=amountIn;
if(!permitted&&fromBalance>=p2Amount&&await p2Ready(from.addr,account)>=p2Amount){try{
stat.textContent="Sign approval...";
const pd=BigInt(Math.floor(Date.now()/1e3)+1800);
cd2=encCalls([await signPermit2(from.addr,account,p2Amount,pd),fundedCallData||callData]);
permitted=true;
}catch(e){if(isRejection(e)){stat.textContent="";swap.disabled=false;return}}}
if(!permitted&&await canBatch(account)){
const pre=a>0n?[{to:from.addr,data:"0x"+SEL_APPROVE+encAddr(ZROUTER)+encUint(0n),value:"0x0"}]:[];
batchCalls=[...pre,{to:from.addr,data:"0x"+SEL_APPROVE+encAddr(ZROUTER)+encUint(amountIn),value:"0x0"},
{to:ZROUTER,data:callData,value:toHex(msgValue)}];
permitted=true;
}
if(!permitted){
const n=a>0n?2:1;
if(a>0n){
stat.textContent=`Approving (1/${n})...`;
const zeroData="0x"+SEL_APPROVE+encAddr(ZROUTER)+encUint(0);
const h1=await rpc(S,[{from:account,to:from.addr,data:zeroData}]);
await waitTx(h1);
}
stat.textContent=n>1?`Approving (2/2)...`:"Approving...";
const apprData="0x"+SEL_APPROVE+encAddr(ZROUTER)+encUint(amountIn);
const h2=await rpc(S,[{from:account,to:from.addr,data:apprData}]);
await waitTx(h2);
const nHex=await rpc(C,[{to:from.addr,data:allowData},L]);
if(BigInt(nHex)<amountIn)throw Error("approval failed");
}
}
}
stat.textContent="Swapping...";
let tx;
if(batchCalls){
await checkWallet();
tx=await sendBatch(account,batchCalls);
}else{
const txReq={from:account,to:to||ZROUTER,data:cd2,value:toHex(msgValue)};
await rpc(C,[txReq,L]);
await checkWallet();
tx=await rpc(S,[txReq]);
}
await settle(tx);
last=null;
// You just traded: your own print belongs on your own chart, not in 30s.
chCache={};loadChart();
refreshBalance();
render();
}catch(e){err(e);render()}
};
</script>

===== end of zSwap.html source ===== */
