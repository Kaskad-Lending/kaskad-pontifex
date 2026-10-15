// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {DeployRobinhood} from "../script/DeployRobinhood.s.sol";
import {
    CertManagerDouble,
    NitroProverDouble,
    NitroVerifierV1Double,
    NitroVerifierV2Double
} from "./doubles/NitroVerifierDoubles.sol";
import {StubAttestationVerifier} from "./doubles/StubAttestationVerifier.sol";

/// @notice DeployRobinhood's verifier identity check: V2 passes, V1 and non-Nitro verifiers do not.
contract DeployRobinhoodScriptTest is Test {
    DeployRobinhood private script;
    address private prover;

    function setUp() public {
        script = new DeployRobinhood();
        prover = address(new NitroProverDouble(address(new CertManagerDouble(false))));
    }

    /// A Nitro verifier without PCR1/PCR2 getters is V2.
    function testV2VerifierPasses() public {
        script.requireV2Verifier(address(new NitroVerifierV2Double(prover, bytes32(uint256(1)), address(1))));
    }

    /// A verifier answering expectedPCR1/expectedPCR2 is V1.
    function testV1VerifierRejected() public {
        address v1 = address(new NitroVerifierV1Double(prover));
        vm.expectRevert(abi.encodeWithSelector(DeployRobinhood.VerifierPinsPcrs.selector, v1));
        script.requireV2Verifier(v1);
    }

    /// A codeless verifier is refused.
    function testCodelessVerifierRejected() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(DeployRobinhood.VerifierHasNoCode.selector, eoa));
        script.requireV2Verifier(eoa);
    }

    /// A verifier without nitroProver() is not a Nitro verifier.
    function testNonNitroVerifierRejected() public {
        address stub = address(new StubAttestationVerifier());
        vm.expectRevert(abi.encodeWithSelector(DeployRobinhood.NotANitroVerifier.selector, stub));
        script.requireV2Verifier(stub);
    }

    /// A prover whose CertManager has no code is not a Nitro verifier.
    function testCodelessCertManagerRejected() public {
        address bare = address(new NitroProverDouble(makeAddr("certManager")));
        address verifier = address(new NitroVerifierV2Double(bare, bytes32(uint256(1)), address(1)));
        vm.expectRevert(abi.encodeWithSelector(DeployRobinhood.NotANitroVerifier.selector, verifier));
        script.requireV2Verifier(verifier);
    }

    /// A codeless prover is not a Nitro verifier.
    function testCodelessProverRejected() public {
        address verifier = address(new NitroVerifierV2Double(makeAddr("prover"), bytes32(uint256(1)), address(1)));
        vm.expectRevert(abi.encodeWithSelector(DeployRobinhood.NotANitroVerifier.selector, verifier));
        script.requireV2Verifier(verifier);
    }
}
