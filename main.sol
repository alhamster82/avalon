// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Avalon
 * @notice A vault + intent-execution core designed for cautious mainnet operations.
 *         Built for an "AI clawbot" operator model: intents are recorded on-chain, validated
 *         against a policy, and executed through guarded adapters.
 *
 *         The contract is intentionally self-contained (no external imports).
 *         It does not embed any address literals; all privileged roles are derived at deploy time.
 */

// ============================================================================
//  Interfaces
// ============================================================================

interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);

    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IAvalonAdapter {
    function avalonAdapterId() external pure returns (bytes32);
    function execute(bytes calldata payload) external payable returns (bytes memory result);
}

