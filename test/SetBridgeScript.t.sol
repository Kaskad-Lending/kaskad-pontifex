// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {SetBridge} from "../script/SetBridge.s.sol";
import {KskdBridged} from "../src/KskdBridged.sol";
import {KskdEntry} from "../src/KskdEntry.sol";
import {StubAttestationVerifier} from "./doubles/StubAttestationVerifier.sol";

/// @notice `KskdBridged.setBridge` accepts any address, so the cutover guard lives in
///         the script. These pin it. Driven through `preflight` rather than `run`: forge
///         shares one process env across concurrent suites, so env-driven cases race.
contract SetBridgeScriptTest is Test {
    uint256 private constant KEY = 0xA11CE;
    bytes32 private constant PCR0 = bytes32(uint256(1));
    address private constant OLD_BRIDGE = address(0xBEEF);
    address private constant SIGNER = address(0x5169);
    address private constant GUARDIAN = address(0x6A2D);
    uint256 private constant MINT_LIMIT = 25_000_000 ether;

    KskdBridged private token;
    StubAttestationVerifier private verifier;
    SetBridge private script;
    address private owner;

    function setUp() public {
        vm.chainId(46630);
        owner = vm.addr(KEY);
        token = new KskdBridged(OLD_BRIDGE, owner);
        verifier = new StubAttestationVerifier();
        script = new SetBridge();
    }

    function _entryFor(address token_, uint256 mintLimit) private returns (KskdEntry entry) {
        entry = _unguardedEntryFor(token_, mintLimit);
        vm.prank(owner);
        entry.setGuardian(GUARDIAN);
    }

    function _unguardedEntryFor(address token_, uint256 mintLimit) private returns (KskdEntry entry) {
        entry = new KskdEntry(token_, address(verifier), PCR0, 1, mintLimit, owner);
        vm.prank(owner);
        entry.registerEnclave(abi.encode(true, PCR0, SIGNER));
    }

    /// A claim-ready entry without a guardian is refused: nothing could pause it after the flip.
    function testUnguardedEntryIsRejected() public {
        KskdEntry entry = _unguardedEntryFor(address(token), MINT_LIMIT);

        vm.expectRevert(abi.encodeWithSelector(SetBridge.NoGuardian.selector, address(entry)));
        script.preflight(address(token), address(entry));

        assertEq(token.bridge(), OLD_BRIDGE);
    }

    /// An entry wired to a different KskdBridged is refused even when claim-ready.
    function testForeignTokenEntryIsRejected() public {
        KskdBridged foreign = new KskdBridged(OLD_BRIDGE, owner);
        KskdEntry entry = _entryFor(address(foreign), MINT_LIMIT);

        vm.expectRevert(
            abi.encodeWithSelector(SetBridge.BridgeTokenMismatch.selector, address(foreign), address(token))
        );
        script.preflight(address(token), address(entry));

        assertEq(token.bridge(), OLD_BRIDGE);
    }

    /// An entry that cannot reach quorum yet is refused.
    function testEntryBelowThresholdIsRejected() public {
        KskdEntry entry = new KskdEntry(address(token), address(verifier), PCR0, 1, MINT_LIMIT, owner);

        vm.expectRevert(abi.encodeWithSelector(SetBridge.NotClaimReady.selector, 0, 1));
        script.preflight(address(token), address(entry));

        assertEq(token.bridge(), OLD_BRIDGE);
    }

    /// A codeless cutover target is refused before any entry read.
    function testCodelessBridgeIsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(SetBridge.BridgeHasNoCode.selector, address(0xDEAD)));
        script.preflight(address(token), address(0xDEAD));
    }

    /// A codeless token is refused before the freeze branch is even reached.
    function testCodelessTokenIsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(SetBridge.TokenHasNoCode.selector, address(0xDEAD)));
        script.preflight(address(0xDEAD), address(0));
    }

    /// A matching claim-ready entry passes, and the owner's flip then lands.
    function testClaimReadyEntryPassesAndFlips() public {
        KskdEntry entry = _entryFor(address(token), MINT_LIMIT);

        script.preflight(address(token), address(entry));

        vm.prank(owner);
        token.setBridge(address(entry));
        assertEq(token.bridge(), address(entry));
    }

    /// mintLimit == 0 warns but does not block: the owner can raise it after the flip.
    function testZeroMintLimitEntryPasses() public {
        KskdEntry entry = _entryFor(address(token), 0);
        script.preflight(address(token), address(entry));
    }

    /// The freeze target skips the entry checks.
    function testFreezeTargetIsAccepted() public view {
        script.preflight(address(token), address(0));
    }
}
