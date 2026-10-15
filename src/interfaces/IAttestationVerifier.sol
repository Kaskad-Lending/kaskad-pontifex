// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @notice Attestation verifier interface shared with KaskadPriceOracle.
///         Production implementation: NitroAttestationVerifier (Marlin NitroProver path).
interface IAttestationVerifier {
    function verifyAttestation(bytes calldata attestationDoc)
        external
        view
        returns (bool valid, bytes32 pcr0, address enclaveAddress);
}
