// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Balancer `ERC4626RateProviderFactory` (balancer/metastable-rate-providers). Sonic: 0xc9A0E686C02AfFB176E06F0b344cab182250e487.
///         `create` deploys an `ERC4626RateProvider` whose `getRate()` = `erc4626.convertToAssets(fixedPointOne)`.
interface IERC4626RateProviderFactory {
    event RateProviderCreated(address indexed rateProvider);

    function create(address erc4626) external returns (address rateProvider);
    function isRateProviderFromFactory(address rateProvider) external view returns (bool);
}
