// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IAttestationVerifier} from "../../src/interfaces/IAttestationVerifier.sol";

/// @notice Production NitroAttestationVerifier on Igra. `verifyAttestation` is view; `verifyCerts`
///         writes the certificate chain into the CertManager cache and must land first on a cold chain.
interface INitroAttestationVerifier is IAttestationVerifier {
    function verifyCerts(bytes calldata attestationDoc) external;
    function nitroProver() external view returns (INitroProver);
}

/// @notice Marlin NitroProver. Only the CertManager handle is used (fork tests and RegisterEnclave).
interface INitroProver {
    function certManager() external view returns (ICertManager);
}

/// @notice Marlin CertManager. Verification cache is keyed by `keccak256(certificate)`.
interface ICertManager {
    function verifyCert(bytes calldata certificate, bytes32 parentCertHash) external;
    function certPubKey(bytes32 certHash) external view returns (bytes memory);
    function ROOT_CA_CERT_HASH() external view returns (bytes32);
}
