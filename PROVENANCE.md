# Provenance

Single-commit public copy of the private Pontifex contracts repository. History is squashed; sources are unchanged.

## Source

| item | value |
|---|---|
| Published tree | private commit `d7e8f4b92321f752931cf5b806a4535c887ae6b9` |
| Deployed bytecode | private commit `2284bd883370f9f4573eb780d4fc5e2dcf5b75ed` |
| Identical in both | `src/` (git tree `ac8d0cd2f1283ddd2e43ec175827914146b6cec2`), `foundry.toml`, `foundry.lock`, `remappings.txt`, `.gitmodules`, `lib/` pins |
| `lib/forge-std` | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` (v1.16.2) |
| `lib/openzeppelin-contracts` | `5fd1781b1454fd1ef8e722282f86f9293cacf256` (v5.6.1) |
| Compiler | solc 0.8.30+commit.73712a01, optimizer 200 runs, EVM `cancun`, `via_ir` off, metadata hash `ipfs` |

`git rev-parse HEAD:src` in this repository prints the `src/` tree id above.

## Deployed contracts

| contract | chain | address | creation transaction | block | deployer |
|---|---|---|---|---|---|
| `KskdExit` | Igra 38833 | `0x5A818D42cA142483f72AE7D426E199324FEc4871` | `0x7a948c8a13517da11f8937f4eade6ed37b06a74370cbd6187f5f8ef539f50f32` | 18880615 | `0x047b9729d53d6b6c7Df82B032EE4FCDD37Bb146f` |
| `KskdBridged` | Robinhood 4663 | `0x6ddb8541Af17DAdEA47dF41D1C13faf8Deee1902` | `0xa309ae9d8aeb0ba1dbd068141081f69bfc433c48cd973cd759fa4bb8483dc43f` | 84780073 | `0x2DA5224C284B210D1E217c3AcEa8d93B7b7FE5e6` |
| `KskdEntry` | Robinhood 4663 | `0x7b1D080d2485E63791468d73418e2B262c25C402` | `0xaaa322c8aac5edc7cd74e4b169619363745dfc39da51ee3f3f87f33d4ed61adb` | 84780080 | `0x2DA5224C284B210D1E217c3AcEa8d93B7b7FE5e6` |

Constructor arguments: `deployments/mainnet.json`.

## Reproduce

```sh
git clone <this repository> pontifex && cd pontifex
git submodule update --init      # not --recursive
forge build
```

Each creation transaction input equals `out/<Name>.sol/<Name>.json` `.bytecode.object` followed by the ABI-encoded
constructor arguments (`cast tx <hash> input --rpc-url <rpc>`); the deployed runtime equals `.deployedBytecode.object`
outside `.deployedBytecode.immutableReferences`.

Initialise the submodules with `git submodule update --init` before the first forge command, never with
`--recursive`. `forge install`, and `forge build` on an empty `lib/`, also check out OpenZeppelin's nested
submodules; their forge auto-remappings enter the solc metadata and change the trailing metadata hash, though not
the executable code.

## Scripts

Scripts here are as of the published commit, not the deploy commit. These differ from the deploy commit; scripts do
not enter the contract bytecode:

- `script/DeployExit.s.sol` (changed)
- `script/DeployRobinhood.s.sol` (changed)
- `script/NitroDoc.sol` (added)
- `script/README.md` (changed)
- `script/RegisterEnclave.s.sol` (changed)
- `script/SafeOps.s.sol` (added)
- `script/SafeScript.sol` (added)
- `script/SetBridge.s.sol` (changed)
- `script/SetExpectedPcr0.s.sol` (changed)
- `script/SetGuardian.s.sol` (changed)
