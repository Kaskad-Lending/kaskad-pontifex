// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IAttestationVerifier} from "../../src/interfaces/IAttestationVerifier.sol";

/// @notice CertManager double: caches every certificate it verifies, or refuses all of them.
contract CertManagerDouble {
    bytes32 public constant ROOT_CA_CERT_HASH = keccak256("aws-nitro-root");

    bool private immutable REFUSE;
    mapping(bytes32 => bytes) private pubKeys;
    uint256 public verified;

    error CertWarmed(bytes32 certHash);

    constructor(bool refuse) {
        REFUSE = refuse;
    }

    function verifyCert(bytes calldata certificate, bytes32) external {
        if (REFUSE) revert CertWarmed(keccak256(certificate));
        pubKeys[keccak256(certificate)] = hex"04";
        verified++;
    }

    function certPubKey(bytes32 certHash) external view returns (bytes memory) {
        return pubKeys[certHash];
    }
}

/// @notice NitroProver double: only the CertManager handle.
contract NitroProverDouble {
    address private immutable CERT_MANAGER;

    constructor(address certManager_) {
        CERT_MANAGER = certManager_;
    }

    function certManager() external view returns (address) {
        return CERT_MANAGER;
    }
}

/// @notice V2-shaped verifier (pins no PCR): `nitroProver()` and one fixed attestation answer.
contract NitroVerifierV2Double is IAttestationVerifier {
    address private immutable PROVER;
    bytes32 private immutable PCR0;
    address private immutable SIGNER;

    constructor(address prover, bytes32 pcr0, address signer) {
        PROVER = prover;
        PCR0 = pcr0;
        SIGNER = signer;
    }

    function nitroProver() external view returns (address) {
        return PROVER;
    }

    function verifyAttestation(bytes calldata) external view returns (bool, bytes32, address) {
        return (true, PCR0, SIGNER);
    }
}

/// @notice V1-shaped verifier: the V2 surface plus the pinned PCR1/PCR2 getters.
contract NitroVerifierV1Double is NitroVerifierV2Double {
    constructor(address prover) NitroVerifierV2Double(prover, bytes32(uint256(1)), address(1)) {}

    // forge-lint: disable-next-line(mixed-case-function)
    function expectedPCR1() external pure returns (bytes32) {
        return bytes32(uint256(0x11));
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function expectedPCR2() external pure returns (bytes32) {
        return bytes32(uint256(0x22));
    }
}
