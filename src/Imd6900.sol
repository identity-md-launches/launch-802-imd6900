// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Imd6900
/// @notice Fixed-supply, fee-free ERC-20 with 18 decimals and no administrative privileges.
contract Imd6900 is ERC20 {
    /// @notice One billion tokens, expressed in the token's smallest unit.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Mints the entire supply once to the immediate deployer (including a factory).
    constructor() ERC20("Imd6900", "IMD6900") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
