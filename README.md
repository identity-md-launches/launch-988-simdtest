# SIMDTEST

`SIMDTESTToken` is an immutable ERC-20 with 18 decimals and a fixed supply of
**1,000,000,000 SIMDTEST** (`1000000000000000000000000000` minor units). Its
argument-free constructor mints the entire supply to `msg.sender`. The launch
factory must be that deployer. There is no owner, mint function, burn function,
pause, blacklist, upgrade mechanism, fee setter, or rescue function.

## Build and test

```sh
forge build
forge test
forge fmt --check
```

The root configuration pins Solidity **0.8.26**, Cancun, optimization with 200
runs, and `bytecode_hash = "none"`. All Solidity dependencies are ordinary files
in `lib/`; no package installation, submodule, RPC, environment variable, FFI, or
filesystem cheatcode permission is needed by the delivered tests. Foundry and
the pinned compiler must already be installed for an offline build.

The suite covers supply and factory allocation, buy/sell/wallet transfers,
allowances and failed transfers, proportional claims, historical entitlements,
excluded accounts, fractional credit, the zero-holder case, unsupported admin
selectors, and forbidden runtime opcodes. Two fuzz tests use 512 cases each.
Four stateful invariants run over 128 sequences of 64 actions, checking balances,
fee accounting, exclusions, and dividend solvency.

Integration tests execute the vendored Uniswap v4 PoolManager constructor at the
specified mainnet address in a local EVM. They deploy the actual token using
CREATE2, allocate the swarm share, initialize and seed a single-sided pool, then
buy and sell in both currency orders. They check net buy receipts and zero
outstanding settlement deltas. An unpaid swap must revert with
`CurrencyNotSettled`, rolling back its token fee. IMD and the factory are local
test fixtures; these tests do not claim to be a mainnet fork or verification of
the live IMD deployment.

## Launch parameters and precedence

The deployable artifact is `src/SIMDTESTToken.sol:SIMDTESTToken`, with no
constructor arguments. `launch.json` uses `kind: "custom_token"` and an empty
application list. The token itself imports no libraries.

| Parameter | Value |
| --- | --- |
| Chain | Ethereum mainnet, chain ID 1 |
| PoolManager, fixed in the token | `0x000000000004444c5dc75cB358380D2e3dE08A90` |
| Paired currency, IMD | `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` |
| Pool fee | `3000`, or 0.30% |
| Tick spacing | `60` |
| Provenance sqrtPriceX96 | `125270724187523965593206900` |
| Pool budget | `poolBps: 9000`, 900,000,000 SIMDTEST |
| Opening market capitalization | `initialMarketCapWei: "2500000000000000000000"`, 2500 IMD |
| Remainder recipient | `0x000000000000000000000000000000000000dead` |

The mandatory manifest requirement explicitly specifies fee **3000**; it takes
precedence over the earlier narrative fee **12500 (1.25%)**. The mandatory
factory allocation requirement and pinned constructor check likewise take
precedence over the narrative test asking for a constructor mint to the
PoolManager. There is one mint to the deployer, followed by factory transfers.

The provenance price assumes SIMDTEST is currency0. The external deployer must
derive the real opening price, valid ticks and liquidity from the economics and
the deployed address ordering. The paired currency's minor units are used for
the opening cap. The integration tests exercise both orderings.

## Allocation responsibilities

The existing external `ProjectFactory.launchCustom` flow must:

1. Deploy `SIMDTESTToken` and hold the entire supply.
2. Transfer exactly 100,000,000 tokens to its external Merkle distributor for
   the swarm. Distributor-to-beneficiary claims are ordinary, untaxed transfers.
3. Budget exactly 900,000,000 tokens for the single-sided pool seed and settle
   the seed from the factory's balance. Incoming PoolManager transfers arrive
   whole. Uniswap's integer liquidity rounding can leave a small remainder.
4. Forward any remaining balance to the specified `remainderTo` burn address.
   Sending there does not reduce `totalSupply`.

No token function performs swarm allocation or pool initialization. There is no
requester-chosen distributor address or configurable launch recipient to supply
to this token. `LaunchLiquidity`, `HookFlags`, and `PoolInitializationGuard` are
supporting source interfaces/helpers for the pinned launch compatibility checks;
they are not additional applications in the manifest. The guard lets only its
deploying factory initialize pools through its immutable PoolManager and has no
swap callbacks or token authority. A factory deploying that guard must choose
an address whose low 14 bits equal the `BEFORE_INITIALIZE` flag.

## Transfers and dividends

A transfer **from** the fixed PoolManager, except a self-transfer back to that
same address, splits its gross amount into:

- `floor(gross * 300 / 10000)` tokens credited to the token contract;
- the remaining tokens credited to the recipient.

The PoolManager loses exactly the gross amount. Transfers **to** it, including
sells and the seed, and all other wallet transfers have zero token fees.
`transferFrom` follows the same rules and consumes the gross allowance; an
unlimited approval retains the usual ERC-20 semantics. Zero-value and
self-transfers are allowed. Transfers to the zero address are rejected.

For example, a 1000-token buy delivers 970 tokens and reserves 30 tokens for
dividends. Before that buy, holders with respectively 25% and 75% of the eligible
balance earn approximately 7.5 and 22.5 tokens. The newly purchased balance
starts earning on later fees. If the buyer already held tokens, those old tokens
participate in the current fee.

The PoolManager, the token contract and `0x...dEaD` are permanently excluded
from rewards. All other holders, including the external distributor and other
contracts, are eligible. Historical rewards stay with the account that earned
them when balances move, even if that account sells all its tokens. New balances
never acquire historical rewards.

`claimableDividends(account)` returns whole minor units currently claimable.
`claim()` pays only `msg.sender`, reverts with `NoDividends()` if nothing is due,
and uses an internal untaxed transfer. Claims make no external calls and give
the claimed tokens eligibility only for future fees. No holder iteration or
automatic payout is performed during a transfer.

Accounting uses a cumulative index with precision `2**128` and checkpoints taken
before every balance change. Sub-wei account credit survives transfers and
claims. Buy fees and index increments round down; residual index dust remains
in the contract with no privileged withdrawal route. Transfers too small to
produce a one-wei fee are untaxed. The implementation multiplies a holder's
unchanged balance by its index difference, avoiding lifetime-index multiplication
by a newly acquired large balance.

If eligible supply is zero, fees queue without division. The first subsequent
transfer or claim that creates eligible supply distributes that queue to the
resulting holders. This includes the first buyer if all tokens were previously excluded;
it is the explicit exception to pre-buy allocation because there were no prior
eligible holders. Direct donations to the token contract are not fees and create
no dividend entitlement; they are irretrievable surplus reserves.

## Operational limits and after launch

All addresses in production configuration come from the assignment. There are
no settings to change after deployment. The external launch operator supplies
the factory, distributor, Merkle root, pool liquidity calculation and transaction
execution; this project never loads keys or broadcasts transactions.

The fee recognizes only an ERC-20 transfer's `from` address. Consequently it also
applies to liquidity withdrawals and other outgoing PoolManager transfers, and
to transfers involving other pools in that singleton. It cannot distinguish a
swap from those operations. Swaps netted entirely inside v4 without a SIMDTEST
ERC-20 payout do not trigger a token transfer fee.

Integrators must measure the recipient's net token balance for output/slippage
checks and support fee-on-transfer outputs. An exact-output request to v4 is a
gross output and delivers 97% after this token's fee. Local direct-settlement
success does not establish compatibility with every router or multi-hop route.
The settlement behavior tested here follows Uniswap's
[PoolManager implementation](https://github.com/Uniswap/v4-core/blob/46c6834698c48bc4a463a86d8420f4eb1d7f3b75/src/PoolManager.sol).

Dividends earned while swarm tokens sit in the distributor accrue to that
distributor. They do not follow its later Merkle token transfers. Contract
holders need their own ability to call `claim()`; if a distributor or router lacks
that ability, its earned dividends remain reserved and inaccessible. The token
has no administrator who can redirect them.

Identity.md's **additional 1% creator fee** is entirely off-chain: 0.5% of swap
volume to **$SIMD holders**, and 0.5% to IMD seat agents, as specified in the
assignment. The external service handles volume measurement, entitlements and
payouts. These are separate from the on-chain 3% SIMDTEST buy dividend and the
pool's 0.30% LP fee.

Before release, the operator is responsible for an independent adversarial
review, verifying the live chain addresses and pool configuration, and explorer
verification of the deployed artifact. Local unit, fuzz and integration tests
are the checks provided here; Slither, Mythril and a mainnet fork were not run.
