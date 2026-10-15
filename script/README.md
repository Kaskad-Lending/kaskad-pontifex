# Pontifex ops runbook

KSKD one-way migration bridge: burn on Igra (`KskdExit`), attested claim on
Robinhood (`KskdEntry` mints through `KskdBridged`).

## Chains

- Igra mainnet `38833` / Galleon testnet `38836` — `DeployExit` target.
- Robinhood mainnet `4663` / testnet `46630` — `DeployRobinhood` and
  `RegisterEnclave` target.
- Mainnet deployment (addresses, transactions, blocks, deployers, constructor
  arguments, source commit): `deployments/mainnet.json`.

## Toolchain

- forge 1.4.3, solc 0.8.30, OZ 5.6.1, forge-std 1.16.2.
- `via_ir = false` in `foundry.toml` — never enable it.
- No string reverts in `src/` or `script/` — custom errors only.
- Before any PR: `forge build --sizes` clean, `forge fmt --check` clean, `forge test`
  green (`IGRA_RPC_URL` / `ROBINHOOD_RPC_URL` exported for the fork suites).

## Contracts

- `KskdExit` (Igra) — burns KSKD (`exit`, or `exitWithPermit` with an
  EIP-2612 permit in the same transaction), tracks `burned[recipient]`,
  one-way `close()` gated by immutable `CLOSER`.
- `KskdBridged` (Robinhood) — the KSKD ERC20 there, mints only through the
  current `bridge`, capped at `MAX_SUPPLY = 1_000_000_000 ether`, matching
  Igra KSKD's total supply.
- `KskdEntry` (Robinhood) — holds the `bridge` role, admits enclave signers
  via Nitro attestation of the image whose PCR0 is `expectedPcr0`
  (owner-settable), mints against `threshold`-of-N signed claims,
  rate-limited by `mintLimit` per `WINDOW = 1 days`.

## Prerequisites, every session

- [ ] `export IGRA_RPC_URL=...` and `export ROBINHOOD_RPC_URL=...` — matches
      `foundry.toml`'s `[rpc_endpoints]`, so `--rpc-url igra` /
      `--rpc-url robinhood` work as shorthand for the commands below.
- [ ] `export PRIVATE_KEY=...` in the session only — never write it to a file
      on disk. `SafeOps` and the Safe mode of `SetGuardian`,
      `SetExpectedPcr0` and `SetBridge` (§ 4) do not read it;
      `RegisterEnclave` needs it for the cert warm-up.
- [ ] Simulate before every broadcast: run the command without `--broadcast`
      first, read the full log, only then add `--broadcast`.

## 1. DeployExit.s.sol — Igra

Deploys `KskdExit`.

Env:
- `KSKD` — optional, defaults to `0x16d92794F5B81d2CdEd0F0958779A410401e6435`.
- `CLOSER` — required, address allowed to call `close()` and `setMinBurn`.
  Mainnet: the Igra Safe `0x5B95Ea5D5B63998467eE92B0b175ACE49ccC1943`.
- `MIN_BURN` — optional, wei, the smallest `exit` accepted. Default
  `1000 ether` on 38833, `0` on 38836. `type(uint256).max` keeps every exit
  closed until `CLOSER` lowers it (`SafeOps.setMinBurn`, § 4); the mainnet
  exit was deployed that way.
- `EXPECTED_EXIT` — optional, the exit address baked into the bridge image
  (`PONTIFEX_EXIT`). The run stops before gas when the deployer's nonce would
  put the exit anywhere else.
- `REQUIRE_PERMIT` — optional bool, default `true` on 38833: KSKD must expose
  EIP-2612 under the expected domain, or the run reverts (in the simulation,
  before anything is sent); `false` turns that into a warning
  (`exitWithPermit` unusable, `approve` + `exit` unaffected).
- `REQUIRE_SAFE` — optional bool, default `true` on 38833: `CLOSER` must be a
  Safe (code that answers `getThreshold() >= 2`).
- `PRIVATE_KEY` — required.

Preflight (script-enforced): chain id must be `38833` or `38836`;
`CLOSER` is a Safe per `REQUIRE_SAFE`; `KSKD.symbol() == "KSKD"` and
`KSKD.decimals() == 18`; the predicted address equals `EXPECTED_EXIT` when set.

Postflight (script-enforced): `exit.KSKD() == KSKD`, `exit.CLOSER() ==
CLOSER`, `exit.minBurn() == MIN_BURN`, `!exit.closed()`, KSKD's permit domain
per `REQUIRE_PERMIT`.

Igra specifics (both proven by the dry run below and by other Kaskad
deployments on Igra):
- Fee floor is 1000 gwei — the node's own estimate is exactly that. Igra
  prices transactions by mass, so a simulation that passes can still be
  refused at broadcast: send legacy transactions at 2000 gwei
  (`--legacy --gas-price 2000000000000`) and raise `--gas-price` if the
  broadcast is refused.
- The public RPC is load-balanced across nodes at different heights. forge
  sets the fork up twice per run, and the second setup fails with
  `failed to get block for block number N; latest block number: N` when it
  lands on a node that has not seen the head yet. Pin the fork 768 blocks
  back — Igra's finality lag, the same offset the fork tests use. The
  deployer's nonce is read at the pinned block: send nothing else from the
  deployer key between pinning and broadcast.

```
forge script script/DeployExit.s.sol --rpc-url igra \
  --fork-block-number $(( $(cast block-number --rpc-url igra) - 768 )) \
  --legacy --gas-price 2000000000000 -vvv
# same command plus --broadcast
```

## 2. DeployRobinhood.s.sol — Robinhood

Deploys `KskdBridged` then `KskdEntry`, with `OWNER` as the immediate owner
of both from block 0 — no `Ownable2Step` handoff runs here. Pass the Safe
that is the long-term owner as `OWNER` directly.

Env:
- `OWNER` — required, final owner of both contracts. `REQUIRE_SAFE`
  (optional bool, default `true` on 4663) requires a Safe: code that answers
  `getThreshold() >= 2`.
- `VERIFIER` — required, deployed `NitroAttestationVerifier` (not part of
  this repository; this script does not deploy it). Mainnet 4663
  uses the V2 verifier `0x52A22A678Af63d74BBfCB4c8fA90299db2760ACD`: V2 pins
  no PCR, so the entry's `expectedPcr0` is the only image pin.
  `REQUIRE_V2_VERIFIER` (optional bool, default `true` on 4663) refuses
  anything else: the verifier must answer `nitroProver()` → `certManager()`,
  both with code, and must not answer V1's `expectedPCR1()` /
  `expectedPCR2()`. The 46630 testnet entry runs on the V1 verifier
  `0x525604a7cE2352F9D156C66a3D5d2cb7C96c0562`, which pins PCR1/PCR2.
- `EXPECTED_PCR0` — required. The **first 32 of the 48** PCR0 measurement
  bytes of the accepted enclave image, `0x`-prefixed (64 hex chars).
  `nitro-cli describe-eif` prints all 48 — drop the trailing 32 hex
  characters. Stored as `expectedPcr0`; the owner changes it with
  `setExpectedPcr0`, so a wrong value costs one Safe transaction, not a
  redeploy. Deploy first when the image is not built yet: pass the
  placeholder `0x0000000000000000000000000000000000000000000000000000000000000001`
  (zero is rejected), then set the real PCR0 through the Safe with
  `SetExpectedPcr0.s.sol` (§ 4) once the image exists. No signer can register
  before that. Mainnet was deployed this way.
- `EXPECTED_ENTRY` — optional, the entry address baked into the bridge image
  (`PONTIFEX_ENTRY`). The run stops before gas when deployer nonce + 1 would
  put the entry anywhere else.
- `THRESHOLD` — required, signature quorum for `claim()`; must be ≥ 1.
  Pick it to match the enclave fleet you are about to register — nothing
  enforces it against `signerCount` until the first `setThreshold` call.
  Launch value: `1`.
- `MINT_LIMIT` — required, wei, per-`WINDOW` (1 day) mint budget. Public
  phase: `25000000000000000000000000` (25M KSKD); the treasury tranche goes
  first under a temporary raise — § Treasury migration.
- `PRIVATE_KEY` — required, deployer.

`KskdBridged`'s constructor takes the entry address up front, so the script
predicts it via `vm.computeCreateAddress(deployer, nonce+1)` before either
deploy and asserts the prediction matched afterward.

Postflight (script-enforced, 14 checks): predicted entry == actual,
`token.bridge() == entry`, token/entry `owner() == OWNER`, no pending owner
on either, `entry.TOKEN()` / `entry.VERIFIER()` / `expectedPcr0` /
`threshold` / `mintLimit` all match the inputs, `entry.signerCount() == 0`,
`token.totalSupply() == 0`, `entry.guardian() == 0`.

Robinhood is EIP-1559 (0.01 gwei floor on 46630, ~0.04 gwei base fee on
4663): never pass `--legacy` or `--gas-price` there, forge's fee estimate is
correct as is.

```
forge script script/DeployRobinhood.s.sol --rpc-url robinhood -vvv
forge script script/DeployRobinhood.s.sol --rpc-url robinhood --broadcast --slow -vvv
```

`--slow` waits for each receipt before the next transaction, as every
broadcast in this runbook does.

## 3. RegisterEnclave.s.sol — Robinhood, owner operation

Registers one enclave signer on an already-deployed `KskdEntry`. Reads PCR0
out of the attestation document and compares it with `expectedPcr0` before
any certificate work, so a document of another image costs no gas
(`PCR0Mismatch`). Then warms the attestation's cert chain one certificate at
a time — never `verifyCerts`, see the gas note — and either registers
directly or prints the Safe transaction (§ 4). Reverts `NoGuardian` when the
entry is the token's live bridge and has no guardian: run `SetGuardian` first
(under a Safe, as its own earlier tx).

Env:
- `ENTRY` — required, `KskdEntry` address.
- `ATTESTATION_DOC` — required, 0x-prefixed hex attestation document.
- `CERT_CHAIN` — required, comma-separated 0x-hex certs: CA bundle (root
  excluded) then the leaf, in that order.
- `DIRECT_REGISTER` — optional bool, default `false`. `true` broadcasts
  `registerEnclave` directly — sender must already be `entry.owner()`
  (EOA-owned entry, typically testnet). `false` prints the Safe transaction:
  the full Safe-mode output (§ 4) for a Safe owner, the bare calldata for any
  other owner.
- `SAFE_NONCE` — optional, Safe owner only (§ 4).
- `PRIVATE_KEY` — required; funds the cert warm-up broadcasts either way,
  and is the registering key when `DIRECT_REGISTER=true`.

Extract `CERT_CHAIN` from the raw attestation document once, offline:
```
pip install cbor2   # the script's only dependency
python3 script/extract_certs.py attestation.hex
```

Why never `verifyCerts`: Robinhood's per-tx gas cap
(`ArbGasInfo.getGasAccountingParams().maxTxGasLimit`) is 32,000,000. A
bundled `verifyCerts` over a full 4-certificate chain costs ~61,000,000 —
over the cap unconditionally. Warming certs one at a time through
`CertManager.verifyCert` fits: measured 14.9M–15.5M gas per cert (cold),
~23.8M for the following `registerEnclave` once every cert is cached — both
comfortably under the cap.

`verifyCert` revert reasons:
- `"VC1"` — parent cert hash not cached yet; certs must warm in chain order,
  root first. (The script chains `parentHash` for you.)
- `"VC2"` — this exact certificate is already cached; harmless — the script
  checks the cache first and skips it.
- `"certificate not valid anymore"` — `block.timestamp` is past this
  certificate's `notAfter`. The leaf (instance) cert has the shortest window,
  3 hours from issuance (fixture leaf: 20:16:32Z → 23:16:35Z) — the only
  deadline for a first-time registration. Extract and warm the certs
  promptly after capturing the attestation.
- Certificate not yet valid — `block.timestamp` is before the leaf's
  `notBefore`. Robinhood's clock tracks wall time (measured 16 s ahead on
  46630, 2026-09-18), so this should not fire here; it is the Igra failure
  mode, whose chain clock lags wall time by minutes. If it does fire on
  Robinhood the capture is from the future — re-capture and retry.
- A cached certificate is never re-checked against `notAfter`, and the
  verifier's `MAX_ATTESTATION_AGE` never rejects (the document timestamp is
  in milliseconds, the check compares it with `block.timestamp` in seconds —
  asserted by `test/fork/RealVerifier.t.sol::testCachedCertsMakeDocReplayableAfterExpiry`).
  So once its chain is cached a document stays registrable indefinitely; on
  the entry only `SignerAlreadyRegistered` stops the same signer from being
  admitted twice. A captured attestation whose chain is cached is a standing
  credential — store it like one.

The cert warm-up always broadcasts when `--broadcast` is passed (warming is
permissionless, cheap relative to the alternative, and safe to run ahead of
time) regardless of `DIRECT_REGISTER`; only the final `registerEnclave` call
is conditional on it. Pass `--slow` on every broadcast run: each `verifyCert`
chains on the previous cert's hash, so it must be mined before the next is
sent.

```
export CERT_CHAIN=$(python3 script/extract_certs.py attestation.hex)
export ATTESTATION_DOC=0x$(cat attestation.hex)

# Safe-owned entry (mainnet) — simulate, then warm certs for real:
DIRECT_REGISTER=false forge script script/RegisterEnclave.s.sol --rpc-url robinhood -vvv
DIRECT_REGISTER=false forge script script/RegisterEnclave.s.sol --rpc-url robinhood --broadcast --slow -vvv
# → submit the printed Safe transaction (§ 4).

# EOA-owned entry (testnet only, PRIVATE_KEY == entry.owner()):
DIRECT_REGISTER=true forge script script/RegisterEnclave.s.sol --rpc-url robinhood --broadcast --slow -vvv
```

## 4. Safe mode and SafeOps.s.sol — Safe-owned calls

On mainnet every owner call belongs to a Safe. The Robinhood Safe
`0x313807B857222278FbddF36541DE2Af5a50BdCB5` (Safe{L2} 1.4.1, 3/5) owns
`KskdBridged` and `KskdEntry`; the Igra Safe
`0x5B95Ea5D5B63998467eE92B0b175ACE49ccC1943` (Safe{L2} 1.5.0, 3/5) is the
exit's `CLOSER` and holds the treasury KSKD. No script sends a Safe's
transaction: when the owner has code, `SetGuardian`, `SetExpectedPcr0`,
`SetBridge` (without `DIRECT`) and `RegisterEnclave` (without
`DIRECT_REGISTER`) switch to Safe mode, and `SafeOps.s.sol` covers the
remaining Safe-only calls. Safe mode:

- dry-runs every call from the Safe against current chain state; a call that
  would revert stops the run with `SafeCallReverts(index, reason)`;
- prints `Safe tx to`, `value` (always 0), `data`, `op` (0 = Call,
  1 = DelegateCall), the Safe nonce and `safeTxHash` — the value the Safe's
  own `getTransactionHash` returns for these fields with `safeTxGas`,
  `baseGas`, `gasPrice`, `gasToken` and `refundReceiver` all zero;
- sends several calls as one DelegateCall to the chain's canonical
  `MultiSendCallOnly` — 1.4.1 `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` on
  Robinhood 4663 / 46630, 1.5.0 `0xA83c336B20401Af773B6219BA5027174338D1836`
  on Igra 38833 — and refuses other code at those addresses; the `call i`
  lines list the batch in execution order. Galleon 38836 has no
  MultiSendCallOnly there, so only single calls run on it;
- uses the Safe's current `nonce()`; `SAFE_NONCE=<n>` queues the transaction
  behind pending ones (a consumed nonce is refused). The dry run sees current
  chain state, without the effects of the pending transactions.

Submit: create the transaction in the Safe UI — a Call with the printed `to`
and `data`, or for a batch one Transaction Builder entry per `call i` line, in
order — at the printed nonce. Before the first owner signs, confirm that the
`safeTxHash` the UI and each signer's wallet show equals the printed one, then
collect 3 of 5 signatures and execute. Cross-check any hash on chain:

```
cast call <safe> "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
  <to> 0 <data> <op> 0 0 0 0x0000000000000000000000000000000000000000 0x0000000000000000000000000000000000000000 <nonce> \
  --rpc-url robinhood
```

`SafeOps.s.sol` entry points — pick one with `--sig`; each resolves the Safe
that owns the call from chain state:

| call | chain | Safe | `--sig` and arguments |
|---|---|---|---|
| `KskdEntry.setMintLimit` | 4663 / 46630 | entry owner | `"setMintLimit(address,uint256)" $ENTRY <wei>` |
| `KskdEntry.setThreshold` | 4663 / 46630 | entry owner | `"setThreshold(address,uint256)" $ENTRY <n>` |
| `KskdEntry.removeSigner` | 4663 / 46630 | entry owner | `"removeSigner(address,address)" $ENTRY <signer>`; warns when `signerCount < threshold` afterwards |
| `transferOwnership` | 4663 / 46630 | current owner | `"transferOwnership(address,address)" <token or entry> <newOwner>`; `newOwner` must be a Safe on 4663 (`REQUIRE_SAFE`) |
| `acceptOwnership` | 4663 / 46630 | pending owner | `"acceptOwnership(address)" <token or entry>` |
| `KskdExit.setMinBurn` | 38833 / 38836 | `CLOSER` | `"setMinBurn(address,uint256)" $EXIT <wei>` |
| `KskdExit.close` | 38833 / 38836 | `CLOSER` | `"close(address)" $EXIT` — one-way |
| treasury exit | 38833 | the KSKD holder | `"treasuryExit(address,address,uint256,address)" <safe> $EXIT <wei> <robinhoodRecipient>` |
| any calls | any | given | `"batch(address,address[],bytes[])" <safe> "[<to>,<to>]" "[<data>,<data>]"` — two or more calls need a pinned MultiSendCallOnly |

`treasuryExit` batches `KSKD.approve(exit, amount)` and
`exit(amount, recipient)` — a Safe cannot sign the permit. When the Safe is
`CLOSER` and `amount` is below `minBurn`, the batch also lowers `minBurn` to
`amount` first and restores the previous value last, inside the same
transaction; on mainnet (`minBurn = type(uint256).max`) that is the only way
any exit runs before the public opening.

```
# Robinhood: raise the entry's daily budget
forge script script/SafeOps.s.sol --rpc-url robinhood \
  --sig "setMintLimit(address,uint256)" 0x7b1D080d2485E63791468d73418e2B262c25C402 <wei> -vvv
# Igra: treasury tranche to the Robinhood Safe
forge script script/SafeOps.s.sol --rpc-url igra \
  --sig "treasuryExit(address,address,uint256,address)" \
  0x5B95Ea5D5B63998467eE92B0b175ACE49ccC1943 0x5A818D42cA142483f72AE7D426E199324FEc4871 <wei> \
  0x313807B857222278FbddF36541DE2Af5a50BdCB5 -vvv
```

## Roles

| Role | Held by | Can do | Cannot do |
|---|---|---|---|
| `KskdExit.CLOSER` | immutable, set at deploy | `close()` — one-way stop of new exits; `setMinBurn` — the exit floor | touch the `burned` ledger, reopen |
| `KskdBridged.owner` | `Ownable2Step`, usually a Safe | `setBridge`, `renounceOwnership`, transfer/accept ownership | mint or burn directly — but `setBridge(self)` makes it the bridge, so it is one transaction from a mint right; only `renounceOwnership()` closes that |
| `KskdEntry.owner` | `Ownable2Step`, usually a Safe | `registerEnclave`, `removeSigner`, `setExpectedPcr0`, `setThreshold`, `setMintLimit`, `setGuardian`, transfer/accept ownership | bypass `threshold`-of-N signatures on `claim`; renounce ownership (`RenounceDisabled`) |
| `KskdEntry.guardian` | plain address, owner-set: the watchdog bot's hot key (pauses on any `Claimed` without a matching Igra burn) | `pause()` — zeroes `mintLimit` only | restore `mintLimit`, touch signers/threshold |

## Emergency levers

- Fastest stop, Robinhood side: `guardian.pause()` — zeroes `mintLimit`
  without Safe latency. Reverse only via owner `setMintLimit(newLimit)`.
- Owner-level stop, Robinhood side: `KskdEntry.setMintLimit(0)` — same
  effect, Safe-gated.
- Compromised signer: `KskdEntry.removeSigner(signer)` — may drop
  `signerCount` below `threshold`; claims then fail until a signer is
  re-registered or `setThreshold` lowered.
- Flawed image: `removeSigner` for every signer of it, and
  `KskdEntry.setExpectedPcr0` to the replacement's PCR0 so a restarted
  instance of the flawed image cannot re-register — retargeting alone
  revokes nothing. On the 4663 V2 verifier that covers any replacement
  image; on a V1 verifier (46630) a rebuilt application changes PCR2 too and
  takes the new-verifier path (§ Image rotation).
- Hard mint kill, Robinhood side: `KskdBridged.setBridge(address(0))` —
  `bridgeMint` reverts unconditionally, independent of the entry's state.
- Pairing requirement: pausing or zeroing the Robinhood side does not
  stop `KskdExit.exit()` on Igra — burns there are irreversible. Disable
  the frontend's exit/burn flow at the same time as any Robinhood-side
  freeze, or users burn KSKD they cannot yet claim.
- `KskdExit.close()` has no Robinhood-side counterpart and is one-way —
  it only stops new burns. Balances already in `burned[recipient]`
  remain claimable on Robinhood after `close()`; it is not a substitute
  for freezing the entry.

## Known behaviors worth tracking (ops-relevant, not defects to fix here)

- `Claimed(recipient, minted, cumulative, attested)`: `cumulative < attested`
  is a partial fill (window budget ran short). The remainder stays
  claimable with the same signatures until their deadline — resend once
  the window rolls.
- `pause()` and owner `setMintLimit(0)` both emit only `MintLimitSet(0)`
  — no distinct `Paused` event. A log-based monitor cannot tell which
  actor triggered a freeze from the event alone.
- `windowStart` resets to `block.timestamp` on the first claim after the
  prior window elapsed, so up to `2 × mintLimit` can mint across a
  self-timed window boundary. Documented in the contract's own NatSpec;
  accepted, not a bug to patch here.
- `KskdExit.exit()` only excludes the zero address, the exit contract
  itself, and the KSKD token address from `recipient` — a mistyped
  Robinhood address burns KSKD with no recovery path.

## Same-image restart re-enrollment

An enclave instance restart (same PCR0/PCR1/PCR2, new instance keypair)
needs a fresh `registerEnclave` — the old signer stays valid until removed.

- [ ] Capture the new attestation document from the restarted instance.
- [ ] Run `RegisterEnclave.s.sol` for the new signer, as above.
- [ ] Decide whether to `removeSigner` the old instance's key — leaving it
      is safe (it can never sign again) but inflates `signerCount` against
      `threshold`.

## Relayer

Kaskad-operated; pays the Robinhood gas for `claim` (≈ $0.02 each at the
0.055 gwei read on 2026-09-18). Policy, not contract: relay only when the
unclaimed amount reaches a floor (proposed 1,000 KSKD) and rate-limit per
recipient and per source. A dust exit costs a bot nothing but locked KSKD,
so the relayer wallet is the only thing it can drain; smaller holders call
the permissionless `claim` with their own gas.

## Treasury migration (before the public opening)

`setMintLimit` does not reset `windowMinted`: lowering the limit below what
the current window already minted blocks every claim until the window rolls
(≤ 24 h). The treasury tranche therefore goes first, in its own window:

- [ ] Robinhood Safe exists and is `OWNER` of token and entry.
- [ ] `MINT_LIMIT` at deploy ≥ the tranche, or `setMintLimit(tranche)`
      before the claim (`SafeOps.setMintLimit`).
- [ ] `KskdExit.exit(tranche, robinhoodSafe)` from the Igra Safe —
      `SafeOps.treasuryExit` (§ 4): `approve` + `exit` in one batch, with
      `minBurn` lowered and restored around them while it is
      `type(uint256).max`.
- [ ] Enclave signature, then `claim` on Robinhood; verify
      `token.balanceOf(robinhoodSafe) == tranche`.
- [ ] `setMintLimit(25000000000000000000000000)`. Open the frontend only
      once `block.timestamp ≥ windowStart + WINDOW`; until then the public
      budget reads `MintLimitExhausted`.
- [ ] Public opening on Igra: `SafeOps.setMinBurn` from `type(uint256).max`
      to the public floor (`DeployExit`'s mainnet default: 1,000 KSKD).

## Image rotation

On a V2 verifier (mainnet 4663) `expectedPcr0` is the only image pin: every
image change — EIF repack, kernel, application rebuild — takes the
no-redeploy path below. On a V1 verifier (testnet 46630) the path covers
only a PCR0 that moved while PCR1/PCR2 held: an EIF repack of the same
kernel and the same application, or a wrong `EXPECTED_PCR0` supplied at
deploy. An application rebuild changes PCR2 as well (Nitro PCR2 measures the
user application) and V1 pins PCR2 immutably — that case is the
new-verifier path further down. No redeploy:

- [ ] Take the first 32 of the 48 PCR0 bytes of the new EIF
      (`nitro-cli describe-eif`).
- [ ] `KskdEntry.setExpectedPcr0(newPcr0)` (Robinhood, by owner) —
      `SetExpectedPcr0.s.sol`; a Safe owner gets the Safe transaction (§ 4).
- [ ] Warm the new document's certificates and `registerEnclave(newDoc)`
      — § 3.
- [ ] `removeSigner(oldSigner)` for every signer of the old image
      (`SafeOps.removeSigner`) — the entry keeps no signer list, take the addresses from the
      `EnclaveRegistered` events, minus any already in `SignerRemoved`.
      Until then both images sign; outstanding signatures stay valid because
      the entry, and with it the EIP-712 domain, is unchanged.
- [ ] Read back `expectedPcr0()` and confirm `signerCount() >= threshold()` —
      `removeSigner` does not enforce the quorum bound and silently bricks
      `claim` when it drops below it.

On a V1 verifier, changing PCR1/PCR2 (kernel, bootstrap or application)
needs a new `NitroAttestationVerifier` (those are immutable there) and,
because `VERIFIER` is immutable on the entry, a new entry:

- [ ] Deploy a new `NitroAttestationVerifier` pinning the new PCR1/PCR2.
- [ ] Deploy a new `KskdEntry` against it, reusing `TOKEN` —
      `RotateEntry.s.sol` (entry only, at the `EXPECTED_ENTRY` baked into the
      new image; its `OWNER` must be the token owner).
- [ ] Register signers on the new entry and set its guardian, then
      `KskdBridged.setBridge(newEntry)` — `SetBridge.s.sol`, which refuses an
      entry that is not claim-ready or has no guardian.
- [ ] The old entry keeps working right up to the `setBridge` call.
      Signatures issued for the old entry are invalid on the new one
      (different EIP-712 domain) — users re-request them.

## Wind-down (permanent shutdown)

Order matters — claiming already-burned balances must stay possible until
the grace period ends:

- [ ] `KskdExit.close()` (Igra, by `CLOSER`; `SafeOps.close`) — stops new
      burns; `burned` stays readable.
- [ ] Grace period: let outstanding attested burns get claimed on Robinhood.
- [ ] `KskdEntry.setMintLimit(0)` (Robinhood, by owner; `SafeOps.setMintLimit`)
      — stops further claims.
- [ ] `KskdBridged.setBridge(address(0))` (Robinhood, by owner;
      `SetBridge.s.sol` with `NEW_BRIDGE=0x0`) — disables `bridgeMint`
      unconditionally.
- [ ] `KskdBridged.renounceOwnership()` (Robinhood, by owner;
      `SafeOps.batch` with calldata `0x715018a6`) — freezes the supply for
      good. Irreversible — only once wind-down is final.

## Verification (`cast call`)

```
export EXIT=0x…    # KskdExit, from the DeployExit output
export TOKEN=0x…   # KskdBridged, from DeployRobinhood
export ENTRY=0x…   # KskdEntry, from DeployRobinhood
export SIGNER=0x…  # enclave signer, from RegisterEnclave

cast call $EXIT  "KSKD()(address)"             --rpc-url igra
cast call $EXIT  "CLOSER()(address)"           --rpc-url igra
cast call $EXIT  "closed()(bool)"              --rpc-url igra
cast call $EXIT  "minBurn()(uint256)"          --rpc-url igra

cast call $TOKEN "bridge()(address)"           --rpc-url robinhood
cast call $TOKEN "owner()(address)"            --rpc-url robinhood
cast call $TOKEN "totalSupply()(uint256)"      --rpc-url robinhood

cast call $ENTRY "owner()(address)"            --rpc-url robinhood
cast call $ENTRY "guardian()(address)"         --rpc-url robinhood
cast call $ENTRY "expectedPcr0()(bytes32)"     --rpc-url robinhood
cast call $ENTRY "threshold()(uint256)"        --rpc-url robinhood
cast call $ENTRY "signerCount()(uint256)"      --rpc-url robinhood
cast call $ENTRY "mintLimit()(uint256)"        --rpc-url robinhood
cast call $ENTRY "validSigner(address)(bool)" $SIGNER --rpc-url robinhood
```

## Validated runs

- `DeployExit` dry run on live Igra (38833, fork pinned at head − 768,
  `--legacy --gas-price 2000000000000`, Igra Safe as `CLOSER`): every
  pre/post assert passes, 468,783 gas.
- `DeployRobinhood` broadcast on a local anvil forking Igra with
  `--chain-id 46630` (Igra's verifier `0x76216b3bde5bC81b04FA5A5d4a67F6AfACc666B9`
  as stand-in): every postflight assert passes.
- `RegisterEnclave` on that anvil, `DIRECT_REGISTER=false` then `=true`:
  4 certs warmed at 14.9M–15.5M gas each, `registerEnclave` 23.8M — all
  under the 32,000,000 Robinhood cap and the suite's `GAS_BUDGET`
  (`test/fork/RealVerifier.t.sol`).
- Mainnet deploys (`DeployExit` on 38833, `DeployRobinhood` on 4663): see
  `deployments/mainnet.json`.
- Safe mode, simulated against mainnet on 2026-10-10 (nothing sent): on 4663,
  `SetGuardian`, `SetExpectedPcr0` and a two-call `SafeOps.batch` for the
  Robinhood Safe; on 38833, `SafeOps.treasuryExit` (four calls: lower
  `minBurn`, `approve`, `exit`, restore) for the Igra Safe, with test amounts.
  Each printed `safeTxHash` equals the live Safe's `getTransactionHash` for
  the printed fields. These dry runs check the scripts; they are not
  transactions to sign.
- `DeployRobinhood` dry run on 4663 with the Robinhood Safe as `OWNER` and the
  V2 verifier: `REQUIRE_SAFE` and `REQUIRE_V2_VERIFIER` pass; an EOA `OWNER`
  stops at `NotAContract`. `DeployExit` dry run on 38833 with the Igra Safe
  as `CLOSER`: `REQUIRE_SAFE` passes.
- `test/fork/SafeScripts.t.sol` executes prepared transactions on the live
  Safes with three owner approvals: `setGuardian` and a `MultiSendCallOnly`
  1.4.1 batch on the 46630 Safe; a 1,000,000 KSKD treasury exit with the
  `minBurn` lift and restore through `MultiSendCallOnly` 1.5.0 on the Igra
  Safe.

Fork Igra at a historical block whose timestamp lies inside the captured
attestation's leaf-cert window (`--fork-block-number`, not `latest`): a
live-tip fork carries current time, outside any captured 3-hour window.
