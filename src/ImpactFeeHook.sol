// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Uniswap V4 Imports
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

// OpenZeppelin Imports
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Custom Imports
import {YDSVault} from "./YDSVault.sol";

/**
 * @title ImpactFeeHook
 * @notice A Uniswap V4 Hook that automatically donates a portion of swap fees to Octant V2 YDS Vault
 * @dev Integrates Uniswap V4 with Octant's Yield Donating Strategy to fund public goods
 * 
 * Key Features:
 * - Intercepts swaps via beforeSwap hook with BeforeSwapDelta
 * - Correctly handles exactInput vs exactOutput semantics
 * - Collects impact fee as ERC6909 claims during swap
 * - Processes fees via unlock callback to convert claims to ERC20
 * - Deposits fees into YDSVault which mints donation shares to charity
 * 
 * Architecture:
 * - User swaps → beforeSwap() calculates fee on correct currency
 * - Hook takes fee as ERC6909 claims (stays in PoolManager)
 * - Returns BeforeSwapDelta (positive for input fee, negative for output fee)
 * - Later, processFees() converts claims to ERC20 via unlock callback
 * - Hook deposits ERC20 to YDSVault → charity receives shares
 * 
 * Safety Features:
 * - Address permission validation in constructor
 * - Safe int128 casting with overflow checks
 * - Pausability for emergency stops
 * - Per-pool fee overrides
 * - Dust guard to skip tiny fees
 * - Batch processing for gas efficiency
 * 
 * @custom:security-contact For Octant DeFi Hackathon 2025
 */
contract ImpactFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The YDS Vault that receives impact fees
    YDSVault public immutable ydsVault;

    /// @notice Impact fee in basis points (e.g., 10 = 0.1%, 100 = 1%)
    /// @dev uint16 saves gas and max value 65535 > MAX_IMPACT_FEE_BPS (500)
    uint16 public impactFeeBps;

    /// @notice Owner/governance address
    address public immutable owner;

    /// @notice Basis points denominator (10000 = 100%)
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum impact fee (5% = 500 bps)
    uint256 public constant MAX_IMPACT_FEE_BPS = 500;
    
    /// @notice Minimum fee to process (dust guard) - 1 wei/smallest unit
    /// @dev Set to 1 to support tokens with different decimals (USDC=6, DAI=18, etc.)
    /// @dev For production: consider per-currency dust thresholds via mapping
    uint256 public constant MIN_FEE_DUST = 1;

    /// @notice Tracks total fees collected per pool per currency
    mapping(PoolId => mapping(Currency => uint256)) public feesCollected;

    /// @notice Tracks total swaps per pool
    mapping(PoolId => uint256) public swapCount;

    /// @notice Pending fees (as ERC6909 claims) from beforeSwap to be processed later
    mapping(PoolId => mapping(Currency => uint256)) internal _pendingFees;
    
    /// @notice Per-pool fee override (0 = use global impactFeeBps)
    mapping(PoolId => uint16) internal _poolFeeOverride;
    
    /// @notice Paused state
    bool public paused;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an impact fee is collected and deposited to vault
    /// @param poolId The pool where the swap occurred
    /// @param currency The currency of the fee
    /// @param feeAmount The amount of fee collected
    event ImpactFeeCollected(PoolId indexed poolId, Currency indexed currency, uint256 feeAmount);

    /// @notice Emitted when fee is accrued during beforeSwap (as ERC6909 claims)
    /// @param poolId The pool where the swap occurred
    /// @param currency The currency of the fee
    /// @param feeAmount The amount of fee accrued
    /// @param swapper The address that initiated the swap (address(0) if unknown)
    event ImpactFeeAccrued(PoolId indexed poolId, Currency indexed currency, uint256 feeAmount, address swapper);

    /// @notice Emitted when the impact fee is updated
    /// @param oldFeeBps The previous fee in basis points
    /// @param newFeeBps The new fee in basis points
    event ImpactFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    
    /// @notice Emitted when paused state changes
    /// @param paused New paused state
    event PausedSet(bool paused);
    
    /// @notice Emitted when per-pool fee is set
    /// @param poolId Pool ID
    /// @param feeBps Fee in basis points (0 = use global)
    event PoolFeeSet(PoolId indexed poolId, uint16 feeBps);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an unauthorized address tries to update settings
    error Unauthorized();

    /// @notice Thrown when trying to set an invalid fee
    error InvalidFee();

    /// @notice Thrown when the vault asset doesn't match the swap currency
    error CurrencyMismatch();
    
    /// @notice Thrown when hook is paused
    error Paused();
    
    /// @notice Thrown when int128 cast would overflow
    error Int128Overflow();
    
    /// @notice Thrown when arrays length mismatch
    error ArrayLengthMismatch();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the Impact Fee Hook
     * @param poolManager_ The Uniswap V4 PoolManager
     * @param ydsVault_ The YDS Vault to receive donations
     * @param impactFeeBps_ Initial impact fee in basis points (e.g., 10 = 0.1%)
     * @param owner_ The owner/governance address
     */
    constructor(IPoolManager poolManager_, YDSVault ydsVault_, uint256 impactFeeBps_, address owner_)
        BaseHook(poolManager_)
    {
        // Validate hook address has correct permissions encoded in lower bits
        // This ensures the hook was deployed to an address matching its permissions
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        
        if (impactFeeBps_ > MAX_IMPACT_FEE_BPS) revert InvalidFee();
        ydsVault = ydsVault_;
        impactFeeBps = uint16(impactFeeBps_); // Safe cast: checked above
        owner = owner_;
    }

    /*//////////////////////////////////////////////////////////////
                        HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the hook's permissions
     * @dev We need beforeSwap with beforeSwapReturnDelta to collect fees as ERC6909 claims
     * @dev These permissions must match the flags encoded in the hook's address
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                        CORE HOOK LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Hook called before each swap
     * @dev Collects impact fee as ERC6909 claims that can be processed later
     * @dev Correctly handles exactInput vs exactOutput swap types
     * @dev CRITICAL: Fee always charged in the currency of amountSpecified for dimensional correctness
     * 
     * ExactInput (amountSpecified < 0):
     *   - User specifies exact input amount
     *   - Fee charged on INPUT currency (same as amountSpecified currency)
     *   - Positive delta on input (user pays more)
     *   - feeAmount calculated from |amountSpecified|
     * 
     * ExactOutput (amountSpecified > 0):
     *   - User specifies exact output amount  
     *   - Fee charged on OUTPUT currency (same as amountSpecified currency)
     *   - Negative delta on output (user receives less)
     *   - feeAmount calculated from amountSpecified
     * 
     * This ensures fee = bps * amountSpecified in the correct currency units.
     * Attempting to charge output fees in input currency would be dimensionally incorrect.
     * 
     * @param key The pool key
     * @param params The swap parameters
     * @return selector The function selector
     * @return beforeSwapDelta The delta representing fee taken
     * @return lpFeeOverride Fee override (0 = no override)
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Early return if paused
        if (paused) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        
        // Determine exactInput vs exactOutput
        bool exactInput = params.amountSpecified < 0;
        
        // Determine fee currency based on swap type
        // CRITICAL: Always charge fee in the currency of amountSpecified for dimensional correctness
        // - ExactInput: fee on INPUT currency (positive delta, user pays more input)
        // - ExactOutput: fee on OUTPUT currency (negative delta, user receives less output)
        Currency feeCurrency = exactInput
            ? (params.zeroForOne ? key.currency0 : key.currency1) // Input currency
            : (params.zeroForOne ? key.currency1 : key.currency0); // Output currency
        
        // Only charge fee if feeCurrency matches vault asset
        if (ydsVault.asset() != Currency.unwrap(feeCurrency)) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Get effective fee for this pool
        PoolId poolId = key.toId();
        uint16 feeBps = _getEffectiveFeeBps(poolId);
        if (feeBps == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        
        // Calculate fee
        uint256 feeAmount;
        unchecked {
            uint256 baseAmount = exactInput 
                ? uint256(-params.amountSpecified) 
                : uint256(params.amountSpecified);
            feeAmount = (baseAmount * uint256(feeBps)) / BPS_DENOMINATOR;
        }
        
        // Dust guard
        if (feeAmount < MIN_FEE_DUST) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Take fee as ERC6909 claims
        feeCurrency.take(poolManager, address(this), feeAmount, true);

        // Accrue pending fees
        unchecked {
            _pendingFees[poolId][feeCurrency] += feeAmount;
            swapCount[poolId]++;
        }
        
        emit ImpactFeeAccrued(poolId, feeCurrency, feeAmount, sender);
        
        // Build BeforeSwapDelta: Fee applied to specified amount
        // CRITICAL DIMENSIONAL CORRECTNESS:
        // - ExactInput: positive delta on input (user pays more) -> negative=false
        // - ExactOutput: negative delta on output (user receives less) -> negative=true
        return (
            this.beforeSwap.selector, 
            toBeforeSwapDelta(
                (feeCurrency == key.currency0) ? _safeToInt128(feeAmount, !exactInput) : int128(0),
                (feeCurrency == key.currency0) ? int128(0) : _safeToInt128(feeAmount, !exactInput)
            ), 
            0
        );
    }
    
    /*//////////////////////////////////////////////////////////////
                        FEE PROCESSING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Process accumulated fees: convert ERC6909 claims to ERC20 and deposit to vault
     * @dev Can be called by anyone (permissionless)
     * @dev Converts all pending fees for a specific pool/currency pair
     * @dev Uses unlock callback to ensure delta settlement
     * @param poolId The pool ID
     * @param currency The currency to process
     */
    function processFees(PoolId poolId, Currency currency) public {
        uint256 feeAmount = _pendingFees[poolId][currency];
        if (feeAmount == 0) return;
        
        // Validate currency matches vault (safety check)
        if (ydsVault.asset() != Currency.unwrap(currency)) revert CurrencyMismatch();

        // Clear pending fees before unlock to prevent reentrancy
        delete _pendingFees[poolId][currency];

        // Encode the unlock callback data
        bytes memory unlockData = abi.encode(poolId, currency, feeAmount);
        
        // Execute burn/take inside unlock callback
        // This opens a fresh unlock context where we can net deltas to zero
        poolManager.unlock(unlockData);
    }
    
    /**
     * @notice Process fees for multiple pool/currency pairs in batch
     * @dev Gas-efficient way to process multiple pending fees
     * @param poolIds Array of pool IDs
     * @param currencies Array of currencies (must match poolIds length)
     */
    function processFeesMany(PoolId[] calldata poolIds, Currency[] calldata currencies) external {
        if (poolIds.length != currencies.length) revert ArrayLengthMismatch();
        
        for (uint256 i = 0; i < poolIds.length;) {
            processFees(poolIds[i], currencies[i]);
            unchecked { ++i; }
        }
    }

    /**
     * @notice Unlock callback to process fees
     * @dev Called by PoolManager during unlock
     * @dev Burns ERC6909 claims and takes ERC20, netting deltas to zero
     * @dev This is the ONLY place where we should call unlock-dependent operations
     * 
     * Delta accounting:
     * - burn() creates -feeAmount delta (we destroy claims)
     * - take() creates +feeAmount delta (we extract ERC20)
     * - Net: -feeAmount + feeAmount = 0 ✅ (settlement successful)
     * 
     * @param data Encoded (poolId, currency, feeAmount)
     * @return Empty bytes (unused)
     */
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (PoolId poolId, Currency currency, uint256 feeAmount) = abi.decode(data, (PoolId, Currency, uint256));

        // Burn ERC6909 claims (creates -feeAmount delta)
        poolManager.burn(address(this), currency.toId(), feeAmount);
        
        // Take ERC20 tokens from PoolManager (creates +feeAmount delta)
        // Net delta: -feeAmount + feeAmount = 0 ✅
        poolManager.take(currency, address(this), feeAmount);

        // Approve vault to spend the tokens
        IERC20(Currency.unwrap(currency)).forceApprove(address(ydsVault), feeAmount);

        // Deposit to vault (mints shares to address(this), which should be donation address)
        // The vault will mint shares to its configured donation address
        ydsVault.deposit(feeAmount, address(this));

        // Update tracking
        unchecked { 
            feesCollected[poolId][currency] += feeAmount; 
        }

        // Emit event (no swapper since this is batch processing)
        emit ImpactFeeCollected(poolId, currency, feeAmount);

        return "";
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the global impact fee
     * @dev Only callable by owner
     * @param newFeeBps New fee in basis points
     */
    function setImpactFee(uint256 newFeeBps) external {
        if (msg.sender != owner) revert Unauthorized();
        if (newFeeBps > MAX_IMPACT_FEE_BPS) revert InvalidFee();

        uint16 oldFeeBps = impactFeeBps;
        impactFeeBps = uint16(newFeeBps); // Safe cast: checked above

        emit ImpactFeeUpdated(oldFeeBps, impactFeeBps); // No need to cast again
    }
    
    /**
     * @notice Set paused state (emergency stop)
     * @dev Only callable by owner
     * @param _paused New paused state
     */
    function setPaused(bool _paused) external {
        if (msg.sender != owner) revert Unauthorized();
        paused = _paused;
        emit PausedSet(_paused);
    }
    
    /**
     * @notice Set per-pool fee override
     * @dev Only callable by owner
     * @dev Allows different fees for different pools
     * @param poolId Pool ID
     * @param feeBps Fee in basis points (0 = use global fee)
     */
    function setPoolImpactFee(PoolId poolId, uint16 feeBps) external {
        if (msg.sender != owner) revert Unauthorized();
        if (feeBps > MAX_IMPACT_FEE_BPS) revert InvalidFee();
        _poolFeeOverride[poolId] = feeBps;
        emit PoolFeeSet(poolId, feeBps);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Get effective fee for a pool (override or global)
     * @param poolId Pool ID
     * @return Effective fee in basis points
     */
    function getEffectiveFeeBps(PoolId poolId) external view returns (uint16) {
        return _getEffectiveFeeBps(poolId);
    }

    /**
     * @notice Returns statistics for a specific pool
     * @param poolId The pool ID
     * @param currency The currency to query
     * @return totalFees Total fees collected and processed
     * @return totalSwaps Total number of swaps
     */
    function getPoolStats(PoolId poolId, Currency currency)
        external
        view
        returns (uint256 totalFees, uint256 totalSwaps)
    {
        return (feesCollected[poolId][currency], swapCount[poolId]);
    }

    /**
     * @notice Calculates the fee for a given swap amount
     * @param amount The swap amount
     * @return The calculated fee
     */
    function calculateFee(uint256 amount) external view returns (uint256) {
        return (amount * impactFeeBps) / BPS_DENOMINATOR;
    }

    /**
     * @notice Returns pending fees (as ERC6909 claims) for a pool/currency
     * @dev These fees have been accrued but not yet processed
     * @param poolId The pool ID
     * @param currency The currency to query
     * @return The pending fee amount
     */
    function getPendingFees(PoolId poolId, Currency currency) external view returns (uint256) {
        return _pendingFees[poolId][currency];
    }
    
    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @notice Safely cast uint256 to int128 with optional negation
     * @dev Prevents overflow when constructing BeforeSwapDelta
     * @param value Value to cast
     * @param negative Whether to negate the result
     * @return Result as int128
     */
    function _safeToInt128(uint256 value, bool negative) internal pure returns (int128) {
        // Check if value fits in int128 positive range (2^127 - 1)
        if (value > uint128(type(int128).max)) revert Int128Overflow();
        
        int128 result = int128(uint128(value));
        return negative ? -result : result;
    }
    
    /**
     * @notice Get effective fee for a pool (internal)
     * @dev Checks per-pool override first, falls back to global
     * @param poolId Pool ID
     * @return Effective fee in basis points
     */
    function _getEffectiveFeeBps(PoolId poolId) internal view returns (uint16) {
        uint16 override_ = _poolFeeOverride[poolId];
        if (override_ > 0) {
            return override_;
        }
        // Safe cast: impactFeeBps is constrained to MAX_IMPACT_FEE_BPS (500)
        return uint16(impactFeeBps);
    }
}
