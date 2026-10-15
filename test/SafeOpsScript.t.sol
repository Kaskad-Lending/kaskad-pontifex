// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Fixtures} from "./Fixtures.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {KskdBridged} from "../src/KskdBridged.sol";
import {KskdEntry} from "../src/KskdEntry.sol";
import {KskdExit} from "../src/KskdExit.sol";
import {SafeOps} from "../script/SafeOps.s.sol";
import {IMultiSendCallOnly, Operation, SafeCall, SafeScript, SafeTx} from "../script/SafeScript.sol";
import {KSKD} from "./fixtures/KSKD.sol";
import {SafeDouble} from "./doubles/SafeDouble.sol";
import {StubAttestationVerifier} from "./doubles/StubAttestationVerifier.sol";

/// @notice Each SafeOps entry point: the Safe it resolves, the calldata, and the dry-run effect.
contract SafeOpsScriptTest is Fixtures {
    address private constant MULTISEND_141 = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address private constant MULTISEND_150 = 0xA83c336B20401Af773B6219BA5027174338D1836;
    bytes32 private constant PCR0 = bytes32(uint256(1));
    uint256 private constant MINT_LIMIT = 25_000_000 ether;
    uint256 private constant TRANCHE = 100 ether;

    SafeOps private ops;
    SafeDouble private safe;
    StubAttestationVerifier private stub;
    KskdBridged private token;
    KskdEntry private entry;
    address private recipient = makeAddr("robinhoodRecipient");

    function setUp() public {
        vm.chainId(46630);
        vm.etch(MULTISEND_141, _fixture("multisend-call-only-1.4.1.hex"));
        vm.etch(MULTISEND_150, _fixture("multisend-call-only-1.5.0.hex"));
        ops = new SafeOps();
        safe = new SafeDouble(3);
        stub = new StubAttestationVerifier();
        token = new KskdBridged(address(0), address(safe));
        entry = new KskdEntry(address(token), address(stub), PCR0, 1, MINT_LIMIT, address(safe));
    }

    /// setMintLimit is a Call from the entry owner.
    function testSetMintLimit() public {
        SafeTx memory t = ops.setMintLimit(entry, 7);
        assertEq(t.safe, address(safe));
        assertEq(t.to, address(entry));
        assertEq(t.data, abi.encodeCall(KskdEntry.setMintLimit, (7)));
        assertEq(uint8(t.operation), uint8(Operation.Call));
        assertEq(entry.mintLimit(), 7);
    }

    /// setThreshold dry-runs against the live signer count.
    function testSetThreshold() public {
        _register(address(0xA));
        _register(address(0xB));
        ops.setThreshold(entry, 2);
        assertEq(entry.threshold(), 2);
    }

    /// A threshold above the signer count surfaces the entry's own error.
    function testSetThresholdAboveSignerCountReverts() public {
        bytes memory reason = abi.encodeWithSelector(KskdEntry.ThresholdAboveSignerCount.selector, 2, 0);
        vm.expectRevert(abi.encodeWithSelector(SafeScript.SafeCallReverts.selector, 0, reason));
        ops.setThreshold(entry, 2);
    }

    /// removeSigner drops the signer.
    function testRemoveSigner() public {
        _register(address(0xA));
        ops.removeSigner(entry, address(0xA));
        assertFalse(entry.validSigner(address(0xA)));
        assertEq(entry.signerCount(), 0);
    }

    /// transferOwnership starts the handover to another Safe.
    function testTransferOwnershipToSafe() public {
        SafeDouble next = new SafeDouble(3);
        SafeTx memory t = ops.transferOwnership(Ownable2Step(address(entry)), address(next));
        assertEq(t.safe, address(safe));
        assertEq(entry.pendingOwner(), address(next));
    }

    /// On Robinhood mainnet a new owner without code is refused.
    function testTransferOwnershipToEoaRefusedOnMainnet() public {
        vm.chainId(4663);
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(SafeScript.NotAContract.selector, eoa));
        ops.transferOwnership(Ownable2Step(address(token)), eoa);
    }

    /// acceptOwnership is prepared for the pending owner's Safe.
    function testAcceptOwnershipFromPendingSafe() public {
        SafeDouble next = new SafeDouble(3);
        vm.prank(address(safe));
        token.transferOwnership(address(next));

        SafeTx memory t = ops.acceptOwnership(Ownable2Step(address(token)));
        assertEq(t.safe, address(next));
        assertEq(t.data, abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        assertEq(token.owner(), address(next));
    }

    /// acceptOwnership needs a pending owner.
    function testAcceptOwnershipWithoutPendingOwnerReverts() public {
        vm.expectRevert(abi.encodeWithSelector(SafeOps.NoPendingOwner.selector, address(entry)));
        ops.acceptOwnership(Ownable2Step(address(entry)));
    }

    /// Robinhood operations refuse an Igra chain id.
    function testRobinhoodOpsRefuseIgra() public {
        vm.chainId(38833);
        vm.expectRevert(abi.encodeWithSelector(SafeOps.WrongChain.selector, 38833));
        ops.setMintLimit(entry, 7);
    }

    /// setMinBurn is a Call from CLOSER.
    function testSetMinBurn() public {
        (, KskdExit exit) = _igra(address(safe), type(uint256).max);
        SafeTx memory t = ops.setMinBurn(exit, 1000 ether);
        assertEq(t.safe, address(safe));
        assertEq(t.data, abi.encodeCall(KskdExit.setMinBurn, (1000 ether)));
        assertEq(exit.minBurn(), 1000 ether);
    }

    /// close is a Call from CLOSER.
    function testClose() public {
        (, KskdExit exit) = _igra(address(safe), 0);
        ops.close(exit);
        assertTrue(exit.closed());
    }

    /// Igra operations refuse a Robinhood chain id.
    function testIgraOpsRefuseRobinhood() public {
        (, KskdExit exit) = _igra(address(safe), 0);
        vm.chainId(46630);
        vm.expectRevert(abi.encodeWithSelector(SafeOps.WrongChain.selector, 46630));
        ops.close(exit);
    }

    /// At or above the floor the tranche is approve + exit.
    function testTreasuryExitAboveFloor() public {
        (KSKD kskd, KskdExit exit) = _igra(address(safe), 0);
        SafeTx memory t = ops.treasuryExit(address(safe), exit, TRANCHE, recipient);

        SafeCall[] memory calls = new SafeCall[](2);
        calls[0] = SafeCall({to: address(kskd), data: abi.encodeCall(IERC20.approve, (address(exit), TRANCHE))});
        calls[1] = SafeCall({to: address(exit), data: abi.encodeCall(KskdExit.exit, (TRANCHE, recipient))});
        assertEq(t.to, MULTISEND_150);
        assertEq(uint8(t.operation), uint8(Operation.DelegateCall));
        assertEq(t.data, abi.encodeCall(IMultiSendCallOnly.multiSend, (ops.encodeMultiSend(calls))));
        assertEq(exit.burned(recipient), TRANCHE);
    }

    /// Below the floor, CLOSER's tranche lowers minBurn for the batch and restores it; the Safe executes it.
    function testTreasuryExitLiftsAndRestoresFloor() public {
        (KSKD kskd, KskdExit exit) = _igra(address(safe), type(uint256).max);
        uint256 clean = vm.snapshotState();
        SafeTx memory t = ops.treasuryExit(address(safe), exit, TRANCHE, recipient);
        assertEq(exit.burned(recipient), TRANCHE);
        assertEq(exit.minBurn(), type(uint256).max);
        vm.revertToState(clean);

        uint256 supply = kskd.totalSupply();
        safe.exec(t.to, t.data, t.operation);
        assertEq(exit.burned(recipient), TRANCHE);
        assertEq(exit.minBurn(), type(uint256).max);
        assertEq(kskd.totalSupply(), supply - TRANCHE);
        assertEq(kskd.allowance(address(safe), address(exit)), 0);
    }

    /// Below the floor a Safe that is not CLOSER cannot exit.
    function testTreasuryExitBelowFloorFromNonCloserReverts() public {
        (, KskdExit exit) = _igra(makeAddr("closer"), 1000 ether);
        bytes memory reason = abi.encodeWithSelector(KskdExit.BelowMinBurn.selector, TRANCHE, 1000 ether);
        vm.expectRevert(abi.encodeWithSelector(SafeScript.SafeCallReverts.selector, 1, reason));
        ops.treasuryExit(address(safe), exit, TRANCHE, recipient);
    }

    /// batch with one pair is a plain Call.
    function testBatchSinglePairIsCall() public {
        address[] memory targets = new address[](1);
        bytes[] memory datas = new bytes[](1);
        (targets[0], datas[0]) = (address(entry), abi.encodeCall(KskdEntry.setMintLimit, (7)));
        SafeTx memory t = ops.batch(address(safe), targets, datas);
        assertEq(uint8(t.operation), uint8(Operation.Call));
        assertEq(t.to, address(entry));
    }

    /// batch refuses mismatched arrays.
    function testBatchLengthMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(SafeOps.LengthMismatch.selector, 2, 1));
        ops.batch(address(safe), new address[](2), new bytes[](1));
    }

    function _register(address signer) private {
        bytes memory doc = stub.encode(true, PCR0, signer);
        vm.prank(address(safe));
        entry.registerEnclave(doc);
    }

    /// @dev KSKD minted to the Safe and an exit with the given CLOSER and floor, on Igra mainnet's chain id.
    function _igra(address closer, uint256 minBurn) private returns (KSKD kskd, KskdExit exit) {
        vm.chainId(38833);
        kskd = new KSKD(address(safe));
        exit = new KskdExit(address(kskd), closer, minBurn);
    }
}
