// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Operation} from "../../script/SafeScript.sol";

/// @notice Safe{L2} 1.4.1 transaction hashing with a fixed threshold. `exec` runs a transaction the way
///         the Safe does once signatures pass, and skips the signature check.
contract SafeDouble {
    bytes32 private constant DOMAIN_SEPARATOR_TYPEHASH =
        keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
    bytes32 private constant SAFE_TX_TYPEHASH = keccak256(
        "SafeTx(address to,uint256 value,bytes data,uint8 operation,uint256 safeTxGas,uint256 baseGas,uint256 gasPrice,address gasToken,address refundReceiver,uint256 nonce)"
    );

    uint256 public nonce;
    uint256 private immutable THRESHOLD;

    error ExecFailed(bytes reason);

    constructor(uint256 threshold) {
        THRESHOLD = threshold;
    }

    function getThreshold() external view returns (uint256) {
        return THRESHOLD;
    }

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
    ) external view returns (bytes32) {
        bytes32 structHash = keccak256(
            bytes.concat(
                abi.encode(SAFE_TX_TYPEHASH, to, value, keccak256(data), operation, safeTxGas),
                abi.encode(baseGas, gasPrice, gasToken, refundReceiver, nonce_)
            )
        );
        bytes32 domain = keccak256(abi.encode(DOMAIN_SEPARATOR_TYPEHASH, block.chainid, address(this)));
        return keccak256(abi.encodePacked(bytes1(0x19), bytes1(0x01), domain, structHash));
    }

    function exec(address to, bytes calldata data, Operation operation) external {
        nonce++;
        (bool ok, bytes memory reason) = operation == Operation.Call ? to.call(data) : to.delegatecall(data);
        if (!ok) revert ExecFailed(reason);
    }
}
