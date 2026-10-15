# Pontifex

One-way migration bridge for KSKD: burn on Igra, mint on Robinhood Chain, 1:1. Claims are signed by AWS Nitro enclaves
whose keys are admitted on-chain through attestation. No reserve and no bridge-back: Robinhood KSKD exists only through
the bridge.

## How it works

1. **Burn on Igra (38833).** The holder calls `KskdExit.exit(amount, recipient)` or `exitWithPermit`. The KSKD is
   burned and `burned[recipient]`, a cumulative total, grows by `amount`.
2. **Attest.** An enclave running the pinned image reads `burned[recipient]` at Igra finality and signs the EIP-712
   message `Claim(recipient, cumulativeBurned, deadline)`.
3. **Mint on Robinhood Chain (4663).** Anyone submits the signatures to `KskdEntry.claim`. The entry checks the signer
   quorum and the daily mint limit; `KskdBridged` mints `cumulativeBurned − bridgedIn[recipient]` to the recipient.

Enclave source: https://github.com/Kaskad-Lending/kaskad-pontifex-enclave

## Deployed contracts

| chain | contract | address | owner / admin |
|---|---|---|---|
| Igra 38833 | `KskdExit` | `0x5A818D42cA142483f72AE7D426E199324FEc4871` | no owner; `CLOSER` = Igra Safe `0x5B95Ea5D5B63998467eE92B0b175ACE49ccC1943` (3 of 5): `close()` once, `setMinBurn` |
| Robinhood 4663 | `KskdBridged` (KSKD) | `0x6ddb8541Af17DAdEA47dF41D1C13faf8Deee1902` | Robinhood Safe `0x313807B857222278FbddF36541DE2Af5a50BdCB5` (3 of 5) |
| Robinhood 4663 | `KskdEntry` | `0x7b1D080d2485E63791468d73418e2B262c25C402` | Robinhood Safe; `guardian` `0x217714D086f7254940a46c0C6Abc1e7bF270235e` can only pause |
| Robinhood 4663 | `NitroAttestationVerifierV2` | `0x52A22A678Af63d74BBfCB4c8fA90299db2760ACD` | none: stateless, no admin function; not built from this repository |

## Live configuration

Read on Igra block 19,307,398 and Robinhood block 89,211,154.

| parameter | value |
|---|---|
| `KskdExit.minBurn` | 1,000 KSKD per `exit` call |
| `KskdExit.closed` | `false` |
| `KskdEntry.threshold` / `signerCount` | 1 / 1 |
| `KskdEntry.mintLimit` | 25,000,000 KSKD per 1-day window |
| `KskdEntry.expectedPcr0` | `0x8761b33a338db4fab12c9201eef87e1c582310d59645848c2574061d1e070d71` (first 32 of the 48 PCR0 bytes) |
| `KskdBridged.MAX_SUPPLY` | 1,000,000,000 KSKD |

## Source verification

Sourcify status, read 2026-10-15.

| contract | status |
|---|---|
| `KskdBridged` | Sourcify exact match |
| `KskdEntry` | not verified |
| `KskdExit` | not verified; Sourcify does not support Igra 38833 |

`PROVENANCE.md` maps this tree to the commit the deployed bytecode was built from.

## Build and test

Toolchain: forge 1.4.3, solc 0.8.30, optimizer 200 runs, EVM `cancun`, no `via_ir`.

```sh
git clone https://github.com/Kaskad-Lending/kaskad-pontifex && cd kaskad-pontifex
git submodule update --init                    # NOT --recursive, and before the first forge command
forge build --sizes
forge test --no-match-path 'test/fork/*'       # unit
forge test --match-path 'test/fork/*' -vv      # fork: Igra mainnet + Robinhood testnet
```

- Initialise submodules only with `git submodule update --init`. `git clone --recursive`,
  `git submodule update --init --recursive`, `forge install`, and `forge build` on an empty `lib/` all check out
  OpenZeppelin's nested submodules. Their forge auto-remappings enter the solc metadata and change the trailing
  metadata hash, so the build no longer matches the deployed bytecode byte for byte; the executable code is
  unchanged.
- Fork tests read `IGRA_RPC_URL` (default `https://rpc.igralabs.com:8545`) and `ROBINHOOD_RPC_URL` (default
  `https://rpc.testnet.chain.robinhood.com/rpc`).

## Docs

| file | content |
|---|---|
| `docs/ARCHITECTURE.md` | overview, roles, limits |
| `docs/DESIGN.md` | specification: contracts, message format, trust model, invariants |
| `script/README.md` | deployment and operations runbook |

Testnet chains: Galleon 38836 (Igra side), Robinhood testnet 46630. License: Apache-2.0.
