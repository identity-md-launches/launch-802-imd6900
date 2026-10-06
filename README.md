# Imd6900 (IMD6900)

An immutable ERC-20 token with no transfer fee. The constructor mints the entire
supply to `msg.sender` once. The token has no owner, external mint or burn method,
pause, blacklist, seizure, upgrade, or initialization mechanism.

| Deployment parameter | Value |
| --- | --- |
| Contract | `src/Imd6900.sol:Imd6900` |
| Name | `Imd6900` |
| Symbol | `IMD6900` |
| Decimals | `18` |
| Whole-token supply | `1,000,000,000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None (`[]`, empty encoded argument bytes) |
| Deployment transaction value | `0` |
| Initial recipient | Immediate deployer; the factory when deployed through a factory |
| Solidity compiler | `0.8.26` |
| EVM target | `cancun` |
| Optimizer | Enabled, 200 runs |
| Metadata bytecode hash | `none` |

## Build and check

With Foundry and Solidity 0.8.26 installed:

```sh
forge build
forge test
forge fmt --check
```

All Solidity dependencies are ordinary files in `lib/`; no installation command,
submodule, RPC endpoint, or environment configuration is needed. An offline runner
must already provide the compiler specified in `foundry.toml`. FFI and filesystem
cheatcode permissions are disabled. The project does not read or write environment
variables in tests.

`test/Imd6900.t.sol` covers metadata, constructor minting and its event, EOA and
CREATE2 factory deployment, exact transfers including one smallest unit and the
whole supply, self and zero transfers, approvals, finite and unlimited allowances,
rejection of invalid recipients and insufficient balances/allowances, rollback on
failure, and absence of privileged minting/freezing/seizure calls. It also checks
the runtime for the forbidden DELEGATECALL, CALLCODE, and SELFDESTRUCT opcodes.

The fuzz tests run 1,000 cases per function. The invariant suite runs 128 sequences
of 64 calls, interleaving transfers, approvals and delegated transfers across four
holders. It checks total supply, aggregate balances, exact received amounts,
allowance consumption and rollback of invalid actions. Each test has independent
setup and can run in parallel.

The factory-flow test models token transfers to a distributor, a pool manager,
and holders, including transfers in both directions with the pool manager. These
are token accounting checks: the fixtures are not a working Uniswap pool or Merkle
distributor. The supplied protected harness also requires launch infrastructure,
v4 dependencies, manifest values and deployment addresses that are not part of
this assignment's repository. Full pool seeding and swap execution remain checks
for the network's launch integration environment.

## Deployment and operations

Build the contract using the settings above. The creation bytecode and ABI are in
`out/Imd6900.sol/Imd6900.json`; these read-only commands also expose them:

```sh
forge inspect src/Imd6900.sol:Imd6900 bytecode
forge inspect src/Imd6900.sol:Imd6900 abi
```

An authorized deployment process submits the creation bytecode with no appended
constructor arguments and no native currency. A Solidity factory can deploy it
with `new Imd6900()` or `new Imd6900{salt: salt}()`. The **factory** receives all
tokens in that case, even when a different account initiated the transaction.
There is no follow-up initialization transaction. Deploy the concrete contract;
its constructor-based supply mechanism is not intended for proxy deployment.

For the network's custom-token manifest, use the contract identifier and exact
metadata/supply above, with `constructorArgs: []`. No application contracts are
required. The chain, factory, CREATE2 salt, paired currency, pool parameters,
opening market cap, pool allocation and remainder recipient belong to the launch
operator; this assignment does not specify or invent them. Distribution and pool
seeding are responsibilities of the external factory. The token charges no fee
on any address, so it needs no launch exemptions or distributor lookup.

The deployer is responsible for selecting a chain supporting the configured EVM
target, checking deployment inputs and the resulting address, verifying source
and compiler settings on the chain explorer, checking that `totalSupply()` and
the deployer's balance equal `10^27` immediately after construction, and safely
distributing or using that initial balance. Once distributed, the deployer has
only ordinary holder permissions. No ongoing keeper or administrator is needed.
No transaction is broadcast by this project.

## Behavior and assumptions

- Transfer amounts are integer smallest units. Both `transfer` and `transferFrom`
  debit and credit exactly the requested amount. Gas costs are separate from token
  transfer fees. Supply never changes after construction.
- Zero-value and self transfers are valid; zero-address recipients and spenders
  are rejected. Invalid operations revert with ERC-20 custom errors and leave
  balances and allowances unchanged.
- `approve` replaces an allowance; finite allowances are consumed by
  `transferFrom`. `type(uint256).max` is treated as unlimited and is not decremented.
  Approval emits `Approval`; transfer emits `Transfer`. Allowance consumption does
  not emit another `Approval`, so integrations should read `allowance` when needed.
- Holders control their balances and allowances. As with standard ERC-20 approval,
  a spender may consume an existing allowance before a replacement confirms.
  Revoke an existing approval first and wait for confirmation before granting a
  new amount when that distinction matters. Holders must choose trusted spenders.
- Transfers do not call recipients, and the contract makes no external calls. It
  has no oracle, randomness, signature, time, chain-address, or upgrade dependency.
  Native-currency payments revert. Tokens sent to an address unable to move them,
  including this token contract, cannot be recovered by an administrator.
- Local tests and source review are not an independent security audit. Independent
  adversarial review and launch integration verification remain release
  responsibilities of the network operator. Slither and Mythril were not run.

## Vendored source provenance

The token inherits the unmodified ERC-20 implementation and its required imports
from [OpenZeppelin Contracts v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2).
Tests use the source distribution of
[forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7).
`DEPENDENCIES.json` records the source archives and SHA-256 hashes of every vendored
file. The upstream MIT and Apache licenses are included beside the dependencies.
Project-authored source is MIT licensed; see `LICENSE`.
