// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {KskdBridged} from "../src/KskdBridged.sol";
import {KskdEntry} from "../src/KskdEntry.sol";
import {SetBridge} from "../script/SetBridge.s.sol";
import {SetExpectedPcr0} from "../script/SetExpectedPcr0.s.sol";
import {SetGuardian} from "../script/SetGuardian.s.sol";
import {Operation, SafeScript, SafeTx} from "../script/SafeScript.sol";
import {SafeDouble} from "./doubles/SafeDouble.sol";
import {StubAttestationVerifier} from "./doubles/StubAttestationVerifier.sol";

/// @notice Safe mode of SetGuardian, SetExpectedPcr0 and SetBridge: a Safe-owned target gets the Safe tx.
contract SafeModeScriptsTest is Test {
    bytes32 private constant PCR0 = bytes32(uint256(1));
    bytes32 private constant NEW_PCR0 = keccak256("new image");
    uint256 private constant MINT_LIMIT = 25_000_000 ether;
    address private constant GUARDIAN = 0x217714D086f7254940a46c0C6Abc1e7bF270235e;

    SafeDouble private safe;
    KskdBridged private token;
    KskdEntry private entry;

    function setUp() public {
        vm.chainId(4663);
        safe = new SafeDouble(3);
        token = new KskdBridged(address(0), address(safe));
        entry =
            new KskdEntry(address(token), address(new StubAttestationVerifier()), PCR0, 1, MINT_LIMIT, address(safe));
    }

    /// setGuardian goes out as a Call from the owner Safe at the given nonce.
    function testSetGuardianSafeMode() public {
        SafeTx memory t = new SetGuardian().safeMode(entry, GUARDIAN, 2);
        bytes memory data = abi.encodeCall(KskdEntry.setGuardian, (GUARDIAN));

        assertEq(t.safe, address(safe));
        assertEq(t.to, address(entry));
        assertEq(t.data, data);
        assertEq(uint8(t.operation), uint8(Operation.Call));
        assertEq(t.nonce, 2);
        assertEq(
            t.safeTxHash,
            safe.getTransactionHash(address(entry), 0, data, Operation.Call, 0, 0, 0, address(0), address(0), 2)
        );
        assertEq(entry.guardian(), GUARDIAN);
    }

    /// The zero guardian is refused before anything is prepared.
    function testSetGuardianSafeModeRejectsZero() public {
        SetGuardian script = new SetGuardian();
        vm.expectRevert(SetGuardian.ZeroGuardian.selector);
        script.safeMode(entry, address(0), 0);
    }

    /// An EOA owner is not prepared as a Safe.
    function testSafeModeRejectsEoaOwner() public {
        address eoa = makeAddr("eoaOwner");
        KskdEntry eoaEntry =
            new KskdEntry(address(token), address(new StubAttestationVerifier()), PCR0, 1, MINT_LIMIT, eoa);
        SetGuardian script = new SetGuardian();
        vm.expectRevert(abi.encodeWithSelector(SafeScript.NotAContract.selector, eoa));
        script.safeMode(eoaEntry, GUARDIAN, 0);
    }

    /// setExpectedPcr0 goes out as a Call from the owner Safe.
    function testSetExpectedPcr0SafeMode() public {
        SafeTx memory t = new SetExpectedPcr0().safeMode(entry, NEW_PCR0, 0);
        assertEq(t.to, address(entry));
        assertEq(t.data, abi.encodeCall(KskdEntry.setExpectedPcr0, (NEW_PCR0)));
        assertEq(entry.expectedPcr0(), NEW_PCR0);
    }

    /// A zero PCR0 is refused before anything is prepared.
    function testSetExpectedPcr0SafeModeRejectsZero() public {
        SetExpectedPcr0 script = new SetExpectedPcr0();
        vm.expectRevert(SetExpectedPcr0.ZeroPcr0.selector);
        script.safeMode(entry, bytes32(0), 0);
    }

    /// setBridge goes out as a Call from the token's owner Safe.
    function testSetBridgeSafeMode() public {
        SafeTx memory t = new SetBridge().safeMode(token, address(entry), 0);
        assertEq(t.safe, address(safe));
        assertEq(t.to, address(token));
        assertEq(t.data, abi.encodeCall(KskdBridged.setBridge, (address(entry))));
        assertEq(token.bridge(), address(entry));
    }
}
