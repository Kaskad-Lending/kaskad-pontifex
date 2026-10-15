// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console} from "forge-std/Script.sol";
import {KskdBridged} from "../src/KskdBridged.sol";
import {KskdEntry} from "../src/KskdEntry.sol";
import {SafeCall, SafeScript, SafeTx} from "./SafeScript.sol";

/// @notice Points KskdBridged.bridge at a new KskdEntry (verifier-rotation cutover)
///         or at address(0) to freeze minting. setBridge is onlyOwner on the token,
///         so the broadcast key must be the token owner (DIRECT) — otherwise the
///         Safe tx is printed, with nonce and safeTxHash when the owner is a Safe. A
///         non-zero target is checked claim-ready and guarded first: an entry that cannot
///         yet mint would silently halt the bridge, and one without a guardian could not be paused.
///
/// Env:
///   TOKEN       — KskdBridged address.
///   NEW_BRIDGE  — new KskdEntry, or 0x0 to freeze minting.
///   DIRECT      — bool; true broadcasts (EOA owner), false prints Safe calldata. Default false.
///   SAFE_NONCE  — optional uint, Safe owner only; defaults to the Safe's nonce().
///   PRIVATE_KEY — uint; required only for DIRECT (must be the token owner). The Safe/calldata path never reads it.
contract SetBridge is SafeScript {
    error WrongChain(uint256 chainid);
    error TokenHasNoCode(address token);
    error BridgeHasNoCode(address bridge);
    error BridgeTokenMismatch(address bridgeToken, address token);
    error NotClaimReady(uint256 signerCount, uint256 threshold);
    error NoGuardian(address entry);
    error NotOwner(address broadcaster, address owner);
    error BridgeNotSet(address expected, address actual);

    /// @notice Everything checkable before the flip. Split out of `run` so tests can
    ///         pass the two addresses directly instead of through the process env.
    function preflight(address tokenAddr, address newBridge) public view {
        if (tokenAddr.code.length == 0) revert TokenHasNoCode(tokenAddr);

        if (newBridge == address(0)) {
            console.log("FREEZE: setBridge(0) halts minting; only the owner can point it back");
            return;
        }

        if (newBridge.code.length == 0) revert BridgeHasNoCode(newBridge);
        KskdEntry entry = KskdEntry(newBridge);
        if (address(entry.TOKEN()) != tokenAddr) revert BridgeTokenMismatch(address(entry.TOKEN()), tokenAddr);
        // A live cutover needs a claim-ready entry; register signers before flipping.
        if (entry.signerCount() < entry.threshold()) {
            revert NotClaimReady(entry.signerCount(), entry.threshold());
        }
        // Run SetGuardian before the flip, not after it.
        if (entry.guardian() == address(0)) revert NoGuardian(newBridge);
        if (entry.mintLimit() == 0) {
            console.log("WARN: new entry mintLimit == 0 (claims paused until setMintLimit)");
        }
    }

    function run() external {
        if (block.chainid != 4663 && block.chainid != 46630) revert WrongChain(block.chainid);

        address tokenAddr = vm.envAddress("TOKEN");
        address newBridge = vm.envAddress("NEW_BRIDGE");
        bool direct = vm.envOr("DIRECT", false);

        preflight(tokenAddr, newBridge);
        KskdBridged token = KskdBridged(tokenAddr);

        if (direct) {
            uint256 pk = vm.envUint("PRIVATE_KEY");
            address broadcaster = vm.addr(pk);
            address owner_ = token.owner();
            if (broadcaster != owner_) revert NotOwner(broadcaster, owner_);

            vm.startBroadcast(pk);
            token.setBridge(newBridge);
            vm.stopBroadcast();

            require(token.bridge() == newBridge, BridgeNotSet(newBridge, token.bridge()));
            console.log("token.bridge set:", newBridge);
        } else {
            address owner_ = token.owner();
            if (owner_.code.length != 0) {
                safeMode(token, newBridge, safeNonce(owner_));
                return;
            }
            console.log("Safe tx to   :", tokenAddr);
            console.log("Safe tx value: 0");
            console.log("Safe tx data :", vm.toString(abi.encodeCall(KskdBridged.setBridge, (newBridge))));
        }
    }

    /// @notice Safe-owned token: dry-runs `setBridge` from the Safe and prints the Safe tx.
    function safeMode(KskdBridged token, address newBridge, uint256 nonce_) public returns (SafeTx memory t) {
        SafeCall[] memory calls = new SafeCall[](1);
        calls[0] = SafeCall({to: address(token), data: abi.encodeCall(KskdBridged.setBridge, (newBridge))});
        t = prepare(token.owner(), calls, nonce_);
        require(token.bridge() == newBridge, BridgeNotSet(newBridge, token.bridge()));
        printSafeTx(t, calls);
    }
}
