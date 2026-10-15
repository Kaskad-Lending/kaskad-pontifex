// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console} from "forge-std/Script.sol";
import {KskdBridged} from "../src/KskdBridged.sol";
import {KskdEntry} from "../src/KskdEntry.sol";
import {INitroAttestationVerifier, INitroProver} from "../test/interfaces/INitroAttestationVerifier.sol";
import {SafeScript} from "./SafeScript.sol";

/// @notice Getters only the V1 NitroAttestationVerifier has: it pins PCR1/PCR2, V2 pins none.
interface INitroAttestationVerifierV1 {
    // forge-lint: disable-next-line(mixed-case-function)
    function expectedPCR1() external view returns (bytes32);
    // forge-lint: disable-next-line(mixed-case-function)
    function expectedPCR2() external view returns (bytes32);
}

/// @notice Deploys KskdBridged + KskdEntry on Robinhood (mainnet 4663 / testnet 46630).
///         OWNER owns both from block 0 — no Ownable2Step handover to run here. On 4663 OWNER
///         must be a Safe with threshold >= 2 (REQUIRE_SAFE) and VERIFIER a V2 verifier
///         (REQUIRE_V2_VERIFIER); either env switch set to false turns its check off.
contract DeployRobinhood is SafeScript {
    error WrongChain(uint256 chainid);
    error VerifierHasNoCode(address verifier);
    error NotANitroVerifier(address verifier);
    error VerifierPinsPcrs(address verifier);
    error EntryPredictionMismatch(address predicted, address expected);
    error PredictedAddressMismatch(address predicted, address actual);
    error BridgeMismatch(address expected, address actual);
    error TokenOwnerMismatch(address expected, address actual);
    error TokenPendingOwnerSet(address pendingOwner);
    error TokenMismatch(address expected, address actual);
    error VerifierMismatch(address expected, address actual);
    error ThresholdMismatch(uint256 expected, uint256 actual);
    error MintLimitMismatch(uint256 expected, uint256 actual);
    error EntryOwnerMismatch(address expected, address actual);
    error EntryPendingOwnerSet(address pendingOwner);
    error SignerCountNotZero(uint256 signerCount);
    error TokenSupplyNotZero(uint256 supply);
    error GuardianPreset(address guardian);

    /// @notice V2 = a Nitro verifier (`nitroProver()` -> `certManager()`, both with code) that
    ///         answers neither of V1's `expectedPCR1()` / `expectedPCR2()`.
    function requireV2Verifier(address verifier) public view {
        if (verifier.code.length == 0) revert VerifierHasNoCode(verifier);
        address prover = _readAddress(verifier, verifier, abi.encodeCall(INitroAttestationVerifier.nitroProver, ()));
        address certManager = _readAddress(verifier, prover, abi.encodeCall(INitroProver.certManager, ()));
        if (certManager.code.length == 0) revert NotANitroVerifier(verifier);
        if (
            _answers(verifier, abi.encodeCall(INitroAttestationVerifierV1.expectedPCR1, ()))
                || _answers(verifier, abi.encodeCall(INitroAttestationVerifierV1.expectedPCR2, ()))
        ) revert VerifierPinsPcrs(verifier);
    }

    function run() external {
        if (block.chainid != 4663 && block.chainid != 46630) revert WrongChain(block.chainid);

        address owner_ = vm.envAddress("OWNER");
        address verifier = vm.envAddress("VERIFIER");
        bytes32 pcr0 = vm.envBytes32("EXPECTED_PCR0");
        uint256 threshold_ = vm.envUint("THRESHOLD");
        uint256 mintLimit = vm.envUint("MINT_LIMIT");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        if (verifier.code.length == 0) revert VerifierHasNoCode(verifier);
        if (vm.envOr("REQUIRE_V2_VERIFIER", block.chainid == 4663)) requireV2Verifier(verifier);
        if (requireSafeByDefault()) requireSafe(owner_);

        address predictedEntry = vm.computeCreateAddress(deployer, uint256(vm.getNonce(deployer)) + 1);
        // Optional pre-commit: fail before gas if the live nonce won't land the entry
        // on a pre-announced address (host config / off-chain records pinned it).
        address expectedEntry = vm.envOr("EXPECTED_ENTRY", address(0));
        if (expectedEntry != address(0) && predictedEntry != expectedEntry) {
            revert EntryPredictionMismatch(predictedEntry, expectedEntry);
        }

        vm.startBroadcast(pk);
        KskdBridged token = new KskdBridged(predictedEntry, owner_);
        KskdEntry entry = new KskdEntry(address(token), verifier, pcr0, threshold_, mintLimit, owner_);
        vm.stopBroadcast();

        require(address(entry) == predictedEntry, PredictedAddressMismatch(predictedEntry, address(entry)));
        require(token.bridge() == address(entry), BridgeMismatch(address(entry), token.bridge()));
        require(token.owner() == owner_, TokenOwnerMismatch(owner_, token.owner()));
        require(token.pendingOwner() == address(0), TokenPendingOwnerSet(token.pendingOwner()));
        require(address(entry.TOKEN()) == address(token), TokenMismatch(address(token), address(entry.TOKEN())));
        require(address(entry.VERIFIER()) == verifier, VerifierMismatch(verifier, address(entry.VERIFIER())));
        require(entry.expectedPcr0() == pcr0, KskdEntry.PCR0Mismatch(entry.expectedPcr0(), pcr0));
        require(entry.threshold() == threshold_, ThresholdMismatch(threshold_, entry.threshold()));
        require(entry.mintLimit() == mintLimit, MintLimitMismatch(mintLimit, entry.mintLimit()));
        require(entry.owner() == owner_, EntryOwnerMismatch(owner_, entry.owner()));
        require(entry.pendingOwner() == address(0), EntryPendingOwnerSet(entry.pendingOwner()));
        require(entry.signerCount() == 0, SignerCountNotZero(entry.signerCount()));
        require(token.totalSupply() == 0, TokenSupplyNotZero(token.totalSupply()));
        require(entry.guardian() == address(0), GuardianPreset(entry.guardian()));

        console.log("KskdBridged (token):", address(token));
        console.log("KskdEntry   (entry):", address(entry));
        console.log("owner              :", owner_);
        console.log("verifier           :", verifier);
    }

    /// @dev The address `target` returns for `call`; codeless, reverting or short means `verifier`
    ///      is not a Nitro verifier.
    function _readAddress(address verifier, address target, bytes memory call) internal view returns (address) {
        if (target.code.length == 0) revert NotANitroVerifier(verifier);
        (bool ok, bytes memory ret) = target.staticcall(call);
        if (!ok || ret.length != 32) revert NotANitroVerifier(verifier);
        return abi.decode(ret, (address));
    }

    function _answers(address target, bytes memory call) internal view returns (bool) {
        (bool ok, bytes memory ret) = target.staticcall(call);
        return ok && ret.length >= 32;
    }
}
