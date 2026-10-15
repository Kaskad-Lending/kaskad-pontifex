// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IAttestationVerifier} from "./interfaces/IAttestationVerifier.sol";
import {KskdBridged} from "./KskdBridged.sol";

/// @title KskdEntry
/// @notice Robinhood side of the KSKD migration bridge. Enclave signers are
///         admitted through Nitro attestation of one pinned image plus owner
///         approval; a claim carrying `threshold` signatures over (recipient,
///         cumulative burn on Igra, deadline) mints the unclaimed difference,
///         partially when the window budget runs short. Image rotation =
///         `setExpectedPcr0` + `registerEnclave`; a verifier change needs a new
///         entry + `KskdBridged.setBridge`.
contract KskdEntry is Ownable2Step, EIP712 {
    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(address recipient,uint256 cumulativeBurned,uint256 deadline)");

    /// @notice Fixed mint-limit window. Up to 2 × `mintLimit` can mint across one boundary.
    uint256 public constant WINDOW = 1 days;

    KskdBridged public immutable TOKEN;

    /// @notice Verifier pinning PCR1/PCR2 of the accepted enclave image.
    IAttestationVerifier public immutable VERIFIER;

    /// @notice PCR0 of the accepted enclave image. Owner-settable for image rotation.
    bytes32 public expectedPcr0;

    /// @notice Enclave signing addresses. Every member entered through `registerEnclave`.
    mapping(address signer => bool) public validSigner;
    uint256 public signerCount;

    /// @notice Distinct valid signatures a claim must carry.
    uint256 public threshold;

    /// @notice May zero `mintLimit` without the owner. Zero disables the role.
    address public guardian;

    /// @notice Max KSKD minted per `WINDOW`. Zero disables claims.
    uint256 public mintLimit;
    uint256 public windowStart;
    uint256 public windowMinted;

    event EnclaveRegistered(address indexed signer);
    event SignerRemoved(address indexed signer);
    event ThresholdSet(uint256 threshold);
    event ExpectedPcr0Set(bytes32 pcr0);
    event GuardianSet(address indexed guardian);
    event MintLimitSet(uint256 mintLimit);
    /// @notice `cumulative` is `bridgedIn` after the mint, `attested` the signed
    ///         `cumulativeBurned`; `cumulative < attested` marks a partial fill.
    event Claimed(address indexed recipient, uint256 minted, uint256 cumulative, uint256 attested);

    error ZeroAddress();
    error ZeroPCR0();
    error ZeroThreshold();
    error InvalidAttestation();
    error PCR0Mismatch(bytes32 provided, bytes32 expected);
    error SignerAlreadyRegistered(address signer);
    error SignerNotRegistered(address signer);
    error ThresholdAboveSignerCount(uint256 threshold, uint256 signerCount);
    error NotGuardian();
    error ClaimExpired(uint256 deadline);
    error InsufficientSignatures(uint256 provided, uint256 required);
    error UnsortedSigners();
    error InvalidSigner(address signer);
    error MintLimitExhausted();
    error RenounceDisabled();

    constructor(
        address token,
        address verifier,
        bytes32 pcr0,
        uint256 threshold_,
        uint256 mintLimit_,
        address initialOwner
    ) EIP712("Pontifex", "1") Ownable(initialOwner) {
        if (token == address(0) || verifier == address(0)) revert ZeroAddress();
        if (pcr0 == bytes32(0)) revert ZeroPCR0();
        if (threshold_ == 0) revert ZeroThreshold();
        TOKEN = KskdBridged(token);
        VERIFIER = IAttestationVerifier(verifier);
        expectedPcr0 = pcr0;
        threshold = threshold_;
        mintLimit = mintLimit_;
        emit ExpectedPcr0Set(pcr0);
        emit ThresholdSet(threshold_);
        emit MintLimitSet(mintLimit_);
    }

    // ─── Signer registry ─────────────────────────────────────────────────

    /// @notice Admit the signer proven by a Nitro attestation of the pinned image.
    ///         The production verifier reverts on a malformed or mismatched document.
    function registerEnclave(bytes calldata attestationDoc) external onlyOwner {
        (bool valid, bytes32 pcr0, address signer) = VERIFIER.verifyAttestation(attestationDoc);
        if (!valid) revert InvalidAttestation();
        bytes32 expected = expectedPcr0;
        if (pcr0 != expected) revert PCR0Mismatch(pcr0, expected);
        if (signer == address(0)) revert ZeroAddress();
        if (validSigner[signer]) revert SignerAlreadyRegistered(signer);

        validSigner[signer] = true;
        signerCount += 1;
        emit EnclaveRegistered(signer);
    }

    /// @notice Revoke a signer. May leave `signerCount < threshold`; claims then fail
    ///         until a signer is re-admitted or the threshold lowered.
    function removeSigner(address signer) external onlyOwner {
        if (!validSigner[signer]) revert SignerNotRegistered(signer);
        delete validSigner[signer];
        signerCount -= 1;
        emit SignerRemoved(signer);
    }

    /// @notice Accept a new enclave image. Signers admitted under the previous PCR0
    ///         stay valid until removed, so a rotation can overlap.
    function setExpectedPcr0(bytes32 pcr0) external onlyOwner {
        if (pcr0 == bytes32(0)) revert ZeroPCR0();
        expectedPcr0 = pcr0;
        emit ExpectedPcr0Set(pcr0);
    }

    /// @notice Set the signature quorum, bounded by the current signer count.
    function setThreshold(uint256 newThreshold) external onlyOwner {
        if (newThreshold == 0) revert ZeroThreshold();
        if (newThreshold > signerCount) revert ThresholdAboveSignerCount(newThreshold, signerCount);
        threshold = newThreshold;
        emit ThresholdSet(newThreshold);
    }

    /// @notice Disabled: an ownerless entry could never restore `mintLimit` after a
    ///         guardian pause or rotate signers.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ─── Mint limit ──────────────────────────────────────────────────────

    /// @notice Set the per-window budget. Zero stops claims; lowering below the
    ///         amount already minted stops them until the window rolls.
    function setMintLimit(uint256 newLimit) external onlyOwner {
        mintLimit = newLimit;
        emit MintLimitSet(newLimit);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        guardian = newGuardian;
        emit GuardianSet(newGuardian);
    }

    /// @notice Emergency stop: zero the budget. Only the owner can restore it.
    function pause() external {
        if (msg.sender != guardian) revert NotGuardian();
        mintLimit = 0;
        emit MintLimitSet(0);
    }

    // ─── Claims ──────────────────────────────────────────────────────────

    /// @notice Mint up to `cumulativeBurned − bridgedIn[recipient]` to `recipient`, less
    ///         when the window budget runs short; the signatures stay valid for the rest.
    ///         Permissionless; `signatures` sorted by ascending signer address.
    function claim(address recipient, uint256 cumulativeBurned, uint256 deadline, bytes[] calldata signatures)
        external
    {
        if (block.timestamp > deadline) revert ClaimExpired(deadline);
        if (signatures.length < threshold) revert InsufficientSignatures(signatures.length, threshold);

        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CLAIM_TYPEHASH, recipient, cumulativeBurned, deadline)));
        address last;
        for (uint256 i = 0; i < signatures.length; i++) {
            address signer = ECDSA.recoverCalldata(digest, signatures[i]);
            if (signer <= last) revert UnsortedSigners();
            if (!validSigner[signer]) revert InvalidSigner(signer);
            last = signer;
        }

        uint256 prior = TOKEN.bridgedIn(recipient);
        if (cumulativeBurned <= prior) revert KskdBridged.NothingToMint(cumulativeBurned, prior);
        uint256 minted = _reserve(cumulativeBurned - prior);
        uint256 cumulative = prior + minted;

        TOKEN.bridgeMint(recipient, cumulative);
        emit Claimed(recipient, minted, cumulative, cumulativeBurned);
    }

    // ─── Internals ───────────────────────────────────────────────────────

    /// @dev Roll the window when due, then take up to `requested` of the remaining budget.
    function _reserve(uint256 requested) internal returns (uint256 granted) {
        uint256 used = windowMinted;
        if (block.timestamp >= windowStart + WINDOW) {
            windowStart = block.timestamp;
            used = 0;
        }
        uint256 limit = mintLimit;
        if (used >= limit) revert MintLimitExhausted();
        uint256 room = limit - used;
        granted = requested < room ? requested : room;
        windowMinted = used + granted;
    }
}
