// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ITokenizedStrategy
 * @notice Minimal interface shim for BaseStrategy compatibility
 * @dev This is a local stub to satisfy BaseStrategy imports from octant-v2-core
 */
interface ITokenizedStrategy {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    
    function report() external returns (uint256 profit, uint256 loss);
    function tend() external;
    function tendTrigger() external view returns (bool);
    
    function management() external view returns (address);
    function keeper() external view returns (address);
    function performanceFeeRecipient() external view returns (address);
    
    function requireManagement(address caller) external view;
    function requireKeeperOrManagement(address caller) external view;
    function requireEmergencyAuthorized(address caller) external view;
    
    function isShutdown() external view returns (bool);
    function unlockedShares() external view returns (uint256);
}
