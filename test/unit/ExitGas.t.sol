// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {KskdExit} from "../../src/KskdExit.sol";
import {KSKD} from "../fixtures/KSKD.sol";

/// @notice Execution gas of both exit paths on the Igra side, cold and warm.
contract ExitGasTest is Test {
    /// Widest measured path plus headroom; a regression past this is a design change, not noise.
    uint256 internal constant CEILING = 160_000;

    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 internal constant HOLDER_PK = 0xA11CE;
    uint256 internal constant AMOUNT = 1_000 ether;
    uint256 internal constant FUNDING = 1_000_000 ether;

    KSKD internal kskd;
    KskdExit internal exitBridge;

    address internal multisig = makeAddr("multisig");
    address internal closer = makeAddr("closer");
    address internal recipient = makeAddr("recipient");
    address internal holder = vm.addr(HOLDER_PK);

    function _deploy() internal {
        kskd = new KSKD(multisig);
        exitBridge = new KskdExit(address(kskd), closer, 0);
        vm.prank(multisig);
        assertTrue(kskd.transfer(holder, FUNDING));
    }

    function _signPermit(uint256 value, uint256 deadline) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 structHash =
            keccak256(abi.encode(PERMIT_TYPEHASH, holder, address(exitBridge), value, kskd.nonces(holder), deadline));
        return vm.sign(HOLDER_PK, keccak256(abi.encodePacked("\x19\x01", kskd.DOMAIN_SEPARATOR(), structHash)));
    }

    function _exit() internal returns (uint256 used) {
        vm.prank(holder);
        uint256 before = gasleft();
        exitBridge.exit(AMOUNT, recipient);
        used = before - gasleft();
        assertLt(used, CEILING);
    }

    function _exitWithPermit(uint256 deadline) internal returns (uint256 used) {
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(AMOUNT, deadline);
        vm.prank(holder);
        uint256 before = gasleft();
        exitBridge.exitWithPermit(AMOUNT, recipient, deadline, v, r, s);
        used = before - gasleft();
        assertLt(used, CEILING);
    }

    /// Both exit paths stay far under the ceiling, first exit and repeat, and the permit costs one signature check.
    function test_ExitPathsStayUnderTheCeiling() public {
        vm.warp(1_700_000_000);
        uint256 deadline = block.timestamp + 365 days;

        _deploy();
        vm.prank(holder);
        kskd.approve(address(exitBridge), type(uint256).max);
        emit log_named_uint("1 exit, first for the recipient (standing approval)", _exit());
        emit log_named_uint("2 exit, repeat for the same recipient", _exit());

        _deploy();
        emit log_named_uint("3 exitWithPermit, first for the recipient", _exitWithPermit(deadline));
        emit log_named_uint("4 exitWithPermit, repeat for the same recipient", _exitWithPermit(deadline));
    }
}
