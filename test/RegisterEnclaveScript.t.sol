// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Fixtures} from "./Fixtures.sol";
import {RegisterEnclave} from "../script/RegisterEnclave.s.sol";
import {Operation} from "../script/SafeScript.sol";
import {KskdBridged} from "../src/KskdBridged.sol";
import {KskdEntry} from "../src/KskdEntry.sol";
import {SafeDouble} from "./doubles/SafeDouble.sol";
import {StubAttestationVerifier} from "./doubles/StubAttestationVerifier.sol";
import {CertManagerDouble, NitroProverDouble, NitroVerifierV2Double} from "./doubles/NitroVerifierDoubles.sol";

/// @notice RegisterEnclave guards: no arming of an unpausable live bridge, no cert work for another image,
///         and the Safe tx for a Safe-owned entry.
contract RegisterEnclaveScriptTest is Fixtures {
    bytes32 private constant PCR0 = bytes32(uint256(1));
    bytes32 private constant FIXTURE_PCR0 = 0x2e66fc4f74006323675a397ab3c6b6eab68f2ccc36f4cf10bb4d0e5c82b2106c;
    address private constant SIGNER = 0x544705F5d72E1C6f24bFD7C2E176F2Cd2aA8Dc2A;
    uint256 private constant WARM_KEY = 0xA11CE;
    address private constant GUARDIAN = address(0x6A2D);
    uint256 private constant MINT_LIMIT = 25_000_000 ether;

    address private owner = makeAddr("owner");
    KskdBridged private token;
    KskdEntry private entry;
    RegisterEnclave private script;

    function setUp() public {
        vm.chainId(46630);
        token = new KskdBridged(address(0), owner);
        entry = new KskdEntry(address(token), address(new StubAttestationVerifier()), PCR0, 1, MINT_LIMIT, owner);
        script = new RegisterEnclave();
    }

    /// The token's live bridge without a guardian is refused before any certificate work.
    function testLiveUnguardedEntryIsRejected() public {
        vm.prank(owner);
        token.setBridge(address(entry));

        vm.expectRevert(abi.encodeWithSelector(RegisterEnclave.NoGuardian.selector, address(entry)));
        script.armingPreflight(entry);
    }

    /// The live bridge passes once a guardian is set.
    function testLiveGuardedEntryPasses() public {
        vm.startPrank(owner);
        token.setBridge(address(entry));
        entry.setGuardian(GUARDIAN);
        vm.stopPrank();

        script.armingPreflight(entry);
    }

    /// A rotation target that is not yet the bridge may register first; SetBridge checks the guardian.
    function testRotationTargetWithoutGuardianPasses() public view {
        script.armingPreflight(entry);
    }

    /// The document's own PCR0 passes when the entry pins it.
    function testImagePreflightAcceptsPinnedImage() public {
        script.imagePreflight(_entry(address(new StubAttestationVerifier()), FIXTURE_PCR0, owner), _doc());
    }

    /// A document of another image is refused with both PCR0 values.
    function testImagePreflightRejectsOtherImage() public {
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.PCR0Mismatch.selector, FIXTURE_PCR0, PCR0));
        script.imagePreflight(entry, _doc());
    }

    /// Another image is refused before the first certificate is sent to CertManager.
    function testOtherImageRejectedBeforeCertWarmUp() public {
        KskdEntry other = _entry(_verifier(new CertManagerDouble(true)), PCR0, owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.PCR0Mismatch.selector, FIXTURE_PCR0, PCR0));
        script.register(other, _doc(), _certs(), false, WARM_KEY);
    }

    /// A Safe-owned entry: certs warm, then registerEnclave is dry-run from the Safe and hashed by it.
    function testSafeOwnedEntryGetsSafeTx() public {
        CertManagerDouble certManager = new CertManagerDouble(false);
        SafeDouble safe = new SafeDouble(3);
        KskdEntry safeEntry = _entry(_verifier(certManager), FIXTURE_PCR0, address(safe));
        bytes memory data = abi.encodeCall(KskdEntry.registerEnclave, (_doc()));

        vm.expectCall(
            address(safe),
            abi.encodeCall(
                SafeDouble.getTransactionHash,
                (address(safeEntry), 0, data, Operation.Call, 0, 0, 0, address(0), address(0), 0)
            )
        );
        script.register(safeEntry, _doc(), _certs(), false, WARM_KEY);
        assertEq(certManager.verified(), 2);
        assertTrue(safeEntry.validSigner(SIGNER));
    }

    function _entry(address verifier, bytes32 pcr0, address owner_) private returns (KskdEntry) {
        return new KskdEntry(address(new KskdBridged(address(0), owner_)), verifier, pcr0, 1, MINT_LIMIT, owner_);
    }

    function _verifier(CertManagerDouble certManager) private returns (address) {
        return
            address(
                new NitroVerifierV2Double(address(new NitroProverDouble(address(certManager))), FIXTURE_PCR0, SIGNER)
            );
    }

    function _certs() private pure returns (bytes[] memory certs) {
        certs = new bytes[](2);
        (certs[0], certs[1]) = (hex"c0", hex"c1");
    }

    function _doc() private view returns (bytes memory) {
        return _fixture("attestation-us.hex");
    }
}
