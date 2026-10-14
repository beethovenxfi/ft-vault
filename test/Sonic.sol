// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Sonic mainnet (chainId 146) addresses used by the fork tests. Verified 2026-10-13 against the
///         Flying Tulip address book (flyingtulip.com/address-book/flying-tulip-address-book-prod.json) and RPC reads.
library Sonic {
    uint256 internal constant FORK_BLOCK = 80_900_000;

    // Flying Tulip Lend
    address internal constant PM = 0xbe4050a73a7Fb384c65E885a15C33461A4B20055; // PositionsManager (UUPS proxy)
    address internal constant LENS = 0x3682168023E6bA8D1F995FdA1D920827C5A8A43E; // LendingLens (proxy)
    address internal constant FT = 0x5DD1A7A369e8273371d2DBf9d83356057088082c;
    address internal constant FT_USDC = 0xE91DAA84Df38A30D609249C6830cDf7465800841; // ftUSDC, PM tokenizer for USDC

    // Assets
    address internal constant USDC = 0x29219dd400f2Bf60E5a23d13Be72B486D4038894; // native USDC (Circle), 6 decimals
    address internal constant WS = 0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38; // wS, 18 decimals

    // Balancer v3 / Beets
    address internal constant BALANCER_VAULT = 0xbA1333333333a1BA1108E8412f11850A5C319bA9;
    address internal constant BUFFER_ROUTER = 0x532dA919D3EB5606b5867A6f505969c57F3A721b;
    address internal constant ERC4626_RATE_PROVIDER_FACTORY = 0xc9A0E686C02AfFB176E06F0b344cab182250e487;
}
