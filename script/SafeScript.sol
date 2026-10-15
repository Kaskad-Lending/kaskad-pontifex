// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";

/// @notice Safe `Enum.Operation`.
enum Operation {
    Call,
    DelegateCall
}

/// @notice Safe{L2} 1.4.1 / 1.5.0 surface the scripts read.
interface ISafe {
    function nonce() external view returns (uint256);
    function getThreshold() external view returns (uint256);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce_
    ) external view returns (bytes32);
}

interface IMultiSendCallOnly {
    function multiSend(bytes memory transactions) external payable;
}

/// @notice One call the Safe makes, value 0: no Safe-owned bridge call takes ether.
struct SafeCall {
    address to;
    bytes data;
}

/// @notice A prepared Safe transaction. safeTxGas, baseGas, gasPrice, gasToken and
///         refundReceiver are all zero.
struct SafeTx {
    address safe;
    address to;
    uint256 value;
    bytes data;
    Operation operation;
    uint256 nonce;
    bytes32 safeTxHash;
}

/// @notice Prepares Safe transactions without broadcasting: the hash comes from the Safe's
///         own `getTransactionHash`, and every call is dry-run from the Safe against current state.
abstract contract SafeScript is Script {
    /// @notice Canonical MultiSendCallOnly per chain, pinned by runtime code hash.
    address internal constant MULTISEND_CALL_ONLY_141 = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    bytes32 internal constant MULTISEND_CALL_ONLY_141_CODEHASH =
        0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939;
    address internal constant MULTISEND_CALL_ONLY_150 = 0xA83c336B20401Af773B6219BA5027174338D1836;
    bytes32 internal constant MULTISEND_CALL_ONLY_150_CODEHASH =
        0xcdbdcec38d2f1c7d961b0029ff8416b7e86e9974d6f0e9c9580c7d17fcfb6663;

    uint256 internal constant MIN_SAFE_THRESHOLD = 2;

    error NotAContract(address account);
    error NotASafe(address account);
    error SafeThresholdTooLow(address safe, uint256 threshold);
    error StaleSafeNonce(uint256 given, uint256 current);
    error EmptyBatch();
    error TargetHasNoCode(uint256 index, address target);
    error NoMultiSend(uint256 chainid);
    error UnknownMultiSend(address multiSend, bytes32 codehash);
    error SafeCallReverts(uint256 index, bytes reason);

    /// @notice Reverts unless `account` has code and answers `getThreshold() >= 2`.
    function requireSafe(address account) public view {
        uint256 threshold = safeThreshold(account);
        if (threshold < MIN_SAFE_THRESHOLD) revert SafeThresholdTooLow(account, threshold);
    }

    /// @notice `getThreshold()` of `account`; reverts when it is codeless or does not answer.
    function safeThreshold(address account) public view returns (uint256) {
        if (account.code.length == 0) revert NotAContract(account);
        (bool ok, bytes memory ret) = account.staticcall(abi.encodeCall(ISafe.getThreshold, ()));
        if (!ok || ret.length != 32) revert NotASafe(account);
        return abi.decode(ret, (uint256));
    }

    /// @notice Default of the `REQUIRE_SAFE` env switch: on for Igra and Robinhood mainnet.
    function requireSafeByDefault() internal view returns (bool) {
        return vm.envOr("REQUIRE_SAFE", block.chainid == 38833 || block.chainid == 4663);
    }

    /// @notice `SAFE_NONCE` when set (to queue behind pending transactions), else the Safe's nonce.
    function safeNonce(address safe) internal view returns (uint256) {
        return checkNonce(safe, vm.envOr("SAFE_NONCE", ISafe(safe).nonce()));
    }

    /// @notice Reverts on a nonce the Safe has already consumed.
    function checkNonce(address safe, uint256 nonce_) public view returns (uint256) {
        uint256 current = ISafe(safe).nonce();
        if (nonce_ < current) revert StaleSafeNonce(nonce_, current);
        return nonce_;
    }

    /// @notice MultiSendCallOnly for this chain; refuses any other runtime code.
    function multiSendCallOnly() public view returns (address multiSend) {
        bytes32 expected;
        if (block.chainid == 38833) {
            (multiSend, expected) = (MULTISEND_CALL_ONLY_150, MULTISEND_CALL_ONLY_150_CODEHASH);
        } else if (block.chainid == 4663 || block.chainid == 46630) {
            (multiSend, expected) = (MULTISEND_CALL_ONLY_141, MULTISEND_CALL_ONLY_141_CODEHASH);
        } else {
            revert NoMultiSend(block.chainid);
        }
        if (multiSend.codehash != expected) revert UnknownMultiSend(multiSend, multiSend.codehash);
    }

    /// @notice MultiSend packing: operation (Call), to, value 0, data length, data — per call.
    function encodeMultiSend(SafeCall[] memory calls) public pure returns (bytes memory packed) {
        for (uint256 i = 0; i < calls.length; i++) {
            packed = bytes.concat(
                packed,
                abi.encodePacked(uint8(Operation.Call), calls[i].to, uint256(0), calls[i].data.length, calls[i].data)
            );
        }
    }

    /// @notice One call becomes a Call to its target, several a DelegateCall to MultiSendCallOnly.
    ///         Hash first, then each call is run in order from `safe`, as MultiSendCallOnly would.
    function prepare(address safe, SafeCall[] memory calls, uint256 nonce_) public returns (SafeTx memory t) {
        if (calls.length == 0) revert EmptyBatch();
        safeThreshold(safe);
        for (uint256 i = 0; i < calls.length; i++) {
            if (calls[i].to.code.length == 0) revert TargetHasNoCode(i, calls[i].to);
        }

        t.safe = safe;
        t.nonce = checkNonce(safe, nonce_);
        if (calls.length == 1) {
            (t.to, t.data, t.operation) = (calls[0].to, calls[0].data, Operation.Call);
        } else {
            t.to = multiSendCallOnly();
            t.data = abi.encodeCall(IMultiSendCallOnly.multiSend, (encodeMultiSend(calls)));
            t.operation = Operation.DelegateCall;
        }
        t.safeTxHash =
            ISafe(safe).getTransactionHash(t.to, 0, t.data, t.operation, 0, 0, 0, address(0), address(0), t.nonce);

        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(safe);
            (bool ok, bytes memory reason) = calls[i].to.call(calls[i].data);
            if (!ok) revert SafeCallReverts(i, reason);
        }
    }

    /// @notice Same lines as the Safe-calldata output of the other scripts, plus op, nonce and hash.
    function printSafeTx(SafeTx memory t, SafeCall[] memory calls) internal pure {
        console.log("Safe         :", t.safe);
        console.log("Safe tx to   :", t.to);
        console.log("Safe tx value: 0");
        console.log("Safe tx data :", vm.toString(t.data));
        if (t.operation == Operation.Call) {
            console.log("Safe tx op   : 0 (Call)");
        } else {
            console.log("Safe tx op   : 1 (DelegateCall to MultiSendCallOnly)");
            for (uint256 i = 0; i < calls.length; i++) {
                console.log(string.concat("  call ", vm.toString(i), " to  :"), calls[i].to);
                console.log(string.concat("  call ", vm.toString(i), " data:"), vm.toString(calls[i].data));
            }
        }
        console.log("Safe nonce   :", t.nonce);
        console.log("safeTxHash   :", vm.toString(t.safeTxHash));
        console.log("refund fields: safeTxGas, baseGas, gasPrice 0; gasToken, refundReceiver 0x0");
    }

    /// @notice One call from `safe`, prepared and printed at the Safe's resolved nonce.
    function proposeCall(address safe, address to, bytes memory data) internal returns (SafeTx memory) {
        SafeCall[] memory calls = new SafeCall[](1);
        calls[0] = SafeCall({to: to, data: data});
        return propose(safe, calls);
    }

    /// @notice `prepare` + print, at the Safe's resolved nonce.
    function propose(address safe, SafeCall[] memory calls) internal returns (SafeTx memory t) {
        t = prepare(safe, calls, safeNonce(safe));
        printSafeTx(t, calls);
    }
}
