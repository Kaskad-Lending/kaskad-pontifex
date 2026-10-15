// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {KskdBridged} from "../../src/KskdBridged.sol";
import {KskdEntry} from "../../src/KskdEntry.sol";
import {StubAttestationVerifier} from "../doubles/StubAttestationVerifier.sol";

/// @notice Execution gas of every `claim` path, against the Robinhood 32,000,000 per-transaction cap.
contract ClaimGasTest is Test {
    /// Widest measured path plus headroom; a regression past this is a design change, not noise.
    uint256 internal constant CEILING = 150_000;

    bytes32 constant PCR0 = keccak256("pontifex-enclave-image");
    bytes32 constant CLAIM_TYPEHASH = keccak256("Claim(address recipient,uint256 cumulativeBurned,uint256 deadline)");
    address owner = makeAddr("owner");
    KskdBridged token;
    KskdEntry entry;
    address[3] sg;
    uint256[3] kk;

    function _sorted() internal {
        (address a, uint256 ka) = makeAddrAndKey("enclaveA");
        (address b, uint256 kb) = makeAddrAndKey("enclaveB");
        (address c, uint256 kc) = makeAddrAndKey("enclaveC");
        sg = [a, b, c];
        kk = [ka, kb, kc];
        for (uint256 i = 1; i < 3; i++) {
            for (uint256 j = i; j > 0 && sg[j] < sg[j - 1]; j--) {
                (sg[j], sg[j - 1]) = (sg[j - 1], sg[j]);
                (kk[j], kk[j - 1]) = (kk[j - 1], kk[j]);
            }
        }
    }

    function _digest(address r, uint256 c, uint256 d) internal view returns (bytes32) {
        bytes32 dom = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Pontifex"),
                keccak256("1"),
                block.chainid,
                address(entry)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", dom, keccak256(abi.encode(CLAIM_TYPEHASH, r, c, d))));
    }

    function _s(uint256 n, address r, uint256 c, uint256 d) internal view returns (bytes[] memory o) {
        o = new bytes[](n);
        for (uint256 i = 0; i < n; i++) {
            (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(kk[i], _digest(r, c, d));
            o[i] = abi.encodePacked(rr, ss, v);
        }
    }

    function _deploy(uint256 t) internal {
        StubAttestationVerifier ver = new StubAttestationVerifier();
        token = new KskdBridged(address(0), owner);
        entry = new KskdEntry(address(token), address(ver), PCR0, t, 1e27, owner);
        vm.startPrank(owner);
        token.setBridge(address(entry));
        for (uint256 i = 0; i < t; i++) {
            entry.registerEnclave(abi.encode(true, PCR0, sg[i]));
        }
        vm.stopPrank();
    }

    function _go(uint256 n, address r, uint256 c, uint256 d) internal returns (uint256 used) {
        bytes[] memory s = _s(n, r, c, d);
        uint256 g = gasleft();
        entry.claim(r, c, d, s);
        used = g - gasleft();
        assertLt(used, CEILING);
    }

    function test_EveryClaimPathIsFarUnderTheRobinhoodGasCap() public {
        vm.warp(1_700_000_000);
        _sorted();
        uint256 d = block.timestamp + 365 days;
        address a = makeAddr("a");
        address b = makeAddr("b");

        _deploy(1);
        emit log_named_uint("1 first claim of the deployment", _go(1, a, 1 ether, d));
        emit log_named_uint("2 same recipient again", _go(1, a, 2 ether, d));
        emit log_named_uint("3 fresh recipient, warm window, threshold 1", _go(1, b, 1 ether, d));
        vm.warp(block.timestamp + 1 days);
        emit log_named_uint("6 first claim of a new window, known recipient", _go(1, a, 3 ether, d));

        _deploy(2);
        _go(2, a, 1 ether, d);
        emit log_named_uint("4 fresh recipient, warm window, threshold 2", _go(2, b, 1 ether, d));

        _deploy(3);
        _go(3, a, 1 ether, d);
        emit log_named_uint("5 fresh recipient, warm window, threshold 3", _go(3, b, 1 ether, d));
    }
}
