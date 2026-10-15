// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @notice Verifier that writes storage and does not inherit `IAttestationVerifier`, so solc lets it
///         be non-view. `KskdEntry` calls it through the `view` interface, i.e. under STATICCALL.
contract StateWritingVerifier {
    uint256 public calls;

    bytes32 internal immutable PCR0;
    address internal immutable SIGNER;

    constructor(bytes32 pcr0, address signer) {
        PCR0 = pcr0;
        SIGNER = signer;
    }

    function verifyAttestation(bytes calldata) external returns (bool, bytes32, address) {
        calls += 1;
        return (true, PCR0, SIGNER);
    }
}

/// @notice Verifier that reenters the entry and reverts `ReentrancyBlocked` when the reentrant frame
///         fails, which it must: SSTORE and LOG are forbidden under STATICCALL.
contract ReentrantVerifier {
    error ReentrancyBlocked();

    bytes32 internal immutable PCR0;
    address internal immutable SIGNER;
    address public entry;

    constructor(bytes32 pcr0, address signer) {
        PCR0 = pcr0;
        SIGNER = signer;
    }

    function setEntry(address entry_) external {
        entry = entry_;
    }

    function verifyAttestation(bytes calldata) external returns (bool, bytes32, address) {
        (bool ok,) = entry.call(
            abi.encodeWithSignature("claim(address,uint256,uint256,bytes[])", address(1), 1, 1, new bytes[](0))
        );
        if (!ok) revert ReentrancyBlocked();
        return (true, PCR0, SIGNER);
    }
}
