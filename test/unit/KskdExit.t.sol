// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KskdExit} from "../../src/KskdExit.sol";
import {KSKD} from "../fixtures/KSKD.sol";
import {ReentrantKskd, PermitReentrantKskd} from "../doubles/ReentrantKskd.sol";

/// @notice Igra side of the bridge against the verbatim Igra KSKD token.
contract KskdExitTest is Test {
    KSKD internal kskd;
    KskdExit internal exitBridge;

    address internal multisig = makeAddr("multisig");
    address internal closer = makeAddr("closer");
    address internal holder = makeAddr("holder");
    address internal other = makeAddr("other");
    address internal stranger = makeAddr("stranger");
    address internal recipient = makeAddr("recipient");

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 internal constant HOLDER_BALANCE = 10_000_000 ether;

    /// In-test key so the suite can sign EIP-2612 permits as this holder.
    uint256 internal constant PERMIT_HOLDER_PK = 0xA11CE;
    address internal permitHolder = vm.addr(PERMIT_HOLDER_PK);

    function setUp() public {
        kskd = new KSKD(multisig);
        exitBridge = new KskdExit(address(kskd), closer, 0);

        vm.startPrank(multisig);
        assertTrue(kskd.transfer(holder, HOLDER_BALANCE));
        assertTrue(kskd.transfer(other, HOLDER_BALANCE));
        assertTrue(kskd.transfer(permitHolder, HOLDER_BALANCE));
        vm.stopPrank();

        vm.prank(holder);
        kskd.approve(address(exitBridge), type(uint256).max);
        vm.prank(other);
        kskd.approve(address(exitBridge), type(uint256).max);
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _permitDigest(address owner_, uint256 value, uint256 deadline) internal view returns (bytes32) {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, owner_, address(exitBridge), value, kskd.nonces(owner_), deadline));
        return keccak256(abi.encodePacked("\x19\x01", kskd.DOMAIN_SEPARATOR(), structHash));
    }

    /// Permit for `value` to the exit, signed by `key` over that owner's current nonce.
    function _signPermit(uint256 key, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return vm.sign(key, _permitDigest(vm.addr(key), value, deadline));
    }

    // ─── Constructor ─────────────────────────────────────────────────────

    /// Zero token address is rejected at construction.
    function test_ConstructorRevertsOnZeroToken() public {
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ZeroAddress.selector));
        new KskdExit(address(0), closer, 0);
    }

    /// Zero closer address is rejected at construction.
    function test_ConstructorRevertsOnZeroCloser() public {
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ZeroAddress.selector));
        new KskdExit(address(kskd), address(0), 0);
    }

    /// Both addresses zero is the same single error.
    function test_ConstructorRevertsOnBothZero() public {
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ZeroAddress.selector));
        new KskdExit(address(0), address(0), 0);
    }

    /// Constructor stores token and closer and starts open with empty accounting.
    function test_ConstructorStoresTokenAndCloser() public view {
        assertEq(address(exitBridge.KSKD()), address(kskd));
        assertEq(exitBridge.CLOSER(), closer);
        assertFalse(exitBridge.closed());
        assertEq(exitBridge.totalBurned(), 0);
        assertEq(exitBridge.burned(recipient), 0);
    }

    /// The closer may equal the token holder or any EOA; no further constraint.
    function test_ConstructorAcceptsAnyNonZeroCloser() public {
        KskdExit fresh = new KskdExit(address(kskd), holder, 0);
        assertEq(fresh.CLOSER(), holder);
    }

    // ─── Happy path ──────────────────────────────────────────────────────

    /// exit moves nothing to the bridge, drops totalSupply and credits the recipient.
    function test_ExitBurnsAndCredits() public {
        uint256 amount = 1_234 ether;
        uint256 supplyBefore = kskd.totalSupply();

        vm.prank(holder);
        exitBridge.exit(amount, recipient);

        assertEq(kskd.balanceOf(holder), HOLDER_BALANCE - amount);
        assertEq(kskd.balanceOf(address(exitBridge)), 0);
        assertEq(kskd.balanceOf(recipient), 0);
        assertEq(kskd.totalSupply(), supplyBefore - amount);
        assertEq(exitBridge.burned(recipient), amount);
        assertEq(exitBridge.totalBurned(), amount);
    }

    /// Exited carries sender, recipient, amount and the new cumulative.
    function test_ExitEmitsExited() public {
        uint256 amount = 7 ether;

        vm.expectEmit(true, true, false, true, address(exitBridge));
        emit KskdExit.Exited(holder, recipient, amount, amount);
        vm.prank(holder);
        exitBridge.exit(amount, recipient);

        vm.expectEmit(true, true, false, true, address(exitBridge));
        emit KskdExit.Exited(holder, recipient, amount, 2 * amount);
        vm.prank(holder);
        exitBridge.exit(amount, recipient);
    }

    /// Successive exits accumulate into burned[recipient] and totalBurned.
    function test_RepeatedExitsAccumulate() public {
        vm.startPrank(holder);
        exitBridge.exit(1 ether, recipient);
        exitBridge.exit(2 ether, recipient);
        exitBridge.exit(3 ether, recipient);
        vm.stopPrank();

        assertEq(exitBridge.burned(recipient), 6 ether);
        assertEq(exitBridge.totalBurned(), 6 ether);
        assertEq(kskd.balanceOf(address(exitBridge)), 0);
    }

    /// Two senders crediting one recipient sum into the same slot.
    function test_DifferentSendersAccumulateForOneRecipient() public {
        vm.prank(holder);
        exitBridge.exit(4 ether, recipient);
        vm.prank(other);
        exitBridge.exit(6 ether, recipient);

        assertEq(exitBridge.burned(recipient), 10 ether);
        assertEq(exitBridge.totalBurned(), 10 ether);
    }

    /// Per-recipient accounting is independent while totalBurned is global.
    function test_RecipientsAreIndependent() public {
        address second = makeAddr("second");

        vm.startPrank(holder);
        exitBridge.exit(5 ether, recipient);
        exitBridge.exit(9 ether, second);
        vm.stopPrank();

        assertEq(exitBridge.burned(recipient), 5 ether);
        assertEq(exitBridge.burned(second), 9 ether);
        assertEq(exitBridge.totalBurned(), 14 ether);
    }

    /// The sender may name itself as the Robinhood recipient.
    function test_ExitToSelf() public {
        vm.prank(holder);
        exitBridge.exit(11 ether, holder);

        assertEq(exitBridge.burned(holder), 11 ether);
        assertEq(kskd.balanceOf(holder), HOLDER_BALANCE - 11 ether);
    }

    /// The closer is an ordinary recipient; the role touches only `close`.
    function test_ExitToCloserIsAllowed() public {
        vm.prank(holder);
        exitBridge.exit(3 ether, closer);

        assertEq(exitBridge.burned(closer), 3 ether);
    }

    // ─── Reverts ─────────────────────────────────────────────────────────

    /// Zero amount is rejected.
    function test_ExitRevertsOnZeroAmount() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ZeroAmount.selector));
        exitBridge.exit(0, recipient);
    }

    /// The zero recipient is rejected and names itself in the error.
    function test_ExitRevertsOnZeroRecipient() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.InvalidRecipient.selector, address(0)));
        exitBridge.exit(1 ether, address(0));
    }

    /// The exit contract itself is rejected as recipient.
    function test_ExitRevertsOnBridgeAsRecipient() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.InvalidRecipient.selector, address(exitBridge)));
        exitBridge.exit(1 ether, address(exitBridge));
    }

    /// The KSKD token itself is rejected as recipient.
    function test_ExitRevertsOnTokenAsRecipient() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.InvalidRecipient.selector, address(kskd)));
        exitBridge.exit(1 ether, address(kskd));
    }

    /// An invalid recipient burns nothing.
    function test_InvalidRecipientLeavesNoAccounting() public {
        uint256 supplyBefore = kskd.totalSupply();

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.InvalidRecipient.selector, address(0)));
        exitBridge.exit(1 ether, address(0));

        assertEq(kskd.totalSupply(), supplyBefore);
        assertEq(exitBridge.totalBurned(), 0);
        assertEq(kskd.balanceOf(holder), HOLDER_BALANCE);
    }

    /// Amount check precedes the recipient check.
    function test_ZeroAmountTakesPrecedenceOverInvalidRecipient() public {
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ZeroAmount.selector));
        exitBridge.exit(0, address(0));
    }

    /// Without approval the token's allowance error bubbles through SafeERC20.
    function test_ExitRevertsWithoutAllowance() public {
        address fresh = makeAddr("fresh");
        vm.prank(multisig);
        assertTrue(kskd.transfer(fresh, 100 ether));

        vm.prank(fresh);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(exitBridge), 0, 1 ether)
        );
        exitBridge.exit(1 ether, recipient);
    }

    /// A partial allowance reports the shortfall with the granted amount.
    function test_ExitRevertsOnPartialAllowance() public {
        address fresh = makeAddr("fresh2");
        vm.prank(multisig);
        assertTrue(kskd.transfer(fresh, 100 ether));

        vm.startPrank(fresh);
        kskd.approve(address(exitBridge), 5 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(exitBridge), 5 ether, 6 ether
            )
        );
        exitBridge.exit(6 ether, recipient);
        vm.stopPrank();
    }

    /// Approving more than you hold still fails on balance.
    function test_ExitRevertsOnInsufficientBalance() public {
        uint256 amount = HOLDER_BALANCE + 1;

        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, HOLDER_BALANCE, amount)
        );
        exitBridge.exit(amount, recipient);
    }

    /// A failed exit leaves burned and totalBurned untouched.
    function test_FailedExitLeavesNoAccounting() public {
        vm.prank(holder);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, holder, HOLDER_BALANCE, HOLDER_BALANCE + 1
            )
        );
        exitBridge.exit(HOLDER_BALANCE + 1, recipient);

        assertEq(exitBridge.burned(recipient), 0);
        assertEq(exitBridge.totalBurned(), 0);
    }

    // ─── exitWithPermit ──────────────────────────────────────────────────

    /// A permit in the same call burns without a standing approval and leaves no allowance behind.
    function test_ExitWithPermitBurnsAndCredits() public {
        uint256 amount = 1_234 ether;
        uint256 supplyBefore = kskd.totalSupply();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_HOLDER_PK, amount, deadline);

        vm.expectEmit(true, true, false, true, address(exitBridge));
        emit KskdExit.Exited(permitHolder, recipient, amount, amount);
        vm.prank(permitHolder);
        exitBridge.exitWithPermit(amount, recipient, deadline, v, r, s);

        assertEq(exitBridge.burned(recipient), amount);
        assertEq(exitBridge.totalBurned(), amount);
        assertEq(kskd.balanceOf(permitHolder), HOLDER_BALANCE - amount);
        assertEq(kskd.balanceOf(address(exitBridge)), 0);
        assertEq(kskd.totalSupply(), supplyBefore - amount);
        assertEq(kskd.allowance(permitHolder, address(exitBridge)), 0);
        assertEq(kskd.nonces(permitHolder), 1);
    }

    /// A front-run permit is harmless: the inner permit reverts into the catch and the allowance stands.
    function test_ExitWithPermitSurvivesAFrontRunPermit() public {
        uint256 amount = 500 ether;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_HOLDER_PK, amount, deadline);

        vm.prank(stranger);
        kskd.permit(permitHolder, address(exitBridge), amount, deadline, v, r, s);
        assertEq(kskd.allowance(permitHolder, address(exitBridge)), amount);
        assertEq(kskd.nonces(permitHolder), 1);

        vm.prank(permitHolder);
        exitBridge.exitWithPermit(amount, recipient, deadline, v, r, s);

        assertEq(exitBridge.burned(recipient), amount);
        assertEq(kskd.allowance(permitHolder, address(exitBridge)), 0);
        assertEq(kskd.nonces(permitHolder), 1);
    }

    /// An unusable signature leaves the caller with no allowance and the token's error bubbles up.
    function test_ExitWithPermitRevertsOnAForeignSignature() public {
        uint256 amount = 5 ether;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBADBAD, _permitDigest(permitHolder, amount, deadline));

        vm.prank(permitHolder);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(exitBridge), 0, amount)
        );
        exitBridge.exitWithPermit(amount, recipient, deadline, v, r, s);

        assertEq(exitBridge.totalBurned(), 0);
        assertEq(kskd.nonces(permitHolder), 0);
    }

    /// An expired permit falls back to a standing approval and consumes no nonce.
    function test_ExitWithPermitFallsBackToAStandingApproval() public {
        uint256 amount = 9 ether;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_HOLDER_PK, amount, deadline);

        vm.prank(permitHolder);
        kskd.approve(address(exitBridge), amount);
        vm.warp(deadline + 1);

        vm.prank(permitHolder);
        exitBridge.exitWithPermit(amount, recipient, deadline, v, r, s);

        assertEq(exitBridge.burned(recipient), amount);
        assertEq(kskd.allowance(permitHolder, address(exitBridge)), 0);
        assertEq(kskd.nonces(permitHolder), 0);
    }

    /// An expired permit with nothing approved reverts on the allowance, not inside the permit.
    function test_ExitWithPermitRevertsWhenExpiredAndUnapproved() public {
        uint256 amount = 9 ether;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_HOLDER_PK, amount, deadline);

        vm.warp(deadline + 1);

        vm.prank(permitHolder);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(exitBridge), 0, amount)
        );
        exitBridge.exitWithPermit(amount, recipient, deadline, v, r, s);

        assertEq(exitBridge.totalBurned(), 0);
    }

    /// A standing permit below the exit amount reports the shortfall: the inner permit is for `amount`.
    function test_ExitWithPermitRevertsOnAShortStandingPermit() public {
        uint256 permitted = 3 ether;
        uint256 amount = 4 ether;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_HOLDER_PK, permitted, deadline);

        vm.prank(stranger);
        kskd.permit(permitHolder, address(exitBridge), permitted, deadline, v, r, s);

        vm.prank(permitHolder);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(exitBridge), permitted, amount
            )
        );
        exitBridge.exitWithPermit(amount, recipient, deadline, v, r, s);

        assertEq(exitBridge.totalBurned(), 0);
        assertEq(kskd.allowance(permitHolder, address(exitBridge)), permitted);
    }

    /// A closed exit refuses a valid permit and the reverted call consumes no nonce.
    function test_ExitWithPermitRevertsAfterClose() public {
        uint256 amount = 2 ether;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_HOLDER_PK, amount, deadline);

        vm.prank(closer);
        exitBridge.close();

        vm.prank(permitHolder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ExitClosed.selector));
        exitBridge.exitWithPermit(amount, recipient, deadline, v, r, s);

        assertEq(kskd.nonces(permitHolder), 0);
        assertEq(kskd.allowance(permitHolder, address(exitBridge)), 0);
    }

    /// A zero amount is refused after the permit lands.
    function test_ExitWithPermitRejectsZeroAmount() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_HOLDER_PK, 0, deadline);

        vm.prank(permitHolder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ZeroAmount.selector));
        exitBridge.exitWithPermit(0, recipient, deadline, v, r, s);

        assertEq(kskd.nonces(permitHolder), 0);
    }

    /// The three banned recipients are refused on the permit path too.
    function test_ExitWithPermitRejectsBannedRecipients() public {
        uint256 amount = 1 ether;
        uint256 deadline = block.timestamp + 1 hours;
        address[3] memory bad = [address(0), address(exitBridge), address(kskd)];

        for (uint256 i = 0; i < bad.length; i++) {
            (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_HOLDER_PK, amount, deadline);
            vm.prank(permitHolder);
            vm.expectRevert(abi.encodeWithSelector(KskdExit.InvalidRecipient.selector, bad[i]));
            exitBridge.exitWithPermit(amount, bad[i], deadline, v, r, s);
        }

        assertEq(exitBridge.totalBurned(), 0);
        assertEq(kskd.nonces(permitHolder), 0);
    }

    // ─── minBurn ─────────────────────────────────────────────────────────

    /// The constructor stores the floor and announces it.
    function test_ConstructorStoresAndEmitsMinBurn() public {
        vm.expectEmit(false, false, false, true);
        emit KskdExit.MinBurnSet(1000 ether);
        KskdExit fresh = new KskdExit(address(kskd), closer, 1000 ether);
        assertEq(fresh.minBurn(), 1000 ether);
    }

    /// A burn below the floor reverts and touches no accounting.
    function test_ExitRevertsBelowMinBurn() public {
        KskdExit bridge = new KskdExit(address(kskd), closer, 1000 ether);
        vm.startPrank(holder);
        kskd.approve(address(bridge), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.BelowMinBurn.selector, 999 ether, 1000 ether));
        bridge.exit(999 ether, recipient);
        vm.stopPrank();
        assertEq(bridge.burned(recipient), 0);
        assertEq(bridge.totalBurned(), 0);
        assertEq(kskd.balanceOf(holder), HOLDER_BALANCE);
    }

    /// Exactly the floor is accepted.
    function test_ExitAtMinBurnPasses() public {
        KskdExit bridge = new KskdExit(address(kskd), closer, 1000 ether);
        vm.startPrank(holder);
        kskd.approve(address(bridge), type(uint256).max);
        bridge.exit(1000 ether, recipient);
        vm.stopPrank();
        assertEq(bridge.burned(recipient), 1000 ether);
    }

    /// The floor is per call, not cumulative: a second top-up must clear it too.
    function test_MinBurnAppliesPerCallNotCumulative() public {
        KskdExit bridge = new KskdExit(address(kskd), closer, 1000 ether);
        vm.startPrank(holder);
        kskd.approve(address(bridge), type(uint256).max);
        bridge.exit(5000 ether, recipient);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.BelowMinBurn.selector, 1 ether, 1000 ether));
        bridge.exit(1 ether, recipient);
        bridge.exit(1000 ether, recipient);
        vm.stopPrank();
        assertEq(bridge.burned(recipient), 6000 ether);
    }

    /// A zero amount still reports ZeroAmount, not BelowMinBurn.
    function test_ZeroAmountTakesPrecedenceOverMinBurn() public {
        KskdExit bridge = new KskdExit(address(kskd), closer, 1000 ether);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ZeroAmount.selector));
        bridge.exit(0, recipient);
    }

    /// Closed takes precedence over the floor.
    function test_ClosedTakesPrecedenceOverMinBurn() public {
        KskdExit bridge = new KskdExit(address(kskd), closer, 1000 ether);
        vm.prank(closer);
        bridge.close();
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ExitClosed.selector));
        bridge.exit(1 ether, recipient);
    }

    /// The floor gates exitWithPermit on the same terms as exit.
    function test_ExitWithPermitRespectsMinBurn() public {
        KskdExit bridge = new KskdExit(address(kskd), closer, 1000 ether);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, permitHolder, address(bridge), 1 ether, kskd.nonces(permitHolder), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", kskd.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(PERMIT_HOLDER_PK, digest);
        vm.prank(permitHolder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.BelowMinBurn.selector, 1 ether, 1000 ether));
        bridge.exitWithPermit(1 ether, recipient, deadline, v, r, s_);
    }

    /// Only CLOSER may retune the floor.
    function test_SetMinBurnOnlyCloser() public {
        address[3] memory callers = [stranger, holder, multisig];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(KskdExit.NotCloser.selector));
            exitBridge.setMinBurn(1 ether);
        }
        assertEq(exitBridge.minBurn(), 0);
    }

    /// CLOSER retunes the floor and the change takes effect on the next exit.
    function test_SetMinBurnTakesEffectAndEmits() public {
        vm.expectEmit(false, false, false, true, address(exitBridge));
        emit KskdExit.MinBurnSet(1000 ether);
        vm.prank(closer);
        exitBridge.setMinBurn(1000 ether);
        assertEq(exitBridge.minBurn(), 1000 ether);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.BelowMinBurn.selector, 500 ether, 1000 ether));
        exitBridge.exit(500 ether, recipient);

        vm.prank(closer);
        exitBridge.setMinBurn(0);
        vm.prank(holder);
        exitBridge.exit(500 ether, recipient);
        assertEq(exitBridge.burned(recipient), 500 ether);
    }

    // ─── close ───────────────────────────────────────────────────────────

    /// Only CLOSER may close; holders and strangers cannot.
    function test_CloseOnlyCloser() public {
        address[3] memory callers = [stranger, holder, multisig];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(KskdExit.NotCloser.selector));
            exitBridge.close();
        }
        assertFalse(exitBridge.closed());
    }

    /// close sets the flag and announces it.
    function test_CloseSetsClosedAndEmits() public {
        vm.expectEmit(false, false, false, true, address(exitBridge));
        emit KskdExit.Closed();
        vm.prank(closer);
        exitBridge.close();

        assertTrue(exitBridge.closed());
    }

    /// close is one-way: a second call by the closer reverts.
    function test_CloseIsOneWay() public {
        vm.startPrank(closer);
        exitBridge.close();
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ExitClosed.selector));
        exitBridge.close();
        vm.stopPrank();

        assertTrue(exitBridge.closed());
    }

    /// The caller check precedes the closed check.
    function test_NotCloserTakesPrecedenceOverExitClosed() public {
        vm.prank(closer);
        exitBridge.close();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.NotCloser.selector));
        exitBridge.close();
    }

    /// After close every exit reverts, the closer's included.
    function test_ExitRevertsAfterClose() public {
        vm.prank(closer);
        exitBridge.close();

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ExitClosed.selector));
        exitBridge.exit(1 ether, recipient);

        vm.prank(closer);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ExitClosed.selector));
        exitBridge.exit(1 ether, recipient);
    }

    /// The closed check precedes the amount check.
    function test_ClosedTakesPrecedenceOverZeroAmount() public {
        vm.prank(closer);
        exitBridge.close();

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ExitClosed.selector));
        exitBridge.exit(0, recipient);
    }

    /// The closed check precedes the recipient check.
    function test_ClosedTakesPrecedenceOverInvalidRecipient() public {
        vm.prank(closer);
        exitBridge.close();

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ExitClosed.selector));
        exitBridge.exit(1 ether, address(0));
    }

    /// The ledger the enclave reads stays readable and unchanged after close.
    function test_LedgerReadableAfterClose() public {
        address second = makeAddr("secondRecipient");
        vm.startPrank(holder);
        exitBridge.exit(40 ether, recipient);
        exitBridge.exit(2 ether, second);
        vm.stopPrank();

        vm.prank(closer);
        exitBridge.close();

        assertEq(exitBridge.burned(recipient), 40 ether);
        assertEq(exitBridge.burned(second), 2 ether);
        assertEq(exitBridge.totalBurned(), 42 ether);
        assertEq(address(exitBridge.KSKD()), address(kskd));
        assertEq(exitBridge.CLOSER(), closer);
    }

    /// close touches no balances and no supply.
    function test_CloseTouchesNoTokens() public {
        vm.prank(holder);
        exitBridge.exit(5 ether, recipient);
        uint256 supply = kskd.totalSupply();
        uint256 balance = kskd.balanceOf(holder);

        vm.prank(closer);
        exitBridge.close();

        assertEq(kskd.totalSupply(), supply);
        assertEq(kskd.balanceOf(holder), balance);
        assertEq(kskd.balanceOf(address(exitBridge)), 0);
        assertEq(kskd.allowance(holder, address(exitBridge)), type(uint256).max);
    }

    /// Closing before any exit freezes an empty ledger.
    function test_CloseOnEmptyLedger() public {
        vm.prank(closer);
        exitBridge.close();

        assertTrue(exitBridge.closed());
        assertEq(exitBridge.totalBurned(), 0);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ExitClosed.selector));
        exitBridge.exit(1 ether, recipient);
    }

    // ─── Fuzz ────────────────────────────────────────────────────────────

    /// Any amount within the holder's balance burns exactly that much and holds no dust.
    function testFuzz_Exit(uint256 amount) public {
        amount = bound(amount, 1, HOLDER_BALANCE);
        uint256 supplyBefore = kskd.totalSupply();

        vm.prank(holder);
        exitBridge.exit(amount, recipient);

        assertEq(exitBridge.burned(recipient), amount);
        assertEq(exitBridge.totalBurned(), amount);
        assertEq(kskd.totalSupply(), supplyBefore - amount);
        assertEq(kskd.balanceOf(holder), HOLDER_BALANCE - amount);
        assertEq(kskd.balanceOf(address(exitBridge)), 0);
    }

    /// Two fuzzed exits sum into the cumulative and never leave a bridge balance.
    function testFuzz_ExitTwiceAccumulates(uint256 first, uint256 second) public {
        first = bound(first, 1, HOLDER_BALANCE - 1);
        second = bound(second, 1, HOLDER_BALANCE - first);

        vm.startPrank(holder);
        exitBridge.exit(first, recipient);
        exitBridge.exit(second, recipient);
        vm.stopPrank();

        assertEq(exitBridge.burned(recipient), first + second);
        assertEq(exitBridge.totalBurned(), first + second);
        assertEq(kskd.balanceOf(address(exitBridge)), 0);
    }

    /// burned and totalBurned only grow, and close freezes them at the last value.
    function testFuzz_BurnedIsMonotoneAndSurvivesClose(uint256 first, uint256 second) public {
        first = bound(first, 1, HOLDER_BALANCE - 1);
        second = bound(second, 1, HOLDER_BALANCE - first);

        vm.prank(holder);
        exitBridge.exit(first, recipient);
        uint256 afterFirst = exitBridge.burned(recipient);

        vm.prank(holder);
        exitBridge.exit(second, recipient);
        uint256 afterSecond = exitBridge.burned(recipient);
        assertGe(afterSecond, afterFirst);

        vm.prank(closer);
        exitBridge.close();

        assertEq(exitBridge.burned(recipient), afterSecond);
        assertEq(exitBridge.totalBurned(), afterSecond);

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ExitClosed.selector));
        exitBridge.exit(1, recipient);

        assertEq(exitBridge.burned(recipient), afterSecond);
        assertEq(exitBridge.totalBurned(), afterSecond);
    }

    /// Any amount within the balance and any live deadline burn through a single-call permit.
    function testFuzz_ExitWithPermit(uint256 amount, uint256 rawDeadline) public {
        amount = bound(amount, 1, HOLDER_BALANCE);
        uint256 deadline = bound(rawDeadline, block.timestamp, type(uint256).max);
        uint256 supplyBefore = kskd.totalSupply();
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_HOLDER_PK, amount, deadline);

        vm.prank(permitHolder);
        exitBridge.exitWithPermit(amount, recipient, deadline, v, r, s);

        assertEq(exitBridge.burned(recipient), amount);
        assertEq(exitBridge.totalBurned(), amount);
        assertEq(kskd.totalSupply(), supplyBefore - amount);
        assertEq(kskd.balanceOf(permitHolder), HOLDER_BALANCE - amount);
        assertEq(kskd.balanceOf(address(exitBridge)), 0);
        assertEq(kskd.allowance(permitHolder, address(exitBridge)), 0);
        assertEq(kskd.nonces(permitHolder), 1);
    }

    /// Nobody but CLOSER can close, whatever the caller.
    function testFuzz_CloseRejectsEveryoneButCloser(address caller) public {
        vm.assume(caller != closer);

        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.NotCloser.selector));
        exitBridge.close();

        assertFalse(exitBridge.closed());
    }

    /// Whatever the amount, a closed exit refuses it before any other check.
    function testFuzz_ExitAfterCloseAlwaysReverts(uint256 amount) public {
        vm.prank(closer);
        exitBridge.close();

        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.ExitClosed.selector));
        exitBridge.exit(amount, recipient);
    }

    /// Any recipient outside the three banned addresses is accepted.
    function testFuzz_ExitAcceptsAnyOtherRecipient(address target, uint256 amount) public {
        vm.assume(target != address(0) && target != address(exitBridge) && target != address(kskd));
        amount = bound(amount, 1, HOLDER_BALANCE);

        vm.prank(holder);
        exitBridge.exit(amount, target);

        assertEq(exitBridge.burned(target), amount);
        assertEq(exitBridge.totalBurned(), amount);
    }

    // ─── Reentrancy ──────────────────────────────────────────────────────

    /// A token that reenters `exit` from `transferFrom` cannot corrupt the ledger: state is written
    /// before the transfer, so both burns are accounted and nothing is minted twice.
    function test_ExitSurvivesAReentrantToken() public {
        ReentrantKskd evil = new ReentrantKskd(holder);
        KskdExit bridge = new KskdExit(address(evil), closer, 0);

        vm.prank(holder);
        evil.approve(address(bridge), type(uint256).max);
        evil.arm(bridge, recipient, 40 ether);

        uint256 supplyBefore = evil.totalSupply();

        vm.prank(holder);
        bridge.exit(100 ether, recipient);

        assertEq(bridge.burned(recipient), 140 ether);
        assertEq(bridge.totalBurned(), 140 ether);
        assertEq(evil.totalSupply(), supplyBefore - 140 ether);
        assertEq(evil.balanceOf(address(bridge)), 0);
    }

    /// Under reentrancy the outer `Exited` log carries a cumulative that is already stale; the
    /// enclave reads `burned` from state, so the ledger stays authoritative.
    function test_ReentrantExitEmitsAStaleCumulative() public {
        ReentrantKskd evil = new ReentrantKskd(holder);
        KskdExit bridge = new KskdExit(address(evil), closer, 0);

        vm.prank(holder);
        evil.approve(address(bridge), type(uint256).max);
        evil.arm(bridge, recipient, 40 ether);

        vm.recordLogs();
        vm.prank(holder);
        bridge.exit(100 ether, recipient);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        uint256 lastCumulative;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != KskdExit.Exited.selector) continue;
            (, uint256 cumulative) = abi.decode(logs[i].data, (uint256, uint256));
            lastCumulative = cumulative;
            seen++;
        }

        assertEq(seen, 2);
        assertEq(lastCumulative, 100 ether);
        assertEq(bridge.burned(recipient), 140 ether);
    }

    /// A token with no `permit` still exits: the failed call is caught and the standing allowance pays.
    function test_ExitWithPermitReachesExitOnATokenWithoutPermit() public {
        ReentrantKskd noPermit = new ReentrantKskd(permitHolder);
        KskdExit bridge = new KskdExit(address(noPermit), closer, 0);

        vm.prank(permitHolder);
        noPermit.approve(address(bridge), 50 ether);

        vm.prank(permitHolder);
        bridge.exitWithPermit(50 ether, recipient, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));

        assertEq(bridge.burned(recipient), 50 ether);
        assertEq(bridge.totalBurned(), 50 ether);
        assertEq(noPermit.balanceOf(address(bridge)), 0);
    }

    /// The inner permit takes `msg.sender` as the owner, so a relayer holding a user's signature
    /// can only permit itself: the user's tokens stay put.
    function test_ExitWithPermitCannotBeRelayedForAnotherHolder() public {
        uint256 amount = 7 ether;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_HOLDER_PK, amount, deadline);

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(exitBridge), 0, amount)
        );
        exitBridge.exitWithPermit(amount, recipient, deadline, v, r, s);

        assertEq(exitBridge.totalBurned(), 0);
        assertEq(kskd.nonces(permitHolder), 0);
        assertEq(kskd.balanceOf(permitHolder), HOLDER_BALANCE);
    }

    /// A token whose `permit` reenters `exit` cannot double-credit: both burns are paid and booked.
    function test_ExitWithPermitReentrancyThroughPermitIsAnOrdinaryExit() public {
        PermitReentrantKskd token = new PermitReentrantKskd(permitHolder);
        KskdExit bridge = new KskdExit(address(token), closer, 0);
        token.arm(bridge, recipient, 30 ether);

        vm.prank(permitHolder);
        token.approve(address(bridge), type(uint256).max);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(permitHolder);
        bridge.exitWithPermit(50 ether, recipient, block.timestamp + 1 hours, 27, bytes32(0), bytes32(0));

        assertTrue(token.reentered());
        assertEq(bridge.burned(recipient), 80 ether, "inner and outer burn both booked");
        assertEq(bridge.totalBurned(), 80 ether);
        assertEq(token.totalSupply(), supplyBefore - 80 ether, "credited more than was burned");
        assertEq(token.balanceOf(address(bridge)), 0);
    }

    /// The exit refuses to credit itself or the token, closing the obvious self-burn loops.
    function test_ExitRejectsSelfAndTokenRecipients() public {
        vm.startPrank(holder);
        vm.expectRevert(abi.encodeWithSelector(KskdExit.InvalidRecipient.selector, address(exitBridge)));
        exitBridge.exit(1 ether, address(exitBridge));

        vm.expectRevert(abi.encodeWithSelector(KskdExit.InvalidRecipient.selector, address(kskd)));
        exitBridge.exit(1 ether, address(kskd));
        vm.stopPrank();
    }
}

/// @notice Drives exits and the one-way close for the exit invariants.
contract KskdExitHandler is CommonBase, StdUtils {
    KSKD internal immutable TOKEN;
    KskdExit internal immutable EXIT;
    address internal immutable CLOSER_ADDR;

    address[] internal recipients;

    /// Second funded exiter, keyed so the handler can sign real EIP-2612 permits for it.
    uint256 internal constant PERMIT_PK = 0xBEEF;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    mapping(address recipient => uint256) public highWater;
    uint256 public ghostTotalBurned;
    bool public sawClosed;

    constructor(KSKD token_, KskdExit exit_, address closer_, address[] memory recipients_) {
        TOKEN = token_;
        EXIT = exit_;
        CLOSER_ADDR = closer_;
        recipients = recipients_;
        token_.approve(address(exit_), type(uint256).max);
    }

    function permitHolder() public pure returns (address) {
        return vm.addr(PERMIT_PK);
    }

    function recipientCount() external view returns (uint256) {
        return recipients.length;
    }

    function recipientAt(uint256 i) external view returns (address) {
        return recipients[i];
    }

    function exit(uint256 seed, uint256 rawAmount) external {
        address recipient = recipients[seed % recipients.length];
        uint256 balance = TOKEN.balanceOf(address(this));
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance);

        try EXIT.exit(amount, recipient) {
            ghostTotalBurned += amount;
        } catch {}
        highWater[recipient] = EXIT.burned(recipient);
    }

    /// Same ledger through the permit entry point, signed for the exact amount each time.
    function exitWithPermit(uint256 seed, uint256 rawAmount) external {
        address holder = permitHolder();
        address recipient = recipients[seed % recipients.length];
        uint256 balance = TOKEN.balanceOf(holder);
        if (balance == 0) return;
        uint256 amount = bound(rawAmount, 1, balance);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, holder, address(EXIT), amount, TOKEN.nonces(holder), deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(PERMIT_PK, keccak256(abi.encodePacked("\x19\x01", TOKEN.DOMAIN_SEPARATOR(), structHash)));

        vm.prank(holder);
        try EXIT.exitWithPermit(amount, recipient, deadline, v, r, s) {
            ghostTotalBurned += amount;
        } catch {}
        highWater[recipient] = EXIT.burned(recipient);
    }

    /// Rare on purpose: closing early would starve the rest of the sequence.
    function maybeClose(uint256 seed) external {
        if (seed % 64 != 0) return;
        vm.prank(CLOSER_ADDR);
        try EXIT.close() {
            sawClosed = true;
        } catch {}
    }
}

/// @notice Invariants of the exit ledger under random exits and a possible close.
contract KskdExitInvariantTest is Test {
    KSKD internal kskd;
    KskdExit internal exitBridge;
    KskdExitHandler internal handler;

    address internal multisig = makeAddr("multisig");
    address internal closer = makeAddr("closer");

    uint256 internal constant FUNDING = 100_000_000 ether;

    function setUp() public {
        kskd = new KSKD(multisig);
        exitBridge = new KskdExit(address(kskd), closer, 0);

        address[] memory recipients = new address[](4);
        recipients[0] = makeAddr("r1");
        recipients[1] = makeAddr("r2");
        recipients[2] = makeAddr("r3");
        recipients[3] = makeAddr("r4");

        handler = new KskdExitHandler(kskd, exitBridge, closer, recipients);
        vm.startPrank(multisig);
        assertTrue(kskd.transfer(address(handler), FUNDING));
        assertTrue(kskd.transfer(handler.permitHolder(), FUNDING));
        vm.stopPrank();

        targetContract(address(handler));
    }

    /// The exit contract never holds KSKD: every transfer in is burned in the same call.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    function invariant_ExitHoldsNoTokens() public view {
        assertEq(kskd.balanceOf(address(exitBridge)), 0);
    }

    /// totalBurned equals the drop in live KSKD supply.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    function invariant_TotalBurnedMatchesSupplyDrop() public view {
        assertEq(kskd.TOTAL_SUPPLY() - kskd.totalSupply(), exitBridge.totalBurned());
        assertEq(exitBridge.totalBurned(), handler.ghostTotalBurned());
    }

    /// totalBurned is the sum of the per-recipient ledger.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    function invariant_TotalBurnedIsSumOfRecipients() public view {
        uint256 sum;
        for (uint256 i = 0; i < handler.recipientCount(); i++) {
            sum += exitBridge.burned(handler.recipientAt(i));
        }
        assertEq(sum, exitBridge.totalBurned());
    }

    /// Per-recipient cumulatives never decrease, close included.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    function invariant_BurnedNeverDecreases() public view {
        for (uint256 i = 0; i < handler.recipientCount(); i++) {
            address recipient = handler.recipientAt(i);
            assertGe(exitBridge.burned(recipient), handler.highWater(recipient));
        }
    }

    /// Once closed, always closed.
    /// forge-config: default.invariant.runs = 24
    /// forge-config: default.invariant.depth = 48
    function invariant_CloseIsOneWay() public view {
        if (handler.sawClosed()) assertTrue(exitBridge.closed());
    }
}
