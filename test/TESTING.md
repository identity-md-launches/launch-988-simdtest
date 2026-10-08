# SIMDTEST test coverage

Run `forge build` and `forge test` from the repository root. The suite uses the
existing vendored dependencies and requires no RPC, FFI, environment changes or
filesystem cheatcode permissions.

The original token and dividend invariant suites remain in place. Added coverage:

| File | Properties |
| --- | --- |
| `TokenAdversarial.t.sol` | Fee-rounding boundaries and transfer events; pre-buy eligibility; claim-order independence; historical rewards after delegated full exits; gross allowances; allowance revocation; maximum inputs; atomic rollback; unauthorized claims and admin selectors. Four arithmetic properties each run 1,000 fuzz cases. |
| `DividendModelInvariant.t.sol` | Independent balance and reward ledger over 256 sequences of 96 random actions. Mixes buys, direct/delegated transfers, claims, full exits, queued fees and rejected calls. Checks proportional historical entitlements, fixed supply, exclusions, reserve solvency and final redemption of every holder's whole-unit rewards. |
| `UniswapV4.t.sol` | Extends the existing real local PoolManager tests with multiple traders buying, claiming and selling in both currency orders; pool and token conservation; unpaid swaps with existing rewards; a deliberately short pair-token payment; zero swaps and locked withdrawals. The multi-trader property runs 128 fuzz cases. |

The independent dividend model allocates each fee directly over balances using
decimal sub-wei precision. It does not derive expected rewards from the token's
cumulative index or reported eligible supply. Its one-minor-unit tolerance
accounts for the two models' different rounding precision; balance conservation,
fees, claims and pending amounts are compared exactly.

The revised fixtures supply the launch number and implement the factory's
distributor lookup. The model initializes after deployment so that lookup is
callable, and tracks the factory and distributor as excluded accounts even when
random transfers fund them. Swap reward expectations cover the first buyer
releasing queued fees when no eligible holder exists yet.

Constructor minting is checked separately from external launch allocation: the
deployer receives the full supply, then the external factory/distributor flows
allocate the pool and swarm shares. Pool fee 3000 follows the task's mandatory
manifest requirements. Off-chain creator-fee payments and the external Merkle
proof implementation are outside this token's test surface.

Integration runs the vendored Uniswap v4 PoolManager locally at the specified
mainnet address, with local factory, IMD and trader fixtures. The short-payment
fixture is intentional fault injection, not a claim about live IMD behavior.
Live mainnet IMD, deployed factory/distributor and production router compatibility
still require fork or deployment integration checks; this suite does not verify
their live state.
