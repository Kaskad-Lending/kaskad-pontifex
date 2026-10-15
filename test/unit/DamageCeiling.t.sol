// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KskdBridged} from "../../src/KskdBridged.sol";
import {KskdEntry} from "../../src/KskdEntry.sol";
import {StubAttestationVerifier} from "../doubles/StubAttestationVerifier.sol";

/// @notice What one compromised key can mint, and which of those paths the guardian can stop.
contract DamageCeilingTest is Test {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant CLAIM_TYPEHASH =
        keccak256("Claim(address recipient,uint256 cumulativeBurned,uint256 deadline)");
    bytes32 internal constant PCR0 = keccak256("pontifex-enclave-image");
    bytes32 internal constant ROGUE_PCR0 = keccak256("rogue-image");
    uint256 internal constant MINT_LIMIT = 25_000_000 ether;
    uint256 internal constant T0 = 1_700_000_000;

    StubAttestationVerifier internal verifier;
    KskdBridged internal token;
    KskdEntry internal entry;

    address internal owner = makeAddr("owner");
    address internal guard = makeAddr("guardian");
    address internal attacker = makeAddr("attacker");
    address internal alice = makeAddr("alice");
    address internal enclave;
    uint256 internal enclaveKey;

    function setUp() public {
        vm.warp(T0);
        verifier = new StubAttestationVerifier();
        (enclave, enclaveKey) = makeAddrAndKey("enclave");
        token = new KskdBridged(address(0), owner);
        entry = new KskdEntry(address(token), address(verifier), PCR0, 1, MINT_LIMIT, owner);
        vm.startPrank(owner);
        token.setBridge(address(entry));
        entry.registerEnclave(abi.encode(true, PCR0, enclave));
        entry.setGuardian(guard);
        vm.stopPrank();
    }

    function _sigs(uint256 key, address recipient, uint256 cumulative, uint256 deadline)
        internal
        view
        returns (bytes[] memory out)
    {
        bytes32 domain = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("Pontifex"), keccak256("1"), block.chainid, address(entry))
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(CLAIM_TYPEHASH, recipient, cumulative, deadline)))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        out = new bytes[](1);
        out[0] = abi.encodePacked(r, s, v);
    }

    function _claim(uint256 key, address recipient, uint256 cumulative) internal {
        uint256 deadline = block.timestamp + 1 hours;
        entry.claim(recipient, cumulative, deadline, _sigs(key, recipient, cumulative, deadline));
    }

    /// A paused entry does not bind the token owner: setBridge reaches the whole MAX_SUPPLY.
    function test_TokenOwnerMintsFullCapPastGuardianPause() public {
        vm.prank(guard);
        entry.pause();

        vm.prank(owner);
        token.setBridge(attacker);
        uint256 cap = token.MAX_SUPPLY();
        vm.prank(attacker);
        token.bridgeMint(attacker, cap);

        assertEq(token.balanceOf(attacker), cap);
        assertEq(entry.mintLimit(), 0);
    }

    /// The guardian holds no right on the token, so it cannot freeze a rogue bridge.
    function test_GuardianCannotFreezeTokenBridge() public {
        vm.prank(owner);
        token.setBridge(attacker);

        vm.prank(guard);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guard));
        token.setBridge(address(0));
    }

    /// Under a PCR0-only verifier the entry owner alone admits any key, lifts the pause and
    /// disarms the guardian, so the ceiling is MAX_SUPPLY rather than mintLimit.
    function test_EntryOwnerAloneMintsFullCapUnderPcr0OnlyVerifier() public {
        vm.prank(guard);
        entry.pause();

        (address rogue, uint256 rogueKey) = makeAddrAndKey("rogue");
        vm.startPrank(owner);
        entry.setGuardian(address(0));
        entry.setExpectedPcr0(ROGUE_PCR0);
        entry.registerEnclave(abi.encode(true, ROGUE_PCR0, rogue));
        entry.setMintLimit(type(uint256).max);
        vm.stopPrank();

        uint256 cap = token.MAX_SUPPLY();
        _claim(rogueKey, attacker, cap);
        assertEq(token.balanceOf(attacker), cap);

        vm.prank(guard);
        vm.expectRevert(KskdEntry.NotGuardian.selector);
        entry.pause();
    }

    /// A rogue claim signature (a leaked k_bridge or a lying Igra RPC) is capped per window and
    /// stops at the guardian pause.
    function test_SignerCompromiseIsCappedPerWindowUntilPause() public {
        _claim(enclaveKey, attacker, 10 * MINT_LIMIT);
        assertEq(token.balanceOf(attacker), MINT_LIMIT);

        vm.warp(block.timestamp + entry.WINDOW());
        _claim(enclaveKey, attacker, 10 * MINT_LIMIT);
        assertEq(token.balanceOf(attacker), 2 * MINT_LIMIT);

        vm.prank(guard);
        entry.pause();
        vm.warp(block.timestamp + entry.WINDOW());
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _sigs(enclaveKey, attacker, 10 * MINT_LIMIT, deadline);
        vm.expectRevert(KskdEntry.MintLimitExhausted.selector);
        entry.claim(attacker, 10 * MINT_LIMIT, deadline, sigs);
    }

    /// A replacement KskdExit restarts `burned` at zero while `bridgedIn` persists, so burns
    /// into it stay unclaimable up to the recipient's old total.
    function test_ReplacedExitStrandsBurnsBelowPriorBridgedIn() public {
        _claim(enclaveKey, alice, 3_000 ether);

        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _sigs(enclaveKey, alice, 1_000 ether, deadline);
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NothingToMint.selector, 1_000 ether, 3_000 ether));
        entry.claim(alice, 1_000 ether, deadline, sigs);

        // 6_500 burned across both exits, 3_500 minted.
        _claim(enclaveKey, alice, 3_500 ether);
        assertEq(token.balanceOf(alice), 3_500 ether);
    }
}
