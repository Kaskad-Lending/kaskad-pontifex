// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {KskdExit, IKskdBurnable} from "../../src/KskdExit.sol";
import {KskdBridged} from "../../src/KskdBridged.sol";
import {KskdEntry} from "../../src/KskdEntry.sol";
import {StubAttestationVerifier} from "../doubles/StubAttestationVerifier.sol";

/// @notice End-to-end migration over two live forks: the exit burns the real Igra KSKD, the test
///         plays the enclave (reads `burned` on the Igra fork, signs the EIP-712 claim) and the
///         entry mints on the Robinhood fork. StubAttestationVerifier is the only double — the
///         Nitro verifier stack is not deployed on Robinhood; everything else runs against live
///         chain state. The real verifier is exercised in RealVerifier.t.sol on the Igra fork.
contract BridgeForkTest is Test {
    uint256 constant IGRA_CHAIN_ID = 38833;
    uint256 constant ROBINHOOD_CHAIN_ID = 46630;
    string constant IGRA_RPC_DEFAULT = "https://rpc.igralabs.com:8545";
    string constant ROBINHOOD_RPC_DEFAULT = "https://rpc.testnet.chain.robinhood.com/rpc";

    address constant KSKD = 0x16d92794F5B81d2CdEd0F0958779A410401e6435;
    address constant HOLDER_SAFE = 0x5B95Ea5D5B63998467eE92B0b175ACE49ccC1943;
    address constant HOLDER_2 = 0xB30099964080a9B6724A94782d156Cc22280389E;
    address constant HOLDER_3 = 0x326020A92b0c475EE00fe0235fC238Ab1bbacdA1;
    address constant HOLDER_4 = 0xDF2f434B3a1a1939A0A2bDd9BEd56B1C50a32750;

    // Test-only enclave signing keys; the production key never leaves the enclave.
    uint256 constant ENCLAVE_KEY_A = 0xA11CE;
    uint256 constant ENCLAVE_KEY_B = 0xB0B;

    /// In-test key funded from the Safe so the suite can sign an EIP-2612 permit for the live KSKD.
    uint256 constant PERMIT_KEY = 0x5E17;

    bytes32 constant PCR0 = keccak256("pontifex.enclave.pcr0");
    uint256 constant MINT_LIMIT = 500_000_000 ether;
    uint256 constant SMALL_LIMIT = 1 ether;
    uint256 constant EXIT_AMOUNT = 1_000 ether;

    /// Igra's RPC is load balanced across nodes at slightly different heights; pin the fork to
    /// `finalized` (latest − 768) so state lookups never race the head.
    uint256 constant IGRA_FINALITY_LAG = 768;

    /// Robinhood keeps ~5200 blocks of state; pin off the head so a lagging backend still has it.
    uint256 constant ROBINHOOD_LAG = 64;

    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 constant CLAIM_TYPEHASH = keccak256("Claim(address recipient,uint256 cumulativeBurned,uint256 deadline)");
    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    uint256 igraFork;
    uint256 robinFork;
    uint256 igraBlock;
    uint256 robinBlock;

    address holder; // live Igra KSKD holder, picked at runtime
    address permitHolder; // funded from the Safe on the Igra fork
    address owner;
    address guardian;
    address relayer;
    address recipient;
    address recipient2;

    KskdExit exitContract; // Igra fork only
    KskdBridged bridged; // Robinhood fork only
    KskdEntry entry; // Robinhood fork only
    StubAttestationVerifier stub; // Robinhood fork only

    /// Creating a fork at the head races the load balancer: one backend reports a height that
    /// another has not stored yet. Resolve the head first, then pin the fork below it.
    function _pinnedFork(string memory url, uint256 lag) private returns (uint256) {
        bytes memory raw = vm.rpc(url, "eth_blockNumber", "[]");
        uint256 head;
        for (uint256 i = 0; i < raw.length; i++) {
            head = (head << 8) | uint8(raw[i]);
        }
        return vm.createFork(url, head - lag);
    }

    function setUp() public {
        igraFork = _pinnedFork(vm.envOr("IGRA_RPC_URL", IGRA_RPC_DEFAULT), IGRA_FINALITY_LAG);
        robinFork = _pinnedFork(vm.envOr("ROBINHOOD_RPC_URL", ROBINHOOD_RPC_DEFAULT), ROBINHOOD_LAG);

        owner = makeAddr("pontifexOwner");
        guardian = makeAddr("pontifexGuardian");
        relayer = makeAddr("relayer");
        permitHolder = vm.addr(PERMIT_KEY);
        recipient = makeAddr("robinhoodRecipient");
        recipient2 = makeAddr("robinhoodRecipient2");

        vm.selectFork(igraFork);
        require(block.chainid == IGRA_CHAIN_ID, "IGRA_RPC_URL is not chain 38833");
        igraBlock = block.number;
        holder = _pickHolder();
        exitContract = new KskdExit(KSKD, HOLDER_SAFE, 0);

        vm.selectFork(robinFork);
        require(block.chainid == ROBINHOOD_CHAIN_ID, "ROBINHOOD_RPC_URL is not chain 46630");
        robinBlock = block.number;
        stub = new StubAttestationVerifier();
        bridged = new KskdBridged(address(0), owner);
        entry = new KskdEntry(address(bridged), address(stub), PCR0, 1, MINT_LIMIT, owner);
        vm.prank(owner);
        bridged.setBridge(address(entry));
        _registerEnclave(entry, ENCLAVE_KEY_A);
    }

    // ─── 1. Fork sanity ──────────────────────────────────────────────────

    /// Each fork is its own live chain, live KSKD metadata is as expected and the bridged cap
    /// covers the live Igra supply.
    function test_ForkSanity_LiveTokenFitsBridgedCap() public {
        vm.selectFork(robinFork);
        assertEq(block.chainid, ROBINHOOD_CHAIN_ID, "robinhood chain id");
        uint256 cap = bridged.MAX_SUPPLY();
        assertEq(cap, 1_000_000_000 ether, "MAX_SUPPLY");

        vm.selectFork(igraFork);
        assertEq(block.chainid, IGRA_CHAIN_ID, "igra chain id");
        assertEq(IERC20Metadata(KSKD).name(), "Kaskad", "live KSKD name");
        assertEq(IERC20Metadata(KSKD).symbol(), "KSKD", "live KSKD symbol");
        assertEq(IERC20Metadata(KSKD).decimals(), 18, "live KSKD decimals");

        uint256 live = IKskdBurnable(KSKD).totalSupply();
        assertGt(live, 0, "live supply");
        assertLe(live, cap, "live supply exceeds bridged cap");

        console2.log("igra fork block      ", igraBlock);
        console2.log("robinhood fork block ", robinBlock);
        console2.log("live KSKD totalSupply", live);
        console2.log("holder               ", holder);
    }

    /// The entry's EIP-712 domain and claim typehash are the ones the enclave has to sign under.
    function test_ForkSanity_EntryDomainIsRobinhoodScoped() public {
        vm.selectFork(robinFork);
        (, string memory name, string memory version, uint256 chainId, address verifying,,) = entry.eip712Domain();
        assertEq(name, "Pontifex", "domain name");
        assertEq(version, "1", "domain version");
        assertEq(chainId, ROBINHOOD_CHAIN_ID, "domain chain id");
        assertEq(verifying, address(entry), "domain verifying contract");
        assertEq(entry.CLAIM_TYPEHASH(), CLAIM_TYPEHASH, "typehash");
        assertEq(entry.WINDOW(), 1 days, "mint-limit window");
    }

    // ─── 2. Igra exit against the live token ─────────────────────────────

    /// exit() burns live KSKD: holder balance and live total supply drop, the exit keeps nothing
    /// and a second exit accumulates.
    function test_Igra_ExitBurnsLiveSupplyAndAccumulates() public {
        vm.selectFork(igraFork);
        IKskdBurnable kskd = IKskdBurnable(KSKD);

        uint256 holderBefore = kskd.balanceOf(holder);
        uint256 supplyBefore = kskd.totalSupply();

        vm.prank(holder);
        kskd.approve(address(exitContract), EXIT_AMOUNT * 2);

        vm.expectEmit(true, true, false, true, address(exitContract));
        emit KskdExit.Exited(holder, recipient, EXIT_AMOUNT, EXIT_AMOUNT);
        vm.prank(holder);
        exitContract.exit(EXIT_AMOUNT, recipient);

        assertEq(kskd.balanceOf(holder), holderBefore - EXIT_AMOUNT, "holder balance");
        assertEq(kskd.totalSupply(), supplyBefore - EXIT_AMOUNT, "burn did not reduce live supply");
        assertEq(kskd.balanceOf(address(exitContract)), 0, "exit contract holds KSKD");
        assertEq(exitContract.burned(recipient), EXIT_AMOUNT, "burned[recipient]");
        assertEq(exitContract.totalBurned(), EXIT_AMOUNT, "totalBurned");

        vm.prank(holder);
        exitContract.exit(EXIT_AMOUNT, recipient);

        assertEq(exitContract.burned(recipient), 2 * EXIT_AMOUNT, "burned[recipient] after second exit");
        assertEq(exitContract.totalBurned(), 2 * EXIT_AMOUNT, "totalBurned after second exit");
        assertEq(kskd.totalSupply(), supplyBefore - 2 * EXIT_AMOUNT, "live supply after second exit");
        assertEq(kskd.balanceOf(address(exitContract)), 0, "exit contract holds KSKD after second exit");
    }

    /// exit() rejects a zero amount and the three recipients that would strand the burn.
    function test_Igra_ExitRejectsZeroAmountAndBadRecipients() public {
        vm.selectFork(igraFork);
        vm.prank(holder);
        IKskdBurnable(KSKD).approve(address(exitContract), EXIT_AMOUNT);

        vm.prank(holder);
        vm.expectRevert(KskdExit.ZeroAmount.selector);
        exitContract.exit(0, recipient);

        address[3] memory bad = [address(0), address(exitContract), KSKD];
        for (uint256 i = 0; i < bad.length; i++) {
            vm.prank(holder);
            vm.expectRevert(abi.encodeWithSelector(KskdExit.InvalidRecipient.selector, bad[i]));
            exitContract.exit(EXIT_AMOUNT, bad[i]);
        }

        assertEq(exitContract.totalBurned(), 0, "nothing burned");
    }

    /// close() by the Igra Safe stops exit() for good, leaves `burned` readable and does not
    /// strand the last attested total on Robinhood.
    function test_Igra_CloseBySafeStopsExitAndKeepsLedger() public {
        uint256 cumulative = _exitOnIgra(EXIT_AMOUNT);
        assertEq(exitContract.CLOSER(), HOLDER_SAFE, "CLOSER");

        vm.prank(relayer);
        vm.expectRevert(KskdExit.NotCloser.selector);
        exitContract.close();

        vm.expectEmit(false, false, false, true, address(exitContract));
        emit KskdExit.Closed();
        vm.prank(HOLDER_SAFE);
        exitContract.close();
        assertTrue(exitContract.closed(), "closed");

        vm.prank(holder);
        IKskdBurnable(KSKD).approve(address(exitContract), EXIT_AMOUNT);
        vm.prank(holder);
        vm.expectRevert(KskdExit.ExitClosed.selector);
        exitContract.exit(EXIT_AMOUNT, recipient);

        vm.prank(HOLDER_SAFE);
        vm.expectRevert(KskdExit.ExitClosed.selector);
        exitContract.close();

        assertEq(exitContract.burned(recipient), cumulative, "burned[recipient] after close");
        assertEq(exitContract.totalBurned(), cumulative, "totalBurned after close");

        vm.selectFork(robinFork);
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(relayer);
        entry.claim(recipient, cumulative, deadline, _attest(ENCLAVE_KEY_A, recipient, cumulative, deadline));
        assertEq(bridged.balanceOf(recipient), cumulative, "last total still claimable after close");
    }

    // ─── 3. End to end, Igra → Robinhood ─────────────────────────────────

    /// Burn on Igra, read `burned`, sign on Robinhood: the claim mints 1:1 and a later burn mints
    /// only the delta.
    function test_EndToEnd_IgraBurnMintsOnRobinhood() public {
        uint256 cumulative = _exitOnIgra(EXIT_AMOUNT);
        assertEq(cumulative, EXIT_AMOUNT, "first cumulative burn");

        vm.selectFork(robinFork);
        uint256 deadline = block.timestamp + 1 hours;
        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.Claimed(recipient, cumulative, cumulative, cumulative);
        vm.prank(relayer);
        entry.claim(recipient, cumulative, deadline, _attest(ENCLAVE_KEY_A, recipient, cumulative, deadline));

        assertEq(bridged.balanceOf(recipient), cumulative, "minted balance");
        assertEq(bridged.bridgedIn(recipient), cumulative, "bridgedIn");
        assertEq(bridged.totalSupply(), cumulative, "total supply");
        assertEq(bridged.totalSupply(), cumulative, "bridged total supply");

        uint256 cumulative2 = _exitOnIgra(EXIT_AMOUNT * 3);
        assertEq(cumulative2, cumulative + EXIT_AMOUNT * 3, "second cumulative burn");

        vm.selectFork(robinFork);
        deadline = block.timestamp + 1 hours;
        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.Claimed(recipient, cumulative2 - cumulative, cumulative2, cumulative2);
        vm.prank(relayer);
        entry.claim(recipient, cumulative2, deadline, _attest(ENCLAVE_KEY_A, recipient, cumulative2, deadline));

        assertEq(bridged.balanceOf(recipient), cumulative2, "only the delta was minted");
        assertEq(bridged.totalSupply(), cumulative2, "total supply after delta");
        assertEq(bridged.totalSupply(), cumulative2, "bridged total supply after delta");
    }

    /// Re-presenting a total already bridged reverts NothingToMint, so signatures are not a bearer
    /// instrument.
    function test_EndToEnd_ReplayOfBridgedTotalReverts() public {
        uint256 cumulative = _exitOnIgra(EXIT_AMOUNT);

        vm.selectFork(robinFork);
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _attest(ENCLAVE_KEY_A, recipient, cumulative, deadline);
        vm.prank(relayer);
        entry.claim(recipient, cumulative, deadline, sigs);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NothingToMint.selector, cumulative, cumulative));
        entry.claim(recipient, cumulative, deadline, sigs);

        assertEq(bridged.balanceOf(recipient), cumulative, "replay minted twice");
    }

    // ─── 4. Partial fill ─────────────────────────────────────────────────

    /// A total larger than the window budget fills in slices: the same signatures finish the job
    /// after each window roll, then NothingToMint.
    function test_PartialFill_SameSignaturesCompleteAfterWindowRoll() public {
        uint256 cumulative = _exitOnIgra(EXIT_AMOUNT * 3);

        vm.selectFork(robinFork);
        vm.prank(owner);
        entry.setMintLimit(EXIT_AMOUNT);

        uint256 deadline = block.timestamp + 30 days;
        bytes[] memory sigs = _attest(ENCLAVE_KEY_A, recipient, cumulative, deadline);

        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.Claimed(recipient, EXIT_AMOUNT, EXIT_AMOUNT, cumulative);
        vm.prank(relayer);
        entry.claim(recipient, cumulative, deadline, sigs);
        assertEq(bridged.balanceOf(recipient), EXIT_AMOUNT, "first slice");
        assertEq(entry.windowMinted(), EXIT_AMOUNT, "windowMinted after first slice");

        vm.prank(relayer);
        vm.expectRevert(KskdEntry.MintLimitExhausted.selector);
        entry.claim(recipient, cumulative, deadline, sigs);

        vm.warp(entry.windowStart() + entry.WINDOW());
        vm.prank(relayer);
        entry.claim(recipient, cumulative, deadline, sigs);
        assertEq(bridged.balanceOf(recipient), 2 * EXIT_AMOUNT, "second slice");

        vm.warp(entry.windowStart() + entry.WINDOW());
        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.Claimed(recipient, EXIT_AMOUNT, cumulative, cumulative);
        vm.prank(relayer);
        entry.claim(recipient, cumulative, deadline, sigs);
        assertEq(bridged.balanceOf(recipient), cumulative, "third slice completes the total");
        assertEq(bridged.bridgedIn(recipient), cumulative, "bridgedIn after completion");

        vm.warp(entry.windowStart() + entry.WINDOW());
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NothingToMint.selector, cumulative, cumulative));
        entry.claim(recipient, cumulative, deadline, sigs);
    }

    // ─── 5. Deadline ─────────────────────────────────────────────────────

    /// A claim past its deadline reverts ClaimExpired; the boundary block is still accepted.
    function test_Claim_ExpiredDeadlineReverts() public {
        vm.selectFork(robinFork);

        uint256 stale = block.timestamp - 1;
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ClaimExpired.selector, stale));
        entry.claim(recipient, EXIT_AMOUNT, stale, _attest(ENCLAVE_KEY_A, recipient, EXIT_AMOUNT, stale));
        assertEq(bridged.balanceOf(recipient), 0, "expired claim minted");

        uint256 edge = block.timestamp;
        vm.prank(relayer);
        entry.claim(recipient, EXIT_AMOUNT, edge, _attest(ENCLAVE_KEY_A, recipient, EXIT_AMOUNT, edge));
        assertEq(bridged.balanceOf(recipient), EXIT_AMOUNT, "deadline == now rejected");
    }

    // ─── 6. threshold = 2 ────────────────────────────────────────────────

    /// With threshold 2 a single signature is InsufficientSignatures and the sorted A+B quorum mints.
    function test_Threshold2_QuorumMintsWhenSorted() public {
        vm.selectFork(robinFork);
        _registerEnclave(entry, ENCLAVE_KEY_B);
        vm.prank(owner);
        entry.setThreshold(2);
        assertEq(entry.signerCount(), 2, "signerCount");
        assertEq(entry.threshold(), 2, "threshold");

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _claimDigest(address(entry), block.chainid, recipient, EXIT_AMOUNT, deadline);

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InsufficientSignatures.selector, 1, 2));
        entry.claim(recipient, EXIT_AMOUNT, deadline, _sigs(_sign(ENCLAVE_KEY_A, digest)));

        bytes[] memory quorum = _quorum(digest, true);
        uint256 gasBefore = gasleft();
        vm.prank(relayer);
        entry.claim(recipient, EXIT_AMOUNT, deadline, quorum);
        emit log_named_uint("threshold-2 claim gas", gasBefore - gasleft());
        assertEq(bridged.balanceOf(recipient), EXIT_AMOUNT, "quorum mint");
    }

    /// A quorum in descending signer order is rejected, so duplicates cannot pad the count.
    function test_Threshold2_DescendingQuorumReverts() public {
        vm.selectFork(robinFork);
        _registerEnclave(entry, ENCLAVE_KEY_B);
        vm.prank(owner);
        entry.setThreshold(2);

        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory unsorted =
            _quorum(_claimDigest(address(entry), block.chainid, recipient, EXIT_AMOUNT, deadline), false);

        vm.prank(relayer);
        vm.expectRevert(KskdEntry.UnsortedSigners.selector);
        entry.claim(recipient, EXIT_AMOUNT, deadline, unsorted);
    }

    /// setThreshold cannot exceed the signer count, so the quorum is never unreachable by mistake.
    function test_Threshold_AboveSignerCountReverts() public {
        vm.selectFork(robinFork);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.ThresholdAboveSignerCount.selector, 2, 1));
        entry.setThreshold(2);

        _registerEnclave(entry, ENCLAVE_KEY_B);
        vm.prank(owner);
        entry.setThreshold(2);
        assertEq(entry.threshold(), 2, "threshold after second signer");
    }

    // ─── 7. Signer registry ──────────────────────────────────────────────

    /// registerEnclave rejects a re-registration, a zero signer and an invalid document.
    function test_Registry_SecondRegistrationReverts() public {
        vm.selectFork(robinFork);
        address signerA = vm.addr(ENCLAVE_KEY_A);
        assertTrue(entry.validSigner(signerA), "signer A registered in setUp");

        bytes memory replay = stub.encode(true, PCR0, signerA);
        bytes memory zeroSigner = stub.encode(true, PCR0, address(0));
        bytes memory invalid = stub.encode(false, PCR0, vm.addr(ENCLAVE_KEY_B));

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.SignerAlreadyRegistered.selector, signerA));
        entry.registerEnclave(replay);
        assertEq(entry.signerCount(), 1, "signerCount after rejected re-registration");

        vm.prank(owner);
        vm.expectRevert(KskdEntry.ZeroAddress.selector);
        entry.registerEnclave(zeroSigner);

        vm.prank(owner);
        vm.expectRevert(KskdEntry.InvalidAttestation.selector);
        entry.registerEnclave(invalid);
    }

    // ─── 8. Cross domain ─────────────────────────────────────────────────

    /// A claim signed under the Igra chain id recovers a foreign address on Robinhood.
    function test_CrossDomain_IgraChainIdSignatureRejected() public {
        vm.selectFork(robinFork);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 igraDigest = _claimDigest(address(entry), IGRA_CHAIN_ID, recipient, EXIT_AMOUNT, deadline);
        bytes32 robinDigest = _claimDigest(address(entry), block.chainid, recipient, EXIT_AMOUNT, deadline);
        assertTrue(igraDigest != robinDigest, "domains collide");

        bytes memory sig = _sign(ENCLAVE_KEY_A, igraDigest);
        address recovered = ECDSA.recover(robinDigest, sig);
        assertTrue(recovered != vm.addr(ENCLAVE_KEY_A), "cross-domain signature recovered the enclave");

        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(KskdEntry.InvalidSigner.selector, recovered));
        entry.claim(recipient, EXIT_AMOUNT, deadline, _sigs(sig));
    }

    // ─── 9. Trust boundary ───────────────────────────────────────────────

    /// The enclave key is the trust root: the entry cannot read Igra, so a total larger than the
    /// real burn mints the inflated amount.
    function test_TrustBoundary_UnbackedTotalStillMints() public {
        uint256 burnedOnIgra = _exitOnIgra(EXIT_AMOUNT);

        vm.selectFork(robinFork);
        uint256 inflated = burnedOnIgra * 10;
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(relayer);
        entry.claim(recipient, inflated, deadline, _attest(ENCLAVE_KEY_A, recipient, inflated, deadline));

        assertEq(bridged.balanceOf(recipient), inflated, "unbacked mint");
        assertGt(bridged.bridgedIn(recipient), burnedOnIgra, "bridgedIn exceeds Igra burn");
    }

    /// mintLimit is the only on-chain bound on a leaked key: an unbacked total is trimmed to the
    /// window budget and the rest is stuck until the window rolls.
    function test_TrustBoundary_MintLimitCapsLeakedKey() public {
        vm.selectFork(robinFork);
        vm.prank(owner);
        entry.setMintLimit(SMALL_LIMIT);

        uint256 requested = 1_000_000 ether;
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _attest(ENCLAVE_KEY_A, recipient, requested, deadline);

        vm.prank(relayer);
        entry.claim(recipient, requested, deadline, sigs);
        assertEq(bridged.balanceOf(recipient), SMALL_LIMIT, "leaked key drained more than the window");
        assertEq(bridged.totalSupply(), SMALL_LIMIT, "total supply");

        vm.prank(relayer);
        vm.expectRevert(KskdEntry.MintLimitExhausted.selector);
        entry.claim(recipient, requested, deadline, sigs);
    }

    // ─── 10. Whale starvation (accepted behaviour) ───────────────────────

    /// Accepted: one claim can take the whole window, starving a second recipient until the roll.
    function test_WhaleStarvation_OneClaimExhaustsTheWindow() public {
        uint256 whaleTotal = _exitOnIgra(EXIT_AMOUNT * 2);

        vm.selectFork(robinFork);
        vm.prank(owner);
        entry.setMintLimit(EXIT_AMOUNT);

        uint256 deadline = block.timestamp + 7 days;
        vm.prank(relayer);
        entry.claim(recipient, whaleTotal, deadline, _attest(ENCLAVE_KEY_A, recipient, whaleTotal, deadline));
        assertEq(bridged.balanceOf(recipient), EXIT_AMOUNT, "whale slice");
        assertEq(entry.windowMinted(), entry.mintLimit(), "window not exhausted");

        bytes[] memory small = _attest(ENCLAVE_KEY_A, recipient2, 1 ether, deadline);
        vm.prank(relayer);
        vm.expectRevert(KskdEntry.MintLimitExhausted.selector);
        entry.claim(recipient2, 1 ether, deadline, small);
        assertEq(bridged.balanceOf(recipient2), 0, "starved recipient minted");

        vm.warp(entry.windowStart() + entry.WINDOW());
        vm.prank(relayer);
        entry.claim(recipient2, 1 ether, deadline, small);
        assertEq(bridged.balanceOf(recipient2), 1 ether, "starved recipient after the roll");
    }

    // ─── 11. Kill switches ───────────────────────────────────────────────

    /// The guardian can only zero mintLimit; that stops claims until the owner restores it.
    function test_Guardian_PauseZeroesMintLimit() public {
        vm.selectFork(robinFork);

        vm.prank(guardian);
        vm.expectRevert(KskdEntry.NotGuardian.selector);
        entry.pause();

        vm.prank(owner);
        entry.setGuardian(guardian);
        assertEq(entry.guardian(), guardian, "guardian");

        vm.expectEmit(false, false, false, true, address(entry));
        emit KskdEntry.MintLimitSet(0);
        vm.prank(guardian);
        entry.pause();
        assertEq(entry.mintLimit(), 0, "mintLimit after pause");

        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _attest(ENCLAVE_KEY_A, recipient, EXIT_AMOUNT, deadline);
        vm.prank(relayer);
        vm.expectRevert(KskdEntry.MintLimitExhausted.selector);
        entry.claim(recipient, EXIT_AMOUNT, deadline, sigs);

        vm.prank(owner);
        entry.setMintLimit(MINT_LIMIT);
        vm.prank(relayer);
        entry.claim(recipient, EXIT_AMOUNT, deadline, sigs);
        assertEq(bridged.balanceOf(recipient), EXIT_AMOUNT, "claims resume after the owner restores the budget");
    }

    /// Unwiring the bridge on the token stops every claim with NotBridge.
    function test_KillSwitch_SetBridgeZeroStopsClaims() public {
        vm.selectFork(robinFork);
        uint256 deadline = block.timestamp + 1 hours;
        bytes[] memory sigs = _attest(ENCLAVE_KEY_A, recipient, EXIT_AMOUNT, deadline);

        vm.prank(owner);
        bridged.setBridge(address(0));

        vm.prank(relayer);
        vm.expectRevert(KskdBridged.NotBridge.selector);
        entry.claim(recipient, EXIT_AMOUNT, deadline, sigs);
    }

    // ─── 12. Image rotation ──────────────────────────────────────────────

    /// Rotating the token to a replacement entry keeps `bridgedIn`: the old total mints nothing
    /// through the new entry, only the delta does, and the retired entry is dead.
    function test_TokenRotation_ReplacementEntryKeepsCumulative() public {
        vm.selectFork(robinFork);
        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(relayer);
        entry.claim(recipient, EXIT_AMOUNT, deadline, _attest(ENCLAVE_KEY_A, recipient, EXIT_AMOUNT, deadline));
        assertEq(bridged.bridgedIn(recipient), EXIT_AMOUNT, "bridgedIn before rotation");

        KskdEntry next = new KskdEntry(address(bridged), address(stub), PCR0, 1, MINT_LIMIT, owner);
        vm.prank(owner);
        bridged.setBridge(address(next));
        _registerEnclave(next, ENCLAVE_KEY_A);

        bytes32 replayDigest = _claimDigest(address(next), block.chainid, recipient, EXIT_AMOUNT, deadline);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(KskdBridged.NothingToMint.selector, EXIT_AMOUNT, EXIT_AMOUNT));
        next.claim(recipient, EXIT_AMOUNT, deadline, _sigs(_sign(ENCLAVE_KEY_A, replayDigest)));

        uint256 higher = EXIT_AMOUNT * 3;
        bytes32 deltaDigest = _claimDigest(address(next), block.chainid, recipient, higher, deadline);
        vm.expectEmit(true, false, false, true, address(next));
        emit KskdEntry.Claimed(recipient, higher - EXIT_AMOUNT, higher, higher);
        vm.prank(relayer);
        next.claim(recipient, higher, deadline, _sigs(_sign(ENCLAVE_KEY_A, deltaDigest)));
        assertEq(bridged.balanceOf(recipient), higher, "balance after rotation");
        assertEq(bridged.totalSupply(), higher, "total supply after rotation");
        assertEq(bridged.totalSupply(), higher, "no double mint across the rotation");

        uint256 more = higher + EXIT_AMOUNT;
        bytes32 oldDigest = _claimDigest(address(entry), block.chainid, recipient, more, deadline);
        vm.prank(relayer);
        vm.expectRevert(KskdBridged.NotBridge.selector);
        entry.claim(recipient, more, deadline, _sigs(_sign(ENCLAVE_KEY_A, oldDigest)));
    }

    // ─── 13. Permit on the live token ────────────────────────────────────

    /// The Igra leg runs as a single `exitWithPermit` against the live KSKD and the burn mints on Robinhood.
    function test_EndToEnd_ExitWithPermitOnLiveKskdMintsOnRobinhood() public {
        vm.selectFork(igraFork);
        IKskdBurnable kskd = IKskdBurnable(KSKD);
        assertEq(kskd.DOMAIN_SEPARATOR(), _liveKskdDomainSeparator(), "live KSKD is not EIP-2612 Kaskad/1/38833");
        _fundPermitHolder(EXIT_AMOUNT);

        uint256 supplyBefore = kskd.totalSupply();
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_KEY, EXIT_AMOUNT, deadline);

        vm.expectEmit(true, true, false, true, address(exitContract));
        emit KskdExit.Exited(permitHolder, recipient2, EXIT_AMOUNT, EXIT_AMOUNT);
        vm.prank(permitHolder);
        exitContract.exitWithPermit(EXIT_AMOUNT, recipient2, deadline, v, r, s);

        assertEq(kskd.balanceOf(permitHolder), 0, "permit holder balance");
        assertEq(kskd.balanceOf(address(exitContract)), 0, "exit contract holds KSKD");
        assertEq(kskd.totalSupply(), supplyBefore - EXIT_AMOUNT, "permit exit did not reduce live supply");
        assertEq(kskd.allowance(permitHolder, address(exitContract)), 0, "allowance left standing");
        assertEq(kskd.nonces(permitHolder), 1, "permit nonce");

        uint256 cumulative = exitContract.burned(recipient2);
        assertEq(cumulative, EXIT_AMOUNT, "burned[recipient2]");

        vm.selectFork(robinFork);
        uint256 claimDeadline = block.timestamp + 1 hours;
        vm.expectEmit(true, false, false, true, address(entry));
        emit KskdEntry.Claimed(recipient2, cumulative, cumulative, cumulative);
        vm.prank(relayer);
        entry.claim(
            recipient2, cumulative, claimDeadline, _attest(ENCLAVE_KEY_A, recipient2, cumulative, claimDeadline)
        );

        assertEq(bridged.balanceOf(recipient2), cumulative, "minted balance");
        assertEq(bridged.bridgedIn(recipient2), cumulative, "bridgedIn");
        assertEq(bridged.totalSupply(), cumulative, "total supply");
    }

    /// A front-run permit on the live token is harmless: the replay reverts inside the catch and the
    /// allowance the attacker set pays for the exit.
    function test_Igra_ExitWithPermitSurvivesAFrontRunOnTheLiveToken() public {
        vm.selectFork(igraFork);
        IKskdBurnable kskd = IKskdBurnable(KSKD);
        _fundPermitHolder(EXIT_AMOUNT);

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(PERMIT_KEY, EXIT_AMOUNT, deadline);

        vm.prank(relayer);
        kskd.permit(permitHolder, address(exitContract), EXIT_AMOUNT, deadline, v, r, s);
        assertEq(kskd.allowance(permitHolder, address(exitContract)), EXIT_AMOUNT, "front-run allowance");
        assertEq(kskd.nonces(permitHolder), 1, "nonce after the front-run");

        // The consumed nonce makes the same signature recover a stranger; the live token refuses it.
        address recovered = ECDSA.recover(_permitDigest(permitHolder, EXIT_AMOUNT, deadline), v, r, s);
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, recovered, permitHolder));
        kskd.permit(permitHolder, address(exitContract), EXIT_AMOUNT, deadline, v, r, s);

        vm.prank(permitHolder);
        exitContract.exitWithPermit(EXIT_AMOUNT, recipient2, deadline, v, r, s);

        assertEq(exitContract.burned(recipient2), EXIT_AMOUNT, "burned after the front-run");
        assertEq(kskd.balanceOf(permitHolder), 0, "permit holder balance");
        assertEq(kskd.allowance(permitHolder, address(exitContract)), 0, "allowance not consumed");
        assertEq(kskd.nonces(permitHolder), 1, "nonce advanced more than once");
    }

    // ─── Helpers ─────────────────────────────────────────────────────────

    function _pickHolder() internal view returns (address) {
        address[4] memory candidates = [HOLDER_SAFE, HOLDER_2, HOLDER_3, HOLDER_4];
        for (uint256 i = 0; i < candidates.length; i++) {
            uint256 balance = IKskdBurnable(KSKD).balanceOf(candidates[i]);
            if (balance > 0) {
                require(balance >= 8 * EXIT_AMOUNT, "live holder balance too small for the exit amount");
                return candidates[i];
            }
        }
        revert("no live KSKD holder with a balance");
    }

    /// Owner admits the enclave signer behind `key` through a stub-encoded attestation.
    function _registerEnclave(KskdEntry target, uint256 key) internal {
        bytes memory doc = stub.encode(true, PCR0, vm.addr(key));
        vm.prank(owner);
        target.registerEnclave(doc);
    }

    /// Burn on the Igra fork and read back the cumulative total the enclave would attest.
    function _exitOnIgra(uint256 amount) internal returns (uint256 cumulative) {
        vm.selectFork(igraFork);
        vm.startPrank(holder);
        IKskdBurnable(KSKD).approve(address(exitContract), amount);
        exitContract.exit(amount, recipient);
        vm.stopPrank();
        cumulative = exitContract.burned(recipient);
    }

    /// Move `amount` of live KSKD from the Safe to the in-test permit signer.
    function _fundPermitHolder(uint256 amount) internal {
        vm.prank(HOLDER_SAFE);
        assertTrue(IKskdBurnable(KSKD).transfer(permitHolder, amount), "safe transfer to the permit holder");
    }

    /// The live token's own domain, recomputed from its published ERC-5267 fields.
    function _liveKskdDomainSeparator() internal pure returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Kaskad"), keccak256("1"), IGRA_CHAIN_ID, KSKD));
    }

    /// EIP-2612 digest for `owner` approving the exit, over the owner's current live nonce.
    function _permitDigest(address owner_, uint256 value, uint256 deadline) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH, owner_, address(exitContract), value, IKskdBurnable(KSKD).nonces(owner_), deadline
            )
        );
        return keccak256(abi.encodePacked(hex"1901", IKskdBurnable(KSKD).DOMAIN_SEPARATOR(), structHash));
    }

    function _signPermit(uint256 key, uint256 value, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        return vm.sign(key, _permitDigest(vm.addr(key), value, deadline));
    }

    function _claimDigest(address verifying, uint256 chainId, address to, uint256 cumulativeBurned, uint256 deadline)
        internal
        pure
        returns (bytes32)
    {
        bytes32 domainSeparator =
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("Pontifex"), keccak256("1"), chainId, verifying));
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, to, cumulativeBurned, deadline));
        return keccak256(abi.encodePacked(hex"1901", domainSeparator, structHash));
    }

    /// One enclave signature over the live entry's domain.
    function _attest(uint256 key, address to, uint256 cumulativeBurned, uint256 deadline)
        internal
        view
        returns (bytes[] memory)
    {
        return _sigs(_sign(key, _claimDigest(address(entry), block.chainid, to, cumulativeBurned, deadline)));
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sigs(bytes memory sig) internal pure returns (bytes[] memory out) {
        out = new bytes[](1);
        out[0] = sig;
    }

    /// A/B signatures ordered by signer address, ascending as claim() requires or reversed.
    function _quorum(bytes32 digest, bool ascending) internal pure returns (bytes[] memory out) {
        (uint256 lo, uint256 hi) = vm.addr(ENCLAVE_KEY_A) < vm.addr(ENCLAVE_KEY_B)
            ? (ENCLAVE_KEY_A, ENCLAVE_KEY_B)
            : (ENCLAVE_KEY_B, ENCLAVE_KEY_A);
        out = new bytes[](2);
        out[0] = _sign(ascending ? lo : hi, digest);
        out[1] = _sign(ascending ? hi : lo, digest);
    }
}
