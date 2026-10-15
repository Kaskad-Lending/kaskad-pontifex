// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {RotateEntry} from "../script/RotateEntry.s.sol";
import {KskdBridged} from "../src/KskdBridged.sol";
import {KskdEntry} from "../src/KskdEntry.sol";

contract RotationVerifierFixture {}

contract RotateEntryScriptTest is Test {
    uint256 private constant KEY = 0xA11CE;
    address private constant OLD_BRIDGE = address(0xBEEF);
    KskdBridged private token;
    RotateEntry private script;
    address private deployer;
    address private predicted;

    function setUp() public {
        vm.chainId(46630);
        deployer = vm.addr(KEY);
        vm.setNonce(deployer, 7);
        predicted = vm.computeCreateAddress(deployer, 7);
        token = new KskdBridged(OLD_BRIDGE, deployer);
        RotationVerifierFixture verifier = new RotationVerifierFixture();
        script = new RotateEntry();
        vm.setEnv("TOKEN", vm.toString(address(token)));
        vm.setEnv("VERIFIER", vm.toString(address(verifier)));
        vm.setEnv("EXPECTED_PCR0", vm.toString(bytes32(uint256(1))));
        vm.setEnv("EXPECTED_ENTRY", vm.toString(predicted));
        vm.setEnv("THRESHOLD", "1");
        vm.setEnv("MINT_LIMIT", vm.toString(uint256(25_000_000 ether)));
        vm.setEnv("OWNER", vm.toString(deployer));
        vm.setEnv("PRIVATE_KEY", vm.toString(KEY));
    }

    function testDeploysAtBakedAddressWithoutActivatingBridge() public {
        script.run();
        KskdEntry entry = KskdEntry(predicted);
        assertEq(address(entry.TOKEN()), address(token));
        assertEq(entry.owner(), deployer);
        assertEq(entry.signerCount(), 0);
        assertEq(token.bridge(), OLD_BRIDGE);
        assertEq(token.totalSupply(), 0);
        assertEq(vm.getNonce(deployer), 8);
    }

    function testNonceDriftRevertsBeforeBroadcast() public {
        vm.setNonce(deployer, 8);
        address changed = vm.computeCreateAddress(deployer, 8);
        vm.expectRevert(abi.encodeWithSelector(RotateEntry.EntryAddressMismatch.selector, changed, predicted));
        script.run();
        assertEq(vm.getNonce(deployer), 8);
        assertEq(changed.code.length, 0);
        assertEq(token.bridge(), OLD_BRIDGE);
    }
}
