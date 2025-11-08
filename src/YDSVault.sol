// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/**
 * @title YDSVault
 * @notice A simplified Yield Donating Strategy (YDS) vault for the Octant V2 integration
 * @dev This vault automatically mints donation shares to a designated charity address when deposits are made.
 * 
 * Key Features:
 * - Inherits from ERC4626 standard vault interface
 * - Automatically donates yield by minting shares to a charity address
 * - Designed to integrate with Uniswap V4 ImpactFeeHook
 * 
 * Architecture:
 * - ImpactFeeHook calls deposit() with swap fees
 * - YDSVault mints donation shares to the donationAddress
 * - Donation shares represent claims on future yield
 * 
 * @custom:security-contact For Octant DeFi Hackathon 2025
 */
contract YDSVault is ERC4626 {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The address that receives donation shares (the charity/public good)
    address public donationAddress;

    /// @notice The address authorized to update the donation address (governance/admin)
    address public immutable governance;

    /// @notice Total assets deposited through the ImpactFeeHook
    uint256 public totalDonatedAssets;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a donation is made through the vault
    /// @param depositor The address making the deposit (usually the ImpactFeeHook)
    /// @param assets The amount of assets deposited
    /// @param shares The amount of shares minted to the donation address
    event DonationMade(address indexed depositor, uint256 assets, uint256 shares);

    /// @notice Emitted when the donation address is updated
    /// @param oldAddress The previous donation address
    /// @param newAddress The new donation address
    event DonationAddressUpdated(address indexed oldAddress, address indexed newAddress);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Thrown when an unauthorized address tries to update the donation address
    error Unauthorized();

    /// @notice Thrown when trying to set the donation address to zero
    error InvalidDonationAddress();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the YDS Vault
     * @param asset_ The underlying ERC20 asset to be deposited (e.g., USDC, DAI)
     * @param donationAddress_ The initial address to receive donation shares
     * @param governance_ The governance address that can update settings
     * @param name_ The name of the vault token (e.g., "Octant Impact Vault USDC")
     * @param symbol_ The symbol of the vault token (e.g., "oivUSDC")
     */
    constructor(
        IERC20 asset_,
        address donationAddress_,
        address governance_,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) ERC4626(asset_) {
        if (donationAddress_ == address(0)) revert InvalidDonationAddress();
        donationAddress = donationAddress_;
        governance = governance_;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits assets and automatically mints shares to the donation address
     * @dev This function is called by the ImpactFeeHook when swap fees are collected
     * @param assets The amount of assets to deposit
     * @param receiver The address that initiated the deposit (for tracking/events)
     * @return shares The amount of shares minted to the donation address
     * 
     * Flow:
     * 1. Transfer assets from caller (ImpactFeeHook) to vault
     * 2. Calculate shares based on current exchange rate
     * 3. Mint shares to donationAddress (not to receiver)
     * 4. Emit DonationMade event
     */
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        // Check deposit limits (inherited from ERC4626)
        if (assets > maxDeposit(receiver)) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxDeposit(receiver));
        }

        // Calculate shares to mint
        uint256 shares = previewDeposit(assets);

        // Transfer assets from depositor to vault
        SafeERC20.safeTransferFrom(IERC20(asset()), msg.sender, address(this), assets);

        // Mint shares to the donation address (not to receiver!)
        _mint(donationAddress, shares);

        // Update total donated assets
        totalDonatedAssets += assets;

        // Emit events
        emit Deposit(msg.sender, donationAddress, assets, shares);
        emit DonationMade(msg.sender, assets, shares);

        return shares;
    }

    /**
     * @notice Deposits exact amount of assets and mints shares to donation address
     * @dev Alternative deposit function for convenience
     * @param assets The amount of assets to deposit
     * @return shares The amount of shares minted
     */
    function depositForDonation(uint256 assets) external returns (uint256 shares) {
        return deposit(assets, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the donation address
     * @dev Only callable by governance
     * @param newDonationAddress The new address to receive donation shares
     */
    function setDonationAddress(address newDonationAddress) external {
        if (msg.sender != governance) revert Unauthorized();
        if (newDonationAddress == address(0)) revert InvalidDonationAddress();

        address oldAddress = donationAddress;
        donationAddress = newDonationAddress;

        emit DonationAddressUpdated(oldAddress, newDonationAddress);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the total assets held by the vault
     * @dev Override to include any yield strategy logic in the future
     * @return Total assets in the vault
     */
    function totalAssets() public view virtual override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    /**
     * @notice Returns vault statistics
     * @return _donationAddress Current donation address
     * @return _totalDonatedAssets Total assets donated through the vault
     * @return _totalShares Total shares minted to donation address
     */
    function getVaultStats()
        external
        view
        returns (address _donationAddress, uint256 _totalDonatedAssets, uint256 _totalShares)
    {
        return (donationAddress, totalDonatedAssets, balanceOf(donationAddress));
    }
}
