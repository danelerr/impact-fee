// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/**
 * @title YDSVault
 * @notice Simplified ERC4626 vault that automatically donates shares to a designated address
 * @dev Integrates with ImpactFeeHook to receive swap fees and mint donation shares
 */
contract YDSVault is ERC4626 {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The address that receives donation shares
    address public donationAddress;

    /// @notice The address authorized to update settings
    address public immutable governance;

    /// @notice Total assets deposited
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
     * @param asset_ The underlying ERC20 asset
     * @param donationAddress_ The address to receive donation shares
     * @param governance_ The governance address
     * @param name_ The vault token name
     * @param symbol_ The vault token symbol
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
     * @notice Deposits assets and mints shares to donation address
     * @param assets Amount of assets to deposit
     * @param receiver Address that initiated the deposit (for tracking)
     * @return shares Amount of shares minted to donation address
     */
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        if (assets > maxDeposit(receiver)) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxDeposit(receiver));
        }

        uint256 shares = previewDeposit(assets);

        SafeERC20.safeTransferFrom(IERC20(asset()), msg.sender, address(this), assets);

        _mint(donationAddress, shares);

        totalDonatedAssets += assets;

        emit Deposit(msg.sender, donationAddress, assets, shares);
        emit DonationMade(msg.sender, assets, shares);

        return shares;
    }

    /**
     * @notice Deposits exact amount of assets and mints shares to donation address
     * @param assets Amount of assets to deposit
     * @return shares Amount of shares minted
     */
    function depositForDonation(uint256 assets) external returns (uint256 shares) {
        return deposit(assets, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Updates the donation address
     * @param newDonationAddress New address to receive donation shares
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
