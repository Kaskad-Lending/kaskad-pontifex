// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {IAttestationVerifier} from "../../src/interfaces/IAttestationVerifier.sol";

/// @notice Test double for NitroAttestationVerifier.
///         "Attestation document" = abi.encode(bool valid, bytes32 pcr0, address signer).
contract StubAttestationVerifier is IAttestationVerifier {
    function verifyAttestation(bytes calldata attestationDoc)
        external
        pure
        returns (bool valid, bytes32 pcr0, address enclaveAddress)
    {
        return abi.decode(attestationDoc, (bool, bytes32, address));
    }

    function encode(bool valid, bytes32 pcr0, address signer) external pure returns (bytes memory) {
        return abi.encode(valid, pcr0, signer);
    }
}
