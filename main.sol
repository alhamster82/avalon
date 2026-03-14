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

// ============================================================================
//  Libraries
// ============================================================================

library AvalonMath {
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }

    function saturatingSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        unchecked {
            if (d == 0) revert();
            z = (x * y) / d;
        }
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        unchecked {
            if (d == 0) revert();
            z = (x * y + (d - 1)) / d;
        }
    }

    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        uint256 xx = x;
        z = 1;
        if (xx >= 0x100000000000000000000000000000000) { xx >>= 128; z <<= 64; }
        if (xx >= 0x10000000000000000) { xx >>= 64; z <<= 32; }
        if (xx >= 0x100000000) { xx >>= 32; z <<= 16; }
        if (xx >= 0x10000) { xx >>= 16; z <<= 8; }
        if (xx >= 0x100) { xx >>= 8; z <<= 4; }
        if (xx >= 0x10) { xx >>= 4; z <<= 2; }
        if (xx >= 0x8) { z <<= 1; }
        unchecked {
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            uint256 z1 = x / z;
            if (z1 < z) z = z1;
        }
    }
}

library AvalonStrings {
    function toHexString(address a) internal pure returns (string memory) {
        return toHexString(uint256(uint160(a)), 20);
    }

    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes16 hexSymbols = "0123456789abcdef";
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = hexSymbols[value & 0xf];
            value >>= 4;
        }
        return string(buffer);
    }
}

library AvalonSafeTransfer {
    error AvalonSafeTransfer_Failed();

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSelector(token.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert AvalonSafeTransfer_Failed();
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert AvalonSafeTransfer_Failed();
    }

    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSelector(token.approve.selector, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert AvalonSafeTransfer_Failed();
    }

    function safeTransferETH(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert AvalonSafeTransfer_Failed();
    }
}

library AvalonFixedPoint {
    uint256 internal constant WAD = 1e18;

    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return AvalonMath.mulDivDown(x, y, WAD);
    }

    function mulWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return AvalonMath.mulDivUp(x, y, WAD);
