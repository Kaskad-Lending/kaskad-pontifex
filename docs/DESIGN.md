# Pontifex — KSKD migration bridge, Igra → Robinhood

## Purpose

- One-way, one-shot migration of KSKD: burn on Igra, mint on Robinhood, 1:1, instant. No reserve, no batching, no
  challenge window, no bridge-back. Robinhood KSKD exists only through the bridge, mintable only by it (USDC.e model).
- Chains: Igra mainnet `38833` / Galleon testnet `38836`; Robinhood mainnet `4663` / testnet `46630`.
- Deployment and operational procedures live in `script/README.md` and are not repeated here.

## Components

| contract | chain | admin | state |
|---|---|---|---|
| `KskdExit` | Igra | none; immutable `CLOSER` may `close()` once and set `minBurn` | `burned[recipient]`, `totalBurned`, `closed`, `minBurn` |
| `KskdBridged` | Robinhood | `Ownable2Step` owner (Safe) | `bridge`, `bridgedIn[recipient]` |
| `KskdEntry` | Robinhood | `Ownable2Step` owner (Safe), plus `guardian` | `validSigner`, `signerCount`, `threshold`, `mintLimit`, `windowStart`, `windowMinted` |

### `KskdExit` (Igra)

- `exit(amount, recipient)`: credits `burned[recipient] += amount` and `totalBurned += amount`, then `safeTransferFrom`
  from the caller and `KSKD.burn(amount)`, then emits `Exited(sender, recipient, amount, cumulative)` — all state
  before the token calls. Rejects, in this order: a closed exit (`ExitClosed`), `amount == 0` (`ZeroAmount`),
  `amount < minBurn` (`BelowMinBurn(amount, minBurn)`) and `recipient ∈ {0, this exit, the KSKD token}`
  (`InvalidRecipient`).
- `exitWithPermit(amount, recipient, deadline, v, r, s)`: the same, preceded by a best-effort EIP-2612 `permit`
  (`try/catch`): a front-run or already-consumed permit is harmless while the allowance stands, a missing allowance
  reverts inside `safeTransferFrom`. The permit owner is `msg.sender`, so the call is not relayable — a sponsor
  submitting a holder's signature would only permit itself; `deadline` bounds the permit alone, past it the call
  still burns against any standing allowance. The permit must be signed for exactly `amount` (a
  `type(uint256).max` permit fails the inner call and the exit falls back to whatever allowance stands). Igra KSKD
  implements EIP-2612
  (`eip712Domain()` = "Kaskad"/"1"/38833, read 2026-09-18); the treasury Safe cannot sign a permit and uses
  `approve` + `exit`.
- `minBurn` is a per-call floor, not a per-recipient one: `exit` and `exitWithPermit` revert below it, and
  `amount == minBurn` passes. The constructor sets it; `setMinBurn` (`CLOSER` only, else `NotCloser`; emits
  `MinBurnSet`) changes it at any time, also after `close()`. `0` disables the floor; `type(uint256).max` stops all
  new burns until lowered. It never touches the ledger. Live value: 1,000 KSKD (`minBurn()` = `1e21`) at Igra block
  19,307,398.
- Measured execution gas (`gasleft` delta, excludes the 21,000 base and calldata; reproduced by
  `test/unit/ExitGas.t.sol`): `exit` 81,474 for a recipient's first exit, 31,674 for a repeat; `exitWithPermit`
  130,014 and 60,214 — the permit adds 48,540 on a holder's first ever permit and 28,540 afterwards (the 20,000
  difference is the zero-to-non-zero write of the nonce slot). Neither figure counts the separate `approve`
  transaction the plain `exit` path needs.
- `recipient` is not verified. KSKD credited to an address nobody controls on Robinhood is permanently lost, including
  any Igra contract address absent there (Safes, vaults). The frontend must make the user sign a message from
  `recipient` on Robinhood before enabling `exit`.
- `close()` (only `CLOSER`, only once) sets `closed`; `exit` then reverts `ExitClosed`, the ledger stays readable. No
  owner and no rescue path: KSKD transferred directly to the contract is unrecoverable.

### `KskdBridged` (Robinhood)

- ERC20 "Kaskad" / "KSKD" / 18 decimals, plus ERC20Permit (domain "Kaskad" / "1", chain-bound), `Ownable2Step`.
- No premint. Supply enters only via `bridgeMint(recipient, cumulative)`, callable by `bridge` alone (`NotBridge`):
  mints `cumulative − bridgedIn[recipient]`, reverts `NothingToMint` when `cumulative` is not greater and
  `MaxSupplyExceeded` when `totalSupply()` would pass `MAX_SUPPLY = 1e27`. Unlike the window there is no partial
  fill: a claim whose delta would cross the cap reverts whole.
- `MAX_SUPPLY` equals the Igra KSKD `TOTAL_SUPPLY` constant. KSKD burned on Igra outside the bridge can never be
  bridged, so the cap is a backstop, not an exact bound: at Igra block 19,307,398,
  `TOTAL_SUPPLY − totalSupply() − KskdExit.totalBurned()` is 208,835.08 KSKD. There is no burn function;
  `totalSupply()` is monotone and equals the lifetime bridged-in total.
- `bridge` is set at construction (the deploy script predicts the entry); `setBridge` is `onlyOwner`, 0 stops minting.

### `KskdEntry` (Robinhood)

- Immutable `TOKEN`, `VERIFIER` (`NitroAttestationVerifierV2` on mainnet, which pins no PCR); storage
  `expectedPcr0`, the first 32 of the 48 PCR0 bytes of the accepted image, set by the constructor and by
  `setExpectedPcr0` (`onlyOwner`, non-zero, `ExpectedPcr0Set`). The constructor also sets `threshold` and
  `mintLimit`, rejecting a zero token, verifier, PCR0 or threshold.
- `registerEnclave(doc)` is `onlyOwner`: the verifier checks the document, PCR0 must equal `expectedPcr0`
  (`PCR0Mismatch`), the signer must be non-zero (`ZeroAddress`) and new (`SignerAlreadyRegistered`).
- `removeSigner` is `onlyOwner` and unguarded: it may leave `signerCount < threshold`, and claims then fail until a
  signer is re-admitted or the quorum is lowered.
- `setThreshold` is `onlyOwner`, bounded `1 ≤ t ≤ signerCount`; `setGuardian` is `onlyOwner`, zero disables the role.
- Image rotation on the V2 verifier: `setExpectedPcr0(new)` + `registerEnclave(new doc)` + `removeSigner(old)`, for
  any image change (EIF repack, kernel, application). Signers admitted under the old PCR0 stay valid until removed, so
  the cutover overlaps and outstanding signatures survive.
- On a V1 verifier (testnet 46630), which pins PCR1/PCR2 immutably, the same path covers only a PCR0 that moved while
  PCR1/PCR2 held; a kernel, bootstrap or application rebuild (Nitro PCR2 measures the application) needs a new
  verifier, a new entry and `KskdBridged.setBridge(newEntry)`. Claim accounting lives in the token, so a new entry
  migrates no state and cannot double-mint; window counters do not carry over, and signatures for the old entry die
  with its EIP-712 domain.
- The owner is a Safe from block 0; `Ownable2Step` keeps a mistyped transfer from orphaning the contract.
  `renounceOwnership` reverts `RenounceDisabled`: an ownerless entry could never restore `mintLimit` after a guardian
  pause or rotate signers. On the token it stays available as the final wind-down step.

## Message format

- Domain: name `"Pontifex"`, version `"1"`, `chainId` = the Robinhood chain the entry lives on, `verifyingContract` =
  that `KskdEntry`. Type: `Claim(address recipient,uint256 cumulativeBurned,uint256 deadline)`, where
  `cumulativeBurned` is `KskdExit.burned[recipient]` — a monotone total, never a delta.
- Signature: 65-byte `r‖s‖v`, low-`s`. `ECDSA.recoverCalldata` reverts on any other length and on a high `s`, so a
  malformed signature fails inside OZ, not as a bridge error. `signatures` must be strictly ascending by recovered
  signer address (`UnsortedSigners`), so duplicates are impossible.
- One signature binds one chain, one entry, one recipient, one total and one deadline.

## Claim flow

1. The user approves KSKD to `KskdExit` and calls `exit(amount, recipient)`; the exit burns and records `burned[recipient]`.
2. The enclave reads `burned[recipient]` on Igra and signs the `Claim` struct.
3. Anyone calls `KskdEntry.claim(recipient, cumulativeBurned, deadline, signatures)` — permissionless.
4. The entry checks the deadline, the quorum and the signer order, requires `cumulativeBurned > bridgedIn[recipient]`,
   reserves window budget, calls `TOKEN.bridgeMint(recipient, prior + granted)` and emits `Claimed(recipient, minted,
   cumulative, attested)` with `cumulative` = `bridgedIn` after the mint and `attested` = the signed `cumulativeBurned`;
   `cumulative < attested` marks a partial fill. All supplied signatures must verify, not just `threshold` of them.

| condition | error |
|---|---|
| `block.timestamp > deadline` | `ClaimExpired` |
| fewer than `threshold` signatures | `InsufficientSignatures` |
| signatures not strictly ascending by signer | `UnsortedSigners` |
| any supplied signature recovers an unregistered address | `InvalidSigner` |
| `cumulativeBurned ≤ bridgedIn[recipient]` | `KskdBridged.NothingToMint` |
| window budget fully used | `MintLimitExhausted` |
| `bridge` no longer points at this entry | `KskdBridged.NotBridge` |

## Limits and windows

- `WINDOW = 1 days`, fixed (tumbling), anchored at the first claim after the previous window expires. Because it is
  not rolling, the bound is at most `2 × mintLimit` across any rolling 24 h per entry instance.
- Partial fill: a claim mints `min(cumulativeBurned − bridgedIn, mintLimit − windowMinted)` and the same signatures stay
  valid for the remainder until their deadline; `MintLimitExhausted` fires only when the window has no room at all.
- `setMintLimit(0)` stops claims; lowering it below what the window already minted stops them until the window rolls.
- The budget is shared, first-come. A holder with a large attested balance can take every window at gas cost only,
  which delays smaller claimants for as long as it keeps doing so; the levers are `setMintLimit` and sequencing the
  treasury migration outside the public claim period.
- Measured `claim` execution gas (`gasleft` delta inside one transaction sequence, excludes the 21,000 base and
  calldata; reproduced by `test/unit/ClaimGas.t.sol`): first claim of the deployment 124,432; same recipient again
  14,823; fresh recipient in a warm window 58,623 at threshold 1, 63,198 at threshold 2, 67,773 at threshold 3; first
  claim of a new window for a known recipient 14,932. Every path sits three orders of magnitude under the 32,000,000
  cap.

## Trust model

- The Robinhood Safe, owner of token and entry, is the trust root: it admits signers, sets `threshold`, `mintLimit`,
  `guardian` and `expectedPcr0`, and can point `bridge` anywhere — worst case a mint of up to `MAX_SUPPLY` to anyone. It is fully trusted.
- Attestation proves the enclave IMAGE, not the operator: anyone holding the EIF can produce a verifying document, so
  the Safe must confirm out-of-band that the document came from a Kaskad-operated instance.
- Enclave signers hold mint authority. A leaked or rogue key mints unbacked KSKD up to `mintLimit` per window (2× across
  a boundary); with `threshold = 2` one key cannot mint at all. A signature over a reorged-out burn, or over a value
  from a lying Igra RPC, is an unbacked mint with no clawback; `mintLimit` and `MAX_SUPPLY` are the only backstops.
- Revocation is `removeSigner`; in-flight signatures die at their deadline (enclave policy: `deadline = now + 1 h`), so
  `pause()` held for one deadline length then `removeSigner` invalidates everything outstanding.
- A same-image restart produces a NEW signer key with unchanged PCRs; re-enrol by warming the certificates, then
  `registerEnclave(new doc)` and `removeSigner(old)`. With `threshold = 2` and two enclaves, a restart halts claims.
- Production verifier behaviour (`NitroAttestationVerifierV2` over Marlin's `NitroProver` and `CertManager`):
  - `verifyAttestation` returns `valid = true` with the document's PCR0 and signer address, or reverts (`PCR0NotFound`,
    `InvalidPCR0Length`, `InvalidPublicKeyLength`, or a `NitroProver` string require);
    `KskdEntry.InvalidAttestation` can only fire for a verifier that returns false.
  - No attestation-age cap on-chain: `MAX_ATTESTATION_AGE` (4 h) is added to the document's millisecond timestamp and
    compared with the second-denominated block timestamp, so it never fires; freshness is an operational control.
  - Certificate validity (`notBefore` / `notAfter`) is checked only the first time a certificate is verified; cached
    certificates skip the check.
  - The CA chain is warmed one certificate at a time through `CertManager.verifyCert`, because the 32,000,000
    per-transaction gas cap cannot fit `verifyCerts`; `registerEnclave` with warm certificates fits, also via a Safe.
    Measured gas: `script/README.md` § 3.
  - The `VERIFIER` comment in `src/KskdEntry.sol` ("pinning PCR1/PCR2") describes the V1 verifier. `src/` stays
    byte-identical to the deploy commit, comments included, because source text enters the metadata hash.
- Igra facts: chain time lags wall clock by 8–12 minutes (496, 568 and 704 s in three measurements on 2026-09-18; it
  drifts — re-measure before relying on it); the node's `finalized` tag is latest − 768 blocks (identical at heads
  17,091,730 and 17,128,572 on 2026-09-18), `safe` is latest − 35; block time 1.04–1.05 s, so 768 blocks ≈ 13.4 min;
  `rpc.igralabs.com:8545` is the only public Igra RPC (chainid.network lists no other) and is load-balanced across nodes
  whose heads differ by up to 2 blocks; `eth_getLogs` windows are capped at 100,000 blocks. `totalBurned` and
  `totalSupply()` exist, so monitoring needs no log scan.
- Reentrancy: none. `exit` writes all state before the token calls, `exitWithPermit` calls `permit` before any state
  write (a reentrant `exit` from inside it is an ordinary exit), the entry reserves window budget before `bridgeMint`,
  the verifier call is a STATICCALL (`view` interface) and OZ v5 ERC20 has no hooks; no `ReentrancyGuard` by design.

## Invariants

| invariant | where enforced |
|---|---|
| `burned[r]` only grows | `KskdExit.exit` is the sole writer, `+= amount` with `amount > 0` |
| `totalBurned == Σ burned[r]` | the same writer updates both |
| `bridgedIn[r]` only grows | `KskdBridged.bridgeMint` requires `cumulative > prior` |
| `totalSupply() == Σ bridgedIn[r] ≤ MAX_SUPPLY` | `bridgeMint` `MaxSupplyExceeded` check; no burn path exists |
| `bridgedIn[r] ≤ burned[r]` | not enforceable on-chain; holds under honest signers reading final Igra state |
| one burn never mints twice | cumulative accounting plus `NothingToMint`; survives entry replacement because the counters live in the token |
| `windowMinted ≤ mintLimit` | `_reserve` grants at most the remaining room, while the limit is not lowered mid-window |
| `mintLimit == 0` ⇒ no claim succeeds | `_reserve` reverts `MintLimitExhausted` |
| a signature is valid on one chain and one entry only | EIP-712 domain (`chainId`, `verifyingContract`) |
| a signature cannot be replayed as a different message | recipient, cumulative and deadline are all in the struct hash |
| every `validSigner` was attested for the `expectedPcr0` current at its admission and admitted by the owner | `registerEnclave` is the only writer and is `onlyOwner` |

## Enclave / relayer contract

1. Read `burned[recipient]` from state (`eth_call`) on Igra at the block chosen in item 2; never reconstruct it from
   `Exited.cumulative`, which is a log value and not the ledger.
2. One Igra RPC (`rpc.igralabs.com:8545`, load-balanced; no second public endpoint exists and no own node is planned):
   read at the node's `finalized` tag and never above latest − 800; read the same (block hash, `burned`) pair twice
   before signing, since the balancer may answer from different nodes, and refuse on any disagreement.
3. Enumerate recipients from `Exited` logs with a cursor persisted OUTSIDE the enclave (a Nitro enclave has no durable
   storage; `eth_getLogs` accepts at most 100,000 blocks per call).
4. Sign only for `recipient ≠ 0`; never sign the exit or token address (the chain rejects those burns anyway).
5. Set `deadline = now + 1 h`; the entry rejects the claim after it.
6. Re-signing a lower or equal cumulative is harmless — the claim reverts `NothingToMint`.
7. A `burned` value that DECREASES between reads means a reorg or a lying endpoint: refuse and alert.
8. Sign under `chainId` 4663 (mainnet) or 46630 (testnet), `verifyingContract` = the entry address recorded at deploy.
9. The signer key is the enclave's attested public key reduced to an Ethereum address; the entry registers exactly that.
10. The relayer sends exactly `threshold` signatures sorted by signer address and decodes: `ClaimExpired` → fetch a new
    signature; `MintLimitExhausted` → retry after the window rolls; `NothingToMint` → done; `Claimed` with
    `cumulative < attested` → repeat with the same signatures once there is room.
11. The relayer is Kaskad's own service and pays the Robinhood gas (≈ 124,000 gas × 0.055 gwei ≈ $0.02 per claim at
    mainnet prices read 2026-09-18). Dust cannot enter the ledger: `KskdExit.minBurn` rejects any exit below the
    floor (1,000 KSKD live). The relayer also caps transactions, gas and KSKD per recipient and per Igra sender;
    anyone can call the permissionless `claim` with their own gas.

## Emergency levers and wind-down

| lever | who | effect |
|---|---|---|
| `KskdEntry.pause()` | guardian | sets `mintLimit := 0`; only the owner restores it |
| `KskdEntry.setMintLimit(0)` | entry owner | stops all claims |
| `KskdEntry.removeSigner(signer)` | entry owner | revokes one enclave key |
| `KskdEntry.setThreshold(t)` | entry owner | raises the quorum |
| `KskdEntry.setExpectedPcr0(pcr0)` | entry owner | retargets which image `registerEnclave` admits; existing signers stay until removed |
| `KskdBridged.setBridge(0)` | token owner | disables `bridgeMint` entirely |
| `KskdExit.setMinBurn(type(uint256).max)` | `CLOSER` | stops new burns on Igra until lowered again |
| `KskdExit.close()` | `CLOSER` | stops new burns on Igra permanently; the ledger stays readable |

- Guardian `pause()` and owner `setMintLimit(0)` both emit only `MintLimitSet(0)`; there is no separate `Paused()`
  event.
- Freezing the entry must be paired with removing the exit path from the frontend — the chains cannot signal each other.
- Wind-down: see `script/README.md` § Wind-down. The order is load-bearing — a grace period for outstanding claims
  sits between `close()` and `setMintLimit(0)`, because burns on Igra are irreversible and `close()` does not stop
  claims. The last step freezes supply forever.

## Deployment

| item | chain | address |
|---|---|---|
| Igra KSKD | 38833 | `0x16d92794F5B81d2CdEd0F0958779A410401e6435` |
| Igra Safe (`CLOSER`; Safe 1.5.0, 3 of 5) | 38833 | `0x5B95Ea5D5B63998467eE92B0b175ACE49ccC1943` |
| `KskdExit` | 38833 | `0x5A818D42cA142483f72AE7D426E199324FEc4871` |
| `NitroAttestationVerifierV2` | 4663 | `0x52A22A678Af63d74BBfCB4c8fA90299db2760ACD` |
| `NitroProver` (used by the verifier) | 4663 | `0x51c66c55f2fB739aB047c28d913BDC7D9280eDBA` |
| `CertManager` (used by the prover) | 4663 | `0x6B1cD9f27d30fc39a50b45c4B03aC80844760264` |
| `KskdBridged` | 4663 | `0x6ddb8541Af17DAdEA47dF41D1C13faf8Deee1902` |
| `KskdEntry` | 4663 | `0x7b1D080d2485E63791468d73418e2B262c25C402` |
| Robinhood Safe (owner of token and entry; Safe 1.4.1, 3 of 5) | 4663 | `0x313807B857222278FbddF36541DE2Af5a50BdCB5` |
| `guardian` (the watchdog bot's key, EOA) | 4663 | `0x217714D086f7254940a46c0C6Abc1e7bF270235e` |
| `NitroAttestationVerifier` V1 (price-oracle image; fork tests only) | 38833 | `0x76216b3bde5bC81b04FA5A5d4a67F6AfACc666B9` |
| `KaskadPriceOracle` (fork tests only) | 38833 | `0xB01993906D14792DC21B7EA75A971D8191AAE402` |

- The verifier stack is deployed separately and is not built from this repository. The V2 verifier pins no PCR;
  `KskdEntry.expectedPcr0` is the only image pin. Enclave source:
  https://github.com/Kaskad-Lending/kaskad-pontifex-enclave.
- Deployed parameters (Robinhood block 89,211,154; Igra block 19,307,398): `threshold` 1 with 1 registered signer;
  `mintLimit` 25,000,000 KSKD per window; `expectedPcr0`
  `0x8761b33a338db4fab12c9201eef87e1c582310d59645848c2574061d1e070d71`; `minBurn` 1,000 KSKD; `guardian` = the
  watchdog bot's key (pauses on any `Claimed` without a matching burn; only the Safe restores); the enclave reads
  Igra at the `finalized` tag (floor latest − 800) from the single public RPC; the relayer is Kaskad-operated and
  free (§ Enclave / relayer contract, item 11).
- Robinhood is ArbOS with a 96 KiB code limit. Both chains return the same triple from
  `ArbGasInfo(0x000000000000000000000000000000000000006C).getGasAccountingParams()` — speed limit 7,000,000/s, gas pool
  max 32,000,000, max tx gas limit **32,000,000** (read 2026-09-18, mainnet block 65,749,182, two endpoints).
- Runtime sizes (`forge build --sizes`, equal to the deployed runtime): `KskdExit` 1,975 B, `KskdBridged` 4,813 B,
  `KskdEntry` 5,582 B.
