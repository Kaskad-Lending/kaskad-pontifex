// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KskdBridged} from "../../src/KskdBridged.sol";
import {KskdEntry} from "../../src/KskdEntry.sol";
import {KskdExit} from "../../src/KskdExit.sol";
import {DeployRobinhood} from "../../script/DeployRobinhood.s.sol";
import {SafeOps} from "../../script/SafeOps.s.sol";
import {Operation, SafeTx} from "../../script/SafeScript.sol";
import {SetGuardian} from "../../script/SetGuardian.s.sol";
import {StubAttestationVerifier} from "../doubles/StubAttestationVerifier.sol";

/// @notice Safe{L2} 1.4.1 / 1.5.0 surface the fork tests drive.
interface ISafeAdmin {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function nonce() external view returns (uint256);
    function domainSeparator() external view returns (bytes32);
    function approveHash(bytes32 hashToApprove) external;
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes memory signatures
    ) external payable returns (bool success);
}

/// @notice Executes script-prepared transactions on a live Safe: `threshold` owners `approveHash` the
///         printed safeTxHash, then `execTransaction` with approved-hash signatures (v = 1).
abstract contract SafeForkBase is Test {
    bytes32 internal constant DOMAIN_SEPARATOR_TYPEHASH =
        0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;
    bytes32 internal constant SAFE_TX_TYPEHASH = 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8;

    /// @dev Pin below the resolved head: a load-balanced RPC may not have the head stored yet.
    function _selectPinnedFork(string memory url, uint256 lag) internal {
        bytes memory raw = vm.rpc(url, "eth_blockNumber", "[]");
        uint256 head;
        for (uint256 i = 0; i < raw.length; i++) {
            head = (head << 8) | uint8(raw[i]);
        }
        vm.createSelectFork(url, head - lag);
    }

    function _domain(address safe) internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_SEPARATOR_TYPEHASH, block.chainid, safe));
    }

    /// @dev EIP-712 SafeTx hash with zero refund fields, recomputed from the prepared fields.
    function _eip712(SafeTx memory t) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SAFE_TX_TYPEHASH, t.to, 0, keccak256(t.data), t.operation, 0, 0, 0, address(0), address(0), t.nonce
            )
        );
        return keccak256(abi.encodePacked(hex"1901", _domain(t.safe), structHash));
    }

    function _execOnSafe(SafeTx memory t) internal {
        ISafeAdmin safe = ISafeAdmin(t.safe);
        address[] memory owners = safe.getOwners();
        _sortAscending(owners);
        bytes memory signatures;
        for (uint256 i = 0; i < safe.getThreshold(); i++) {
            vm.prank(owners[i]);
            safe.approveHash(t.safeTxHash);
            signatures = bytes.concat(signatures, abi.encodePacked(uint256(uint160(owners[i])), uint256(0), uint8(1)));
        }
        uint256 nonceBefore = safe.nonce();
        assertTrue(
            safe.execTransaction(t.to, 0, t.data, t.operation, 0, 0, 0, address(0), payable(address(0)), signatures)
        );
        assertEq(safe.nonce(), nonceBefore + 1);
    }

    function _sortAscending(address[] memory a) private pure {
        for (uint256 i = 1; i < a.length; i++) {
            address key = a[i];
            uint256 j = i;
            while (j > 0 && a[j - 1] > key) {
                a[j] = a[j - 1];
                j--;
            }
            a[j] = key;
        }
    }
}

/// @notice Robinhood testnet: the 3/5 Safe{L2} 1.4.1 that also owns the mainnet bridge (same address on 4663).
contract RobinhoodSafeForkTest is SafeForkBase {
    string constant ROBINHOOD_RPC_DEFAULT = "https://rpc.testnet.chain.robinhood.com/rpc";
    uint256 constant ROBINHOOD_LAG = 64;

    address constant SAFE = 0x313807B857222278FbddF36541DE2Af5a50BdCB5;
    address constant MULTISEND_141 = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address constant TESTNET_V1_VERIFIER = 0x525604a7cE2352F9D156C66a3D5d2cb7C96c0562;
    address constant GUARDIAN = 0x217714D086f7254940a46c0C6Abc1e7bF270235e;
    bytes32 constant PCR0 = bytes32(uint256(1));
    uint256 constant MINT_LIMIT = 25_000_000 ether;

    KskdBridged token;
    KskdEntry entry;

    function setUp() public {
        _selectPinnedFork(vm.envOr("ROBINHOOD_RPC_URL", ROBINHOOD_RPC_DEFAULT), ROBINHOOD_LAG);
        require(block.chainid == 46630, "ROBINHOOD_RPC_URL is not chain 46630");
        token = new KskdBridged(address(0), SAFE);
        entry = new KskdEntry(address(token), address(new StubAttestationVerifier()), PCR0, 1, MINT_LIMIT, SAFE);
    }

    /// The printed safeTxHash is the live Safe's EIP-712 hash.
    function testSafeTxHashIsLiveSafeEip712() public {
        SafeTx memory t = new SetGuardian().safeMode(entry, GUARDIAN, ISafeAdmin(SAFE).nonce());
        assertEq(_domain(SAFE), ISafeAdmin(SAFE).domainSeparator());
        assertEq(t.safeTxHash, _eip712(t));
    }

    /// The prepared setGuardian executes on the live Safe.
    function testSetGuardianExecutesOnSafe() public {
        SetGuardian script = new SetGuardian();
        uint256 clean = vm.snapshotState();
        SafeTx memory t = script.safeMode(entry, GUARDIAN, ISafeAdmin(SAFE).nonce());
        vm.revertToState(clean);

        _execOnSafe(t);
        assertEq(entry.guardian(), GUARDIAN);
    }

    /// A SafeOps batch executes on the live Safe through the live MultiSendCallOnly 1.4.1.
    function testBatchExecutesOnSafeThroughMultiSend() public {
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);
        (targets[0], datas[0]) = (address(entry), abi.encodeCall(KskdEntry.setMintLimit, (7)));
        (targets[1], datas[1]) = (address(token), abi.encodeCall(KskdBridged.setBridge, (address(entry))));
        SafeOps ops = new SafeOps();
        uint256 clean = vm.snapshotState();
        SafeTx memory t = ops.batch(SAFE, targets, datas);
        vm.revertToState(clean);

        assertEq(t.to, MULTISEND_141);
        _execOnSafe(t);
        assertEq(entry.mintLimit(), 7);
        assertEq(token.bridge(), address(entry));
    }

    /// The testnet entry's V1 verifier fails the V2 identity check.
    function testTestnetV1VerifierRefused() public {
        DeployRobinhood script = new DeployRobinhood();
        vm.expectRevert(abi.encodeWithSelector(DeployRobinhood.VerifierPinsPcrs.selector, TESTNET_V1_VERIFIER));
        script.requireV2Verifier(TESTNET_V1_VERIFIER);
    }

    /// The live Safe passes the deploy-time Safe check.
    function testSafePassesRequireSafe() public {
        new SafeOps().requireSafe(SAFE);
    }
}

/// @notice Igra mainnet: the 3/5 Safe{L2} 1.5.0 that is CLOSER of the live KskdExit and holds the treasury KSKD.
contract IgraSafeForkTest is SafeForkBase {
    string constant IGRA_RPC_DEFAULT = "https://rpc.igralabs.com:8545";
    uint256 constant IGRA_FINALITY_LAG = 768;

    address constant SAFE = 0x5B95Ea5D5B63998467eE92B0b175ACE49ccC1943;
    KskdExit constant EXIT = KskdExit(0x5A818D42cA142483f72AE7D426E199324FEc4871);
    address constant MULTISEND_150 = 0xA83c336B20401Af773B6219BA5027174338D1836;
    address constant IGRA_V1_VERIFIER = 0x76216b3bde5bC81b04FA5A5d4a67F6AfACc666B9;
    uint256 constant TRANCHE = 1_000_000 ether;

    SafeOps ops;
    address recipient = makeAddr("robinhoodTreasury");

    function setUp() public {
        _selectPinnedFork(vm.envOr("IGRA_RPC_URL", IGRA_RPC_DEFAULT), IGRA_FINALITY_LAG);
        require(block.chainid == 38833, "IGRA_RPC_URL is not chain 38833");
        ops = new SafeOps();
    }

    /// setMinBurn is prepared for CLOSER and hashed under the live Safe 1.5.0 domain.
    function testSetMinBurnHashIsLiveSafeEip712() public {
        SafeTx memory t = ops.setMinBurn(EXIT, 1000 ether);
        assertEq(t.safe, SAFE);
        assertEq(_domain(SAFE), ISafeAdmin(SAFE).domainSeparator());
        assertEq(t.safeTxHash, _eip712(t));
    }

    /// The treasury tranche executes on the live Safe through MultiSendCallOnly 1.5.0; the floor is restored.
    function testTreasuryExitExecutesOnSafe() public {
        IERC20 kskd = IERC20(address(EXIT.KSKD()));
        uint256 minBurn = EXIT.minBurn();
        uint256 clean = vm.snapshotState();
        SafeTx memory t = ops.treasuryExit(SAFE, EXIT, TRANCHE, recipient);
        vm.revertToState(clean);

        uint256 balance = kskd.balanceOf(SAFE);
        uint256 burned = EXIT.burned(recipient);
        assertEq(t.to, MULTISEND_150);
        assertEq(uint8(t.operation), uint8(Operation.DelegateCall));
        _execOnSafe(t);
        assertEq(EXIT.burned(recipient), burned + TRANCHE);
        assertEq(kskd.balanceOf(SAFE), balance - TRANCHE);
        assertEq(EXIT.minBurn(), minBurn);
    }

    /// The Igra oracle's V1 verifier fails the V2 identity check.
    function testIgraV1VerifierRefused() public {
        DeployRobinhood script = new DeployRobinhood();
        vm.expectRevert(abi.encodeWithSelector(DeployRobinhood.VerifierPinsPcrs.selector, IGRA_V1_VERIFIER));
        script.requireV2Verifier(IGRA_V1_VERIFIER);
    }
}
