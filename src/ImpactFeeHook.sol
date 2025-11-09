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
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ImpactFeeHook
 * @notice Uniswap V4 hook that charges a small fee on swaps and deposits to an ERC4626 vault
 * @dev Handles exactInput/exactOutput correctly, collects fees as ERC6909 claims, processes via unlock callback
 */
contract ImpactFeeHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The ERC4626 vault that receives impact fees
    IERC4626 public feeSink;

    /// @notice Impact fee in basis points (10 = 0.1%, 100 = 1%)
    uint16 public impactFeeBps;

    /// @notice Owner/governance address
    address public immutable owner;

    /// @notice Basis points denominator (10000 = 100%)
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Maximum impact fee (5% = 500 bps)
    uint256 public constant MAX_IMPACT_FEE_BPS = 500;
    
    /// @notice Minimum fee to process (dust guard)
    uint256 public constant MIN_FEE_DUST = 1;

    /// @notice Tracks total fees collected per pool per currency
    mapping(PoolId => mapping(Currency => uint256)) public feesCollected;

    /// @notice Tracks total swaps per pool
    mapping(PoolId => uint256) public swapCount;

    /// @notice Pending fees (ERC6909 claims) from beforeSwap awaiting processing
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
    
    /// @notice Emitted when fee sink is updated (migration to new vault/strategy)
    /// @param newSink New ERC4626 fee sink address
    event FeeSinkUpdated(address indexed newSink);

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
     * @notice Initializes the ImpactFeeHook
     * @param poolManager_ The Uniswap V4 PoolManager
     * @param feeSink_ The ERC4626 vault to receive fees
     * @param impactFeeBps_ Initial impact fee in basis points
     * @param owner_ The owner/governance address
     */
    constructor(IPoolManager poolManager_, IERC4626 feeSink_, uint256 impactFeeBps_, address owner_)
        BaseHook(poolManager_)
    {
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        
        if (impactFeeBps_ > MAX_IMPACT_FEE_BPS) revert InvalidFee();
        feeSink = feeSink_;
        impactFeeBps = uint16(impactFeeBps_);
        owner = owner_;
    }

    /*//////////////////////////////////////////////////////////////
                        HOOK PERMISSIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the hook's permissions
     * @dev Requires beforeSwap with beforeSwapReturnDelta to collect fees as ERC6909 claims
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
     * @notice Hook called before each swap to collect impact fee
     * @dev Fee charged in currency of amountSpecified for dimensional correctness
     * @dev ExactInput (amountSpecified < 0): fee on input, positive delta
     * @dev ExactOutput (amountSpecified > 0): fee on output, negative delta
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
        
        bool exactInput = params.amountSpecified < 0;
        
        // Fee charged in currency of amountSpecified
        Currency feeCurrency = exactInput
            ? (params.zeroForOne ? key.currency0 : key.currency1)
            : (params.zeroForOne ? key.currency1 : key.currency0);
        
        // Only charge fee if feeCurrency matches feeSink asset
        if (feeSink.asset() != Currency.unwrap(feeCurrency)) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

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

        unchecked {
            _pendingFees[poolId][feeCurrency] += feeAmount;
            swapCount[poolId]++;
        }
        
        emit ImpactFeeAccrued(poolId, feeCurrency, feeAmount, sender);
        
        // Build BeforeSwapDelta
        // ExactInput: positive delta on input
        // ExactOutput: negative delta on output
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
     * @param poolId The pool ID
     * @param currency The currency to process
     */
    function processFees(PoolId poolId, Currency currency) public {
        uint256 feeAmount = _pendingFees[poolId][currency];
        if (feeAmount == 0) return;
        
        if (feeSink.asset() != Currency.unwrap(currency)) revert CurrencyMismatch();

        delete _pendingFees[poolId][currency];

        bytes memory unlockData = abi.encode(poolId, currency, feeAmount);
        
        poolManager.unlock(unlockData);
    }
    
    /**
     * @notice Process fees for multiple pool/currency pairs in batch
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
     * @dev Burns ERC6909 claims and takes ERC20, netting deltas to zero
     * @param data Encoded (poolId, currency, feeAmount)
     * @return Empty bytes
     */
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (PoolId poolId, Currency currency, uint256 feeAmount) = abi.decode(data, (PoolId, Currency, uint256));

        poolManager.burn(address(this), currency.toId(), feeAmount);
        
        poolManager.take(currency, address(this), feeAmount);

        address token = Currency.unwrap(currency);
        
        if (feeSink.asset() != token) revert CurrencyMismatch();

        IERC20(token).forceApprove(address(feeSink), feeAmount);
        
        feeSink.deposit(feeAmount, address(this));

        unchecked { 
            feesCollected[poolId][currency] += feeAmount; 
        }

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
    
    /**
     * @notice Set the fee sink
     * @dev Validates that new sink uses same asset
     * @param newSink New ERC4626 vault to receive fees
     */
    function setFeeSink(IERC4626 newSink) external {
        if (msg.sender != owner) revert Unauthorized();
        if (newSink.asset() != feeSink.asset()) revert CurrencyMismatch();
        feeSink = newSink;
        emit FeeSinkUpdated(address(newSink));
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
     * @notice Returns pending fees for a pool/currency
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
     * @param value Value to cast
     * @param negative Whether to negate the result
     * @return Result as int128
     */
    function _safeToInt128(uint256 value, bool negative) internal pure returns (int128) {
        if (value > uint128(type(int128).max)) revert Int128Overflow();
        
        int128 result = int128(uint128(value));
        return negative ? -result : result;
    }
    
    /**
     * @notice Get effective fee for a pool
     * @param poolId Pool ID
     * @return Effective fee in basis points
     */
    function _getEffectiveFeeBps(PoolId poolId) internal view returns (uint16) {
        uint16 override_ = _poolFeeOverride[poolId];
        if (override_ > 0) {
            return override_;
        }
        return uint16(impactFeeBps);
    }
}
