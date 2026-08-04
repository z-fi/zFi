// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

/// @title ZorgPageStyle
/// @notice The dashboard stylesheet, held in its own contract.
/// @dev `ZorgConvictionRenderer` reached the EIP-170 limit: it is almost
///      entirely literal page text, which the optimizer cannot compress, so the
///      only way to keep adding to the page was to stop storing all of it in one
///      contract. `IZorgConvictionRenderer.html` is `view`, not `pure`, so the
///      renderer can read this at call time. Splitting the CSS out is the
///      cleanest seam: it is the largest self-contained block and it changes for
///      reasons entirely separate from the page's behaviour.
contract ZorgPageStyle {
    function css() external pure returns (string memory) {
        return "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
            "<title>TokenList - 100% onchain token data</title><style>"
            ":root{color-scheme:dark;--b:#09090b;--p:#141417;--l:#303036;--d:#96969e;--f:#f1f1f4;--a:#c7ffa8;--gold:#d9b34a;--warn:#ff9d6b}"
            "*{box-sizing:border-box}html{background:var(--b)}"
            "body{margin:0;background:var(--b);color:var(--f);font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}"
            ".w{max-width:1000px;margin:auto;padding:clamp(24px,4vw,44px) clamp(16px,3vw,26px) 64px}"
            "header{display:flex;gap:24px;align-items:flex-start;justify-content:space-between;border-bottom:1px solid var(--l);padding-bottom:20px}"
            "h1{font-size:clamp(23px,3vw,31px);line-height:1.14;letter-spacing:-.045em;margin:6px 0}"
            ".k{font-size:10px;color:var(--d);letter-spacing:.14em;text-transform:uppercase}"
            ".sub{color:var(--d);max-width:620px;margin:9px 0 0}"
            // `!important` because .off is a utility that must beat whatever
            // display a component sets. `.me{display:flex}` is declared later
            // at equal specificity, so plain `.off{display:none}` lost the
            // cascade and the receipt strip rendered for every visitor as a
            // stray empty avatar tile. Ordering alone would fix it today and
            // break again the next time a rule is appended.
            ".off{display:none!important}"
            ".idrow{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}"
            ".idrow input{width:84px;background:transparent;color:var(--f);border:1px solid var(--l);padding:6px 7px;font:inherit;min-height:32px}"
            ".idrow .btn{min-height:32px;padding:5px 9px;font-size:10px}"
            ".face{width:22px;height:22px;flex:0 0 22px;image-rendering:pixelated;border:1px solid var(--l);background:#1c1c20 center/cover no-repeat}"
            ".me{display:flex;flex-wrap:wrap;gap:6px 16px;align-items:center;margin:14px 0 0;color:var(--d);font-size:12px}"
            ".msg{color:var(--d);font-size:11px;margin:12px 0 0;min-height:15px}"
            ".me b{color:var(--f);font-weight:500}"
            ".eternal-name b{color:var(--gold)}"
            "h2{display:flex;gap:12px;align-items:baseline;font-size:11px;letter-spacing:.14em;text-transform:uppercase;margin:26px 0 0;padding-bottom:8px;border-bottom:1px solid var(--l);color:var(--d)}"
            ".note{margin-left:auto;font-size:11px;text-transform:none;letter-spacing:0}"
            ".logo{width:26px;height:26px;flex:0 0 26px;object-fit:contain;display:block;background:#1c1c20}"
            "small{display:block;color:var(--d);font-size:11px;overflow-wrap:anywhere}"
            ".r{display:grid;grid-template-columns:32px minmax(0,1fr) auto;gap:12px;align-items:center;min-height:60px;"
            "border-bottom:1px solid var(--l);padding:6px 4px;cursor:pointer;background:linear-gradient(90deg,#17171c var(--s,0),#0000 0)}"
            ".r:hover,.r:focus-visible{background:var(--p)}"
            ".r.on{grid-template-columns:32px minmax(0,1fr) auto minmax(140px,auto)}"
            ".rank{color:var(--d);font-variant-numeric:tabular-nums}"
            ".top{display:flex;gap:9px;align-items:center;min-width:0}.top b{font-size:15px}"
            ".score{text-align:right;font-variant-numeric:tabular-nums}.score small{font-size:10px}"
            ".alloc{display:flex;gap:6px;justify-content:flex-end;align-items:center;cursor:auto}"
            ".alloc input{width:72px;min-height:36px;background:transparent;color:var(--f);border:1px solid var(--l);padding:6px;font:inherit;text-align:right}"
            ".btn{min-height:36px;background:var(--f);color:var(--b);border:0;padding:7px 10px;font:11px inherit;letter-spacing:.08em;text-transform:uppercase;cursor:pointer}"
            ".btn:hover,.btn:focus-visible{background:var(--a)}"
            ".ghost{background:transparent;color:var(--f);border:1px solid var(--l)}"
            ".ghost:hover,.ghost:focus-visible{background:transparent;border-color:var(--a);color:var(--a)}"
            ".danger{color:var(--warn);border-color:#4a3126}"
            ".btn:disabled{opacity:.45;cursor:not-allowed;color:var(--d);border-color:var(--l);background:transparent}"
            ":focus-visible{outline:2px solid var(--a);outline-offset:2px}"
            "details{border:1px solid var(--l);background:var(--p);margin:16px 0}"
            "summary{padding:11px 13px;cursor:pointer;font-size:11px;letter-spacing:.14em;text-transform:uppercase;color:var(--d)}"
            ".actgrid{display:flex;flex-wrap:wrap;gap:8px;padding:0 13px 13px}"
            ".gl{width:100%;margin:9px 0 0;font-size:10px;letter-spacing:.14em;text-transform:uppercase;color:var(--d)}"
            ".gl i{display:block;font-style:normal;letter-spacing:0;text-transform:none;font-size:11px;color:#6f6f78;margin-top:3px}"
            "dialog{background:var(--p);color:var(--f);border:1px solid var(--l);padding:0;width:min(470px,93vw);font:inherit}"
            "dialog::backdrop{background:rgba(0,0,0,.74)}"
            ".dhead{display:flex;gap:11px;align-items:center;padding:13px;border-bottom:1px solid var(--l);font-size:13px}"
            ".dbody{padding:13px;display:grid;gap:9px}"
            ".dbody label{display:grid;gap:5px;font-size:11px;color:var(--d)}"
            ".dbody input{background:transparent;color:var(--f);border:1px solid var(--l);padding:9px;font:inherit;min-height:38px}"
            ".dl{display:grid;grid-template-columns:86px minmax(0,1fr);gap:10px;font-size:12px}"
            ".dl span{color:var(--d)}.dl code{overflow-wrap:anywhere}"
            ".ic{background:none;border:0;color:#5f5f68;cursor:pointer;padding:0 0 0 7px;font:10px inherit}"
            ".ic:hover,.ic:focus-visible{color:var(--a)}.ic svg{display:inline-block}"
            ".dfoot{display:flex;gap:7px;flex-wrap:wrap;justify-content:flex-end;padding:0 13px 13px}"
            ".links{padding:0 13px 11px;font-size:12px;display:flex;gap:13px}"
            ".derr{color:var(--warn);font-size:11px;padding:0 13px}"
            ".legend{color:var(--d);font-size:11px;line-height:1.55;margin:18px 0 0}"
            "code{color:var(--f)}a{color:var(--f);text-decoration-color:var(--d);text-underline-offset:3px}"
            "@media(max-width:640px){header{display:block}.idrow{justify-content:flex-start;margin-top:14px}"
            ".r,.r.on{grid-template-columns:26px minmax(0,1fr) auto;gap:8px 10px;padding:11px 4px;align-items:start}"
            ".score{grid-column:2/-1;grid-row:2;text-align:left;display:flex;gap:8px;align-items:baseline;font-size:12px}"
            ".alloc{grid-column:2/-1;grid-row:3;justify-content:flex-start;width:100%}.alloc input{flex:1;max-width:190px}"
            ".dl{grid-template-columns:1fr}.btn{min-height:42px}}</style>";
    }
}
