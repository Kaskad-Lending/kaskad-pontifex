// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {KskdBridged} from "../../src/KskdBridged.sol";

/// @notice Robinhood KSKD: bridge-only supply, cumulative mint accounting, EIP-2612 permit, no burn.
contract KskdBridgedTest is Test {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 internal constant HOLDER_KEY = 0xA11CE;

    KskdBridged internal token;

    address internal owner = makeAddr("owner");
    address internal bridge = makeAddr("bridge");
    address internal stranger = makeAddr("stranger");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    function setUp() public {
        token = new KskdBridged(bridge, owner);
    }

    // ─── Constructor, metadata and constants ─────────────────────────────

    /// Deploys as "Kaskad"/"KSKD" with 18 decimals, zero supply, the given bridge and owner.
    function test_ConstructorStoresBridgeAndMetadata() public view {
        assertEq(token.name(), "Kaskad");
        assertEq(token.symbol(), "KSKD");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0);
        assertEq(token.owner(), owner);
        assertEq(token.pendingOwner(), address(0));
        assertEq(token.bridge(), bridge);
        assertEq(token.totalSupply(), 0);
        assertEq(token.bridgedIn(alice), 0);
    }

    /// Construction announces the bridge it was wired to.
    function test_ConstructorEmitsBridgeSet() public {
        vm.expectEmit(true, false, false, true);
        emit KskdBridged.BridgeSet(bridge);
        new KskdBridged(bridge, owner);
    }

    /// A zero bridge is allowed at construction and announced as such.
    function test_ConstructorAcceptsZeroBridge() public {
        vm.expectEmit(true, false, false, true);
        emit KskdBridged.BridgeSet(address(0));
        KskdBridged fresh = new KskdBridged(address(0), owner);

        assertEq(fresh.bridge(), address(0));
        assertEq(fresh.owner(), owner);
    }

    /// Deployed with a zero bridge, nobody can mint until the owner wires one.
    function test_ConstructorZeroBridgeBlocksMinting() public {
        KskdBridged fresh = new KskdBridged(address(0), owner);

        address[3] memory callers = [owner, bridge, stranger];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(KskdBridged.NotBridge.selector));
            fresh.bridgeMint(alice, 1 ether);
        }

        vm.prank(owner);
        fresh.setBridge(bridge);
        vm.prank(bridge);
        fresh.bridgeMint(alice, 1 ether);
        assertEq(fresh.balanceOf(alice), 1 ether);
    }

    /// A zero initial owner is refused by Ownable.
    function test_ConstructorRevertsOnZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new KskdBridged(bridge, address(0));
    }

    /// MAX_SUPPLY equals the Igra KSKD total supply of 1e27.
    function test_MaxSupplyMatchesIgraSupply() public view {
        assertEq(token.MAX_SUPPLY(), 1e27);
        assertEq(token.MAX_SUPPLY(), 1_000_000_000 ether);
    }

    // ─── No burn ─────────────────────────────────────────────────────────

    /// The migration is one-way: no burn entry point exists at all.
    function test_NoBurnFunctionExists() public {
        vm.prank(bridge);
        token.bridgeMint(alice, 100 ether);

        vm.prank(alice);
        (bool ok,) = address(token).call(abi.encodeWithSignature("burn(uint256)", 40 ether));
        assertFalse(ok);

        vm.prank(alice);
        (ok,) = address(token).call(abi.encodeWithSignature("burnFrom(address,uint256)", alice, 40 ether));
        assertFalse(ok);

        assertEq(token.totalSupply(), 100 ether);
        assertEq(token.balanceOf(alice), 100 ether);
    }

    /// bridgeMint is the only mint path: no free-standing mint entry point exists.
    function test_NoMintFunctionBesidesBridgeMint() public {
        vm.prank(bridge);
        (bool ok,) = address(token).call(abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether));
        assertFalse(ok);
        assertEq(token.totalSupply(), 0);
    }

    // ─── setBridge ───────────────────────────────────────────────────────

    /// Only the owner can move the bridge pointer.
    function test_SetBridgeOnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        token.setBridge(stranger);
    }

    /// setBridge stores the address and announces it.
    function test_SetBridgeEmitsBridgeSet() public {
        vm.expectEmit(true, false, false, true, address(token));
        emit KskdBridged.BridgeSet(alice);
        vm.prank(owner);
        token.setBridge(alice);

        assertEq(token.bridge(), alice);
    }

    /// setBridge(0) stops minting for everyone, the previous bridge included.
    function test_SetBridgeZeroStopsMinting() public {
        vm.prank(bridge);
        token.bridgeMint(alice, 5 ether);

        vm.prank(owner);
        token.setBridge(address(0));

        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NotBridge.selector));
        token.bridgeMint(alice, 6 ether);

        assertEq(token.totalSupply(), 5 ether);
        assertEq(token.bridge(), address(0));
    }

    /// Re-pointing the bridge revokes the old one and empowers the new one.
    function test_SetBridgeMovesMintRight() public {
        vm.prank(owner);
        token.setBridge(alice);

        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NotBridge.selector));
        token.bridgeMint(bob, 1 ether);

        vm.prank(alice);
        token.bridgeMint(bob, 1 ether);
        assertEq(token.balanceOf(bob), 1 ether);
    }

    /// Pointing the bridge back restores the old entry's mint right and its accounting.
    function test_SetBridgeRestoresMintingWhenPointedBack() public {
        vm.prank(bridge);
        token.bridgeMint(alice, 10 ether);

        vm.startPrank(owner);
        token.setBridge(address(0));
        token.setBridge(bridge);
        vm.stopPrank();

        vm.prank(bridge);
        token.bridgeMint(alice, 15 ether);
        assertEq(token.balanceOf(alice), 15 ether);
        assertEq(token.bridgedIn(alice), 15 ether);
    }

    // ─── bridgeMint authorisation ────────────────────────────────────────

    /// Non-bridge callers, owner included, cannot mint.
    function test_BridgeMintRejectsNonBridge() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NotBridge.selector));
        token.bridgeMint(alice, 1 ether);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NotBridge.selector));
        token.bridgeMint(alice, 1 ether);
    }

    /// With bridge unset nobody can mint, the previous bridge included.
    function test_BridgeZeroBlocksEveryone() public {
        vm.prank(owner);
        token.setBridge(address(0));

        address[3] memory callers = [bridge, owner, stranger];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(KskdBridged.NotBridge.selector));
            token.bridgeMint(alice, 1 ether);
        }
        assertEq(token.totalSupply(), 0);
    }

    // ─── Cumulative mint semantics ───────────────────────────────────────

    /// Cumulative claims mint only the delta; a replay reverts with both totals.
    function test_BridgeMintCumulativeSemantics() public {
        vm.startPrank(bridge);

        token.bridgeMint(alice, 100);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.bridgedIn(alice), 100);
        assertEq(token.totalSupply(), 100);

        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NothingToMint.selector, 100, 100));
        token.bridgeMint(alice, 100);

        token.bridgeMint(alice, 150);
        assertEq(token.balanceOf(alice), 150);
        assertEq(token.bridgedIn(alice), 150);
        assertEq(token.totalSupply(), 150);

        vm.stopPrank();
    }

    /// A lower cumulative than already minted is rejected, not treated as zero.
    function test_BridgeMintRejectsDecreasingCumulative() public {
        vm.startPrank(bridge);
        token.bridgeMint(alice, 100);

        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NothingToMint.selector, 99, 100));
        token.bridgeMint(alice, 99);

        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NothingToMint.selector, 0, 100));
        token.bridgeMint(alice, 0);
        vm.stopPrank();
    }

    /// A zero cumulative on a fresh recipient mints nothing.
    function test_BridgeMintRejectsZeroOnFreshRecipient() public {
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NothingToMint.selector, 0, 0));
        token.bridgeMint(alice, 0);
    }

    /// bridgeMint mints through a Transfer from address(0).
    function test_BridgeMintEmitsTransferFromZero() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(0), alice, 42 ether);
        vm.prank(bridge);
        token.bridgeMint(alice, 42 ether);
    }

    /// Minting to the zero address is refused by ERC20 and leaves no accounting.
    function test_BridgeMintRejectsZeroRecipient() public {
        vm.prank(bridge);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.bridgeMint(address(0), 1 ether);

        assertEq(token.totalSupply(), 0);
        assertEq(token.bridgedIn(address(0)), 0);
    }

    /// Recipients are accounted independently; the global total is their sum.
    function test_RecipientsAreIndependent() public {
        vm.startPrank(bridge);
        token.bridgeMint(alice, 10 ether);
        token.bridgeMint(bob, 25 ether);
        token.bridgeMint(alice, 30 ether);
        vm.stopPrank();

        assertEq(token.bridgedIn(alice), 30 ether);
        assertEq(token.bridgedIn(bob), 25 ether);
        assertEq(token.totalSupply(), 55 ether);
    }

    /// A one-wei increase of the cumulative mints exactly one wei.
    function test_BridgeMintOneWeiDelta() public {
        vm.startPrank(bridge);
        token.bridgeMint(alice, 1 ether);
        token.bridgeMint(alice, 1 ether + 1);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 1 ether + 1);
        assertEq(token.totalSupply(), 1 ether + 1);
    }

    // ─── Supply cap ──────────────────────────────────────────────────────

    /// Minting exactly MAX_SUPPLY succeeds and one wei more is refused.
    function test_CapAllowsExactlyMaxSupply() public {
        vm.startPrank(bridge);
        token.bridgeMint(alice, token.MAX_SUPPLY());
        assertEq(token.totalSupply(), 1e27);

        vm.expectRevert(abi.encodeWithSelector(KskdBridged.MaxSupplyExceeded.selector, 1, 0));
        token.bridgeMint(bob, 1);
        vm.stopPrank();
    }

    /// The cap is checked against the requested delta, not the cumulative.
    function test_CapReportsDeltaAndRemainingRoom() public {
        vm.startPrank(bridge);
        token.bridgeMint(alice, 1e27 - 10);

        vm.expectRevert(abi.encodeWithSelector(KskdBridged.MaxSupplyExceeded.selector, 11, 10));
        token.bridgeMint(bob, 11);

        token.bridgeMint(bob, 10);
        assertEq(token.totalSupply(), 1e27);
        vm.stopPrank();
    }

    /// Supply can never shrink: no burn, and ERC20 refuses a transfer to the zero address.
    function test_SupplyCannotShrink() public {
        vm.prank(bridge);
        token.bridgeMint(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(address(0), 1 ether);

        assertEq(token.totalSupply(), 100 ether);
    }

    // ─── Permit ──────────────────────────────────────────────────────────

    /// DOMAIN_SEPARATOR matches an independent EIP-712 computation over name "Kaskad"/version "1".
    function test_DomainSeparatorMatchesIndependentComputation() public view {
        bytes32 expected = keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, keccak256("Kaskad"), keccak256("1"), block.chainid, address(token))
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    /// ERC-5267 reports the Kaskad v1 domain bound to this token.
    function test_Eip712DomainIsKaskadV1() public view {
        (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        ) = token.eip712Domain();

        assertEq(uint8(fields), 0x0f);
        assertEq(name, "Kaskad");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
        assertEq(salt, bytes32(0));
        assertEq(extensions.length, 0);
    }

    /// A real EIP-2612 signature grants the allowance and burns the nonce.
    function test_Permit() public {
        address holder = vm.addr(HOLDER_KEY);
        vm.prank(bridge);
        token.bridgeMint(holder, 1_000 ether);

        uint256 value = 250 ether;
        uint256 deadline = block.timestamp + 1 hours;
        assertEq(token.nonces(holder), 0);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, value, uint256(0), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);

        token.permit(holder, spender, value, deadline, v, r, s);

        assertEq(token.allowance(holder, spender), value);
        assertEq(token.nonces(holder), 1);

        vm.prank(spender);
        assertTrue(token.transferFrom(holder, bob, value));
        assertEq(token.balanceOf(bob), value);
        assertEq(token.allowance(holder, spender), 0);
    }

    /// Replaying a permit fails: the nonce has moved, so the recovered signer is wrong.
    function test_PermitReplayReverts() public {
        address holder = vm.addr(HOLDER_KEY);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, 1 ether, uint256(0), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);

        token.permit(holder, spender, 1 ether, deadline, v, r, s);

        address recovered = ECDSA.recover(
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, 1 ether, uint256(1), deadline))
                )
            ),
            abi.encodePacked(r, s, v)
        );
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, recovered, holder));
        token.permit(holder, spender, 1 ether, deadline, v, r, s);
    }

    /// An expired deadline reverts with ERC2612ExpiredSignature.
    function test_PermitRevertsWhenExpired() public {
        address holder = vm.addr(HOLDER_KEY);
        vm.warp(1_000_000);
        uint256 deadline = block.timestamp - 1;

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, 1 ether, uint256(0), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_KEY, digest);

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(holder, spender, 1 ether, deadline, v, r, s);
    }

    // ─── Ownable2Step ────────────────────────────────────────────────────

    /// Ownership moves only after the new owner accepts.
    function test_OwnershipTransferIsTwoStep() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Ownable2Step.OwnershipTransferStarted(owner, alice);
        vm.prank(owner);
        token.transferOwnership(alice);

        assertEq(token.owner(), owner);
        assertEq(token.pendingOwner(), alice);

        vm.prank(alice);
        token.acceptOwnership();

        assertEq(token.owner(), alice);
        assertEq(token.pendingOwner(), address(0));
    }

    /// Only the pending owner can accept.
    function test_AcceptOwnershipRejectsStranger() public {
        vm.prank(owner);
        token.transferOwnership(alice);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        token.acceptOwnership();
    }

    /// After the handover the old owner has no rights and the new one does.
    function test_OldOwnerLosesRights() public {
        vm.prank(owner);
        token.transferOwnership(alice);
        vm.prank(alice);
        token.acceptOwnership();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        token.setBridge(stranger);

        vm.prank(alice);
        token.setBridge(stranger);
        assertEq(token.bridge(), stranger);
    }

    /// Renouncing ownership freezes the bridge pointer for good.
    function test_RenounceOwnershipFreezesBridgePointer() public {
        vm.prank(owner);
        token.renounceOwnership();
        assertEq(token.owner(), address(0));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        token.setBridge(stranger);

        vm.prank(bridge);
        token.bridgeMint(alice, 1 ether);
        assertEq(token.bridge(), bridge);
        assertEq(token.balanceOf(alice), 1 ether);
    }

    // ─── Ordinary ERC20 behaviour ────────────────────────────────────────

    /// Bridged tokens move like any ERC20 without touching the bridge ledger.
    function test_BridgedTokensTransferNormally() public {
        vm.prank(bridge);
        token.bridgeMint(alice, 100 ether);

        vm.prank(alice);
        assertTrue(token.transfer(bob, 30 ether));

        vm.prank(bob);
        token.approve(spender, 10 ether);
        vm.prank(spender);
        assertTrue(token.transferFrom(bob, stranger, 10 ether));

        assertEq(token.balanceOf(alice), 70 ether);
        assertEq(token.balanceOf(bob), 20 ether);
        assertEq(token.balanceOf(stranger), 10 ether);
        assertEq(token.bridgedIn(alice), 100 ether);
        assertEq(token.bridgedIn(bob), 0);
        assertEq(token.totalSupply(), 100 ether);
    }

    // ─── Fuzz ────────────────────────────────────────────────────────────

    /// Any rising sequence of cumulatives mints exactly the deltas.
    function testFuzz_CumulativeIncrements(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 1, 1e26);
        b = bound(b, 1, 1e26);
        c = bound(c, 1, 1e26);

        vm.startPrank(bridge);
        token.bridgeMint(alice, a);
        assertEq(token.balanceOf(alice), a);
        token.bridgeMint(alice, a + b);
        assertEq(token.balanceOf(alice), a + b);
        token.bridgeMint(alice, a + b + c);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), a + b + c);
        assertEq(token.bridgedIn(alice), a + b + c);
        assertEq(token.totalSupply(), a + b + c);
        assertLe(token.totalSupply(), token.MAX_SUPPLY());
    }

    /// Splitting the cap between two recipients fills it exactly and then closes.
    function testFuzz_CapIsGlobal(uint256 split) public {
        split = bound(split, 1, 1e27 - 1);

        vm.startPrank(bridge);
        token.bridgeMint(alice, split);
        token.bridgeMint(bob, 1e27 - split);

        vm.expectRevert(abi.encodeWithSelector(KskdBridged.MaxSupplyExceeded.selector, 1, 0));
        token.bridgeMint(stranger, 1);
        vm.stopPrank();

        assertEq(token.totalSupply(), token.MAX_SUPPLY());
    }

    /// Whoever the caller, only the wired bridge may mint.
    function testFuzz_BridgeMintOnlyFromBridge(address caller) public {
        vm.assume(caller != bridge);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NotBridge.selector));
        token.bridgeMint(alice, 1 ether);

        assertEq(token.totalSupply(), 0);
    }

    /// Any cumulative at or below what was already minted is refused with both totals.
    function testFuzz_NothingToMintOnNonIncreasingCumulative(uint256 minted, uint256 replay) public {
        minted = bound(minted, 1, 1e26);
        replay = bound(replay, 0, minted);

        vm.startPrank(bridge);
        token.bridgeMint(alice, minted);

        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NothingToMint.selector, replay, minted));
        token.bridgeMint(alice, replay);
        vm.stopPrank();

        assertEq(token.bridgedIn(alice), minted);
    }

    /// Transfers never move the bridge ledger, only balances.
    function testFuzz_TransfersDoNotTouchBridgedIn(uint256 minted, uint256 moved) public {
        minted = bound(minted, 1, 1e26);
        moved = bound(moved, 0, minted);

        vm.prank(bridge);
        token.bridgeMint(alice, minted);

        vm.prank(alice);
        assertTrue(token.transfer(bob, moved));

        assertEq(token.bridgedIn(alice), minted);
        assertEq(token.bridgedIn(bob), 0);
        assertEq(token.totalSupply(), minted);
    }
}

/// @notice Mints through the bridge and shuffles balances for the token invariants.
contract KskdBridgedHandler is CommonBase, StdUtils {
    KskdBridged internal immutable TOKEN;

    address[] internal holders;

    mapping(address holder => uint256) public highWater;

    constructor(KskdBridged token_, address[] memory holders_) {
        TOKEN = token_;
        holders = holders_;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function holderAt(uint256 i) external view returns (address) {
        return holders[i];
    }

    function bridgeMint(uint256 seed, uint256 rawDelta) external {
        address recipient = holders[seed % holders.length];
        uint256 prior = TOKEN.bridgedIn(recipient);
        uint256 delta = bound(rawDelta, 1, 5e26);

        try TOKEN.bridgeMint(recipient, prior + delta) {} catch {}
        highWater[recipient] = TOKEN.bridgedIn(recipient);
    }

    function moveTokens(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = holders[fromSeed % holders.length];
        address to = holders[toSeed % holders.length];
        uint256 balance = TOKEN.balanceOf(from);
        if (from == to || balance == 0) return;

        vm.prank(from);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        TOKEN.transfer(to, bound(rawAmount, 1, balance));
    }
}

/// @notice Invariants of the bridged supply under random mints and transfers.
contract KskdBridgedInvariantTest is Test {
    KskdBridged internal token;
    KskdBridgedHandler internal handler;

    address internal owner = makeAddr("owner");

    function setUp() public {
        token = new KskdBridged(address(0), owner);

        address[] memory holders = new address[](4);
        holders[0] = makeAddr("h1");
        holders[1] = makeAddr("h2");
        holders[2] = makeAddr("h3");
        holders[3] = makeAddr("h4");

        handler = new KskdBridgedHandler(token, holders);
        vm.prank(owner);
        token.setBridge(address(handler));

        targetContract(address(handler));
    }

    /// The bridge can never mint past the Igra supply.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    function invariant_SupplyUnderCap() public view {
        assertLe(token.totalSupply(), token.MAX_SUPPLY());
    }

    /// Every token in existence came through the bridge ledger.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    function invariant_SupplyIsSumOfBridgedIn() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.holderCount(); i++) {
            sum += token.bridgedIn(handler.holderAt(i));
        }
        assertEq(sum, token.totalSupply());
    }

    /// Per-recipient cumulatives never decrease, transfers included.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    function invariant_BridgedInNeverDecreases() public view {
        for (uint256 i = 0; i < handler.holderCount(); i++) {
            address holder = handler.holderAt(i);
            assertGe(token.bridgedIn(holder), handler.highWater(holder));
        }
    }
}
