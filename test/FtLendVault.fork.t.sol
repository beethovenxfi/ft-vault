// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { FtLendVault } from "../src/FtLendVault.sol";
import { IRateProvider } from "@balancer-v3-monorepo/interfaces/solidity-utils/helpers/IRateProvider.sol";

import { IERC4626RateProviderFactory } from "../src/interfaces/IERC4626RateProviderFactory.sol";
import { IPositionsManager, ILendingLens, IftYieldWrapper, ICircuitBreaker } from "../src/interfaces/IFtLend.sol";
import { Sonic } from "./Sonic.sol";

/// @notice Sonic fork tests for FtLendVault over FT Lend USDC. Run with SONIC_RPC_URL set.
contract FtLendVaultForkTest is Test {
    IPositionsManager constant PM = IPositionsManager(Sonic.PM);
    IERC20 constant USDC = IERC20(Sonic.USDC);
    IERC20 constant FT = IERC20(Sonic.FT);
    ILendingLens constant LENS = ILendingLens(Sonic.LENS);

    FtLendVault vault;

    /// @dev FT Lend's Chainlink router reverts `StalePrice()` past the feed heartbeat (USDC: 88200s). Every
    ///      withdrawal runs `enforcePostHF`, which prices the position, so fork tests must stay within it.
    uint256 constant EPOCH_SKIP = 6 hours;

    address owner = makeAddr("owner");
    address recipient = makeAddr("rewardRecipient");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address donor = makeAddr("donor");
    address admin;

    function setUp() public {
        vm.createSelectFork("sonic", Sonic.FORK_BLOCK);

        vault = new FtLendVault(PM, USDC, "Beets FT Lend USDC", "bftUSDC", owner, recipient);
        admin = PM.admin();

        deal(Sonic.USDC, alice, 1_000_000e6);
        deal(Sonic.USDC, bob, 1_000_000e6);
        deal(Sonic.USDC, donor, 1_000_000e6);
        vm.prank(alice);
        USDC.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        USDC.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Off-chain monitoring recipe: FT already credited to the vault's PM FT position + FT claimable from
    ///      settled epochs not yet checkpointed (LendingLens). The vault itself exposes no view for this.
    function _pendingRewards() internal view returns (uint256) {
        (uint256 credited,) = PM.getBalance(address(vault), Sonic.FT);
        return credited + LENS.previewFTClaimFor(address(vault), Sonic.USDC);
    }

    function _cash() internal view returns (uint256 cash) {
        (, cash,,,,,,) = PM.astate(Sonic.USDC);
    }

    function _borrows() internal view returns (uint256 borrows) {
        (,, borrows,,,,,) = PM.astate(Sonic.USDC);
    }

    function _settleEpoch(uint256 ftAmount) internal {
        deal(Sonic.FT, admin, ftAmount);
        vm.startPrank(admin);
        FT.approve(Sonic.PM, ftAmount);
        PM.settleEpoch(Sonic.USDC, ftAmount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              TESTS
    //////////////////////////////////////////////////////////////*/

    function test_metadata() public view {
        assertEq(vault.asset(), Sonic.USDC);
        assertEq(vault.decimals(), 6);
        assertEq(vault.FT(), Sonic.FT);
        assertEq(address(vault.PM()), Sonic.PM);
        assertEq(vault.owner(), owner);
        assertEq(vault.rewardRecipient(), recipient);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(USDC.allowance(address(vault), Sonic.PM), type(uint256).max);
    }

    function test_constructorRejectsFTAsAsset() public {
        vm.expectRevert(FtLendVault.AssetIsFT.selector);
        new FtLendVault(PM, FT, "x", "x", owner, recipient);
    }

    function test_constructorRejectsZeroRecipient() public {
        vm.expectRevert(FtLendVault.ZeroAddress.selector);
        new FtLendVault(PM, USDC, "x", "x", owner, address(0));
    }

    /// @dev PM's tokenizer for USDC (`ftUSDC`) is an ERC-20 view over PM `avail`, so the vault's position also shows
    ///      up as an ftUSDC balance. It is a mirror, not a holding: nothing can move it without the vault acting
    ///      (vault never approves / signs), and the vault never calls it.
    function test_positionIsMirroredByFtUSDC() public {
        IERC20 ftUSDC = IERC20(Sonic.FT_USDC);
        assertEq(PM.tokenizerForAsset(Sonic.USDC), Sonic.FT_USDC, "fixture: ftUSDC is the USDC tokenizer");
        assertEq(ftUSDC.balanceOf(address(vault)), 0);

        vm.prank(alice);
        vault.deposit(100_000e6, alice);
        assertEq(ftUSDC.balanceOf(address(vault)), 100_000e6, "ftUSDC mirrors PM avail");
        assertEq(ftUSDC.balanceOf(address(vault)), vault.totalAssets());

        // A third party cannot pull it via the ERC-20 surface: no allowance was ever granted.
        vm.prank(bob);
        (bool ok,) = address(ftUSDC).call(abi.encodeCall(IERC20.transferFrom, (address(vault), bob, 1)));
        assertFalse(ok, "transferFrom without allowance reverts");

        vm.prank(alice);
        vault.withdraw(100_000e6, alice, alice);
        assertEq(ftUSDC.balanceOf(address(vault)), 0);
    }

    function test_depositWithdrawOneToOne() public {
        uint256 cashBefore = _cash();

        vm.prank(alice);
        uint256 shares = vault.deposit(100_000e6, alice);
        assertEq(shares, 100_000e6, "1:1 shares");
        assertEq(vault.totalAssets(), 100_000e6);
        assertEq(vault.totalSupply(), 100_000e6);
        (uint256 avail, uint256 hold) = PM.getBalance(address(vault), Sonic.USDC);
        assertEq(avail, 100_000e6, "PM avail");
        assertEq(hold, 0, "PM hold");
        assertEq(_cash(), cashBefore + 100_000e6, "PM cash grew");
        assertEq(USDC.balanceOf(address(vault)), 0, "vault holds nothing itself");

        // withdraw straight to a third-party receiver
        vm.prank(alice);
        uint256 burned = vault.withdraw(40_000e6, bob, alice);
        assertEq(burned, 40_000e6);
        assertEq(USDC.balanceOf(bob), 1_000_000e6 + 40_000e6);
        assertEq(vault.balanceOf(alice), 60_000e6);
        assertEq(vault.totalAssets(), 60_000e6);

        // redeem remainder
        vm.prank(alice);
        uint256 assets = vault.redeem(60_000e6, alice, alice);
        assertEq(assets, 60_000e6);
        assertEq(USDC.balanceOf(alice), 1_000_000e6 - 40_000e6);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(_cash(), cashBefore);
    }

    function test_mintRedeemAndPreviewsExact() public {
        assertEq(vault.previewDeposit(123_456), 123_456);
        assertEq(vault.previewMint(123_456), 123_456);
        assertEq(vault.previewWithdraw(123_456), 123_456);
        assertEq(vault.previewRedeem(123_456), 123_456);
        assertEq(vault.convertToAssets(1e6), 1e6);
        assertEq(vault.convertToShares(1e6), 1e6);

        vm.prank(alice);
        uint256 assets = vault.mint(5_000e6, alice);
        assertEq(assets, 5_000e6);
        assertEq(vault.balanceOf(alice), 5_000e6);
    }

    function test_withdrawByApprovedSpender() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        vm.prank(alice);
        vault.approve(bob, 4_000e6);

        vm.prank(bob);
        vault.withdraw(4_000e6, bob, alice);
        assertEq(vault.balanceOf(alice), 6_000e6);
        assertEq(vault.allowance(alice, bob), 0);

        vm.prank(bob);
        vm.expectRevert();
        vault.withdraw(1, bob, alice);
    }

    function test_maxDepositReflectsSupplyCapAndPause() public {
        uint256 cap = PM.supplyCap(Sonic.USDC);
        uint256 used = _cash() + _borrows();
        assertGt(cap, used, "fixture: cap has headroom");
        assertEq(vault.maxDeposit(alice), cap - used);
        assertEq(vault.maxMint(alice), cap - used);

        // over-cap deposit reverts through OZ's maxDeposit check
        deal(Sonic.USDC, alice, cap);
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(cap - used + 1, alice);

        vm.prank(admin);
        PM.setDepositPaused(Sonic.USDC, true);
        assertEq(vault.maxDeposit(alice), 0);
        assertEq(vault.maxMint(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1e6, alice);

        vm.prank(admin);
        PM.setDepositPaused(Sonic.USDC, false);
        assertEq(vault.maxDeposit(alice), cap - used);
    }

    function test_maxWithdrawZeroWhenPaused() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);
        assertEq(vault.maxWithdraw(alice), 10_000e6);
        assertEq(vault.maxRedeem(alice), 10_000e6);

        vm.prank(admin);
        PM.setWithdrawPaused(Sonic.USDC, true);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.maxRedeem(alice), 0);
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(1e6, alice, alice);

        vm.prank(admin);
        PM.setWithdrawPaused(Sonic.USDC, false);
        assertEq(vault.maxWithdraw(alice), 10_000e6);
    }

    /// @dev The ftYieldWrapper circuit breaker rate-limits outflows (USDC: 35% of TVL per 4h). `maxWithdraw`
    ///      must reflect it: withdrawing exactly maxWithdraw succeeds, one unit more reverts.
    function test_maxWithdrawBoundedByCircuitBreaker() public {
        vm.prank(alice);
        vault.deposit(600_000e6, alice);

        IftYieldWrapper yw = IftYieldWrapper(PM.config().getAssetCfg(Sonic.USDC).ftYieldWrapper);
        ICircuitBreaker cb = ICircuitBreaker(yw.circuitBreaker());
        assertTrue(cb.isActive() && !cb.paused(), "fixture: breaker live");

        // The breaker credits recent inflows, so right after the deposit the capacity exceeds it. Let the main and
        // elastic windows elapse (4h + 2h on USDC; still inside the 88200s oracle heartbeat).
        (, uint256 mainWindow, uint256 elasticWindow) = cb.getEffectiveConfig(Sonic.USDC);
        skip(mainWindow + elasticWindow + 1);
        uint256 capacity = cb.withdrawalCapacity(Sonic.USDC, yw.capital());
        assertLt(capacity, 600_000e6, "fixture: breaker binds below alice's position");
        assertLt(capacity, _cash(), "fixture: breaker binds before cash");

        uint256 maxW = vault.maxWithdraw(alice);
        assertEq(maxW, capacity, "maxWithdraw == breaker capacity");
        assertEq(vault.maxRedeem(alice), capacity, "maxRedeem == breaker capacity (1:1)");

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(maxW + 1, alice, alice);

        // Bypassing the ERC-4626 max check by calling PM directly as the vault also fails, in the breaker itself:
        // proves maxWithdraw is not under-reporting.
        vm.prank(address(vault));
        vm.expectRevert(); // ftYieldWrapperRateLimitExceeded(requested, available)
        PM.withdraw(address(vault), Sonic.USDC, maxW + 1, alice);

        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);
        assertEq(vault.balanceOf(alice), 600_000e6 - maxW);
        assertLt(vault.maxWithdraw(alice), 1e6, "capacity consumed for this window");
    }

    /// @dev With the breaker paused (owner prank), push utilization up with a real borrow so `cash` drops below the
    ///      vault's position, then check `maxWithdraw` tracks `cash` and an over-withdraw reverts.
    function test_maxWithdrawBoundedByLendingLiquidity() public {
        IftYieldWrapper yw = IftYieldWrapper(PM.config().getAssetCfg(Sonic.USDC).ftYieldWrapper);
        ICircuitBreaker cb = ICircuitBreaker(yw.circuitBreaker());
        vm.prank(cb.owner());
        cb.pause();

        vm.prank(alice);
        vault.deposit(200_000e6, alice);
        assertEq(vault.maxWithdraw(alice), 200_000e6, "breaker paused: only cash binds");

        uint256 cash = _cash();
        uint256 target = 150_000e6; // leave 150k cash so alice (200k) is liquidity-bound
        assertGt(cash, target, "fixture: enough cash to drain");
        uint256 toBorrow = cash - target;

        // The live borrow cap is close to current borrows; lift it (admin) so the borrow below is a real flow.
        uint256 supplyCap = PM.supplyCap(Sonic.USDC);
        uint256 newBorrowCap = _borrows() + toBorrow + 1e6;
        vm.prank(admin);
        PM.setCaps(Sonic.USDC, supplyCap, newBorrowCap);

        // Borrower: post wS collateral (wS supply cap 50M, ~34M used), borrow USDC.
        address borrower = makeAddr("borrower");
        deal(Sonic.WS, borrower, 15_000_000e18);
        vm.startPrank(borrower);
        IERC20(Sonic.WS).approve(Sonic.PM, type(uint256).max);
        PM.deposit(Sonic.WS, 15_000_000e18);
        PM.borrow(Sonic.USDC, toBorrow);
        vm.stopPrank();

        uint256 cashAfter = _cash();
        assertEq(cashAfter, cash - toBorrow);
        assertLt(cashAfter, 200_000e6, "fixture: cash below alice's position");

        assertEq(vault.maxWithdraw(alice), cashAfter, "maxWithdraw == cash");
        assertEq(vault.maxRedeem(alice), cashAfter, "maxRedeem == cash (1:1)");
        assertEq(vault.totalAssets(), 200_000e6, "principal untouched by utilization");

        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(cashAfter + 1, alice, alice);

        vm.prank(alice);
        vault.withdraw(cashAfter, alice, alice);
        assertEq(vault.maxWithdraw(alice), 0);
        assertEq(vault.balanceOf(alice), 200_000e6 - cashAfter);
    }

    function test_harvestSendsFTToRecipientOnly() public {
        vm.prank(alice);
        vault.deposit(100_000e6, alice);
        skip(EPOCH_SKIP);
        uint256 reward = 10_000e18;
        _settleEpoch(reward);

        uint256 pending = _pendingRewards();
        assertGt(pending, 0, "pending FT after epoch");
        // Epoch rewards are split by supply-time (asset * seconds). The vault supplied 100k for exactly 1 day of
        // the epoch; the epoch itself also covers the time since the previous settlement before the fork.
        (,,,,, uint256 supplyTimeEpoch) = _latestEpoch();
        uint256 expected = (reward * (100_000e6 * EPOCH_SKIP)) / supplyTimeEpoch;
        assertApproxEqRel(pending, expected, 0.001e18, "pending == pro-rata share of supply-time");

        uint256 got = vault.harvest();
        assertEq(got, pending, "harvest realises exactly the pending amount");
        assertEq(FT.balanceOf(recipient), got, "FT lands at recipient");
        assertEq(FT.balanceOf(address(vault)), 0);
        (uint256 ftAvail,) = PM.getBalance(address(vault), Sonic.FT);
        assertEq(ftAvail, 0, "no FT left in PM position");
        assertEq(vault.totalAssets(), 100_000e6, "principal untouched");
        assertEq(vault.totalSupply(), 100_000e6);

        // idempotent
        assertEq(vault.harvest(), 0);
        assertEq(_pendingRewards(), 0);
    }

    function test_rewardsAccrueEvenWithoutHarvestAndFollowDepositsWithdraws() public {
        vm.prank(alice);
        vault.deposit(100_000e6, alice);
        skip(EPOCH_SKIP);
        _settleEpoch(1_000e18);

        // A user action auto-checkpoints: FT credited inside PM without harvest()
        vm.prank(bob);
        vault.deposit(1e6, bob);
        (uint256 ftAvail,) = PM.getBalance(address(vault), Sonic.FT);
        assertGt(ftAvail, 0, "auto-checkpoint credited FT");
        assertEq(vault.totalAssets(), 100_001e6, "FT never counts as assets");
    }

    /// @dev Production-critical: once an epoch settles, the vault's PM position also holds FT. Both principal
    ///      withdrawals and harvest() must keep working in that state (FT has no Chainlink feed on the router).
    function test_withdrawAndHarvestWorkWhileVaultHoldsFT() public {
        vm.prank(alice);
        vault.deposit(100_000e6, alice);
        skip(EPOCH_SKIP);
        _settleEpoch(1_000e18);

        // Trigger auto-checkpoint so FT is credited but not harvested.
        vm.prank(bob);
        vault.deposit(1e6, bob);
        (uint256 ftAvail,) = PM.getBalance(address(vault), Sonic.FT);
        assertGt(ftAvail, 0, "vault position holds FT");

        // Principal withdrawal while holding FT
        vm.prank(alice);
        vault.withdraw(50_000e6, alice, alice);
        assertEq(vault.balanceOf(alice), 50_000e6);

        // Harvest while holding principal
        uint256 got = vault.harvest();
        assertEq(got, ftAvail);
        assertEq(FT.balanceOf(recipient), ftAvail);
    }

    /// @dev Documents an FT Lend dependency: if the asset's Chainlink feed goes stale (heartbeat 88200s for
    ///      USDC, no stale fallback configured), every withdrawal reverts `StalePrice()` until the feed updates.
    ///      Deposits keep working. Balancer buffer unwraps that fall through to the wrapper would revert too.
    function test_withdrawRevertsWhenOracleStale_documentsDependency() public {
        vm.prank(alice);
        vault.deposit(10_000e6, alice);

        skip(2 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("StalePrice()"));
        vault.withdraw(1e6, alice, alice);

        // maxWithdraw does not see oracle state; it still reports liquidity.
        assertEq(vault.maxWithdraw(alice), 10_000e6);

        vm.prank(bob);
        vault.deposit(1e6, bob);
        assertEq(vault.balanceOf(bob), 1e6, "deposits unaffected by stale oracle");
    }

    function test_donationOnlyRaisesSharePriceAndStaysConsistent() public {
        vm.prank(alice);
        vault.deposit(100_000e6, alice);

        // Third party donates into the vault's PM position (allowed because the vault already holds USDC there).
        vm.startPrank(donor);
        USDC.approve(Sonic.PM, 10_000e6);
        PM.depositFor(address(vault), Sonic.USDC, 10_000e6);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 110_000e6);
        assertEq(vault.totalSupply(), 100_000e6);
        assertGt(vault.convertToAssets(1e6), 1e6, "share price > 1");

        // Later depositor never extracts more than deposited; previews match actuals.
        uint256 depositAmt = 1_000e6;
        uint256 previewShares = vault.previewDeposit(depositAmt);
        vm.prank(bob);
        uint256 shares = vault.deposit(depositAmt, bob);
        assertEq(shares, previewShares, "previewDeposit exact");
        assertLt(shares, depositAmt, "fewer shares after donation");

        uint256 previewAssets = vault.previewRedeem(shares);
        vm.prank(bob);
        uint256 assets = vault.redeem(shares, bob, bob);
        assertEq(assets, previewAssets, "previewRedeem exact");
        assertLe(assets, depositAmt, "never more than deposited");
        assertGe(assets, depositAmt - 2, "within rounding");

        // Alice benefits from the donation on exit.
        vm.prank(alice);
        uint256 aliceOut = vault.redeem(100_000e6, alice, alice);
        assertGt(aliceOut, 100_000e6);
        assertLe(aliceOut, 110_000e6);
    }

    function test_setRewardRecipient() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.setRewardRecipient(alice);

        vm.prank(owner);
        vm.expectRevert(FtLendVault.ZeroAddress.selector);
        vault.setRewardRecipient(address(0));

        vm.prank(owner);
        vault.setRewardRecipient(bob);
        assertEq(vault.rewardRecipient(), bob);
    }

    /// @dev Rate provider comes from Balancer's canonical factory on Sonic (reviewer-approved by default), not from
    ///      this repo. Rate is 1e18 until a third party donates into the vault's PM position.
    function test_factoryRateProviderReadsOneUntilDonation() public {
        IERC4626RateProviderFactory factory = IERC4626RateProviderFactory(Sonic.ERC4626_RATE_PROVIDER_FACTORY);
        IRateProvider rp = IRateProvider(factory.create(address(vault)));
        assertTrue(factory.isRateProviderFromFactory(address(rp)));
        assertEq(rp.getRate(), 1e18, "empty vault rate");

        vm.prank(alice);
        vault.deposit(100_000e6, alice);
        assertEq(rp.getRate(), 1e18, "1:1 rate");

        vm.startPrank(donor);
        USDC.approve(Sonic.PM, 10_000e6);
        PM.depositFor(address(vault), Sonic.USDC, 10_000e6);
        vm.stopPrank();
        assertApproxEqAbs(rp.getRate(), 1.1e18, 1e6, "rate reflects donation");
    }

    function _latestEpoch()
        internal
        view
        returns (uint40 t_end, uint256 S_end, uint256 rateRay, uint256 X_end, uint256 interest, uint256 supplyTime)
    {
        (,,,,,,, uint32 epoch) = PM.astate(Sonic.USDC);
        return PM.epochs(Sonic.USDC, epoch);
    }
}
