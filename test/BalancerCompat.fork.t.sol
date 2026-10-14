// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.24;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ERC4626WrapperBaseTest, ForkState, ERC4626SetupState } from "./vendor/ERC4626WrapperBase.t.sol";
import { FtLendVault } from "../src/FtLendVault.sol";
import { IPositionsManager } from "../src/interfaces/IFtLend.sol";
import { Sonic } from "./Sonic.sol";

/**
 * @notice Balancer's official ERC-4626 buffer compatibility suite, run against a freshly deployed FtLendVault
 *         (USDC) on a Sonic fork. The upstream harness targets already-deployed wrappers; here the wrapper is
 *         deployed inside `_setUpForkTestVariables`, which the base `setUp` calls after selecting the fork.
 *         To re-run against the live deployment, swap `new FtLendVault(...)` for the deployed address.
 */
contract FtLendVaultUsdcBalancerCompatTest is ERC4626WrapperBaseTest {
    address internal constant DONOR = address(uint160(uint256(keccak256("ftlend.donor"))));

    function _setupFork() internal pure override returns (ForkState memory) {
        return ForkState({ network: "sonic", blockNumber: Sonic.FORK_BLOCK });
    }

    function _setUpForkTestVariables() internal override returns (ERC4626SetupState memory s) {
        FtLendVault vault = new FtLendVault(
            IPositionsManager(Sonic.PM),
            IERC20(Sonic.USDC),
            "Beets FT Lend USDC",
            "bftUSDC",
            makeAddr("owner"),
            makeAddr("rewardRecipient")
        );

        // Harness requires the donor to hold >= 3 * amountToDonate.
        deal(Sonic.USDC, DONOR, 1_000_000e6);

        s.wrapper = IERC4626(address(vault));
        s.underlyingDonor = DONOR;
        s.amountToDonate = 200_000e6; // 3 wallets x 200k = 600k routed through FT Lend (cap 10M, cash ~490k)
        s.minDeposit = 1e4; // Balancer Vault minimum wrap amount (getMinimumWrapAmount)
        // Every FT Lend withdrawal runs `enforcePostHF`, which prices all of the position's collateral through the
        // Chainlink oracle router and reverts `StalePrice()` past the feed heartbeat. The harness default skip of
        // 1 day trips that on a fork, so keep the skip inside the heartbeat window.
        s.skipTime = 10 minutes;
    }
}
