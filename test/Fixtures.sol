// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

/// @notice Reads a hex fixture (no `0x` prefix) from `test/fixtures/`.
abstract contract Fixtures is Test {
    function _fixture(string memory name) internal view returns (bytes memory) {
        return vm.parseBytes(string.concat("0x", vm.trim(vm.readFile(string.concat("test/fixtures/", name)))));
    }
}
