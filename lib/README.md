# Vendored dependencies

The files below are unmodified upstream source subsets, copied as ordinary files.
No nested Git repositories, submodules, generated outputs or network installation
steps are required. Upstream test suites and unused dependencies are omitted.

| Directory | Upstream revision | Included files |
| --- | --- | --- |
| `forge-std` | [foundry-rs/forge-std v1.9.7, `77041d2ce690e692d6e03cc812b57d1ddaa4d505`](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | `src/` and MIT/Apache licenses |
| `v4-core` | [Uniswap/v4-core, `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | `src/` excluding `src/test/`, and `licenses/` |
| `solmate` | [transmissions11/solmate, `89365b880c4f3c786bdd453d4b8e8fe410344a69`](https://github.com/transmissions11/solmate/tree/89365b880c4f3c786bdd453d4b8e8fe410344a69) | `src/auth/Owned.sol` and license, required by the test PoolManager |

The token itself has no dependency imports. Vendored Uniswap PoolManager and its
protocol-fee ownership are external-protocol test dependencies, not an ownership
role or deployed application of SIMDTEST. Source-specific SPDX identifiers and
the accompanying upstream license texts are retained.
