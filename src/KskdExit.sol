// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IKskdBurnable is IERC20, IERC20Permit {
    function burn(uint256 amount) external;
}

/// @title KskdExit
/// @notice Igra side of the KSKD migration bridge. Burns KSKD and records the
///         cumulative amount burned per Robinhood recipient; the enclave reads
///         `burned` and attests it to KskdEntry. `CLOSER` can end the migration and
///         retune the dust floor; the ledger itself is untouchable.
contract KskdExit {
    using SafeERC20 for IKskdBurnable;

    IKskdBurnable public immutable KSKD;

    /// @notice Only address allowed to call `close`.
    address public immutable CLOSER;

    /// @notice Cumulative KSKD burned for `recipient`. Only grows.
    mapping(address recipient => uint256) public burned;

    /// @notice Sum of all burns; one call for monitoring instead of a log scan.
    uint256 public totalBurned;

    /// @notice Set once by `close`; `exit` reverts from then on.
    bool public closed;

    /// @notice Per-call burn floor. A free relayer pays the claim gas, so dust must
    ///         not enter the ledger at all.
    uint256 public minBurn;

    event Exited(address indexed sender, address indexed recipient, uint256 amount, uint256 cumulative);
    event Closed();
    event MinBurnSet(uint256 minBurn);

    error ZeroAddress();
    error ZeroAmount();
    error InvalidRecipient(address recipient);
    error ExitClosed();
    error NotCloser();
    error BelowMinBurn(uint256 amount, uint256 minBurn);

    constructor(address kskd, address closer, uint256 minBurn_) {
        if (kskd == address(0) || closer == address(0)) revert ZeroAddress();
        KSKD = IKskdBurnable(kskd);
        CLOSER = closer;
        minBurn = minBurn_;
        emit MinBurnSet(minBurn_);
    }

    /// @notice Burn `amount` KSKD from the caller and credit `recipient` on Robinhood.
    ///         `recipient` is not verified: KSKD credited to an address nobody controls
    ///         on Robinhood is lost.
    function exit(uint256 amount, address recipient) external {
        _exit(amount, recipient);
    }

    /// @notice `exit` with an EIP-2612 permit for exactly `amount` in the same transaction.
    ///         The permit is best-effort: a front-run permit is harmless while the allowance stands.
    function exitWithPermit(uint256 amount, address recipient, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        try KSKD.permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        _exit(amount, recipient);
    }

    function _exit(uint256 amount, address recipient) internal {
        if (closed) revert ExitClosed();
        if (amount == 0) revert ZeroAmount();
        if (amount < minBurn) revert BelowMinBurn(amount, minBurn);
        if (recipient == address(0) || recipient == address(this) || recipient == address(KSKD)) {
            revert InvalidRecipient(recipient);
        }

        uint256 cumulative = burned[recipient] + amount;
        burned[recipient] = cumulative;
        totalBurned += amount;

        KSKD.safeTransferFrom(msg.sender, address(this), amount);
        KSKD.burn(amount);

        emit Exited(msg.sender, recipient, amount, cumulative);
    }

    /// @notice Retune the dust floor. Cannot reach the ledger, and `CLOSER` already
    ///         holds the strictly larger power of `close`.
    function setMinBurn(uint256 newMinBurn) external {
        if (msg.sender != CLOSER) revert NotCloser();
        minBurn = newMinBurn;
        emit MinBurnSet(newMinBurn);
    }

    /// @notice End the migration on this side. One-way; `burned` stays readable.
    function close() external {
        if (msg.sender != CLOSER) revert NotCloser();
        if (closed) revert ExitClosed();
        closed = true;
        emit Closed();
    }
}
