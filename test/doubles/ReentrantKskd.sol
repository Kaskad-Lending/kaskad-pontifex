// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {KskdExit} from "../../src/KskdExit.sol";

/// @notice KSKD-shaped token whose `transferFrom` reenters `KskdExit.exit` once. The real Igra KSKD
///         has no such hook; this exists only to prove the exit's checks-effects-interactions order.
contract ReentrantKskd is ERC20 {
    KskdExit public exitBridge;
    address public reentrantRecipient;
    uint256 public reentrantAmount;
    bool internal entered;

    constructor(address holder) ERC20("Kaskad", "KSKD") {
        _mint(holder, 1_000_000 ether);
        _mint(address(this), 1_000_000 ether);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// Arm the hook: the next `transferFrom` reenters `exit(amount, recipient)` as this token.
    function arm(KskdExit exit_, address recipient, uint256 amount) external {
        exitBridge = exit_;
        reentrantRecipient = recipient;
        reentrantAmount = amount;
        _approve(address(this), address(exit_), type(uint256).max);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (address(exitBridge) != address(0) && !entered) {
            entered = true;
            exitBridge.exit(reentrantAmount, reentrantRecipient);
        }
        return super.transferFrom(from, to, value);
    }
}

/// @notice KSKD-shaped token whose `permit` reenters `KskdExit.exit` once, to prove that the
///         `exitWithPermit` call order leaves no half-written state for the inner exit to read.
contract PermitReentrantKskd is ERC20 {
    KskdExit public exitBridge;
    address public reentrantRecipient;
    uint256 public reentrantAmount;
    bool public reentered;

    constructor(address holder) ERC20("Kaskad", "KSKD") {
        _mint(holder, 1_000_000 ether);
        _mint(address(this), 1_000_000 ether);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// Arm the hook: the next `permit` reenters `exit(amount, recipient)` as this token.
    function arm(KskdExit exit_, address recipient, uint256 amount) external {
        exitBridge = exit_;
        reentrantRecipient = recipient;
        reentrantAmount = amount;
        _approve(address(this), address(exit_), type(uint256).max);
    }

    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external {
        if (address(exitBridge) != address(0) && !reentered) {
            reentered = true;
            exitBridge.exit(reentrantAmount, reentrantRecipient);
        }
        _approve(owner, spender, value);
    }
}
