// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IYDSVault
 * @notice Interface for the Yield Donating Strategy Vault
 */
interface IYDSVault is IERC4626 {
    /// @notice The address that receives donation shares
    function donationAddress() external view returns (address);

    /// @notice The governance address
    function governance() external view returns (address);

    /// @notice Total assets donated through the vault
    function totalDonatedAssets() external view returns (uint256);

    /// @notice Deposits assets and mints shares to donation address
    function depositForDonation(uint256 assets) external returns (uint256 shares);

    /// @notice Updates the donation address (governance only)
    function setDonationAddress(address newDonationAddress) external;

    /// @notice Returns vault statistics
    function getVaultStats()
        external
        view
        returns (address _donationAddress, uint256 _totalDonatedAssets, uint256 _totalShares);

    /// @notice Emitted when a donation is made
    event DonationMade(address indexed depositor, uint256 assets, uint256 shares);

    /// @notice Emitted when donation address is updated
    event DonationAddressUpdated(address indexed oldAddress, address indexed newAddress);
}
