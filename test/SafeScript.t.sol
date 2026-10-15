// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Fixtures} from "./Fixtures.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KskdBridged} from "../src/KskdBridged.sol";
import {KskdEntry} from "../src/KskdEntry.sol";
import {SafeOps} from "../script/SafeOps.s.sol";
import {IMultiSendCallOnly, Operation, SafeCall, SafeScript, SafeTx} from "../script/SafeScript.sol";
import {SafeDouble} from "./doubles/SafeDouble.sol";
import {StubAttestationVerifier} from "./doubles/StubAttestationVerifier.sol";

/// @notice SafeScript through SafeOps: Safe detection, nonce, hashing, one call vs a MultiSendCallOnly batch.
contract SafeScriptTest is Fixtures {
    address private constant MULTISEND_141 = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address private constant MULTISEND_150 = 0xA83c336B20401Af773B6219BA5027174338D1836;
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
        0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;
    bytes32 private constant SAFE_TX_TYPEHASH = 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;
    bytes32 private constant PCR0 = bytes32(uint256(1));
    uint256 private constant MINT_LIMIT = 25_000_000 ether;
    address private constant GUARDIAN = address(0x6A2D);

    SafeOps private ops;
    SafeDouble private safe;
    KskdEntry private entry;

    function setUp() public {
        vm.chainId(46630);
        vm.etch(MULTISEND_141, _fixture("multisend-call-only-1.4.1.hex"));
        ops = new SafeOps();
        safe = new SafeDouble(3);
        KskdBridged token = new KskdBridged(address(0), address(safe));
        entry =
            new KskdEntry(address(token), address(new StubAttestationVerifier()), PCR0, 1, MINT_LIMIT, address(safe));
    }

    /// A codeless owner is not a Safe.
    function testRequireSafeRejectsCodelessAccount() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(SafeScript.NotAContract.selector, eoa));
        ops.requireSafe(eoa);
    }

    /// A contract without `getThreshold` is not a Safe.
    function testRequireSafeRejectsOtherContract() public {
        vm.expectRevert(abi.encodeWithSelector(SafeScript.NotASafe.selector, address(entry)));
        ops.requireSafe(address(entry));
    }

    /// A 1-of-n Safe is refused.
    function testRequireSafeRejectsThresholdOne() public {
        SafeDouble single = new SafeDouble(1);
        vm.expectRevert(abi.encodeWithSelector(SafeScript.SafeThresholdTooLow.selector, address(single), 1));
        ops.requireSafe(address(single));
    }

    /// A 2-of-n Safe passes.
    function testRequireSafeAcceptsThresholdTwo() public {
        ops.requireSafe(address(new SafeDouble(2)));
    }

    /// One call is a plain Call at value 0, dry-run from the Safe.
    function testSingleCallIsPlainCall() public {
        bytes memory data = abi.encodeCall(KskdEntry.setMintLimit, (7));
        SafeTx memory t = ops.prepare(address(safe), _calls(address(entry), data), 0);

        assertEq(t.safe, address(safe));
        assertEq(t.to, address(entry));
        assertEq(t.value, 0);
        assertEq(t.data, data);
        assertEq(uint8(t.operation), uint8(Operation.Call));
        assertEq(t.nonce, 0);
        assertEq(entry.mintLimit(), 7);
    }

    /// safeTxHash is the Safe's EIP-712 hash of (to, 0, data, op, zero refund fields, nonce).
    function testHashIsSafeEip712() public {
        bytes memory data = abi.encodeCall(KskdEntry.setGuardian, (GUARDIAN));
        SafeTx memory t = ops.prepare(address(safe), _calls(address(entry), data), 4);

        assertEq(t.nonce, 4);
        assertEq(t.safeTxHash, _eip712(address(safe), address(entry), data, Operation.Call, 4));
    }

    /// A nonce the Safe already used is refused.
    function testStaleNonceRejected() public {
        safe.exec(address(entry), abi.encodeCall(KskdEntry.setMintLimit, (1)), Operation.Call);
        vm.expectRevert(abi.encodeWithSelector(SafeScript.StaleSafeNonce.selector, 0, 1));
        ops.prepare(address(safe), _calls(address(entry), abi.encodeCall(KskdEntry.setMintLimit, (2))), 0);
    }

    /// Several calls become one DelegateCall to MultiSendCallOnly carrying the packed calls.
    function testBatchIsDelegateCallToMultiSend() public {
        bytes memory first = abi.encodeCall(KskdEntry.setMintLimit, (7));
        bytes memory second = abi.encodeCall(KskdEntry.setGuardian, (GUARDIAN));
        SafeTx memory t = ops.prepare(address(safe), _calls(address(entry), first, address(entry), second), 0);

        bytes memory packed = abi.encodePacked(
            uint8(0),
            address(entry),
            uint256(0),
            uint256(first.length),
            first,
            uint8(0),
            address(entry),
            uint256(0),
            uint256(second.length),
            second
        );
        assertEq(t.to, MULTISEND_141);
        assertEq(uint8(t.operation), uint8(Operation.DelegateCall));
        assertEq(t.data, abi.encodeCall(IMultiSendCallOnly.multiSend, (packed)));
        assertEq(t.safeTxHash, _eip712(address(safe), MULTISEND_141, t.data, Operation.DelegateCall, 0));
    }

    /// The prepared batch, executed by the Safe through the real MultiSendCallOnly code, runs every call.
    function testBatchRunsThroughMultiSendCallOnly() public {
        uint256 clean = vm.snapshotState();
        SafeTx memory t = ops.prepare(
            address(safe),
            _calls(
                address(entry),
                abi.encodeCall(KskdEntry.setMintLimit, (7)),
                address(entry),
                abi.encodeCall(KskdEntry.setGuardian, (GUARDIAN))
            ),
            0
        );
        vm.revertToState(clean);
        assertEq(entry.mintLimit(), MINT_LIMIT);

        safe.exec(t.to, t.data, t.operation);
        assertEq(entry.mintLimit(), 7);
        assertEq(entry.guardian(), GUARDIAN);
    }

    /// Other code at the pinned MultiSendCallOnly address is refused.
    function testUnknownMultiSendRejected() public {
        vm.etch(MULTISEND_141, hex"00");
        vm.expectRevert(abi.encodeWithSelector(SafeScript.UnknownMultiSend.selector, MULTISEND_141, keccak256(hex"00")));
        ops.multiSendCallOnly();
    }

    /// Igra pins the Safe 1.5.0 MultiSendCallOnly.
    function testIgraPinsMultiSend150() public {
        vm.chainId(38833);
        vm.etch(MULTISEND_150, _fixture("multisend-call-only-1.5.0.hex"));
        assertEq(ops.multiSendCallOnly(), MULTISEND_150);
    }

    /// No MultiSendCallOnly is pinned off the bridge chains.
    function testNoMultiSendOffBridgeChains() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(SafeScript.NoMultiSend.selector, 1));
        ops.multiSendCallOnly();
    }

    /// An empty batch is refused.
    function testEmptyBatchRejected() public {
        vm.expectRevert(SafeScript.EmptyBatch.selector);
        ops.prepare(address(safe), new SafeCall[](0), 0);
    }

    /// A call to a codeless target is refused with its index.
    function testCodelessTargetRejected() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(SafeScript.TargetHasNoCode.selector, 1, eoa));
        ops.prepare(address(safe), _calls(address(entry), "", eoa, ""), 0);
    }

    /// A call that reverts from the Safe is reported with its index and reason.
    function testRevertingCallReported() public {
        SafeDouble stranger = new SafeDouble(3);
        bytes memory reason = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(stranger));
        vm.expectRevert(abi.encodeWithSelector(SafeScript.SafeCallReverts.selector, 0, reason));
        ops.prepare(address(stranger), _calls(address(entry), abi.encodeCall(KskdEntry.setMintLimit, (7))), 0);
    }

    function _calls(address to, bytes memory data) private pure returns (SafeCall[] memory calls) {
        calls = new SafeCall[](1);
        calls[0] = SafeCall({to: to, data: data});
    }

    function _calls(address to0, bytes memory data0, address to1, bytes memory data1)
        private
        pure
        returns (SafeCall[] memory calls)
    {
        calls = new SafeCall[](2);
        calls[0] = SafeCall({to: to0, data: data0});
        calls[1] = SafeCall({to: to1, data: data1});
    }

    function _eip712(address safe_, address to, bytes memory data, Operation operation, uint256 nonce_)
        private
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(abi.encode(DOMAIN_SEPARATOR_TYPEHASH, block.chainid, safe_));
        bytes32 structHash = keccak256(
            abi.encode(SAFE_TX_TYPEHASH, to, 0, keccak256(data), operation, 0, 0, 0, address(0), address(0), nonce_)
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }
}
