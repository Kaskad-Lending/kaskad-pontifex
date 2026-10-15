// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console} from "forge-std/Script.sol";
import {KskdEntry} from "../src/KskdEntry.sol";
import {SafeCall, SafeScript, SafeTx} from "./SafeScript.sol";

/// @notice Sets the KskdEntry guardian on Robinhood (mainnet 4663 / testnet 46630).
///         Separate from deploy: DeployRobinhood asserts guardian == address(0).
///         EOA owner: the broadcast key must be the owner. Safe owner (has code): nothing is
///         broadcast and PRIVATE_KEY is not read; the Safe transaction is printed instead.
contract SetGuardian is SafeScript {
    error WrongChain(uint256 chainid);
    error ZeroGuardian();
    error NotOwner(address broadcaster, address owner);
    error GuardianNotSet(address expected, address actual);

    function run() external {
        if (block.chainid != 4663 && block.chainid != 46630) revert WrongChain(block.chainid);

        KskdEntry entry = KskdEntry(vm.envAddress("ENTRY"));
        address guardian_ = vm.envAddress("GUARDIAN");

        if (guardian_ == address(0)) revert ZeroGuardian();
        address owner_ = entry.owner();
        if (owner_.code.length != 0) {
            safeMode(entry, guardian_, safeNonce(owner_));
            return;
        }

        uint256 pk = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(pk);
        if (broadcaster != owner_) revert NotOwner(broadcaster, owner_);

        vm.startBroadcast(pk);
        entry.setGuardian(guardian_);
        vm.stopBroadcast();

        require(entry.guardian() == guardian_, GuardianNotSet(guardian_, entry.guardian()));

        console.log("KskdEntry:", address(entry));
        console.log("guardian :", guardian_);
    }

    /// @notice Safe-owned entry: dry-runs `setGuardian` from the Safe and prints the Safe tx.
    function safeMode(KskdEntry entry, address guardian_, uint256 nonce_) public returns (SafeTx memory t) {
        if (guardian_ == address(0)) revert ZeroGuardian();
        SafeCall[] memory calls = new SafeCall[](1);
        calls[0] = SafeCall({to: address(entry), data: abi.encodeCall(KskdEntry.setGuardian, (guardian_))});
        t = prepare(entry.owner(), calls, nonce_);
        require(entry.guardian() == guardian_, GuardianNotSet(guardian_, entry.guardian()));

        console.log("KskdEntry:", address(entry));
        console.log("guardian :", guardian_);
        printSafeTx(t, calls);
    }
}
