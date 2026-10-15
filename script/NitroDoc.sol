// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

/// @notice Reads PCR0 out of a Nitro attestation document (COSE_Sign1 over a CBOR map) without
///         verifying it, so a wrong image is caught before any certificate work. The verifier
///         stays the authority: this is a preflight, not a check of the document's signature.
library NitroDoc {
    /// @notice CBOR major types, RFC 8949 §3.1.
    enum Major {
        Uint,
        NegInt,
        Bytes,
        Text,
        Array,
        Map,
        Tag,
        Simple
    }

    error MalformedDoc(uint256 offset);
    error Pcr0Missing();
    error BadPcr0Length(uint256 length);

    uint8 private constant BREAK = 0xff;
    uint256 private constant PCR0_LENGTH = 48;

    /// @notice First 32 of the 48 PCR0 bytes, the value `KskdEntry.expectedPcr0` pins.
    function pcr0(bytes memory doc) internal pure returns (bytes32) {
        uint256 i = 0;
        (Major major,, bool indefinite, uint256 next) = _head(doc, 0);
        if (major == Major.Tag && !indefinite) i = next; // optional COSE_Sign1 tag 18
        (uint256 items, uint256 at) = _expect(doc, i, Major.Array);
        if (items != 4) revert MalformedDoc(i);
        at = _skip(doc, at); // protected header
        at = _skip(doc, at); // unprotected header
        (uint256 length, uint256 payload) = _expect(doc, at, Major.Bytes);
        return _pcr0InPayload(_slice(doc, payload, length));
    }

    function _pcr0InPayload(bytes memory p) private pure returns (bytes32) {
        (Major major, uint256 count, bool indefinite, uint256 i) = _head(p, 0);
        if (major != Major.Map) revert MalformedDoc(0);
        for (uint256 k = 0; indefinite ? !_isBreak(p, i) : k < count; k++) {
            (Major keyMajor, uint256 keyLength,, uint256 key) = _head(p, i);
            bool isPcrs = keyMajor == Major.Text && keyLength == 4 && keccak256(_slice(p, key, 4)) == keccak256("pcrs");
            i = _skip(p, i);
            if (isPcrs) return _pcr0InPcrs(p, i);
            i = _skip(p, i);
        }
        revert Pcr0Missing();
    }

    /// @dev `pcrs` is a map of uint index → bstr measurement.
    function _pcr0InPcrs(bytes memory p, uint256 i) private pure returns (bytes32) {
        (Major major, uint256 count, bool indefinite, uint256 next) = _head(p, i);
        if (major != Major.Map) revert MalformedDoc(i);
        for (uint256 k = 0; indefinite ? !_isBreak(p, next) : k < count; k++) {
            (uint256 index, uint256 value) = _expect(p, next, Major.Uint);
            (uint256 length, uint256 data) = _expect(p, value, Major.Bytes);
            if (index == 0) {
                if (length != PCR0_LENGTH) revert BadPcr0Length(length);
                return bytes32(_slice(p, data, 32));
            }
            next = _advance(p, data, length);
        }
        revert Pcr0Missing();
    }

    /// @dev Argument and offset after the head of a definite-length item of type `want`.
    function _expect(bytes memory b, uint256 i, Major want) private pure returns (uint256 arg, uint256 next) {
        Major major;
        bool indefinite;
        (major, arg, indefinite, next) = _head(b, i);
        if (major != want || indefinite) revert MalformedDoc(i);
    }

    /// @dev Offset just past the item starting at `i`.
    function _skip(bytes memory b, uint256 i) private pure returns (uint256) {
        (Major major, uint256 arg, bool indefinite, uint256 next) = _head(b, i);
        if (major == Major.Bytes || major == Major.Text) {
            if (indefinite) revert MalformedDoc(i); // chunked strings: never emitted by the NSM
            return _advance(b, next, arg);
        }
        if (major == Major.Array || major == Major.Map) {
            if (indefinite) {
                while (!_isBreak(b, next)) {
                    next = _skip(b, next);
                }
                return next + 1;
            }
            uint256 items = major == Major.Map ? arg * 2 : arg;
            for (uint256 k = 0; k < items; k++) {
                next = _skip(b, next);
            }
            return next;
        }
        if (indefinite) revert MalformedDoc(i); // info 31 on a tag, an integer or a stray break
        if (major == Major.Tag) return _skip(b, next);
        return next;
    }

    /// @dev Initial byte + argument. `indefinite` marks additional info 31.
    function _head(bytes memory b, uint256 i)
        private
        pure
        returns (Major major, uint256 arg, bool indefinite, uint256 next)
    {
        if (i >= b.length) revert MalformedDoc(i);
        uint8 initial = uint8(b[i]);
        major = Major(initial >> 5);
        uint8 info = initial & 0x1f;
        next = i + 1;
        if (info < 24) {
            arg = info;
        } else if (info <= 27) {
            uint256 size = 2 ** (info - 24);
            if (size > b.length - next) revert MalformedDoc(i);
            for (uint256 k = 0; k < size; k++) {
                arg = (arg << 8) | uint8(b[next + k]);
            }
            next += size;
        } else if (info == 31) {
            indefinite = true;
        } else {
            revert MalformedDoc(i);
        }
    }

    function _isBreak(bytes memory b, uint256 i) private pure returns (bool) {
        if (i >= b.length) revert MalformedDoc(i);
        return uint8(b[i]) == BREAK;
    }

    function _advance(bytes memory b, uint256 i, uint256 length) private pure returns (uint256) {
        if (length > b.length - i) revert MalformedDoc(i);
        return i + length;
    }

    function _slice(bytes memory b, uint256 i, uint256 length) private pure returns (bytes memory out) {
        _advance(b, i, length);
        out = new bytes(length);
        for (uint256 k = 0; k < length; k++) {
            out[k] = b[i + k];
        }
    }
}
