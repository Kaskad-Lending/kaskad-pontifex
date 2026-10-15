// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console} from "forge-std/Script.sol";
import {KskdEntry} from "../src/KskdEntry.sol";
import {INitroAttestationVerifier, INitroProver, ICertManager} from "../test/interfaces/INitroAttestationVerifier.sol";
import {NitroDoc} from "./NitroDoc.sol";
import {SafeCall, SafeScript} from "./SafeScript.sol";

/// @notice Warms an attestation's cert chain on CertManager one cert at a time, then
///         either calls KskdEntry.registerEnclave directly (owner-owned EOA) or prints
///         the Safe calldata for it. Never calls verifyCerts — Robinhood's 32M per-tx
///         gas cap cannot fit that bundled call; per-cert verifyCert does.
contract RegisterEnclave is SafeScript {
    error InvalidAttestation();
    error SignerAlreadyRegistered(address signer);
    error NotOwner(address sender, address owner);
    error WrongChain(uint256 chainid);
    error NoGuardian(address entry);

    /// @notice Refuses to arm the token's live bridge without a guardian: once a signer is
    ///         registered there, claims mint and nothing could pause them.
    function armingPreflight(KskdEntry entry) public view {
        if (entry.guardian() == address(0) && entry.TOKEN().bridge() == address(entry)) {
            revert NoGuardian(address(entry));
        }
    }

    /// @notice Refuses a document of another image before any certificate is warmed. PCR0 is
    ///         read from the unverified document; `_checkAttestation` re-checks it via the verifier.
    function imagePreflight(KskdEntry entry, bytes memory doc) public view {
        bytes32 pcr0 = NitroDoc.pcr0(doc);
        if (pcr0 != entry.expectedPcr0()) revert KskdEntry.PCR0Mismatch(pcr0, entry.expectedPcr0());
    }

    function run() external {
        if (block.chainid != 4663 && block.chainid != 46630) revert WrongChain(block.chainid);

        register(
            KskdEntry(vm.envAddress("ENTRY")),
            vm.envBytes("ATTESTATION_DOC"),
            vm.envBytes("CERT_CHAIN", ","),
            vm.envOr("DIRECT_REGISTER", false),
            vm.envUint("PRIVATE_KEY")
        );
    }

    function register(KskdEntry entry, bytes memory doc, bytes[] memory certChain, bool directRegister, uint256 pk)
        public
    {
        armingPreflight(entry);
        imagePreflight(entry, doc);
        _warmCerts(entry, certChain, pk);
        address signer = _checkAttestation(entry, doc);

        if (directRegister) {
            _directRegister(entry, doc, pk, signer);
        } else {
            _printSafeTx(entry, doc);
        }
    }

    /// @dev Walk CERT_CHAIN (CA bundle without the root, then the leaf) skipping
    ///      whatever CertManager already has cached, parent hash chained from ROOT_CA_CERT_HASH.
    function _warmCerts(KskdEntry entry, bytes[] memory certChain, uint256 pk) internal {
        INitroProver prover = INitroAttestationVerifier(address(entry.VERIFIER())).nitroProver();
        ICertManager certManager = prover.certManager();

        bytes32 parentHash = certManager.ROOT_CA_CERT_HASH();
        for (uint256 i = 0; i < certChain.length; i++) {
            bytes32 certHash = keccak256(certChain[i]);
            if (certManager.certPubKey(certHash).length == 0) {
                uint256 gasBefore = gasleft();
                vm.startBroadcast(pk);
                certManager.verifyCert(certChain[i], parentHash);
                vm.stopBroadcast();
                console.log("verifyCert gas used, cert #", i, gasBefore - gasleft());
            } else {
                console.log("verifyCert already cached, skipped cert #", i);
            }
            parentHash = certHash;
        }
    }

    /// @dev Static call (verifyAttestation is `view`): valid, matches expectedPcr0,
    ///      and the recovered signer is not already registered.
    function _checkAttestation(KskdEntry entry, bytes memory doc) internal view returns (address signer) {
        bool valid;
        bytes32 pcr0;
        (valid, pcr0, signer) = entry.VERIFIER().verifyAttestation(doc);
        if (!valid) revert InvalidAttestation();
        if (pcr0 != entry.expectedPcr0()) revert KskdEntry.PCR0Mismatch(pcr0, entry.expectedPcr0());
        if (entry.validSigner(signer)) revert SignerAlreadyRegistered(signer);
        console.log("verifyAttestation OK, signer:", signer);
    }

    /// @dev Only reachable when the broadcasting key is already `entry.owner()`.
    function _directRegister(KskdEntry entry, bytes memory doc, uint256 pk, address signer) internal {
        address sender = vm.addr(pk);
        address owner_ = entry.owner();
        if (sender != owner_) revert NotOwner(sender, owner_);

        uint256 gasBefore = gasleft();
        vm.startBroadcast(pk);
        entry.registerEnclave(doc);
        vm.stopBroadcast();
        console.log("registerEnclave gas used:", gasBefore - gasleft());
        console.log("Signer registered:", signer);
    }

    /// @dev No broadcast. A Safe owner gets the full Safe tx (dry-run, nonce, safeTxHash);
    ///      any other owner the bare calldata.
    function _printSafeTx(KskdEntry entry, bytes memory doc) internal {
        bytes memory data = abi.encodeCall(KskdEntry.registerEnclave, (doc));
        address owner_ = entry.owner();
        if (owner_.code.length != 0) {
            SafeCall[] memory calls = new SafeCall[](1);
            calls[0] = SafeCall({to: address(entry), data: data});
            printSafeTx(prepare(owner_, calls, safeNonce(owner_)), calls);
            return;
        }
        console.log("Safe tx to   :", address(entry));
        console.log("Safe tx value: 0");
        console.log("Safe tx data :", vm.toString(data));
    }
}
