// SPDX-License-Identifier: MIT
pragma solidity ^0.8.36;

import {TokenList} from "../src/utils/TokenList.sol";

/// @title PostDeployListings
/// @notice The seven listings that no longer fit in `TokenList`'s constructor.
/// @dev These were seeded onchain until EIP-7825's 16,777,216-gas per-transaction
///      cap made an eleven-token constructor undeployable (see the seeding comment
///      in `TokenList`). They are not gone — they are applied by the owner right
///      after deployment, where each logo is calldata instead of initcode.
///
///      This file is the SINGLE SOURCE for that data, deliberately shared by the
///      test that proves the applied list matches what the constructor used to
///      produce and the script that emits the mainnet calldata. Two copies of a
///      colour or a rank would be two chances to ship a card that disagrees with
///      the one that was reviewed.
///
///      Ranks reuse the original sparse weights, so applying these restores the
///      exact order the eleven-token seed produced:
///        1_000_000 ETH · 999_000 WETH · 998_000 wstETH · 997_000 rETH
///        ·  996_000 WBTC · 995_000 USDC · 994_000 USDT · 993_000 BOLD
///        ·  992_000 ZORG · 991_000 zOrgz · 990_000 WNS
///
///      NOTE: every logo carries an explicit `xmlns`. A logo becomes a standalone
///      `data:image/svg+xml` document, and a standalone SVG without `xmlns` is a
///      broken image in every wallet and explorer. `setLogoSVG` rejects markup
///      without it, so a dropped namespace fails the transaction rather than the
///      rendering.
abstract contract PostDeployListings {
    struct Listing {
        address token;
        uint24 color;
        uint32 rank;
        string logo; // raw SVG; `setLogoSVG` base64-encodes it into a data URI
        string url;
        string description;
        bool onchainSvg; // collection whose selected token IDs resolve to data-SVG art
        TokenList.Standard expectedStandard;
    }

    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;
    address internal constant ZORG = 0x00a6bA94BBb5474725515De88fE04F854f2dCb12;
    address internal constant ZORGZ = 0x00000000008835ceF3E0D2333695f288Ee6b63A6;
    address internal constant WNS = 0x0000000000696760E15f265e828DB644A0c242EB;

    string internal constant WSTETH_LOGO = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 32 32"><g fill="none"><circle fill="#00A3FF" cx="16" cy="16" r="16"'
        '/><path d="M9.437 14.864l-.181.275c-2.048 3.097-1.603 7.253 1.034 9.824 1.561 1.521 3.622 2.353 5.683 2.353 '
        '0 0 0 0-6.536-12.452z" fill="#FFF"/><path opacity=".6" d="M15.997 18.611l-6.56-3.747c6.56 12.452 6.56 12.452'
        ' 6.56 12.452 0-2.683 0-5.623 0-8.705z" fill="#FFF"/><path opacity=".6" d="M22.563 14.864l.181.275c2.048 3.09'
        '7 1.603 7.253-1.034 9.824-1.561 1.521-3.622 2.353-5.683 2.353 0 0 0 0 6.536-12.452z" fill="#FFF"/><path opac'
        'ity=".2" d="M16.003 18.611l6.56-3.747c-6.56 12.452-6.56 12.452-6.56 12.452 0-2.683 0-5.623 0-8.705z" fill="#'
        'FFF"/><path opacity=".2" d="M16.004 10.239v6.459l5.654-3.23-5.654-3.229z" fill="#FFF"/><path opacity=".6" d='
        '"M16.005 10.239l-5.655 3.229 5.655 3.23v-6.46z" fill="#FFF"/><path d="M16.005 4.805l-5.655 8.668 5.655-3.233'
        'V4.805z" fill="#FFF"/><path opacity=".6" d="M16.004 10.238l5.658 3.23-5.658-8.674v5.444z" fill="#FFF"/></g><'
        "/svg>";

    string internal constant RETH_LOGO = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 32 32"><circle cx="16" cy="16" r="16" fill="#ED5A37"/><path d="M16 '
        '5.75L9.89 15.85 16 19.45l6.08-3.6z" fill="#FFF"/><path d="M16 20.6l-6.11-3.59L16 25.58l6.08-8.57z" fill="#FF'
        'F"/></svg>';

    string internal constant WBTC_LOGO = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 32 32"><g fill="none" fill-rule="evenodd"><circle cx="16" cy="16" r'
        '="16" fill="#F7931A"/><path fill="#FFF" fill-rule="nonzero" d="M23.189 14.02c.314-2.096-1.283-3.223-3.465-3.'
        "975l.708-2.84-1.728-.43-.69 2.765c-.454-.114-.92-.22-1.385-.326l.695-2.783L15.596 6l-.708 2.839c-.376-.086-."
        "746-.17-1.104-.26l.002-.009-2.384-.595-.46 1.846s1.283.294 1.256.312c.7.175.826.638.805 1.006l-.806 3.235c.0"
        "48.012.11.03.18.057l-.183-.045-1.13 4.532c-.086.212-.303.531-.793.41.018.025-1.256-.313-1.256-.313l-.858 1.9"
        "78 2.25.561c.418.105.828.215 1.231.318l-.715 2.872 1.727.43.708-2.84c.472.127.93.245 1.378.357l-.706 2.828 1"
        ".728.43.715-2.866c2.948.558 5.164.333 6.097-2.333.752-2.146-.037-3.385-1.588-4.192 1.13-.26 1.98-1.003 2.207"
        "-2.538zm-3.95 5.538c-.533 2.147-4.148.986-5.32.695l.95-3.805c1.172.293 4.929.872 4.37 3.11zm.535-5.569c-.487"
        ' 1.953-3.495.96-4.47.717l.86-3.45c.975.243 4.118.696 3.61 2.733z"/></g></svg>';

    string internal constant BOLD_LOGO = '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 32 32" fill="none"><circle cx="16" cy="16" r="16" fill="#63D77D"/><'
        'path fill-rule="evenodd" clip-rule="evenodd" d="M12.1719 4.56641H8.58203V26.1016H15.7617V25.2422C16.8398 25.'
        "793 18.0586 26.1055 19.3555 26.1055C23.7148 26.1055 27.25 22.5703 27.25 18.207C27.25 13.8438 23.7148 10.3086"
        " 19.3555 10.3086C18.0586 10.3086 16.8398 10.6211 15.7617 11.1719V4.56641H12.1719ZM15.7617 11.1719C13.207 12."
        '4805 11.457 15.1406 11.457 18.207C11.457 21.2734 13.207 23.9336 15.7617 25.2422V11.1719Z" fill="#1C1D4F"/></'
        "svg>";

    string internal constant ZORG_LOGO =
        '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 400 400"><style>.zorg-bg{fill:#fff}.zorg-fg{fill:#000}@media(prefers-color-scheme:dark){.zorg-bg{fill:#000}.zorg-fg{fill:#fff}}</style><clipPath id="zorg-clip"><circle cx="200" cy="200" r="200"/></clipPath><g clip-path="url(#zorg-clip)"><rect class="zorg-bg" width="400" height="400"/><path class="zorg-fg" d="M-60-20L460-20L460 90L80 310L460 310L460 420L-60 420L-60 310L320 90L-60 90Z"/></g></svg>';

    string internal constant ZORGZ_LOGO =
        '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20" viewBox="0 0 16 16"><rect width="16" height="16" fill="#0a0a0a"/><rect x="3" y="1" width="1" height="1" fill="#e8e8e0"/><rect x="5" y="2" width="1" height="1" fill="#e8e8e0"/><rect x="10" y="2" width="1" height="1" fill="#e8e8e0"/><rect x="12" y="1" width="1" height="1" fill="#e8e8e0"/><rect x="4" y="4" width="8" height="1" fill="#e8e8e0"/><rect x="3" y="5" width="10" height="1" fill="#e8e8e0"/><rect x="2" y="6" width="12" height="3" fill="#e8e8e0"/><rect x="3" y="9" width="10" height="1" fill="#e8e8e0"/><rect x="4" y="10" width="8" height="1" fill="#e8e8e0"/><rect x="3" y="6" width="3" height="2" fill="#0a0a0a"/><rect x="10" y="6" width="3" height="2" fill="#0a0a0a"/><rect x="5" y="11" width="2" height="1" fill="#e8e8e0"/><rect x="9" y="11" width="2" height="1" fill="#e8e8e0"/><rect x="2" y="12" width="3" height="1" fill="#e8e8e0"/><rect x="7" y="12" width="2" height="1" fill="#e8e8e0"/><rect x="11" y="12" width="3" height="1" fill="#e8e8e0"/><rect x="1" y="13" width="2" height="1" fill="#e8e8e0"/><rect x="13" y="13" width="2" height="1" fill="#e8e8e0"/></svg>';

    string internal constant WNS_LOGO =
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400"><rect width="400" height="400" fill="#fff"/><text x="200" y="200" font-family="sans-serif" font-size="24" text-anchor="middle" dominant-baseline="middle">wns.wei</text></svg>';

    /// @dev In descending rank order, which is the order they should be applied.
    function _postDeployListings() internal pure returns (Listing[] memory l) {
        l = new Listing[](7);
        l[0] = Listing(
            WSTETH,
            0x00A3FF,
            998_000,
            WSTETH_LOGO,
            "https://lido.fi",
            "Lido staked Ether, wrapped to a non-rebasing balance.",
            false,
            TokenList.Standard.ERC20
        );
        l[1] = Listing(
            RETH,
            0xED5A37,
            997_000,
            RETH_LOGO,
            "https://rocketpool.net",
            "Rocket Pool staked Ether. Accrues rewards in its rate.",
            false,
            TokenList.Standard.ERC20
        );
        l[2] = Listing(
            WBTC,
            0xF7931A,
            996_000,
            WBTC_LOGO,
            "https://wbtc.network",
            "Bitcoin custodied and issued as an ERC-20.",
            false,
            TokenList.Standard.ERC20
        );
        l[3] = Listing(
            BOLD,
            0x63D77D,
            993_000,
            BOLD_LOGO,
            "https://liquity.org",
            "Liquity v2 stablecoin, borrowed against staked Ether.",
            false,
            TokenList.Standard.ERC20
        );
        l[4] = Listing(
            ZORG,
            0xFFFFFF,
            992_000,
            ZORG_LOGO,
            "https://zorg.wei.domains",
            "zOrg governance shares. Bonded with zOrgz to direct conviction toward existing TokenList entries.",
            false,
            TokenList.Standard.ERC20
        );
        l[5] = Listing(
            ZORGZ,
            0x0A0A0A,
            991_000,
            ZORGZ_LOGO,
            "https://opensea.io/collection/zorgz",
            "zOrgz is the 10,000-piece ERC-721 collection used to create bonded zOrg governance receipts.",
            true,
            TokenList.Standard.ERC721
        );
        l[6] = Listing(
            WNS,
            0xFFFFFF,
            990_000,
            WNS_LOGO,
            "https://opensea.io/collection/wei-name-service",
            "Wei Name Service is an ERC-721 NameNFT collection. Its collection card uses the live wns.wei onchain SVG.",
            false,
            TokenList.Standard.ERC721
        );
        l[6].onchainSvg = true;
    }
}
