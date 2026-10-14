// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";

import { IPositionsManager, IftYieldWrapper, ICircuitBreaker } from "./interfaces/IFtLend.sol";

/**
 * @title FtLendVault
 * @notice ERC-4626 wrapper around a Flying Tulip Lend (FT Lend) supply position, intended for use as a
 *         Balancer v3 boosted-pool token (Vault ERC4626 buffers).
 *
 * Trust assumptions inherited from FT Lend (documented, not mitigated here): PM is a UUPS proxy controlled by
 * a 3/5 Safe without timelock; the admin-set tokenizer for an asset may move `avail` balances without allowance.
 */
contract FtLendVault is ERC4626, Ownable2Step {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /// @notice Flying Tulip Lend PositionsManager.
    IPositionsManager public immutable PM;
    /// @notice FT reward token (read from PM at construction).
    address public immutable FT;

    /// @notice Receiver of harvested FT rewards.
    address public rewardRecipient;

    event Harvested(address indexed caller, address indexed recipient, uint256 ftAmount);
    event RewardRecipientSet(address indexed recipient);

    error AssetIsFT();
    error ZeroAddress();

    constructor(
        IPositionsManager pm,
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        address owner_,
        address rewardRecipient_
    ) ERC20(name_, symbol_) ERC4626(asset_) Ownable(owner_) {
        if (address(pm) == address(0)) revert ZeroAddress();
        address ft = pm.FT();
        // Wrapping FT itself would make harvest() indistinguishable from principal withdrawal.
        if (address(asset_) == ft) revert AssetIsFT();

        PM = pm;
        FT = ft;
        _setRewardRecipient(rewardRecipient_);

        // PM pulls the asset with safeTransferFrom(msg.sender). PM already custodies all deposited funds, so an
        // unlimited approval adds no trust beyond what the deposit itself requires.
        asset_.forceApprove(address(pm), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              ERC-4626 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626
    function totalAssets() public view override returns (uint256) {
        (uint256 avail,) = PM.getBalance(address(this), asset());
        return avail;
    }

    /// @inheritdoc ERC4626
    function maxDeposit(address) public view override returns (uint256) {
        address asset_ = asset();
        if (PM.depositPaused(asset_)) return 0;
        if (!PM.config().getAssetCfg(asset_).enabled) return 0;

        uint256 cap = PM.supplyCap(asset_);
        if (cap == 0) return type(uint256).max;

        (, uint256 cash, uint256 borrows,,,,,) = PM.astate(asset_);
        uint256 used = cash + borrows;
        return used >= cap ? 0 : cap - used;
    }

    /// @inheritdoc ERC4626
    function maxMint(address receiver) public view override returns (uint256) {
        uint256 assets = maxDeposit(receiver);
        return assets == type(uint256).max ? type(uint256).max : _convertToShares(assets, Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 ownerAssets = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        return _withdrawable(ownerAssets);
    }

    /// @inheritdoc ERC4626
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 shares = balanceOf(owner);
        uint256 ownerAssets = _convertToAssets(shares, Math.Rounding.Floor);
        uint256 withdrawable = _withdrawable(ownerAssets);
        if (withdrawable == ownerAssets) return shares;
        return _convertToShares(withdrawable, Math.Rounding.Floor);
    }

    /*//////////////////////////////////////////////////////////////
                              REWARDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Realise settled FT epochs for this vault and send all credited FT to `rewardRecipient`.
    function harvest() external returns (uint256 ftAmount) {
        PM.checkpointSupply(address(this), asset());
        (ftAmount,) = PM.getBalance(address(this), FT);
        if (ftAmount != 0) {
            PM.withdraw(address(this), FT, ftAmount, rewardRecipient);
        }
        emit Harvested(msg.sender, rewardRecipient, ftAmount);
    }

    function setRewardRecipient(address recipient) external onlyOwner {
        _setRewardRecipient(recipient);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ERC4626
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        PM.deposit(asset(), assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @inheritdoc ERC4626
    /// @dev Uses the 4-arg PM overload so the asset goes straight to `receiver` (no intermediate hop).
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }
        _burn(owner, shares);
        PM.withdraw(address(this), asset(), assets, receiver);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev Largest amount <= `limit` that FT Lend would let this contract withdraw right now:
    ///      min(limit, PM avail, PM cash, ftYieldWrapper liquid balance, circuit-breaker outflow capacity).
    ///      The ftYieldWrapper's own `canWithdraw`/`maxAbleToWithdraw` only cover liquidity; the circuit breaker
    ///      (rate limiter, e.g. 35% of TVL per 4h for USDC) is queried separately with the wrapper's TVL.
    function _withdrawable(uint256 limit) internal view returns (uint256) {
        if (limit == 0) return 0;
        address asset_ = asset();
        if (PM.withdrawPaused(asset_)) return 0;

        (uint256 avail,) = PM.getBalance(address(this), asset_);
        (, uint256 cash,,,,,,) = PM.astate(asset_);
        uint256 hi = Math.min(limit, Math.min(avail, cash));
        if (hi == 0) return 0;

        IftYieldWrapper yw = IftYieldWrapper(PM.config().getAssetCfg(asset_).ftYieldWrapper);
        hi = Math.min(hi, yw.maxAbleToWithdraw(hi));
        if (hi == 0) return 0;

        ICircuitBreaker cb = ICircuitBreaker(yw.circuitBreaker());
        if (address(cb) != address(0) && cb.isActive() && !cb.paused()) {
            hi = Math.min(hi, cb.withdrawalCapacity(asset_, _breakerTvl(yw)));
        }
        return hi;
    }

    /// @dev TVL figure the ftYieldWrapper hands to the circuit breaker (`preTvl`).
    function _breakerTvl(IftYieldWrapper yw) internal view returns (uint256) {
        return yw.capital();
    }

    function _setRewardRecipient(address recipient) internal {
        if (recipient == address(0)) revert ZeroAddress();
        rewardRecipient = recipient;
        emit RewardRecipientSet(recipient);
    }
}
