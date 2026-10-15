# Fixtures

| file | what it is |
|---|---|
| `KSKD.sol` | The Igra KSKD token as deployed: fixed `TOTAL_SUPPLY = 1e27` minted at construction, `ERC20Permit`, public `burn(amount)`. Used by the unit tests as the Igra-side token. |
| `attestation-us.hex` | Live AWS Nitro attestation document, oracle enclave `i-0f073ba50939baaa1-enc019ebba1832e23b1` (us-east-1). COSE_Sign1, hex, no `0x` prefix, 4,527 bytes decoded. |
| `attestation-eu.hex` | Same, oracle2 enclave `i-00ac7088bfed35b6e-enc019e892e91e6f525` (eu-west-1), 4,528 bytes decoded. |
| `attestation-us.certs` | The US document's certificate chain, comma-separated `0x` hex, in verification order — the output of `script/extract_certs.py`: `cabundle[1:]` plus the leaf, i.e. the AWS root (533 B) excluded, 4 certificates of 707 / 792 / 707 / 639 bytes. |
| `multisend-call-only-1.4.1.hex` | Runtime code of Safe `MultiSendCallOnly` 1.4.1 as deployed at `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` on Robinhood 4663 / 46630, hex, no `0x` prefix, 410 bytes, keccak `0xecd5bd14…6c9939` (the hash `script/SafeScript.sol` pins). Etched by the Safe-script unit tests. |
| `multisend-call-only-1.5.0.hex` | Same for 1.5.0 at `0xA83c336B20401Af773B6219BA5027174338D1836` on Igra 38833, 421 bytes, keccak `0xcdbdcec3…fcfb6663`. |

Both documents carry the same measurements — PCR0 `0x2e66fc4f…82b2106c` (the on-chain `bytes32` is the first 32 of the
48 measurement bytes), PCR1 `0x4b4d5b36…`, PCR2 `0xc970fb37…` — and differ in signer: `attestation-us.hex` attests
`0x544705F5d72E1C6f24bFD7C2E176F2Cd2aA8Dc2A`, `attestation-eu.hex` attests
`0xD35e55c7C2d10472e6d9E7132c88BEeD347D91A7`, each the keccak address of the document's 65-byte `public_key`.
`digest` is SHA384; `nonce` and `user_data` are both absent from the document map.

The documents are consumed by `test/fork/RealVerifier.t.sol` against the production `NitroAttestationVerifier` on Igra
mainnet (`0x76216b3bde5bC81b04FA5A5d4a67F6AfACc666B9`), and by `test/NitroDoc.t.sol` and
`test/RegisterEnclaveScript.t.sol` for the PCR0 read; `foundry.toml` grants read access to this directory.

Time is the fragile part of these fixtures:

- Document timestamps (millisecond field): US `1789682499833` = 2026-09-17 22:01:39.833Z, EU `1789682494404` =
  2026-09-17 22:01:34.404Z. The verifier applies no on-chain age cap, so the documents do not expire by age.
- The leaf certificates do expire: US valid 2026-09-17 20:16:32Z → 23:16:35Z, EU 19:51:25Z → 22:51:28Z (~3 h each).
  Certificate validity is checked only the first time a certificate is verified; once `CertManager` has cached it, later
  verification skips the check.
- A fork test must therefore `vm.warp` into the leaf validity window before the first certificate verification
  (`verifyCerts`, or per-certificate `CertManager.verifyCert`), and only then call `verifyAttestation`. Both documents were captured at unix `1789682698` (2026-09-17 22:04:58Z), which lies inside
  both windows.
- Re-capturing replaces the signer addresses and certificates but not the PCRs, as long as the enclave image is
  unchanged.
