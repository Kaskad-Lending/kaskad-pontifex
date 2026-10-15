// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {KskdEntry} from "../src/KskdEntry.sol";
import {KskdExit} from "../src/KskdExit.sol";
import {SafeCall, SafeScript, SafeTx} from "./SafeScript.sol";

/// @notice Prepares the Safe-only bridge calls that have no dedicated script. Broadcasts
///         nothing: each entry point resolves the Safe that owns the call, dry-runs it from that
///         Safe and prints the Safe transaction with its safeTxHash. Pick one with `--sig`.
///
/// Env: SAFE_NONCE — optional uint; defaults to the Safe's nonce(). REQUIRE_SAFE — optional
///      bool, default true on 4663: `transferOwnership` refuses a new owner that is not a Safe.
contract SafeOps is SafeScript {
    error WrongChain(uint256 chainid);
    error ZeroAddress();
    error NoPendingOwner(address target);
    error LengthMismatch(uint256 targets, uint256 datas);

    // ─── Robinhood: KskdEntry, owner = Robinhood Safe ─────────────────────

    function setMintLimit(KskdEntry entry, uint256 newLimit) external returns (SafeTx memory) {
        _onlyRobinhood();
        return proposeCall(entry.owner(), address(entry), abi.encodeCall(KskdEntry.setMintLimit, (newLimit)));
    }

    function setThreshold(KskdEntry entry, uint256 newThreshold) external returns (SafeTx memory) {
        _onlyRobinhood();
        return proposeCall(entry.owner(), address(entry), abi.encodeCall(KskdEntry.setThreshold, (newThreshold)));
    }

    /// @notice Warns when the removal leaves fewer signers than `threshold` (claims stop).
    function removeSigner(KskdEntry entry, address signer) external returns (SafeTx memory t) {
        _onlyRobinhood();
        t = proposeCall(entry.owner(), address(entry), abi.encodeCall(KskdEntry.removeSigner, (signer)));
        if (entry.signerCount() < entry.threshold()) {
            console.log("WARN: signerCount < threshold after removal; claims fail until re-registration");
        }
    }

    // ─── Robinhood: any Ownable2Step (KskdEntry or KskdBridged) ──────────

    /// @notice Starts the two-step handover; the new owner then runs `acceptOwnership`.
    function transferOwnership(Ownable2Step target, address newOwner) external returns (SafeTx memory t) {
        _onlyRobinhood();
        if (newOwner == address(0)) revert ZeroAddress();
        if (requireSafeByDefault()) requireSafe(newOwner);
        t = proposeCall(target.owner(), address(target), abi.encodeCall(Ownable2Step.transferOwnership, (newOwner)));
        console.log("next: acceptOwnership(target) from", newOwner);
    }

    /// @notice Prepared for the pending owner, not the current one.
    function acceptOwnership(Ownable2Step target) external returns (SafeTx memory) {
        _onlyRobinhood();
        address pending = target.pendingOwner();
        if (pending == address(0)) revert NoPendingOwner(address(target));
        return proposeCall(pending, address(target), abi.encodeCall(Ownable2Step.acceptOwnership, ()));
    }

    // ─── Igra: KskdExit, CLOSER = Igra Safe ──────────────────────────────

    function setMinBurn(KskdExit exit, uint256 newMinBurn) external returns (SafeTx memory) {
        _onlyIgra();
        return proposeCall(exit.CLOSER(), address(exit), abi.encodeCall(KskdExit.setMinBurn, (newMinBurn)));
    }

    /// @notice One-way: no exit is accepted afterwards.
    function close(KskdExit exit) external returns (SafeTx memory) {
        _onlyIgra();
        return proposeCall(exit.CLOSER(), address(exit), abi.encodeCall(KskdExit.close, ()));
    }

    /// @notice Treasury tranche from `safe`: `approve(exit, amount)` + `exit(amount, recipient)` in one
    ///         MultiSendCallOnly batch (a Safe cannot sign the permit). When `safe` is CLOSER and `amount`
    ///         is below `minBurn`, the batch lowers the floor to `amount` first and restores it last.
    ///         `recipient` is a Robinhood address and cannot be checked from Igra.
    function treasuryExit(address safe, KskdExit exit, uint256 amount, address recipient)
        external
        returns (SafeTx memory)
    {
        _onlyIgra();
        uint256 minBurn = exit.minBurn();
        bool lift = amount < minBurn && safe == exit.CLOSER();
        SafeCall[] memory calls = new SafeCall[](lift ? 4 : 2);
        uint256 n = 0;
        if (lift) calls[n++] = SafeCall({to: address(exit), data: abi.encodeCall(KskdExit.setMinBurn, (amount))});
        calls[n++] = SafeCall({to: address(exit.KSKD()), data: abi.encodeCall(IERC20.approve, (address(exit), amount))});
        calls[n++] = SafeCall({to: address(exit), data: abi.encodeCall(KskdExit.exit, (amount, recipient))});
        if (lift) calls[n] = SafeCall({to: address(exit), data: abi.encodeCall(KskdExit.setMinBurn, (minBurn))});

        console.log("recipient on Robinhood:", recipient);
        if (lift) console.log("minBurn lowered to the tranche for this tx only, restored to:", minBurn);
        return propose(safe, calls);
    }

    // ─── Any chain with a pinned MultiSendCallOnly ────────────────────────

    /// @notice `targets[i]` gets `datas[i]`, in order; one pair is a plain Call.
    function batch(address safe, address[] calldata targets, bytes[] calldata datas) external returns (SafeTx memory) {
        if (targets.length != datas.length) revert LengthMismatch(targets.length, datas.length);
        SafeCall[] memory calls = new SafeCall[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            calls[i] = SafeCall({to: targets[i], data: datas[i]});
        }
        return propose(safe, calls);
    }

    function _onlyRobinhood() internal view {
        if (block.chainid != 4663 && block.chainid != 46630) revert WrongChain(block.chainid);
    }

    function _onlyIgra() internal view {
        if (block.chainid != 38833 && block.chainid != 38836) revert WrongChain(block.chainid);
    }
}
