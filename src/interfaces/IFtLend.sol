// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Minimal Flying Tulip Lend interfaces
 * @notice Hand-written subsets of the verified Flying Tulip Lend contracts, limited to what FtLendVault calls.
 *
 * Source of truth (verified bytecode, Sourcify / Sonicscan):
 *   PositionsManager impl 0x89b6f9179671C0B471734B897E31F8760a94dc53 (proxy 0xbe4050a73a7Fb384c65E885a15C33461A4B20055)
 *   LendingLens impl     0x054c80b91B39fC4f84EF0ecd53bbb53163229795 (proxy 0x3682168023E6bA8D1F995FdA1D920827C5A8A43E) (tests only)
 *   ftYieldWrapper       interface lib/ft-common-contracts/contracts/interfaces/IftYieldWrapper.sol
 */
interface IConfigRegistry {
    struct AssetCfg {
        address irm;
        uint16 mmBps;
        bool enabled;
        address ftYieldWrapper;
        bool borrowable;
        bool collateral;
    }

    function getAssetCfg(address asset) external view returns (AssetCfg memory);
}

interface IftYieldWrapper {
    function token() external view returns (address);
    function totalSupply() external view returns (uint256);
    /// @dev 1:1 receipt units for all capital routed through the wrapper (PM cash); TVL figure for the breaker.
    function capital() external view returns (uint256);
    /// @dev Liquidity check only (idle cash + strategy liquidity). Does NOT consult the circuit breaker.
    function canWithdraw(uint256 amount) external view returns (bool);
    /// @dev min(amount, liquid balance). Does NOT consult the circuit breaker.
    function maxAbleToWithdraw(uint256 amount) external view returns (uint256);
    function circuitBreaker() external view returns (address);
}

/// @notice Flying Tulip CircuitBreaker (v1) at 0x9676E697399581AB288844cDE5F73d0887eC18e0 on Sonic/Ethereum.
///         Outflow rate limiter per asset: `maxDrawRateWad` of `currentTvl` per `mainWindow` (+ elastic window).
interface ICircuitBreaker {
    function isActive() external view returns (bool);
    function paused() external view returns (bool);
    function owner() external view returns (address);
    function pause() external;
    function unpause() external;
    function withdrawalCapacity(address asset, uint256 currentTvl) external view returns (uint256 capacity);
    function getEffectiveConfig(address asset)
        external
        view
        returns (uint256 maxDrawRateWad, uint256 mainWindow, uint256 elasticWindow);
}

interface IPositionsManager {
    // ---- user flows ----
    function deposit(address asset, uint256 amt) external;
    function depositFor(address beneficiary, address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amt) external;
    function withdraw(address user, address asset, uint256 amt, address to) external;
    function checkpointSupply(address user, address asset) external;
    function borrow(address asset, uint256 amt) external;

    // ---- admin (used only in tests via prank) ----
    function admin() external view returns (address);
    function settleEpoch(address asset, uint256 interest) external;
    function setWithdrawPaused(address asset, bool paused) external;
    function setDepositPaused(address asset, bool paused) external;
    function setCaps(address asset, uint256 supplyCap_, uint256 borrowCap_) external;

    // ---- views ----
    function FT() external view returns (address);
    function config() external view returns (IConfigRegistry);
    function getBalance(address user, address token) external view returns (uint256 avail, uint256 holdBal);
    function withdrawPaused(address asset) external view returns (bool);
    function depositPaused(address asset) external view returns (bool);
    function supplyCap(address asset) external view returns (uint256);
    function borrowCap(address asset) external view returns (uint256);
    function tokenizerForAsset(address asset) external view returns (address);
    function userDebtAssets(address user) external view returns (address[] memory);
    function epochs(address asset, uint32 epochId)
        external
        view
        returns (uint40 t_end, uint256 S_end, uint256 rateRay, uint256 X_end, uint256 interest, uint256 supplyTime);
    function astate(address asset)
        external
        view
        returns (
            uint256 borrowIndexWad,
            uint256 cash,
            uint256 borrows,
            uint256 totalSupplied,
            uint256 reserves,
            uint256 totalSuppliedTime,
            uint40 lastAccrual,
            uint32 epoch
        );
}

interface ILendingLens {
    function previewFTClaimFor(address user, address asset) external view returns (uint256 ftAmount);
    function previewMaxWithdraw(address user, address asset) external view returns (uint256 maxUnits);
    function canWithdraw(address user, address asset, uint256 amt) external view returns (bool);
}
