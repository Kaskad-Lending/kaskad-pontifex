// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Fixtures} from "./Fixtures.sol";
import {NitroDoc} from "../script/NitroDoc.sol";

contract NitroDocHarness {
    function pcr0(bytes memory doc) external pure returns (bytes32) {
        return NitroDoc.pcr0(doc);
    }
}

/// @notice PCR0 read out of Nitro attestation documents: the live fixtures and malformed variants.
contract NitroDocTest is Fixtures {
    bytes32 private constant FIXTURE_PCR0 = 0x2e66fc4f74006323675a397ab3c6b6eab68f2ccc36f4cf10bb4d0e5c82b2106c;

    NitroDocHarness private doc;

    function setUp() public {
        doc = new NitroDocHarness();
    }

    /// The US fixture's PCR0 is the first 32 of its 48 measurement bytes.
    function testUsFixturePcr0() public view {
        assertEq(doc.pcr0(_fixture("attestation-us.hex")), FIXTURE_PCR0);
    }

    /// The EU fixture carries the same image.
    function testEuFixturePcr0() public view {
        assertEq(doc.pcr0(_fixture("attestation-eu.hex")), FIXTURE_PCR0);
    }

    /// A COSE_Sign1 tag (18) in front of the document is accepted.
    function testTaggedDocument() public view {
        assertEq(doc.pcr0(bytes.concat(hex"d2", _fixture("attestation-us.hex"))), FIXTURE_PCR0);
    }

    /// A definite-length payload map with PCR0 listed after PCR1.
    function testDefiniteMapAnyPcrOrder() public view {
        bytes memory pcrs =
            bytes.concat(hex"a2", hex"01", _bstr(_measurement(0x11)), hex"00", _bstr(_measurement(0x22)));
        bytes32 expected = bytes32(_measurement(0x22));
        assertEq(
            doc.pcr0(_cose(bytes.concat(hex"a2", _tstr("module_id"), _tstr("i-1"), _tstr("pcrs"), pcrs))), expected
        );
    }

    /// A payload without `pcrs` is refused.
    function testMissingPcrsRejected() public {
        vm.expectRevert(NitroDoc.Pcr0Missing.selector);
        doc.pcr0(_cose(bytes.concat(hex"a1", _tstr("module_id"), _tstr("i-1"))));
    }

    /// A `pcrs` map without index 0 is refused.
    function testMissingPcr0Rejected() public {
        bytes memory pcrs = bytes.concat(hex"a1", hex"01", _bstr(_measurement(0x11)));
        vm.expectRevert(NitroDoc.Pcr0Missing.selector);
        doc.pcr0(_cose(bytes.concat(hex"a1", _tstr("pcrs"), pcrs)));
    }

    /// PCR0 must be a 48-byte SHA-384 measurement.
    function testShortPcr0Rejected() public {
        bytes memory pcrs = bytes.concat(hex"a1", hex"00", _bstr(new bytes(32)));
        vm.expectRevert(abi.encodeWithSelector(NitroDoc.BadPcr0Length.selector, 32));
        doc.pcr0(_cose(bytes.concat(hex"a1", _tstr("pcrs"), pcrs)));
    }

    /// A document cut inside its payload is refused.
    function testTruncatedDocumentRejected() public {
        bytes memory full = _fixture("attestation-us.hex");
        bytes memory cut = new bytes(200);
        for (uint256 i = 0; i < cut.length; i++) {
            cut[i] = full[i];
        }
        vm.expectPartialRevert(NitroDoc.MalformedDoc.selector);
        doc.pcr0(cut);
    }

    /// Anything but a 4-element COSE_Sign1 array is refused.
    function testNonCoseRejected() public {
        vm.expectRevert(abi.encodeWithSelector(NitroDoc.MalformedDoc.selector, 0));
        doc.pcr0(hex"a0");
    }

    /// @dev COSE_Sign1 around `payload`: protected {1: -35}, empty unprotected, 96-byte signature.
    function _cose(bytes memory payload) private pure returns (bytes memory) {
        return bytes.concat(hex"84", _bstr(hex"a1013822"), hex"a0", _bstr(payload), _bstr(new bytes(96)));
    }

    function _measurement(uint8 fill) private pure returns (bytes memory m) {
        m = new bytes(48);
        for (uint256 i = 0; i < m.length; i++) {
            m[i] = bytes1(fill);
        }
    }

    function _bstr(bytes memory b) private pure returns (bytes memory) {
        return bytes.concat(_head(2, b.length), b);
    }

    function _tstr(string memory s) private pure returns (bytes memory) {
        return bytes.concat(_head(3, bytes(s).length), bytes(s));
    }

    /// @dev Head of a string of `length` < 65536 bytes; major type `major` (2 or 3) fits the top 3 bits.
    function _head(uint8 major, uint256 length) private pure returns (bytes memory) {
        if (length < 24) return abi.encodePacked(bytes1(bytes32((uint256(major) << 5 | length) << 248)));
        if (length < 256) {
            return abi.encodePacked(bytes1(bytes32((uint256(major) << 5 | 24) << 248)), bytes1(bytes32(length << 248)));
        }
        return abi.encodePacked(bytes1(bytes32((uint256(major) << 5 | 25) << 248)), bytes2(bytes32(length << 240)));
    }
}
