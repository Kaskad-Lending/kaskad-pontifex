// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test, stdError} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {KskdBridged} from "../../src/KskdBridged.sol";
import {KskdEntry} from "../../src/KskdEntry.sol";
import {StubAttestationVerifier} from "../doubles/StubAttestationVerifier.sol";
import {ReentrantVerifier, StateWritingVerifier} from "../doubles/StateWritingVerifier.sol";

/// @notice Robinhood entry: attested signer registry, quorum claims, cumulative mint, window budget.
contract KskdEntryTest is Test {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant SECP256K1N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    bytes32 internal constant CLAIM_TYPEHASH =
        keccak256("Claim(address recipient,uint256 cumulativeBurned,uint256 deadline)");

    bytes32 internal constant PCR0 = keccak256("pontifex-enclave-image");
    bytes32 internal constant OTHER_PCR0 = keccak256("some-other-image");
    uint256 internal constant MINT_LIMIT = 1_000_000 ether;
    uint256 internal constant T0 = 1_700_000_000;

    StubAttestationVerifier internal verifier;
    KskdBridged internal token;
    KskdEntry internal entry;

    address internal owner = makeAddr("owner");
    address internal guard = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    address[3] internal signers;
    uint256[3] internal keys;

    function setUp() public {
        vm.warp(T0);
        verifier = new StubAttestationVerifier();
        _loadSortedSigners();
        (token, entry) = _deploy(1, MINT_LIMIT);
        _register(entry, signers[0]);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _loadSortedSigners() internal {
        (address a, uint256 ka) = makeAddrAndKey("enclaveA");
        (address b, uint256 kb) = makeAddrAndKey("enclaveB");
        (address c, uint256 kc) = makeAddrAndKey("enclaveC");
        signers = [a, b, c];
        keys = [ka, kb, kc];

        for (uint256 i = 1; i < 3; i++) {
            for (uint256 j = i; j > 0 && signers[j] < signers[j - 1]; j--) {
                (signers[j], signers[j - 1]) = (signers[j - 1], signers[j]);
                (keys[j], keys[j - 1]) = (keys[j - 1], keys[j]);
            }
        }
    }

    function _deploy(uint256 threshold_, uint256 limit_) internal returns (KskdBridged t, KskdEntry e) {
        t = new KskdBridged(address(0), owner);
        e = new KskdEntry(address(t), address(verifier), PCR0, threshold_, limit_, owner);
        vm.prank(owner);
        t.setBridge(address(e));
    }

    function _register(KskdEntry e, address signer) internal {
        vm.prank(owner);
        e.registerEnclave(abi.encode(true, PCR0, signer));
    }

    function _digestFor(address entryAddr, uint256 chainId, address recipient, uint256 cumulative, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        bytes32 domain =
            keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("Pontifex"), keccak256("1"), chainId, entryAddr));
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, recipient, cumulative, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _digest(address recipient, uint256 cumulative, uint256 deadline) internal view returns (bytes32) {
        return _digestFor(address(entry), block.chainid, recipient, cumulative, deadline);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sigs(uint256 key, address recipient, uint256 cumulative, uint256 deadline)
        internal
        view
        returns (bytes[] memory out)
    {
        out = new bytes[](1);
        out[0] = _sign(key, _digest(recipient, cumulative, deadline));
    }

    function _sigs2(uint256 keyA, uint256 keyB, address recipient, uint256 cumulative, uint256 deadline)
        internal
        view
        returns (bytes[] memory out)
    {
        bytes32 digest = _digest(recipient, cumulative, deadline);
        out = new bytes[](2);
        out[0] = _sign(keyA, digest);
        out[1] = _sign(keyB, digest);
    }

    function _claim(address recipient, uint256 cumulative) internal {
        uint256 deadline = block.timestamp + 1 hours;
        entry.claim(recipient, cumulative, deadline, _sigs(keys[0], recipient, cumulative, deadline));
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    /// Construction stores token, verifier, PCR0, threshold, limit and owner, and starts empty.
    function test_ConstructorStoresConfiguration() public view {
        assertEq(address(entry.TOKEN()), address(token));
        assertEq(address(entry.VERIFIER()), address(verifier));
        assertEq(entry.expectedPcr0(), PCR0);
        assertEq(entry.threshold(), 1);
        assertEq(entry.mintLimit(), MINT_LIMIT);
        assertEq(entry.owner(), owner);
        assertEq(entry.pendingOwner(), address(0));
        assertEq(entry.guardian(), address(0));
        assertEq(entry.windowStart(), 0);
        assertEq(entry.windowMinted(), 0);
    }

    /// Construction announces the threshold and then the mint limit.
    function test_ConstructorEmitsThresholdThenMintLimit() public {
        KskdBridged fresh = new KskdBridged(address(0), owner);

        vm.expectEmit(false, false, false, true);
        emit KskdEntry.ThresholdSet(3);
        vm.expectEmit(false, false, false, true);
        emit KskdEntry.MintLimitSet(77 ether);
        new KskdEntry(address(fresh), address(verifier), PCR0, 3, 77 ether, owner);
    }

    /// Construction announces the pinned image ahead of the threshold and the limit.
    function test_ConstructorEmitsExpectedPcr0First() public {
        KskdBridged fresh = new KskdBridged(address(0), owner);

        vm.expectEmit(false, false, false, true);
        emit KskdEntry.ExpectedPcr0Set(OTHER_PCR0);
        vm.expectEmit(false, false, false, true);
        emit KskdEntry.ThresholdSet(1);
        new KskdEntry(address(fresh), address(verifier), OTHER_PCR0, 1, MINT_LIMIT, owner);
    }

    /// A zero token address is refused.
    function test_ConstructorRevertsOnZeroToken() public {
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ZeroAddress.selector));
        new KskdEntry(address(0), address(verifier), PCR0, 1, MINT_LIMIT, owner);
    }

    /// A zero verifier address is refused.
    function test_ConstructorRevertsOnZeroVerifier() public {
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ZeroAddress.selector));
        new KskdEntry(address(token), address(0), PCR0, 1, MINT_LIMIT, owner);
    }

    /// An unset PCR0 is refused.
    function test_ConstructorRevertsOnZeroPcr0() public {
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ZeroPCR0.selector));
        new KskdEntry(address(token), address(verifier), bytes32(0), 1, MINT_LIMIT, owner);
    }

    /// A zero threshold is refused.
    function test_ConstructorRevertsOnZeroThreshold() public {
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ZeroThreshold.selector));
        new KskdEntry(address(token), address(verifier), PCR0, 0, MINT_LIMIT, owner);
    }

    /// A zero initial owner is refused by Ownable.
    function test_ConstructorRevertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new KskdEntry(address(token), address(verifier), PCR0, 1, MINT_LIMIT, address(0));
    }

    /// A zero mint limit is a valid deployment that admits no claims.
    function test_ConstructorAcceptsZeroMintLimit() public {
        (, KskdEntry e) = _deploy(1, 0);
        _register(e, signers[0]);
        assertEq(e.mintLimit(), 0);

        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(keys[0], _digestFor(address(e), block.chainid, alice, 10 ether, deadline));
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.MintLimitExhausted.selector));
        e.claim(alice, 10 ether, deadline, sigs);
    }

    /// A threshold above the (empty) signer set is accepted at deployment and blocks claims until enough signers exist.
    function test_ConstructorAllowsThresholdAboveSignerCount() public {
        (, KskdEntry e) = _deploy(2, MINT_LIMIT);
        assertEq(e.threshold(), 2);
        assertEq(e.signerCount(), 0);

        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(keys[0], _digestFor(address(e), block.chainid, alice, 1 ether, deadline));
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InsufficientSignatures.selector, 1, 2));
        e.claim(alice, 1 ether, deadline, sigs);
    }

    /// The claim typehash is the three-field EIP-712 struct hash.
    function test_ClaimTypehashMatchesSpec() public view {
        assertEq(
            entry.CLAIM_TYPEHASH(), keccak256("Claim(address recipient,uint256 cumulativeBurned,uint256 deadline)")
        );
    }

    /// The mint window is one day.
    function test_WindowIsOneDay() public view {
        assertEq(entry.WINDOW(), 1 days);
        assertEq(entry.WINDOW(), 86400);
    }

    /// ERC-5267 reports the Pontifex v1 domain bound to this entry.
    function test_Eip712DomainIsPontifexV1() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = entry.eip712Domain();

        assertEq(uint8(fields), 0x0f);
        assertEq(name, "Pontifex");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(entry));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    // ─── registerEnclave ─────────────────────────────────────────────────

    /// A valid attestation of the pinned image admits its signer.
    function test_RegisterEnclaveAdmitsSigner() public {
        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.EnclaveRegistered(signers[1]);
        vm.prank(owner);
        entry.registerEnclave(abi.encode(true, PCR0, signers[1]));

        assertTrue(entry.validSigner(signers[1]));
        assertEq(entry.signerCount(), 2);
    }

    /// Only the owner may admit a signer.
    function test_RegisterEnclaveOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        entry.registerEnclave(abi.encode(true, PCR0, signers[1]));
    }

    /// An attestation the verifier rejects admits nobody.
    function test_RegisterEnclaveRejectsInvalidAttestation() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InvalidAttestation.selector));
        entry.registerEnclave(abi.encode(false, PCR0, signers[1]));

        assertFalse(entry.validSigner(signers[1]));
        assertEq(entry.signerCount(), 1);
    }

    /// An attestation of a different image is refused with both PCR0 values.
    function test_RegisterEnclaveRejectsPcr0Mismatch() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.PCR0Mismatch.selector, OTHER_PCR0, PCR0));
        entry.registerEnclave(abi.encode(true, OTHER_PCR0, signers[1]));
    }

    /// An attestation carrying a zero signer is refused.
    function test_RegisterEnclaveRejectsZeroSigner() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ZeroAddress.selector));
        entry.registerEnclave(abi.encode(true, PCR0, address(0)));
    }

    /// Registering the same signer twice is refused rather than silently repeated.
    function test_RegisterEnclaveRejectsDuplicate() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.SignerAlreadyRegistered.selector, signers[0]));
        entry.registerEnclave(abi.encode(true, PCR0, signers[0]));

        assertEq(entry.signerCount(), 1);
    }

    /// Distinct signers accumulate in the registry.
    function test_RegisterEnclaveCountsDistinctSigners() public {
        _register(entry, signers[1]);
        _register(entry, signers[2]);

        assertEq(entry.signerCount(), 3);
        assertTrue(entry.validSigner(signers[0]));
        assertTrue(entry.validSigner(signers[1]));
        assertTrue(entry.validSigner(signers[2]));
    }

    // ─── removeSigner ────────────────────────────────────────────────────

    /// Removing a signer clears it from the registry and lowers the count.
    function test_RemoveSignerRevokes() public {
        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.SignerRemoved(signers[0]);
        vm.prank(owner);
        entry.removeSigner(signers[0]);

        assertFalse(entry.validSigner(signers[0]));
        assertEq(entry.signerCount(), 0);
    }

    /// Only the owner may revoke a signer.
    function test_RemoveSignerOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        entry.removeSigner(signers[0]);
    }

    /// Removing an unknown signer is refused.
    function test_RemoveSignerRejectsUnknown() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.SignerNotRegistered.selector, signers[2]));
        entry.removeSigner(signers[2]);
    }

    /// Removing a signer below quorum strands claims until the threshold is lowered.
    function test_RemoveSignerCanStrandQuorum() public {
        (, KskdEntry e) = _deploy(2, MINT_LIMIT);
        _register(e, signers[0]);
        _register(e, signers[1]);

        vm.prank(owner);
        e.removeSigner(signers[1]);
        assertEq(e.signerCount(), 1);
        assertEq(e.threshold(), 2);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digestFor(address(e), block.chainid, alice, 5 ether, deadline);

        bytes[] memory one = new bytes[](1);
        one[0] = _sign(keys[0], digest);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InsufficientSignatures.selector, 1, 2));
        e.claim(alice, 5 ether, deadline, one);

        bytes[] memory two = new bytes[](2);
        two[0] = _sign(keys[0], digest);
        two[1] = _sign(keys[1], digest);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InvalidSigner.selector, signers[1]));
        e.claim(alice, 5 ether, deadline, two);

        vm.prank(owner);
        e.setThreshold(1);
        e.claim(alice, 5 ether, deadline, one);
        assertEq(token.bridgedIn(alice), 0);
        assertEq(KskdBridged(address(e.TOKEN())).bridgedIn(alice), 5 ether);
    }

    /// A removed signer can be re-admitted by a fresh attestation.
    function test_RemoveSignerThenReRegister() public {
        vm.prank(owner);
        entry.removeSigner(signers[0]);
        assertEq(entry.signerCount(), 0);

        _register(entry, signers[0]);
        assertTrue(entry.validSigner(signers[0]));
        assertEq(entry.signerCount(), 1);

        _claim(alice, 1 ether);
        assertEq(token.bridgedIn(alice), 1 ether);
    }

    // ─── setExpectedPcr0 ────────────────────────────────────

    /// The owner pins a new enclave image; the value is stored and announced.
    function test_SetExpectedPcr0StoresAndEmits() public {
        vm.expectEmit(false, false, false, true, address(entry));
        emit KskdEntry.ExpectedPcr0Set(OTHER_PCR0);
        vm.prank(owner);
        entry.setExpectedPcr0(OTHER_PCR0);

        assertEq(entry.expectedPcr0(), OTHER_PCR0);
    }

    /// Only the owner may pin a new image.
    function test_SetExpectedPcr0OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        entry.setExpectedPcr0(OTHER_PCR0);

        assertEq(entry.expectedPcr0(), PCR0);
    }

    /// Unpinning is refused: a zero PCR0 would admit any image the verifier accepts.
    function test_SetExpectedPcr0RejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ZeroPCR0.selector));
        entry.setExpectedPcr0(bytes32(0));

        assertEq(entry.expectedPcr0(), PCR0);
    }

    /// After the rotation a document of the new image admits its signer.
    function test_RegisterEnclaveAdmitsTheRotatedImage() public {
        vm.prank(owner);
        entry.setExpectedPcr0(OTHER_PCR0);

        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.EnclaveRegistered(signers[1]);
        vm.prank(owner);
        entry.registerEnclave(abi.encode(true, OTHER_PCR0, signers[1]));

        assertTrue(entry.validSigner(signers[1]));
        assertEq(entry.signerCount(), 2);
    }

    /// After the rotation a document of the retired image is refused, naming both values.
    function test_RegisterEnclaveRejectsTheRetiredImage() public {
        vm.prank(owner);
        entry.setExpectedPcr0(OTHER_PCR0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.PCR0Mismatch.selector, PCR0, OTHER_PCR0));
        entry.registerEnclave(abi.encode(true, PCR0, signers[1]));

        assertFalse(entry.validSigner(signers[1]));
        assertEq(entry.signerCount(), 1);
    }

    /// A rotation overlaps: the retired image's signer keeps signing claims until `removeSigner`.
    function test_RotationOverlapsUntilTheRetiredSignerIsRemoved() public {
        vm.prank(owner);
        entry.setExpectedPcr0(OTHER_PCR0);

        _claim(alice, 1 ether);
        assertEq(token.bridgedIn(alice), 1 ether);

        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory retired = _sigs(keys[0], alice, 2 ether, deadline);

        vm.prank(owner);
        entry.removeSigner(signers[0]);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InvalidSigner.selector, signers[0]));
        entry.claim(alice, 2 ether, deadline, retired);

        vm.prank(owner);
        entry.registerEnclave(abi.encode(true, OTHER_PCR0, signers[1]));
        entry.claim(alice, 2 ether, deadline, _sigs(keys[1], alice, 2 ether, deadline));

        assertEq(token.bridgedIn(alice), 2 ether);
    }

    // ─── setThreshold ────────────────────────────────────────────────────

    /// The owner may raise the threshold up to the signer count.
    function test_SetThresholdWithinSignerCount() public {
        _register(entry, signers[1]);

        vm.expectEmit(false, false, false, true, address(entry));
        emit KskdEntry.ThresholdSet(2);
        vm.prank(owner);
        entry.setThreshold(2);

        assertEq(entry.threshold(), 2);
    }

    /// Only the owner may set the threshold.
    function test_SetThresholdOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        entry.setThreshold(1);
    }

    /// A zero threshold is refused.
    function test_SetThresholdRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ZeroThreshold.selector));
        entry.setThreshold(0);
    }

    /// A threshold above the signer count is refused with both numbers.
    function test_SetThresholdRejectsAboveSignerCount() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ThresholdAboveSignerCount.selector, 2, 1));
        entry.setThreshold(2);
    }

    /// After a removal the threshold may equal the new signer count but not exceed it.
    function test_SetThresholdBoundsAfterRemoveSigner() public {
        _register(entry, signers[1]);
        _register(entry, signers[2]);

        vm.startPrank(owner);
        entry.setThreshold(3);
        entry.removeSigner(signers[2]);

        entry.setThreshold(2);
        assertEq(entry.threshold(), 2);

        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ThresholdAboveSignerCount.selector, 3, 2));
        entry.setThreshold(3);
        vm.stopPrank();
    }

    // ─── Guardian and mint limit ─────────────────────────────────────────

    /// Only the owner may appoint the guardian.
    function test_SetGuardianOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        entry.setGuardian(stranger);
    }

    /// Appointing the guardian stores and announces it.
    function test_SetGuardianEmits() public {
        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.GuardianSet(guard);
        vm.prank(owner);
        entry.setGuardian(guard);

        assertEq(entry.guardian(), guard);
    }

    /// The guardian zeroes the mint limit, announces it, and claims stop.
    function test_PauseZeroesMintLimit() public {
        vm.prank(owner);
        entry.setGuardian(guard);

        vm.expectEmit(false, false, false, true, address(entry));
        emit KskdEntry.MintLimitSet(0);
        vm.prank(guard);
        entry.pause();

        assertEq(entry.mintLimit(), 0);

        uint256 deadline = block.timestamp + 1 hours;
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.MintLimitExhausted.selector));
        entry.claim(alice, 1 ether, deadline, _sigs(keys[0], alice, 1 ether, deadline));
    }

    /// Owner and strangers cannot pause; only the guardian can.
    function test_PauseRejectsOwnerAndStrangers() public {
        vm.prank(owner);
        entry.setGuardian(guard);

        address[3] memory callers = [owner, stranger, alice];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(KskdEntry.NotGuardian.selector));
            entry.pause();
        }
        assertEq(entry.mintLimit(), MINT_LIMIT);
    }

    /// With no guardian appointed nobody can pause.
    function test_PauseWithoutGuardianRejectsEveryone() public {
        assertEq(entry.guardian(), address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.NotGuardian.selector));
        entry.pause();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.NotGuardian.selector));
        entry.pause();
    }

    /// Dismissing the guardian revokes the pause right.
    function test_SetGuardianToZeroDisablesRole() public {
        vm.startPrank(owner);
        entry.setGuardian(guard);
        entry.setGuardian(address(0));
        vm.stopPrank();

        assertEq(entry.guardian(), address(0));
        vm.prank(guard);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.NotGuardian.selector));
        entry.pause();
    }

    /// Only the owner can restore the limit after a pause, and claims resume.
    function test_OwnerRestoresLimitAfterPause() public {
        vm.prank(owner);
        entry.setGuardian(guard);
        vm.prank(guard);
        entry.pause();

        vm.prank(guard);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guard));
        entry.setMintLimit(MINT_LIMIT);

        vm.prank(owner);
        entry.setMintLimit(MINT_LIMIT);
        assertEq(entry.mintLimit(), MINT_LIMIT);

        _claim(alice, 3 ether);
        assertEq(token.bridgedIn(alice), 3 ether);
    }

    /// Only the owner may set the mint limit, and it is announced.
    function test_SetMintLimitOnlyOwnerAndEmits() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        entry.setMintLimit(1);

        vm.expectEmit(false, false, false, true, address(entry));
        emit KskdEntry.MintLimitSet(123 ether);
        vm.prank(owner);
        entry.setMintLimit(123 ether);

        assertEq(entry.mintLimit(), 123 ether);
    }

    // ─── Claim: happy paths ──────────────────────────────────────────────

    /// A quorum claim mints the unclaimed part of the attested burn and reports it.
    function test_ClaimMintsCumulativeDelta() public {
        uint256 deadline = block.timestamp + 1 hours;

        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.Claimed(alice, 100 ether, 100 ether, 100 ether);
        entry.claim(alice, 100 ether, deadline, _sigs(keys[0], alice, 100 ether, deadline));

        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.bridgedIn(alice), 100 ether);
        assertEq(entry.windowMinted(), 100 ether);
        assertEq(entry.windowStart(), block.timestamp);

        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.Claimed(alice, 150 ether, 250 ether, 250 ether);
        entry.claim(alice, 250 ether, deadline, _sigs(keys[0], alice, 250 ether, deadline));

        assertEq(token.balanceOf(alice), 250 ether);
        assertEq(entry.windowMinted(), 250 ether);
    }

    /// Anyone may relay a signed claim; the tokens go to the attested recipient.
    function test_ClaimIsPermissionless() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _sigs(keys[0], alice, 7 ether, deadline);

        vm.prank(stranger);
        entry.claim(alice, 7 ether, deadline, sigs);

        assertEq(token.balanceOf(alice), 7 ether);
        assertEq(token.balanceOf(stranger), 0);
    }

    /// Recipients are accounted independently.
    function test_ClaimMintsRecipientsIndependently() public {
        _claim(alice, 10 ether);
        _claim(bob, 25 ether);
        _claim(alice, 40 ether);

        assertEq(token.bridgedIn(alice), 40 ether);
        assertEq(token.bridgedIn(bob), 25 ether);
        assertEq(token.totalSupply(), 65 ether);
        assertEq(entry.windowMinted(), 65 ether);
    }

    /// A claim at exactly the deadline still passes.
    function test_ClaimAtDeadlineBoundary() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.warp(deadline);

        entry.claim(alice, 5 ether, deadline, _sigs(keys[0], alice, 5 ether, deadline));
        assertEq(token.bridgedIn(alice), 5 ether);
    }

    /// One second past the deadline the same claim is refused.
    function test_ClaimRevertsOneSecondAfterDeadline() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _sigs(keys[0], alice, 5 ether, deadline);
        vm.warp(deadline + 1);

        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ClaimExpired.selector, deadline));
        entry.claim(alice, 5 ether, deadline, sigs);
    }

    /// A quorum of two sorted signers mints.
    function test_ClaimWithTwoSignersSorted() public {
        (KskdBridged t, KskdEntry e) = _deploy(2, MINT_LIMIT);
        _register(e, signers[0]);
        _register(e, signers[1]);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digestFor(address(e), block.chainid, alice, 9 ether, deadline);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(keys[0], digest);
        sigs[1] = _sign(keys[1], digest);

        e.claim(alice, 9 ether, deadline, sigs);
        assertEq(t.bridgedIn(alice), 9 ether);
    }

    // ─── Claim: signature rejections ─────────────────────────────────────

    /// Fewer signatures than the threshold are refused with both counts.
    function test_ClaimRequiresThresholdSignatures() public {
        (, KskdEntry e) = _deploy(2, MINT_LIMIT);
        _register(e, signers[0]);
        _register(e, signers[1]);

        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory none = new bytes[](0);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InsufficientSignatures.selector, 0, 2));
        e.claim(alice, 1 ether, deadline, none);

        bytes[] memory one = new bytes[](1);
        one[0] = _sign(keys[0], _digestFor(address(e), block.chainid, alice, 1 ether, deadline));
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InsufficientSignatures.selector, 1, 2));
        e.claim(alice, 1 ether, deadline, one);
    }

    /// The same signer twice does not make a quorum.
    function test_ClaimRejectsDuplicateSignatures() public {
        (, KskdEntry e) = _deploy(2, MINT_LIMIT);
        _register(e, signers[0]);
        _register(e, signers[1]);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digestFor(address(e), block.chainid, alice, 1 ether, deadline);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(keys[0], digest);
        sigs[1] = _sign(keys[0], digest);

        vm.expectRevert(abi.encodeWithSelector(KskdEntry.UnsortedSigners.selector));
        e.claim(alice, 1 ether, deadline, sigs);
    }

    /// Signatures must arrive sorted by ascending signer address.
    function test_ClaimRejectsUnsortedSignatures() public {
        (, KskdEntry e) = _deploy(2, MINT_LIMIT);
        _register(e, signers[0]);
        _register(e, signers[1]);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digestFor(address(e), block.chainid, alice, 1 ether, deadline);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(keys[1], digest);
        sigs[1] = _sign(keys[0], digest);

        vm.expectRevert(abi.encodeWithSelector(KskdEntry.UnsortedSigners.selector));
        e.claim(alice, 1 ether, deadline, sigs);
    }

    /// A signature from an unregistered key is refused with the recovered address.
    function test_ClaimRejectsUnregisteredSigner() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InvalidSigner.selector, signers[1]));
        entry.claim(alice, 1 ether, deadline, _sigs(keys[1], alice, 1 ether, deadline));
    }

    /// An extra unregistered signature beyond the threshold still sinks the claim.
    function test_ClaimRejectsExtraUnregisteredSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _sigs2(keys[0], keys[1], alice, 1 ether, deadline);

        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InvalidSigner.selector, signers[1]));
        entry.claim(alice, 1 ether, deadline, sigs);
        assertEq(token.totalSupply(), 0);
    }

    /// A signature that is not 65 bytes is refused with its length.
    function test_ClaimRejectsMalformedSignatureLength() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = new bytes[](1);

        // 64-byte truncation drops the recovery id.
        (, bytes32 r, bytes32 s) = vm.sign(keys[0], _digest(alice, 1 ether, deadline));
        sigs[0] = abi.encodePacked(r, s);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 64));
        entry.claim(alice, 1 ether, deadline, sigs);

        sigs[0] = "";
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 0));
        entry.claim(alice, 1 ether, deadline, sigs);
    }

    /// The malleable high-s twin of a valid signature is refused.
    function test_ClaimRejectsHighS() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[0], _digest(alice, 1 ether, deadline));

        bytes32 highS = bytes32(uint256(SECP256K1N) - uint256(s));
        uint8 flipped = v == 27 ? 28 : 27;

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, highS, flipped);

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureS.selector, highS));
        entry.claim(alice, 1 ether, deadline, sigs);
    }

    /// A signature over a different deadline recovers a stranger.
    function test_ClaimRejectsSignatureOverDifferentDeadline() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _sigs(keys[0], alice, 1 ether, deadline + 1);

        address recovered = ECDSA.recover(_digest(alice, 1 ether, deadline), sigs[0]);
        assertTrue(recovered != signers[0]);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InvalidSigner.selector, recovered));
        entry.claim(alice, 1 ether, deadline, sigs);
    }

    /// A signature over a different recipient recovers a stranger.
    function test_ClaimRejectsSignatureOverDifferentRecipient() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _sigs(keys[0], bob, 1 ether, deadline);

        address recovered = ECDSA.recover(_digest(alice, 1 ether, deadline), sigs[0]);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InvalidSigner.selector, recovered));
        entry.claim(alice, 1 ether, deadline, sigs);
    }

    /// A signature over a different cumulative recovers a stranger.
    function test_ClaimRejectsSignatureOverDifferentCumulative() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _sigs(keys[0], alice, 2 ether, deadline);

        address recovered = ECDSA.recover(_digest(alice, 1 ether, deadline), sigs[0]);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InvalidSigner.selector, recovered));
        entry.claim(alice, 1 ether, deadline, sigs);
    }

    /// A signature bound to another chain id does not travel.
    function test_ClaimRejectsWrongChainIdDomain() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 foreign = _digestFor(address(entry), block.chainid + 1, alice, 1 ether, deadline);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(keys[0], foreign);

        address recovered = ECDSA.recover(_digest(alice, 1 ether, deadline), sigs[0]);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InvalidSigner.selector, recovered));
        entry.claim(alice, 1 ether, deadline, sigs);
    }

    /// A signature bound to another entry address does not travel.
    function test_ClaimRejectsOtherEntryDomain() public {
        (, KskdEntry other) = _deploy(1, MINT_LIMIT);
        _register(other, signers[0]);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 foreign = _digestFor(address(other), block.chainid, alice, 1 ether, deadline);
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(keys[0], foreign);

        address recovered = ECDSA.recover(_digest(alice, 1 ether, deadline), sigs[0]);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InvalidSigner.selector, recovered));
        entry.claim(alice, 1 ether, deadline, sigs);

        other.claim(alice, 1 ether, deadline, sigs);
        assertEq(KskdBridged(address(other.TOKEN())).bridgedIn(alice), 1 ether);
    }

    // ─── Claim: accounting rejections ────────────────────────────────────

    /// Replaying a claim mints nothing and reverts with the attested and minted totals.
    function test_ClaimReplayRevertsWithNothingToMint() public {
        _claim(alice, 100 ether);

        uint256 deadline = block.timestamp + 1 hours;
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NothingToMint.selector, 100 ether, 100 ether));
        entry.claim(alice, 100 ether, deadline, _sigs(keys[0], alice, 100 ether, deadline));

        assertEq(token.bridgedIn(alice), 100 ether);
    }

    /// A cumulative below what was already minted is refused.
    function test_ClaimRejectsDecreasingCumulative() public {
        _claim(alice, 100 ether);

        uint256 deadline = block.timestamp + 1 hours;
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NothingToMint.selector, 99 ether, 100 ether));
        entry.claim(alice, 99 ether, deadline, _sigs(keys[0], alice, 99 ether, deadline));
    }

    /// The entry itself raises NothingToMint, before the token is ever called.
    function test_NothingToMintIsRaisedByTheEntry() public {
        _claim(alice, 100 ether);
        uint256 deadline = block.timestamp + 1 hours;

        vm.expectRevert(
            abi.encodeWithSelector(KskdBridged.NothingToMint.selector, 100 ether, 100 ether), address(entry)
        );
        entry.claim(alice, 100 ether, deadline, _sigs(keys[0], alice, 100 ether, deadline));

        vm.prank(owner);
        token.setBridge(stranger);

        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NothingToMint.selector, 100 ether, 100 ether));
        entry.claim(alice, 100 ether, deadline, _sigs(keys[0], alice, 100 ether, deadline));
    }

    /// Once the token points at another bridge the entry can no longer mint.
    function test_ClaimThroughMovedBridgeReverts() public {
        vm.prank(owner);
        token.setBridge(stranger);

        uint256 deadline = block.timestamp + 1 hours;
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NotBridge.selector));
        entry.claim(alice, 1 ether, deadline, _sigs(keys[0], alice, 1 ether, deadline));
    }

    /// The entry does not screen the recipient: a claim to the zero address dies in ERC20.
    function test_ClaimToZeroRecipientRevertsInToken() public {
        uint256 deadline = block.timestamp + 1 hours;
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        entry.claim(address(0), 1 ether, deadline, _sigs(keys[0], address(0), 1 ether, deadline));
    }

    /// The token cap still binds claims that fit the window budget.
    function test_ClaimHonoursTokenCap() public {
        (KskdBridged t, KskdEntry e) = _deploy(1, 2e27);
        _register(e, signers[0]);

        uint256 deadline = block.timestamp + 365 days;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(keys[0], _digestFor(address(e), block.chainid, alice, 1e27, deadline));
        e.claim(alice, 1e27, deadline, sigs);
        assertEq(t.totalSupply(), 1e27);

        vm.warp(block.timestamp + 1 days);
        sigs[0] = _sign(keys[0], _digestFor(address(e), block.chainid, bob, 1, deadline));
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.MaxSupplyExceeded.selector, 1, 0));
        e.claim(bob, 1, deadline, sigs);
    }

    // ─── Mint window ─────────────────────────────────────────────────────

    /// A claim larger than the remaining budget mints the budget; `cumulative < attested` in the event marks the remainder.
    function test_ClaimPartialFillWhenBudgetShort() public {
        vm.prank(owner);
        entry.setMintLimit(300 ether);

        uint256 deadline = block.timestamp + 1 hours;
        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.Claimed(alice, 300 ether, 300 ether, 500 ether);
        entry.claim(alice, 500 ether, deadline, _sigs(keys[0], alice, 500 ether, deadline));

        assertEq(token.bridgedIn(alice), 300 ether);
        assertEq(token.balanceOf(alice), 300 ether);
        assertEq(entry.windowMinted(), 300 ether);
    }

    /// The same signatures mint the remainder once the window rolls.
    function test_SameSignaturesMintRemainderAfterWindow() public {
        vm.prank(owner);
        entry.setMintLimit(300 ether);

        uint256 deadline = block.timestamp + 30 days;
        bytes[] memory sigs = _sigs(keys[0], alice, 500 ether, deadline);
        entry.claim(alice, 500 ether, deadline, sigs);
        assertEq(token.bridgedIn(alice), 300 ether);

        vm.warp(block.timestamp + entry.WINDOW());

        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.Claimed(alice, 200 ether, 500 ether, 500 ether);
        entry.claim(alice, 500 ether, deadline, sigs);

        assertEq(token.bridgedIn(alice), 500 ether);
        assertEq(entry.windowMinted(), 200 ether);
        assertEq(entry.windowStart(), block.timestamp);
    }

    /// A second claim inside an exhausted window is refused.
    function test_ClaimRevertsWhenBudgetExhaustedInWindow() public {
        vm.prank(owner);
        entry.setMintLimit(300 ether);

        uint256 deadline = block.timestamp + 30 days;
        entry.claim(alice, 500 ether, deadline, _sigs(keys[0], alice, 500 ether, deadline));

        vm.warp(block.timestamp + entry.WINDOW() - 1);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.MintLimitExhausted.selector));
        entry.claim(bob, 10 ether, deadline, _sigs(keys[0], bob, 10 ether, deadline));
    }

    /// A zero mint limit stops every claim.
    function test_MintLimitZeroRejectsClaims() public {
        vm.prank(owner);
        entry.setMintLimit(0);

        uint256 deadline = block.timestamp + 1 hours;
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.MintLimitExhausted.selector));
        entry.claim(alice, 1, deadline, _sigs(keys[0], alice, 1, deadline));
    }

    /// Lowering the limit below what the window already minted stops claims until it rolls.
    function test_LoweringLimitMidWindowStopsClaims() public {
        vm.prank(owner);
        entry.setMintLimit(1000 ether);

        uint256 deadline = block.timestamp + 30 days;
        entry.claim(alice, 300 ether, deadline, _sigs(keys[0], alice, 300 ether, deadline));

        vm.prank(owner);
        entry.setMintLimit(200 ether);
        assertGt(entry.windowMinted(), entry.mintLimit());

        vm.expectRevert(abi.encodeWithSelector(KskdEntry.MintLimitExhausted.selector));
        entry.claim(bob, 1 ether, deadline, _sigs(keys[0], bob, 1 ether, deadline));

        vm.warp(block.timestamp + entry.WINDOW());
        entry.claim(bob, 1 ether, deadline, _sigs(keys[0], bob, 1 ether, deadline));
        assertEq(token.bridgedIn(bob), 1 ether);
        assertEq(entry.windowMinted(), 1 ether);
    }

    /// The window is tumbling, not rolling: 2 × mintLimit can mint one second apart.
    function test_WindowIsTumblingNotRolling() public {
        uint256 limit = 1000 ether;
        vm.prank(owner);
        entry.setMintLimit(limit);

        uint256 deadline = block.timestamp + 30 days;
        entry.claim(alice, 1, deadline, _sigs(keys[0], alice, 1, deadline));
        uint256 start = entry.windowStart();

        vm.warp(start + entry.WINDOW() - 1);
        entry.claim(alice, limit, deadline, _sigs(keys[0], alice, limit, deadline));
        assertEq(entry.windowMinted(), limit);

        vm.warp(start + entry.WINDOW());
        entry.claim(bob, limit, deadline, _sigs(keys[0], bob, limit, deadline));

        assertEq(entry.windowMinted(), limit);
        assertEq(entry.windowStart(), block.timestamp);
        assertEq(token.totalSupply(), 2 * limit);
    }

    /// The window only rolls on a claim, however long the entry sits idle.
    function test_WindowRollsOnlyOnClaim() public {
        _claim(alice, 1 ether);
        uint256 start = entry.windowStart();

        vm.warp(block.timestamp + 10 days);
        assertEq(entry.windowStart(), start);
        assertEq(entry.windowMinted(), 1 ether);

        _claim(alice, 2 ether);
        assertEq(entry.windowStart(), block.timestamp);
        assertEq(entry.windowMinted(), 1 ether);
    }

    // ─── Ownable2Step ────────────────────────────────────────────────────

    /// Ownership moves only after the new owner accepts.
    function test_OwnershipTransferIsTwoStep() public {
        vm.expectEmit(true, true, false, true, address(entry));
        emit Ownable2Step.OwnershipTransferStarted(owner, alice);
        vm.prank(owner);
        entry.transferOwnership(alice);

        assertEq(entry.owner(), owner);
        assertEq(entry.pendingOwner(), alice);

        vm.prank(alice);
        entry.acceptOwnership();

        assertEq(entry.owner(), alice);
        assertEq(entry.pendingOwner(), address(0));
    }

    /// Only the pending owner can accept.
    function test_AcceptOwnershipRejectsStranger() public {
        vm.prank(owner);
        entry.transferOwnership(alice);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        entry.acceptOwnership();
    }

    /// After the handover the old owner loses the registry and the new one gains it.
    function test_OldOwnerLosesRegistryRights() public {
        vm.prank(owner);
        entry.transferOwnership(alice);
        vm.prank(alice);
        entry.acceptOwnership();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        entry.registerEnclave(abi.encode(true, PCR0, signers[1]));

        vm.prank(alice);
        entry.registerEnclave(abi.encode(true, PCR0, signers[1]));
        assertTrue(entry.validSigner(signers[1]));
    }

    // ─── Fuzz ────────────────────────────────────────────────────────────

    /// A claim is granted the smaller of the request and the remaining budget.
    function testFuzz_ClaimGrantsMinOfRequestedAndRoom(uint256 rawLimit, uint256 rawRequested) public {
        uint256 limit = bound(rawLimit, 1, 1e24);
        uint256 requested = bound(rawRequested, 1, 1e24);

        vm.prank(owner);
        entry.setMintLimit(limit);

        uint256 deadline = block.timestamp + 1 hours;
        entry.claim(alice, requested, deadline, _sigs(keys[0], alice, requested, deadline));

        uint256 expected = requested < limit ? requested : limit;
        assertEq(token.bridgedIn(alice), expected);
        assertEq(entry.windowMinted(), expected);
        assertLe(expected, requested);
        assertLe(entry.windowMinted(), entry.mintLimit());
    }

    /// Two windows never mint more than the attested cumulative.
    function testFuzz_ClaimNeverMintsPastAttested(uint256 rawLimit, uint256 rawCumulative) public {
        uint256 limit = bound(rawLimit, 1, 1e24);
        uint256 cumulative = bound(rawCumulative, 1, 1e24);

        vm.prank(owner);
        entry.setMintLimit(limit);

        uint256 deadline = block.timestamp + 30 days;
        bytes[] memory sigs = _sigs(keys[0], alice, cumulative, deadline);
        entry.claim(alice, cumulative, deadline, sigs);

        for (uint256 i = 0; i < 3 && token.bridgedIn(alice) < cumulative; i++) {
            vm.warp(block.timestamp + entry.WINDOW());
            entry.claim(alice, cumulative, deadline, sigs);
        }

        assertLe(token.bridgedIn(alice), cumulative);
        assertEq(token.totalSupply(), token.bridgedIn(alice));
    }

    /// Rising cumulatives mint exactly the deltas.
    function testFuzz_CumulativeClaimsAreMonotone(uint256 rawA, uint256 rawB) public {
        uint256 a = bound(rawA, 1, 1e23);
        uint256 b = bound(rawB, 1, 1e23);

        _claim(alice, a);
        assertEq(token.bridgedIn(alice), a);

        _claim(alice, a + b);
        assertEq(token.bridgedIn(alice), a + b);
        assertEq(entry.windowMinted(), a + b);
    }

    /// Any deadline in the past is refused.
    function testFuzz_ClaimRejectsExpiredDeadline(uint256 rawSkew) public {
        uint256 deadline = block.timestamp - bound(rawSkew, 1, 365 days);
        bytes[] memory sigs = _sigs(keys[0], alice, 1 ether, deadline);

        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ClaimExpired.selector, deadline));
        entry.claim(alice, 1 ether, deadline, sigs);
    }

    /// Any key outside the registry is refused with its address.
    function testFuzz_ClaimRejectsUnregisteredSigner(uint256 rawKey) public {
        uint256 key = bound(rawKey, 1, type(uint128).max);
        address signer = vm.addr(key);
        vm.assume(!entry.validSigner(signer));

        uint256 deadline = block.timestamp + 1 hours;
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InvalidSigner.selector, signer));
        entry.claim(alice, 1 ether, deadline, _sigs(key, alice, 1 ether, deadline));
    }

    /// The threshold can never be raised above the signer count.
    function testFuzz_SetThresholdBounds(uint256 rawThreshold) public {
        uint256 newThreshold = bound(rawThreshold, 2, 1e6);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ThresholdAboveSignerCount.selector, newThreshold, 1));
        entry.setThreshold(newThreshold);

        assertEq(entry.threshold(), 1);
    }

    /// Only the appointed guardian may pause.
    function testFuzz_PauseRejectsNonGuardian(address caller) public {
        vm.prank(owner);
        entry.setGuardian(guard);
        vm.assume(caller != guard);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.NotGuardian.selector));
        entry.pause();

        assertEq(entry.mintLimit(), MINT_LIMIT);
    }

    /// Any non-zero image can be pinned, and exactly that image is admitted afterwards.
    function testFuzz_SetExpectedPcr0PinsExactlyOneImage(bytes32 pcr0) public {
        vm.assume(pcr0 != bytes32(0) && pcr0 != PCR0);

        vm.prank(owner);
        entry.setExpectedPcr0(pcr0);
        assertEq(entry.expectedPcr0(), pcr0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.PCR0Mismatch.selector, PCR0, pcr0));
        entry.registerEnclave(abi.encode(true, PCR0, signers[1]));

        vm.prank(owner);
        entry.registerEnclave(abi.encode(true, pcr0, signers[1]));
        assertTrue(entry.validSigner(signers[1]));
    }

    // ─── Window edges ────────────────────────────────────────────────────

    /// The first claim ever rolls the window out of its zero start and gets the whole budget.
    function test_FirstClaimRollsWindowFromZeroStart() public {
        assertEq(entry.windowStart(), 0);
        assertEq(entry.windowMinted(), 0);

        _claim(alice, MINT_LIMIT);

        assertEq(entry.windowStart(), block.timestamp);
        assertEq(entry.windowMinted(), MINT_LIMIT);
        assertEq(token.bridgedIn(alice), MINT_LIMIT);
    }

    /// A partial fill always leaves the window exactly full, so no claim can follow it in that window.
    function test_PartialFillAlwaysExhaustsTheWindow() public {
        vm.prank(owner);
        entry.setMintLimit(300 ether);

        uint256 deadline = block.timestamp + 30 days;
        entry.claim(alice, 500 ether, deadline, _sigs(keys[0], alice, 500 ether, deadline));
        assertEq(entry.windowMinted(), entry.mintLimit());

        vm.expectRevert(abi.encodeWithSelector(KskdEntry.MintLimitExhausted.selector));
        entry.claim(bob, 1, deadline, _sigs(keys[0], bob, 1, deadline));
    }

    /// Raising the limit mid-window reopens room without rolling the window.
    function test_RaisingLimitMidWindowGrantsMoreRoom() public {
        vm.prank(owner);
        entry.setMintLimit(300 ether);

        uint256 deadline = block.timestamp + 30 days;
        entry.claim(alice, 500 ether, deadline, _sigs(keys[0], alice, 500 ether, deadline));
        uint256 start = entry.windowStart();

        vm.prank(owner);
        entry.setMintLimit(800 ether);

        entry.claim(alice, 500 ether, deadline, _sigs(keys[0], alice, 500 ether, deadline));

        assertEq(token.bridgedIn(alice), 500 ether);
        assertEq(entry.windowMinted(), 500 ether);
        assertEq(entry.windowStart(), start);
    }

    /// An unbounded limit never overflows the budget arithmetic; the token cap still binds.
    function test_MintLimitMaxDoesNotOverflow() public {
        vm.prank(owner);
        entry.setMintLimit(type(uint256).max);

        uint256 cap = token.MAX_SUPPLY();
        uint256 deadline = block.timestamp + 30 days;
        entry.claim(alice, cap, deadline, _sigs(keys[0], alice, cap, deadline));

        assertEq(entry.windowMinted(), cap);
        assertEq(entry.mintLimit(), type(uint256).max);
        assertEq(token.totalSupply(), cap);

        vm.expectRevert(abi.encodeWithSelector(KskdBridged.MaxSupplyExceeded.selector, 1, 0));
        entry.claim(bob, 1, deadline, _sigs(keys[0], bob, 1, deadline));
    }

    /// Two claims in the same block share one budget; the window is never charged twice.
    function test_TwoClaimsInOneBlockShareOneBudget() public {
        vm.prank(owner);
        entry.setMintLimit(1000 ether);

        uint256 deadline = block.timestamp + 30 days;
        entry.claim(alice, 600 ether, deadline, _sigs(keys[0], alice, 600 ether, deadline));
        entry.claim(bob, 600 ether, deadline, _sigs(keys[0], bob, 600 ether, deadline));

        assertEq(token.bridgedIn(alice), 600 ether);
        assertEq(token.bridgedIn(bob), 400 ether);
        assertEq(entry.windowMinted(), 1000 ether);
        assertEq(token.totalSupply(), 1000 ether);
    }

    /// `windowStart + WINDOW` only overflows past a timestamp no chain can reach.
    function test_WindowStartOverflowNeedsAnUnreachableTimestamp() public {
        uint256 deadline = type(uint256).max;

        vm.warp(type(uint256).max - entry.WINDOW());
        entry.claim(alice, 1 ether, deadline, _sigs(keys[0], alice, 1 ether, deadline));
        assertEq(entry.windowStart(), type(uint256).max - entry.WINDOW());

        // windowStart + WINDOW == type(uint256).max: still exact, the window rolls once more.
        vm.warp(type(uint256).max);
        entry.claim(alice, 2 ether, deadline, _sigs(keys[0], alice, 2 ether, deadline));
        assertEq(entry.windowStart(), type(uint256).max);

        // Only now does the sum overflow, and only at a timestamp ~1.1e77 times the age of the chain.
        vm.expectRevert(stdError.arithmeticError);
        entry.claim(alice, 3 ether, deadline, _sigs(keys[0], alice, 3 ether, deadline));
    }

    // ─── Supply cap vs window ────────────────────────────────────────────

    /// A claim that would cross MAX_SUPPLY reverts whole; unlike the window there is no partial fill.
    function test_ClaimCrossingCapRevertsInsteadOfPartialFill() public {
        (KskdBridged t, KskdEntry e) = _deploy(1, type(uint256).max);
        _register(e, signers[0]);

        uint256 cap = t.MAX_SUPPLY();
        uint256 deadline = block.timestamp + 365 days;
        bytes[] memory sigs = new bytes[](1);

        sigs[0] = _sign(keys[0], _digestFor(address(e), block.chainid, alice, cap - 100, deadline));
        e.claim(alice, cap - 100, deadline, sigs);
        assertEq(t.totalSupply(), cap - 100);

        // 100 wei of headroom, 500 requested: the window would have part-filled, the cap does not.
        sigs[0] = _sign(keys[0], _digestFor(address(e), block.chainid, bob, 500, deadline));
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.MaxSupplyExceeded.selector, 500, 100));
        e.claim(bob, 500, deadline, sigs);

        assertEq(t.totalSupply(), cap - 100);
        assertEq(e.windowMinted(), cap - 100);
    }

    // ─── Quorum edges ────────────────────────────────────────────────────

    /// Signatures beyond the threshold are accepted as long as each is a registered signer, in order.
    function test_ClaimAcceptsExtraValidSignatureAboveThreshold() public {
        _register(entry, signers[1]);
        assertEq(entry.threshold(), 1);

        uint256 deadline = block.timestamp + 1 hours;
        entry.claim(alice, 5 ether, deadline, _sigs2(keys[0], keys[1], alice, 5 ether, deadline));

        assertEq(token.bridgedIn(alice), 5 ether);
    }

    /// With no signer ever registered no signature set can pass, whatever the threshold.
    function test_ClaimImpossibleWithoutRegisteredSigners() public {
        (, KskdEntry e) = _deploy(1, MINT_LIMIT);
        assertEq(e.signerCount(), 0);
        assertEq(e.threshold(), 1);

        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = _sign(keys[0], _digestFor(address(e), block.chainid, alice, 1 ether, deadline));

        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InvalidSigner.selector, signers[0]));
        e.claim(alice, 1 ether, deadline, sigs);

        bytes[] memory none = new bytes[](0);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InsufficientSignatures.selector, 0, 1));
        e.claim(alice, 1 ether, deadline, none);
    }

    /// A threshold above the signer count at deploy blocks every claim until enough signers exist.
    function test_ClaimBlockedWhileThresholdExceedsSignerCount() public {
        (, KskdEntry e) = _deploy(3, MINT_LIMIT);
        vm.startPrank(owner);
        e.registerEnclave(abi.encode(true, PCR0, signers[0]));
        e.registerEnclave(abi.encode(true, PCR0, signers[1]));
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _digestFor(address(e), block.chainid, alice, 1 ether, deadline);
        bytes[] memory sigs = new bytes[](2);
        sigs[0] = _sign(keys[0], digest);
        sigs[1] = _sign(keys[1], digest);

        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InsufficientSignatures.selector, 2, 3));
        e.claim(alice, 1 ether, deadline, sigs);
    }

    /// No signature can recover the zero address, so the sort sentinel can never be spoofed.
    function test_SignatureCannotRecoverZeroAddress() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(bytes32(0), bytes32(uint256(1)), uint8(27));

        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignature.selector));
        entry.claim(alice, 1 ether, deadline, sigs);
    }

    // ─── Verifier isolation ──────────────────────────────────────────────

    /// The verifier is reached by STATICCALL: a verifier that writes storage cannot be used.
    function test_RegisterEnclaveRejectsStateWritingVerifier() public {
        StateWritingVerifier writer = new StateWritingVerifier(PCR0, signers[0]);
        KskdBridged t = new KskdBridged(address(0), owner);
        KskdEntry e = new KskdEntry(address(t), address(writer), PCR0, 1, MINT_LIMIT, owner);

        vm.prank(owner);
        vm.expectRevert(bytes(""));
        e.registerEnclave(hex"1234");

        assertEq(writer.calls(), 0);
        assertFalse(e.validSigner(signers[0]));
    }

    /// A verifier cannot reenter the entry: the reentrant frame inherits the static context.
    function test_RegisterEnclaveRejectsReentrantVerifier() public {
        ReentrantVerifier reenter = new ReentrantVerifier(PCR0, signers[0]);
        KskdBridged t = new KskdBridged(address(0), owner);
        KskdEntry e = new KskdEntry(address(t), address(reenter), PCR0, 1, MINT_LIMIT, owner);
        reenter.setEntry(address(e));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ReentrantVerifier.ReentrancyBlocked.selector));
        e.registerEnclave(hex"1234");

        assertEq(e.signerCount(), 0);
    }

    // ─── Ownership loss ──────────────────────────────────────────────────

    /// `renounceOwnership` reverts for everyone: an ownerless entry could never restore `mintLimit` or rotate signers.
    function test_RenounceOwnershipDisabled() public {
        vm.prank(owner);
        vm.expectRevert(KskdEntry.RenounceDisabled.selector);
        entry.renounceOwnership();
        assertEq(entry.owner(), owner);

        vm.prank(alice);
        vm.expectRevert(KskdEntry.RenounceDisabled.selector);
        entry.renounceOwnership();
        assertEq(entry.owner(), owner);
    }

    /// A guardian pause stays reversible: the owner restores the budget and claims resume.
    function test_OwnerRestoresBudgetAfterGuardianPause() public {
        vm.prank(owner);
        entry.setGuardian(guard);
        vm.prank(guard);
        entry.pause();
        assertEq(entry.mintLimit(), 0);

        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _sigs(keys[0], alice, 1 ether, deadline);
        vm.expectRevert(KskdEntry.MintLimitExhausted.selector);
        entry.claim(alice, 1 ether, deadline, sigs);

        vm.prank(owner);
        entry.setMintLimit(MINT_LIMIT);
        entry.claim(alice, 1 ether, deadline, sigs);
        assertEq(token.balanceOf(alice), 1 ether);
    }

    // ─── Liveness ────────────────────────────────────────────────────────

    /// Signatures are public calldata: anyone can spend the window ahead of a pending claim.
    function test_FrontRunnerCanExhaustTheWindowAheadOfAPendingClaim() public {
        vm.prank(owner);
        entry.setMintLimit(1000 ether);

        uint256 deadline = block.timestamp + 30 days;
        bytes[] memory victim = _sigs(keys[0], alice, 1000 ether, deadline);

        // Observed in the mempool and replayed for the front-runner's own attested balance.
        entry.claim(bob, 1000 ether, deadline, _sigs(keys[0], bob, 1000 ether, deadline));

        vm.expectRevert(abi.encodeWithSelector(KskdEntry.MintLimitExhausted.selector));
        entry.claim(alice, 1000 ether, deadline, victim);

        // Repeating this on every roll starves the victim for as long as the attacker has budget.
        vm.warp(block.timestamp + entry.WINDOW());
        entry.claim(bob, 2000 ether, deadline, _sigs(keys[0], bob, 2000 ether, deadline));
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.MintLimitExhausted.selector));
        entry.claim(alice, 1000 ether, deadline, victim);
    }

    /// Replaying someone else's signatures still pays them: the recipient is bound into the digest.
    function test_ReplayedSignaturesStillPayTheAttestedRecipient() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _sigs(keys[0], alice, 7 ether, deadline);

        vm.prank(stranger);
        entry.claim(alice, 7 ether, deadline, sigs);

        assertEq(token.balanceOf(alice), 7 ether);
        assertEq(token.balanceOf(stranger), 0);
    }
}

/// @notice Drives signed claims, time and recipients for the entry invariants.
contract KskdEntryHandler is CommonBase, StdUtils {
    KskdEntry internal immutable ENTRY;
    KskdBridged internal immutable TOKEN;
    uint256 internal immutable SIGNER_KEY;
    bytes32 internal immutable DOMAIN;

    address[] internal recipients;

    mapping(address recipient => uint256) public maxAttested;
    mapping(address recipient => uint256) public highWater;

    constructor(KskdEntry entry_, KskdBridged token_, uint256 signerKey_, address[] memory recipients_) {
        ENTRY = entry_;
        TOKEN = token_;
        SIGNER_KEY = signerKey_;
        recipients = recipients_;
        DOMAIN = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Pontifex"),
                keccak256("1"),
                block.chainid,
                address(entry_)
            )
        );
    }

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function recipientAt(uint256 i) external view returns (address) {
        return recipients[i];
    }

    function _digest(address recipient, uint256 cumulative, uint256 deadline) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01", DOMAIN, keccak256(abi.encode(ENTRY.CLAIM_TYPEHASH(), recipient, cumulative, deadline))
            )
        );
    }

    function claim(uint256 seed, uint256 rawDelta, uint256 rawWarp) external {
        address recipient = recipients[seed % recipients.length];
        uint256 cumulative = TOKEN.bridgedIn(recipient) + bound(rawDelta, 1, 3e23);

        vm.warp(block.timestamp + bound(rawWarp, 0, 2 days));
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, _digest(recipient, cumulative, deadline));
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);

        if (cumulative > maxAttested[recipient]) maxAttested[recipient] = cumulative;

        try ENTRY.claim(recipient, cumulative, deadline, sigs) {} catch {}
        highWater[recipient] = TOKEN.bridgedIn(recipient);
    }

    function claimReplay(uint256 seed, uint256 rawWarp) external {
        address recipient = recipients[seed % recipients.length];
        uint256 cumulative = maxAttested[recipient];
        if (cumulative == 0) return;

        vm.warp(block.timestamp + bound(rawWarp, 0, 2 days));
        uint256 deadline = block.timestamp + 1 hours;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, _digest(recipient, cumulative, deadline));
        bytes[] memory sigs = new bytes[](1);
        sigs[0] = abi.encodePacked(r, s, v);

        try ENTRY.claim(recipient, cumulative, deadline, sigs) {} catch {}
        highWater[recipient] = TOKEN.bridgedIn(recipient);
    }
}

/// @notice Invariants of the entry under random signed claims and time jumps.
contract KskdEntryInvariantTest is Test {
    bytes32 internal constant PCR0 = keccak256("pontifex-enclave-image");
    uint256 internal constant MINT_LIMIT = 100_000 ether;

    StubAttestationVerifier internal verifier;
    KskdBridged internal token;
    KskdEntry internal entry;
    KskdEntryHandler internal handler;

    address internal owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1_700_000_000);
        verifier = new StubAttestationVerifier();
        (address signer, uint256 key) = makeAddrAndKey("enclaveInvariant");

        token = new KskdBridged(address(0), owner);
        entry = new KskdEntry(address(token), address(verifier), PCR0, 1, MINT_LIMIT, owner);
        vm.startPrank(owner);
        token.setBridge(address(entry));
        entry.registerEnclave(abi.encode(true, PCR0, signer));
        vm.stopPrank();

        address[] memory recipients = new address[](4);
        recipients[0] = makeAddr("r1");
        recipients[1] = makeAddr("r2");
        recipients[2] = makeAddr("r3");
        recipients[3] = makeAddr("r4");

        handler = new KskdEntryHandler(entry, token, key, recipients);
        targetContract(address(handler));
    }

    /// Minting never passes the Igra supply.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    function invariant_SupplyUnderCap() public view {
        assertLe(token.totalSupply(), token.MAX_SUPPLY());
    }

    /// Per-recipient cumulatives never decrease.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    function invariant_BridgedInNeverDecreases() public view {
        for (uint256 i = 0; i < handler.recipientCount(); i++) {
            address recipient = handler.recipientAt(i);
            assertGe(token.bridgedIn(recipient), handler.highWater(recipient));
        }
    }

    /// No recipient is ever minted more than the largest cumulative signed for it.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    function invariant_MintedNeverExceedsAttested() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.recipientCount(); i++) {
            address recipient = handler.recipientAt(i);
            assertLe(token.bridgedIn(recipient), handler.maxAttested(recipient));
            sum += token.bridgedIn(recipient);
        }
        assertEq(sum, token.totalSupply());
    }

    /// The window budget is never overspent while the limit is not lowered.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    function invariant_WindowMintedWithinLimit() public view {
        assertLe(entry.windowMinted(), entry.mintLimit());
        assertEq(entry.mintLimit(), MINT_LIMIT);
    }
}
