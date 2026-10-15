// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title KSKD — Kaskad protocol token
/// @notice Fixed supply ERC20 with EIP-2612 permit. Whole supply minted to the
///         Kaskad multisig at deploy; further allocations are multisig-directed.
contract KSKD is ERC20, ERC20Permit {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    constructor(address kaskadMultisig) ERC20("Kaskad", "KSKD") ERC20Permit("Kaskad") {
        _mint(kaskadMultisig, TOTAL_SUPPLY);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
