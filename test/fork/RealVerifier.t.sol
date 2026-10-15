// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ICertManager, INitroAttestationVerifier} from "../interfaces/INitroAttestationVerifier.sol";
import {KskdBridged} from "../../src/KskdBridged.sol";
import {KskdEntry} from "../../src/KskdEntry.sol";

interface IKaskadPriceOracle {
    function isValidSigner(address signer) external view returns (bool);
}

/// @notice Captured Nitro documents against the live NitroAttestationVerifier on an Igra fork.
///         Igra is the only chain where the verifier stack is deployed, so the gas budget the
///         Robinhood deployment has to fit is measured here.
contract RealVerifierForkTest is Test {
    address constant VERIFIER = 0x76216b3bde5bC81b04FA5A5d4a67F6AfACc666B9;
    address constant PRICE_ORACLE = 0xB01993906D14792DC21B7EA75A971D8191AAE402;

    bytes32 constant PCR0 = 0x2e66fc4f74006323675a397ab3c6b6eab68f2ccc36f4cf10bb4d0e5c82b2106c;
    address constant US_SIGNER = 0x544705F5d72E1C6f24bFD7C2E176F2Cd2aA8Dc2A;
    address constant EU_SIGNER = 0xD35e55c7C2d10472e6d9E7132c88BEeD347D91A7;

    uint256 constant CAPTURED_AT = 1789682698;
    uint256 constant IN_WINDOW = CAPTURED_AT + 300;
    /// Past the leaf certificate's notAfter (~3 h), which is what rejects a replayed document.
    uint256 constant PAST_LEAF_EXPIRY = CAPTURED_AT + 5 hours;

    /// Robinhood `maxTxGasLimit` is 32,000,000; assert against 30,000,000 to leave calldata headroom.
    uint256 constant GAS_BUDGET = 30_000_000;

    /// Igra's RPC is load balanced across nodes at slightly different heights; pin the fork to
    /// `finalized` (latest − 768) so state lookups never race the head.
    uint256 constant IGRA_FINALITY_LAG = 768;

    uint256 constant THRESHOLD = 1;
    uint256 constant MINT_LIMIT = 1e24;

    INitroAttestationVerifier constant NITRO = INitroAttestationVerifier(VERIFIER);

    bytes usDoc;
    bytes euDoc;
    address owner = makeAddr("owner");

    function setUp() public {
        string memory url = vm.envOr("IGRA_RPC_URL", string("https://rpc.igralabs.com:8545"));
        // Pin below the head: the load balancer serves backends at slightly different heights.
        bytes memory raw = vm.rpc(url, "eth_blockNumber", "[]");
        uint256 head;
        for (uint256 i = 0; i < raw.length; i++) {
            head = (head << 8) | uint8(raw[i]);
        }
        vm.createSelectFork(url, head - 768);
        assertEq(block.chainid, 38833, "not the Igra mainnet fork");
        vm.rollFork(block.number - IGRA_FINALITY_LAG);
        usDoc = _hexFixture("attestation-us.hex");
        euDoc = _hexFixture("attestation-eu.hex");
        emit log_named_uint("fork block", block.number);
        emit log_named_uint("fork timestamp", block.timestamp);
    }

    /// Both captured documents verify against the production verifier; one-shot verifyCerts is
    /// logged because it is the call that does not fit Robinhood's per-tx cap.
    function testRealDocsVerify() public {
        vm.warp(IN_WINDOW);

        uint256 before = gasleft();
        NITRO.verifyCerts(usDoc);
        emit log_named_uint("verifyCerts gas (us, cold chain)", before - gasleft());
        before = gasleft();
        (bool valid, bytes32 pcr0, address signer) = NITRO.verifyAttestation(usDoc);
        emit log_named_uint("verifyAttestation gas (us, certs cached)", before - gasleft());
        assertTrue(valid);
        assertEq(pcr0, PCR0);
        assertEq(signer, US_SIGNER);

        NITRO.verifyCerts(euDoc);
        before = gasleft();
        (valid, pcr0, signer) = NITRO.verifyAttestation(euDoc);
        emit log_named_uint("verifyAttestation gas (eu, certs cached)", before - gasleft());
        assertTrue(valid);
        assertEq(pcr0, PCR0);
        assertEq(signer, EU_SIGNER);
    }

    /// registerEnclave admits both real signers and rejects a re-registration.
    function testRegisterEnclaveWithRealDocs() public {
        vm.warp(IN_WINDOW);
        KskdEntry entry = _deployEntry(PCR0);

        NITRO.verifyCerts(usDoc);
        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.EnclaveRegistered(US_SIGNER);
        vm.prank(owner);
        entry.registerEnclave(usDoc);
        assertTrue(entry.validSigner(US_SIGNER));
        assertEq(entry.signerCount(), 1);

        NITRO.verifyCerts(euDoc);
        vm.prank(owner);
        entry.registerEnclave(euDoc);
        assertTrue(entry.validSigner(EU_SIGNER));
        assertEq(entry.signerCount(), 2);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.SignerAlreadyRegistered.selector, US_SIGNER));
        entry.registerEnclave(usDoc);
        assertEq(entry.signerCount(), 2);
    }

    /// A valid document of the wrong image is rejected by the entry, not the NITRO.
    function testRegisterEnclaveRejectsWrongPCR0() public {
        vm.warp(IN_WINDOW);
        KskdEntry entry = _deployEntry(bytes32(uint256(1)));

        NITRO.verifyCerts(usDoc);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.PCR0Mismatch.selector, PCR0, bytes32(uint256(1))));
        entry.registerEnclave(usDoc);
    }

    /// Past the leaf certificate's notAfter the verifier rejects the document; the same bytes pass
    /// inside the window.
    function testStaleDocRejectedThenAcceptedInWindow() public {
        KskdEntry entry = _deployEntry(PCR0);

        // Marlin's CertManager uses a string revert; the entry bubbles it verbatim.
        bytes memory expired = abi.encodeWithSignature("Error(string)", "certificate not valid anymore");

        vm.warp(PAST_LEAF_EXPIRY);
        vm.expectRevert(expired);
        NITRO.verifyCerts(usDoc);

        vm.expectRevert(expired);
        NITRO.verifyAttestation(usDoc);

        vm.prank(owner);
        vm.expectRevert(expired);
        entry.registerEnclave(usDoc);

        vm.warp(IN_WINDOW);
        NITRO.verifyCerts(usDoc);
        (bool valid,, address signer) = NITRO.verifyAttestation(usDoc);
        assertTrue(valid);
        assertEq(signer, US_SIGNER);

        vm.prank(owner);
        entry.registerEnclave(usDoc);
        assertEq(entry.signerCount(), 1);
    }

    /// The owner rotates the pinned image: the same real document is refused before `setExpectedPcr0`
    /// and admitted after.
    function testSetExpectedPcr0RotatesTheAcceptedImage() public {
        vm.warp(IN_WINDOW);
        bytes32 wrong = keccak256("not-the-pontifex-image");
        KskdEntry entry = _deployEntry(wrong);

        NITRO.verifyCerts(usDoc);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.PCR0Mismatch.selector, PCR0, wrong));
        entry.registerEnclave(usDoc);
        assertEq(entry.signerCount(), 0);

        vm.expectEmit(false, false, false, true, address(entry));
        emit KskdEntry.ExpectedPcr0Set(PCR0);
        vm.prank(owner);
        entry.setExpectedPcr0(PCR0);
        assertEq(entry.expectedPcr0(), PCR0);

        vm.prank(owner);
        entry.registerEnclave(usDoc);
        assertTrue(entry.validSigner(US_SIGNER));
        assertEq(entry.signerCount(), 1);
    }

    /// Both fixture signers are live on KaskadPriceOracle.
    function testLiveOracleKnowsBothSigners() public view {
        assertTrue(IKaskadPriceOracle(PRICE_ORACLE).isValidSigner(US_SIGNER));
        assertTrue(IKaskadPriceOracle(PRICE_ORACLE).isValidSigner(EU_SIGNER));
    }

    /// Once the chain is cached the verifier accepts the document forever: cached certs skip the
    /// notAfter check and MAX_ATTESTATION_AGE compares a millisecond field to block.timestamp.
    function testCachedCertsMakeDocReplayableAfterExpiry() public {
        vm.warp(IN_WINDOW);
        NITRO.verifyCerts(usDoc);

        vm.warp(CAPTURED_AT + 365 days);
        (bool valid, bytes32 pcr0, address signer) = NITRO.verifyAttestation(usDoc);
        assertTrue(valid, "stale doc rejected once its chain is cached");
        assertEq(pcr0, PCR0);
        assertEq(signer, US_SIGNER);

        KskdEntry entry = _deployEntry(PCR0);
        vm.prank(owner);
        entry.registerEnclave(usDoc);
        assertEq(entry.signerCount(), 1);
    }

    /// Warming the chain one certificate at a time fits Robinhood's per-tx gas cap, and the
    /// document then registers without any verifyCerts call.
    function testPerCertWarmupFitsRobinhoodTxGasCap() public {
        vm.warp(IN_WINDOW);
        ICertManager certManager = NITRO.nitroProver().certManager();
        bytes[] memory certs = _certFixture();
        assertGt(certs.length, 0, "no certificates in the fixture");

        bytes32 parentHash = certManager.ROOT_CA_CERT_HASH();
        assertGt(certManager.certPubKey(parentHash).length, 0, "root CA not cached");

        uint256 warmed;
        for (uint256 i = 0; i < certs.length; i++) {
            bytes32 certHash = keccak256(certs[i]);
            if (certManager.certPubKey(certHash).length == 0) {
                uint256 before = gasleft();
                certManager.verifyCert(certs[i], parentHash);
                uint256 used = before - gasleft();
                emit log_named_uint(string.concat("verifyCert gas, cert ", vm.toString(i)), used);
                assertLt(used, GAS_BUDGET, "per-cert warm-up exceeds the Robinhood tx gas cap");
                warmed++;
            } else {
                emit log_named_uint("certificate already cached on the live CertManager", i);
            }
            assertGt(certManager.certPubKey(certHash).length, 0, "certificate not cached after verifyCert");
            parentHash = certHash;
        }
        emit log_named_uint("certificates warmed this run", warmed);

        (bool valid, bytes32 pcr0, address signer) = NITRO.verifyAttestation(usDoc);
        assertTrue(valid, "document invalid after a per-certificate warm-up");
        assertEq(pcr0, PCR0, "pcr0 after warm-up");
        assertEq(signer, US_SIGNER, "signer after warm-up");

        vm.expectRevert(bytes("VC2"));
        NITRO.verifyCerts(usDoc);

        KskdEntry entry = _deployEntry(PCR0);
        vm.prank(owner);
        uint256 gasBefore = gasleft();
        entry.registerEnclave(usDoc);
        uint256 registerGas = gasBefore - gasleft();
        emit log_named_uint("registerEnclave gas (chain warmed)", registerGas);
        assertLt(registerGas, GAS_BUDGET, "registerEnclave exceeds the Robinhood tx gas cap");
        assertTrue(entry.validSigner(US_SIGNER), "US signer not registered");
        assertEq(entry.signerCount(), 1, "signerCount");
    }

    /// @dev Token is constructed pointing at the entry's predicted address, as in production.
    function _deployEntry(bytes32 pcr0) internal returns (KskdEntry entry) {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        KskdBridged token = new KskdBridged(predicted, owner);
        entry = new KskdEntry(address(token), VERIFIER, pcr0, THRESHOLD, MINT_LIMIT, owner);
        assertEq(address(entry), predicted, "entry address mispredicted");
        assertEq(token.bridge(), address(entry), "token bridge");
    }

    function _hexFixture(string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(string.concat("0x", vm.trim(vm.readFile(string.concat("test/fixtures/", name)))));
    }

    /// The document's CA bundle without the root, then the leaf, in verification order.
    function _certFixture() internal view returns (bytes[] memory out) {
        string[] memory parts = vm.split(vm.trim(vm.readFile("test/fixtures/attestation-us.certs")), ",");
        out = new bytes[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            out[i] = vm.parseBytes(vm.trim(parts[i]));
        }
    }
}
