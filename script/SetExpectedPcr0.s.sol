// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console} from "forge-std/Script.sol";
import {KskdEntry} from "../src/KskdEntry.sol";
import {SafeCall, SafeScript, SafeTx} from "./SafeScript.sol";

/// @notice Sets KskdEntry.expectedPcr0; RegisterEnclave.s.sol then admits the new image's
///         signer. On a V2 verifier (pins no PCR) this covers every image change; a V1 verifier
///         pins PCR1/PCR2, so a change there needs RotateEntry + SetBridge instead.
///
/// Env:
///   ENTRY         — KskdEntry address.
///   EXPECTED_PCR0 — bytes32 new image PCR0. Non-zero (KskdEntry rejects zero).
///   PRIVATE_KEY   — uint entry-owner key; EOA owner only. A Safe owner (has code) gets the
///                   Safe transaction printed and nothing broadcast.
///   SAFE_NONCE    — optional uint, Safe owner only; defaults to the Safe's nonce().
contract SetExpectedPcr0 is SafeScript {
    error WrongChain(uint256 chainid);
    error ZeroPcr0();
    error NotOwner(address broadcaster, address owner);
    error Pcr0NotSet(bytes32 expected, bytes32 actual);

    function run() external {
        if (block.chainid != 4663 && block.chainid != 46630) revert WrongChain(block.chainid);

        KskdEntry entry = KskdEntry(vm.envAddress("ENTRY"));
        bytes32 pcr0 = vm.envBytes32("EXPECTED_PCR0");

        if (pcr0 == bytes32(0)) revert ZeroPcr0();
        address owner_ = entry.owner();
        if (owner_.code.length != 0) {
            safeMode(entry, pcr0, safeNonce(owner_));
            return;
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(pk);
        if (broadcaster != owner_) revert NotOwner(broadcaster, owner_);

        vm.startBroadcast(pk);
        entry.setExpectedPcr0(pcr0);
        vm.stopBroadcast();

        require(entry.expectedPcr0() == pcr0, Pcr0NotSet(pcr0, entry.expectedPcr0()));

        console.log("KskdEntry   :", address(entry));
        console.log("expectedPcr0:", vm.toString(pcr0));
        console.log("next: RegisterEnclave (ENTRY=this) to admit the new signer");
    }

    /// @notice Safe-owned entry: dry-runs `setExpectedPcr0` from the Safe and prints the Safe tx.
    function safeMode(KskdEntry entry, bytes32 pcr0, uint256 nonce_) public returns (SafeTx memory t) {
        if (pcr0 == bytes32(0)) revert ZeroPcr0();
        SafeCall[] memory calls = new SafeCall[](1);
        calls[0] = SafeCall({to: address(entry), data: abi.encodeCall(KskdEntry.setExpectedPcr0, (pcr0))});
        t = prepare(entry.owner(), calls, nonce_);
        require(entry.expectedPcr0() == pcr0, Pcr0NotSet(pcr0, entry.expectedPcr0()));

        console.log("KskdEntry   :", address(entry));
        console.log("expectedPcr0:", vm.toString(pcr0));
        printSafeTx(t, calls);
        console.log("next: execute this Safe tx, then RegisterEnclave (ENTRY=this) for the new signer");
    }
}
