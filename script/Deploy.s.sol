// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { FtLendVault } from "../src/FtLendVault.sol";
import { IERC4626RateProviderFactory } from "../src/interfaces/IERC4626RateProviderFactory.sol";
import { IPositionsManager } from "../src/interfaces/IFtLend.sol";

/**
 * @notice Deploys FtLendVault, seeds it, and optionally creates its Balancer rate provider via the canonical factory.
 *
 * Env vars:
 *   PM                      PositionsManager proxy (Sonic: 0xbe4050a73a7Fb384c65E885a15C33461A4B20055)
 *   ASSET                   underlying (Sonic USDC: 0x29219dd400f2Bf60E5a23d13Be72B486D4038894)
 *   NAME / SYMBOL           e.g. "Beets FT Lend USDC" / "bftUSDC"
 *   OWNER                   Beets multisig (owner of the vault; can only change rewardRecipient)
 *   REWARD_RECIPIENT        where harvested FT goes (gauge distributor / multisig)
 *   SEED_AMOUNT             raw units deposited by the broadcaster right after deploy; shares go to OWNER.
 *                           Mitigates first-depositor inflation games. Use >= 100 USDC. 0 to skip.
 *   RATE_PROVIDER_FACTORY   Balancer ERC4626RateProviderFactory; `create(vault)` is called if set
 *                           (Sonic: 0xc9A0E686C02AfFB176E06F0b344cab182250e487). Omit / zero to skip.
 *
 * Run:
 *   forge script script/Deploy.s.sol --rpc-url sonic --broadcast --verify
 */
contract Deploy is Script {
    function run() external {
        IPositionsManager pm = IPositionsManager(vm.envAddress("PM"));
        IERC20 asset = IERC20(vm.envAddress("ASSET"));
        string memory name = vm.envString("NAME");
        string memory symbol = vm.envString("SYMBOL");
        address owner = vm.envAddress("OWNER");
        address rewardRecipient = vm.envAddress("REWARD_RECIPIENT");
        uint256 seed = vm.envOr("SEED_AMOUNT", uint256(0));
        address factory = vm.envOr("RATE_PROVIDER_FACTORY", address(0));

        vm.startBroadcast();

        FtLendVault vault = new FtLendVault(pm, asset, name, symbol, owner, rewardRecipient);
        console.log("FtLendVault:", address(vault));

        if (seed != 0) {
            asset.approve(address(vault), seed);
            uint256 shares = vault.deposit(seed, owner);
            console.log("Seeded shares to owner:", shares);
        }

        if (factory != address(0)) {
            address rp = IERC4626RateProviderFactory(factory).create(address(vault));
            console.log("ERC4626RateProvider (factory):", rp);
        }

        vm.stopBroadcast();
    }
}
