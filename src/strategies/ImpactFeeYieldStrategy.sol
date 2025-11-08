// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseStrategy} from "@octant-core/BaseStrategy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ImpactFeeHook} from "../ImpactFeeHook.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title ImpactFeeYieldStrategy
 * @author Impact Fee Team - Octant DeFi Hackathon 2025
 * @notice Octant V2 YieldDonating Strategy that collects swap fees from ImpactFeeHook
 * 
 * @dev This strategy integrates with ImpactFeeHook to collect fees from Uniswap V4 swaps
 *      and automatically donate 100% of the yield to Octant's dragonRouter for public goods funding.
 * 
 * Architecture:
 * 1. ImpactFeeHook collects fees from swaps as ERC6909 claims
 * 2. Anyone calls processFees() on the hook to convert claims → ERC20 → deposit to this strategy
 * 3. This strategy receives the deposited assets and considers them as "yield"
 * 4. When report() is called, profit is automatically minted as shares to dragonRouter
 * 5. DragonRouter allocates these shares to public goods projects in Octant ecosystem
 * 
 * Key Features:
 * - No external yield source deployment needed (yield comes from swap fees)
 * - 100% of fees donated to public goods via Octant V2
 * - No performance fees charged to users
 * - Compatible with Octant V2's YieldDonatingTokenizedStrategy
 * 
 * Integration with Octant V2:
 * - Inherits from BaseStrategy (Yearn V3 tokenized strategy pattern)
 * - Profits are minted to dragonRouter automatically
 * - Optional loss protection via enableBurning (burns dragon shares on losses)
 * 
 * @custom:security-contact For Octant DeFi Hackathon 2025
 */
contract ImpactFeeYieldStrategy is BaseStrategy {
    using SafeERC20 for ERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The ImpactFeeHook that sends fees to this strategy
    ImpactFeeHook public immutable impactFeeHook;

    /// @notice Tracks assets deposited in the last report period (for yield calculation)
    uint256 public lastReportedAssets;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when fees are received from the hook
    event FeesReceived(uint256 amount, uint256 newBalance);

    /// @notice Emitted when yield is reported and donated
    event YieldDonated(uint256 profit, uint256 totalAssets);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidHookAddress();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize the Impact Fee Yield Strategy
     * @dev Constructor simplified - initialization is handled by TokenizedStrategy pattern
     * @param _impactFeeHook Address of the ImpactFeeHook contract
     * @param _asset Address of the underlying asset (same as hook's fee asset)
     */
    constructor(
        address _impactFeeHook,
        address _asset
    ) {
        if (_impactFeeHook == address(0)) revert InvalidHookAddress();
        impactFeeHook = ImpactFeeHook(_impactFeeHook);
        asset = ERC20(_asset);

        // Initialize last reported assets
        lastReportedAssets = 0;
    }

    /*//////////////////////////////////////////////////////////////
                    MANDATORY BASESTRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy funds into yield source
     * @dev For Impact Fee Strategy, we don't deploy anywhere - yield comes from hook deposits
     *      All assets stay idle in the strategy, waiting for report() to recognize them as profit
     * @param _amount Amount of assets available to deploy (we don't deploy them)
     */
    function _deployFunds(uint256 _amount) internal override {
        // No-op: We don't deploy funds to an external protocol
        // Assets deposited by the hook remain idle until report()
        // This is intentional - our "yield source" is the ImpactFeeHook deposits
        emit FeesReceived(_amount, ERC20(asset).balanceOf(address(this)));
    }

    /**
     * @notice Free funds from yield source
     * @dev For Impact Fee Strategy, funds are already idle (not deployed anywhere)
     *      So we don't need to withdraw from anywhere
     * @param _amount Amount of assets to free (already free)
     */
    function _freeFunds(uint256 _amount) internal override {
        // No-op: Funds are already idle (not deployed anywhere)
        // The TokenizedStrategy will handle the actual transfer to user
    }

    /**
     * @notice Harvest and report total assets
     * @dev This function is called during report() to calculate profit/loss
     *      
     * Flow:
     * 1. Get current idle assets in strategy
     * 2. Compare with lastReportedAssets to determine profit
     * 3. Profit is automatically minted as shares to dragonRouter
     * 4. Update lastReportedAssets for next report
     * 
     * @return _totalAssets Total assets held by strategy (all idle)
     */
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        // Get current balance of assets in this strategy
        _totalAssets = ERC20(asset).balanceOf(address(this));

        // Calculate profit since last report
        uint256 profit = _totalAssets > lastReportedAssets 
            ? _totalAssets - lastReportedAssets 
            : 0;

        // Emit event for tracking
        if (profit > 0) {
            emit YieldDonated(profit, _totalAssets);
        }

        // Update for next report
        // Note: We update AFTER TokenizedStrategy processes this report
        // The actual update happens in the next call since this is internal
        lastReportedAssets = _totalAssets;

        return _totalAssets;
    }

    /*//////////////////////////////////////////////////////////////
                        OPTIONAL OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the max amount of `asset` that can be deposited
     * @dev Only the ImpactFeeHook should deposit into this strategy
     *      But we keep it permissionless for Octant V2 compatibility
     * @return Unlimited deposit (anyone can deposit, but only hook will in practice)
     */
    function availableDepositLimit(address /* _owner */) public view override returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @notice Gets the max amount of `asset` that can be withdrawn
     * @dev All assets are idle, so all can be withdrawn
     * @return Total idle assets
     */
    function availableWithdrawLimit(address /* _owner */) public view override returns (uint256) {
        return ERC20(asset).balanceOf(address(this));
    }

    /**
     * @notice Emergency withdraw when strategy is shutdown
     * @dev For Impact Fee Strategy, assets are already idle, so nothing to withdraw
     * @param _amount Amount to emergency withdraw (no-op since funds are idle)
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // No-op: Funds are already idle in the strategy
        // Emergency admin can shutdown and users can withdraw directly
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get the address of the ImpactFeeHook
     * @return Address of the hook contract
     */
    function getHook() external view returns (address) {
        return address(impactFeeHook);
    }

    /**
     * @notice Get expected yield from pending fees in the hook
     * @dev This queries the hook's pending fees to estimate future yield
     * @param poolId The pool ID to check
     * @param currency The currency to check
     * @return Expected fees that will become yield when processed
     */
    function getExpectedYield(PoolId poolId, Currency currency) external view returns (uint256) {
        return impactFeeHook.getPendingFees(poolId, currency);
    }

    /**
     * @notice Get strategy statistics
     * @return hook Address of ImpactFeeHook
     * @return totalAssets Current total assets
     * @return lastReported Assets reported in last report
     * @return pendingProfit Estimated profit since last report
     */
    function getStrategyStats()
        external
        view
        returns (
            address hook,
            uint256 totalAssets,
            uint256 lastReported,
            uint256 pendingProfit
        )
    {
        hook = address(impactFeeHook);
        totalAssets = ERC20(asset).balanceOf(address(this));
        lastReported = lastReportedAssets;
        pendingProfit = totalAssets > lastReported ? totalAssets - lastReported : 0;
    }
}
