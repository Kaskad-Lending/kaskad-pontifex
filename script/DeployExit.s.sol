// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {KskdExit} from "../src/KskdExit.sol";
import {SafeScript} from "./SafeScript.sol";

/// @notice Deploys KskdExit on Igra (mainnet 38833 / Galleon testnet 38836). On 38833 the
///         CLOSER must be a Safe with threshold >= 2 unless REQUIRE_SAFE=false.
contract DeployExit is SafeScript {
    address constant DEFAULT_KSKD = 0x16d92794F5B81d2CdEd0F0958779A410401e6435;

    error WrongChain(uint256 chainid);
    error UnexpectedSymbol(string symbol);
    error UnexpectedDecimals(uint8 decimals);
    error KskdMismatch(address expected, address actual);
    error CloserMismatch(address expected, address actual);
    error MinBurnMismatch(uint256 expected, uint256 actual);
    error DeployedClosed();
    error PermitDomainMismatch(bytes32 expected, bytes32 actual);
    error PermitUnavailable(address token);
    error ExitPredictionMismatch(address predicted, address expected);
    error PredictedAddressMismatch(address predicted, address actual);

    function run() external {
        if (block.chainid != 38833 && block.chainid != 38836) revert WrongChain(block.chainid);

        address kskd = vm.envOr("KSKD", DEFAULT_KSKD);
        address closer = vm.envAddress("CLOSER");
        if (requireSafeByDefault()) requireSafe(closer);
        // Dust floor: a free relayer pays the claim gas. 1k KSKD on mainnet.
        uint256 minBurn = vm.envOr("MIN_BURN", block.chainid == 38833 ? uint256(1000 ether) : uint256(0));
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        string memory symbol = IERC20Metadata(kskd).symbol();
        if (keccak256(bytes(symbol)) != keccak256(bytes("KSKD"))) revert UnexpectedSymbol(symbol);
        uint8 decimals = IERC20Metadata(kskd).decimals();
        if (decimals != 18) revert UnexpectedDecimals(decimals);

        address predictedExit = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        // Optional pre-commit: KskdExit is baked into the bridge PCR0 (PONTIFEX_EXIT). Fail before
        // gas if the live nonce won't land it on the pre-announced, PCR0-frozen address.
        address expectedExit = vm.envOr("EXPECTED_EXIT", address(0));
        if (expectedExit != address(0) && predictedExit != expectedExit) {
            revert ExitPredictionMismatch(predictedExit, expectedExit);
        }

        vm.startBroadcast(pk);
        KskdExit exit = new KskdExit(kskd, closer, minBurn);
        vm.stopBroadcast();

        require(address(exit) == predictedExit, PredictedAddressMismatch(predictedExit, address(exit)));
        require(address(exit.KSKD()) == kskd, KskdMismatch(kskd, address(exit.KSKD())));
        require(exit.CLOSER() == closer, CloserMismatch(closer, exit.CLOSER()));
        require(exit.minBurn() == minBurn, MinBurnMismatch(minBurn, exit.minBurn()));
        require(!exit.closed(), DeployedClosed());
        // exitWithPermit needs EIP-2612 with a matching domain; permit-less tokens (Galleon KSKD)
        // leave it a graceful no-op, so enforce only where env/chain demands it.
        bool requirePermit = vm.envOr("REQUIRE_PERMIT", block.chainid == 38833);
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(IERC20Metadata(kskd).name())),
                keccak256("1"),
                block.chainid,
                kskd
            )
        );
        try IERC20Permit(kskd).DOMAIN_SEPARATOR() returns (bytes32 live) {
            if (live != domain) {
                if (requirePermit) revert PermitDomainMismatch(domain, live);
                console.log("WARN permit: domain mismatch, exitWithPermit dead (use approve + exit)");
            }
        } catch {
            if (requirePermit) revert PermitUnavailable(kskd);
            console.log("WARN permit: no EIP-2612, exitWithPermit dead (use approve + exit)");
        }

        console.log("KskdExit :", address(exit));
        console.log("KSKD     :", kskd);
        console.log("CLOSER   :", closer);
        console.log("minBurn  :", minBurn);
    }
}
