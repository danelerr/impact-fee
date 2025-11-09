// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title IYDSVault
 * @notice Interface for the Yield Donating Strategy Vault
 */
interface IYDSVault is IERC4626 {
    function donationAddress() external view returns (address);

    function governance() external view returns (address);

    function totalDonatedAssets() external view returns (uint256);

    function depositForDonation(uint256 assets) external returns (uint256 shares);

    function setDonationAddress(address newDonationAddress) external;

    function getVaultStats()
        external
        view
        returns (address _donationAddress, uint256 _totalDonatedAssets, uint256 _totalShares);

    event DonationMade(address indexed depositor, uint256 assets, uint256 shares);

    event DonationAddressUpdated(address indexed oldAddress, address indexed newAddress);
}
