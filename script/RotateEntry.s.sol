// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {KskdBridged} from "../src/KskdBridged.sol";
import {KskdEntry} from "../src/KskdEntry.sol";

/// @notice Deploy a PCR-bound replacement entry at its baked address.
///         Leaves the existing token's minting bridge unchanged.
///
/// Env:
///   TOKEN         — existing KskdBridged address. Unchanged by rotation.
///   VERIFIER      — new bridge verifier (DeployBridgeVerifier.s.sol) pinning new PCR1/PCR2.
///   EXPECTED_PCR0 — bytes32 PCR0 of the new bridge image.
///   EXPECTED_ENTRY — entry address baked into that image.
///   THRESHOLD     — uint signature quorum for the new entry.
///   MINT_LIMIT    — uint per-window budget for the new entry.
///   OWNER         — owner of the new entry. Must equal the token owner or SetBridge cannot run.
///   PRIVATE_KEY   — uint deployer key (any funded key; ownership is set by constructor).
contract RotateEntry is Script {
    error WrongChain(uint256 chainid);
    error TokenHasNoCode(address token);
    error VerifierHasNoCode(address verifier);
    error NotAKskdToken(address token);
    error OwnerNotTokenOwner(address entryOwner, address tokenOwner);
    error TokenMismatch(address expected, address actual);
    error VerifierMismatch(address expected, address actual);
    error ThresholdMismatch(uint256 expected, uint256 actual);
    error MintLimitMismatch(uint256 expected, uint256 actual);
    error EntryOwnerMismatch(address expected, address actual);
    error EntryPendingOwnerSet(address pendingOwner);
    error SignerCountNotZero(uint256 signerCount);
    error GuardianPreset(address guardian);
    error EntryAddressMismatch(address actual, address expected);

    function run() external {
        if (block.chainid != 4663 && block.chainid != 46630) revert WrongChain(block.chainid);

        address tokenAddr = vm.envAddress("TOKEN");
        address verifier = vm.envAddress("VERIFIER");
        bytes32 pcr0 = vm.envBytes32("EXPECTED_PCR0");
        uint256 threshold_ = vm.envUint("THRESHOLD");
        uint256 mintLimit = vm.envUint("MINT_LIMIT");
        address owner_ = vm.envAddress("OWNER");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address expectedEntry = vm.envAddress("EXPECTED_ENTRY");
        {
            address deployer = vm.addr(pk);
            address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
            if (predicted != expectedEntry) revert EntryAddressMismatch(predicted, expectedEntry);
        }

        if (tokenAddr.code.length == 0) revert TokenHasNoCode(tokenAddr);
        if (verifier.code.length == 0) revert VerifierHasNoCode(verifier);

        KskdBridged token = KskdBridged(tokenAddr);
        // Confirm the target is the KSKD token (bridgedIn getter + owner) before rotating.
        if (keccak256(bytes(token.symbol())) != keccak256(bytes("KSKD"))) revert NotAKskdToken(tokenAddr);
        // The new entry's owner must own the token, or the SetBridge flip is unreachable.
        if (owner_ != token.owner()) revert OwnerNotTokenOwner(owner_, token.owner());

        vm.startBroadcast(pk);
        KskdEntry entry = new KskdEntry(tokenAddr, verifier, pcr0, threshold_, mintLimit, owner_);
        vm.stopBroadcast();

        require(address(entry) == expectedEntry, EntryAddressMismatch(address(entry), expectedEntry));
        require(address(entry.TOKEN()) == tokenAddr, TokenMismatch(tokenAddr, address(entry.TOKEN())));
        require(address(entry.VERIFIER()) == verifier, VerifierMismatch(verifier, address(entry.VERIFIER())));
        require(entry.expectedPcr0() == pcr0, KskdEntry.PCR0Mismatch(entry.expectedPcr0(), pcr0));
        require(entry.threshold() == threshold_, ThresholdMismatch(threshold_, entry.threshold()));
        require(entry.mintLimit() == mintLimit, MintLimitMismatch(mintLimit, entry.mintLimit()));
        require(entry.owner() == owner_, EntryOwnerMismatch(owner_, entry.owner()));
        require(entry.pendingOwner() == address(0), EntryPendingOwnerSet(entry.pendingOwner()));
        require(entry.signerCount() == 0, SignerCountNotZero(entry.signerCount()));
        require(entry.guardian() == address(0), GuardianPreset(entry.guardian()));

        console.log("new KskdEntry:", address(entry));
        console.log("token        :", tokenAddr);
        console.log("verifier     :", verifier);
        console.log("owner        :", owner_);
        console.log("next: RegisterEnclave (ENTRY=this) -> SetGuardian -> SetBridge (NEW_BRIDGE=this)");
    }
}
