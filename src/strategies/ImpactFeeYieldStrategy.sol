// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseStrategy} from "@octant-core/BaseStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ImpactFeeHook} from "../ImpactFeeHook.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title ImpactFeeYieldStrategy
 * @notice Octant V2 BaseStrategy that collects swap fees from ImpactFeeHook as yield
 * @dev Idle strategy: fees deposited are considered profit, no external deployment
 */
contract ImpactFeeYieldStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The ImpactFeeHook that sends fees to this strategy
    ImpactFeeHook public immutable impactFeeHook;

    /// @notice Assets reported in last report period
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
     * @param _impactFeeHook Address of the ImpactFeeHook contract
     * @param _asset Address of the underlying asset
     */
    constructor(
        address _impactFeeHook,
        address _asset
    ) {
        if (_impactFeeHook == address(0)) revert InvalidHookAddress();
        impactFeeHook = ImpactFeeHook(_impactFeeHook);
        
        if (address(asset) == address(0)) {
            asset = ERC20(_asset);
        }

        lastReportedAssets = 0;
    }

    /*//////////////////////////////////////////////////////////////
                    MANDATORY BASESTRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy funds into yield source
     * @dev No-op: yield comes from hook deposits, assets stay idle
     * @param _amount Amount available to deploy
     */
    function _deployFunds(uint256 _amount) internal override {
        emit FeesReceived(_amount, IERC20(asset).balanceOf(address(this)));
    }

    /**
     * @notice Free funds from yield source
     * @dev No-op: funds are already idle
     * @param _amount Amount to free
     */
    function _freeFunds(uint256 _amount) internal override {
    }

    /**
     * @notice Harvest and report total assets
     * @return _totalAssets Total assets held by strategy
     */
    function _harvestAndReport() internal override returns (uint256 _totalAssets) {
        _totalAssets = IERC20(asset).balanceOf(address(this));

        uint256 profit = _totalAssets > lastReportedAssets 
            ? _totalAssets - lastReportedAssets 
            : 0;

        if (profit > 0) {
            emit YieldDonated(profit, _totalAssets);
        }

        lastReportedAssets = _totalAssets;

        return _totalAssets;
    }

    /*//////////////////////////////////////////////////////////////
                        OPTIONAL OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Gets the max amount of asset that can be deposited
     * @return Unlimited deposit
     */
    function availableDepositLimit(address /* _owner */) public view override returns (uint256) {
        return type(uint256).max;
    }

    /**
     * @notice Gets the max amount of asset that can be withdrawn
     * @return Total idle assets
     */
    function availableWithdrawLimit(address /* _owner */) public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    /**
     * @notice Emergency withdraw when strategy is shutdown
     * @dev No-op: funds are already idle
     * @param _amount Amount to emergency withdraw
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
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
        totalAssets = IERC20(asset).balanceOf(address(this));
        lastReported = lastReportedAssets;
        pendingProfit = totalAssets > lastReported ? totalAssets - lastReported : 0;
    }
}
