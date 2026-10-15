// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title KskdBridged
/// @notice Robinhood KSKD. No premint: supply enters only through `bridgeMint`
///         from the current `bridge`, monotone per recipient and capped globally
///         by `MAX_SUPPLY`. Matching a recipient's mint to the Igra burn is the
///         entry's job, not this contract's. No burn: the migration is one-way.
contract KskdBridged is ERC20, ERC20Permit, Ownable2Step {
    /// @notice Igra KSKD `TOTAL_SUPPLY`. The bridge can never mint more than was ever issued there.
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;

    /// @notice Only caller allowed to mint. Zero disables minting.
    address public bridge;

    /// @notice Cumulative amount minted to `recipient` through the bridge. Only grows.
    mapping(address recipient => uint256) public bridgedIn;

    event BridgeSet(address indexed bridge);

    error NotBridge();
    error NothingToMint(uint256 cumulative, uint256 alreadyMinted);
    error MaxSupplyExceeded(uint256 requested, uint256 available);

    constructor(address bridge_, address initialOwner)
        ERC20("Kaskad", "KSKD")
        ERC20Permit("Kaskad")
        Ownable(initialOwner)
    {
        bridge = bridge_;
        emit BridgeSet(bridge_);
    }

    /// @notice Point minting at a new entry, or at zero to stop it. Renouncing ownership
    ///         freezes this pointer; only `setBridge(address(0))` first freezes the supply.
    function setBridge(address newBridge) external onlyOwner {
        bridge = newBridge;
        emit BridgeSet(newBridge);
    }

    /// @notice Mint the difference between `cumulative` (attested Igra burn total) and
    ///         what `recipient` already received.
    function bridgeMint(address recipient, uint256 cumulative) external {
        if (msg.sender != bridge) revert NotBridge();

        uint256 prior = bridgedIn[recipient];
        // Typed revert, not a no-op: `bridge` is owner-settable and need not pre-filter.
        if (cumulative <= prior) revert NothingToMint(cumulative, prior);
        uint256 minted = cumulative - prior;

        // No burn path exists, so totalSupply() is the lifetime bridged-in total.
        uint256 available = MAX_SUPPLY - totalSupply();
        if (minted > available) revert MaxSupplyExceeded(minted, available);

        bridgedIn[recipient] = cumulative;
        _mint(recipient, minted);
    }
}
