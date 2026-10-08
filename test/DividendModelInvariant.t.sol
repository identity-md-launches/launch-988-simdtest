// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SIMDTESTToken} from "src/SIMDTESTToken.sol";

/// @dev Reference ledger allocates each fee directly across pre-transfer balances. It never
/// reads eligibleSupply, dividendsPerToken, MAGNITUDE or the token's dividend counters to
/// compute entitlements. Decimal sub-wei precision is independent of the implementation's index.
contract DividendModelHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant PRECISION = 1e18;
    uint256 internal constant POOL = 4;
    uint256 internal constant BURN = 5;
    uint256 internal constant RESERVE = 6;
    uint256 internal constant FACTORY = 7;
    uint256 internal constant DISTRIBUTOR = 8;

    SIMDTESTToken public token;
    address[9] public accounts;
    uint256[9] public balances;
    uint256[4] public earnedScaled;
    uint256[4] public paid;
    uint256 public fees;
    uint256 public claims;
    uint256 public queued;
    uint256 public distributions;

    // Initialize after deployment so the token can call the factory's distributor lookup.
    function initialize() external {
        require(address(token) == address(0), "already initialized");
        token = new SIMDTESTToken(1);
        accounts[FACTORY] = address(this);
        accounts[DISTRIBUTOR] = makeAddr("model swarm distributor");
        for (uint256 i; i < 4; ++i) {
            accounts[i] = makeAddr(string.concat("model holder ", vm.toString(i)));
            balances[i] = 25_000_000 ether;
            token.transfer(accounts[i], balances[i]);
        }
        accounts[POOL] = token.POOL_MANAGER();
        accounts[BURN] = token.BURN_ADDRESS();
        accounts[RESERVE] = address(token);
        balances[POOL] = 900_000_000 ether;
        token.transfer(accounts[POOL], balances[POOL]);
    }

    function distributorOf(uint64 launchNumber) external view returns (address) {
        require(launchNumber == 1, "wrong launch number");
        return accounts[DISTRIBUTOR];
    }

    function buy(uint256 toSeed, uint256 amountSeed, bool delegated) external {
        _transfer(POOL, toSeed % accounts.length, _amount(amountSeed, balances[POOL]), delegated);
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool delegated) external {
        uint256 from = fromSeed % 4;
        _transfer(from, toSeed % accounts.length, _amount(amountSeed, balances[from]), delegated);
    }

    /// @dev Force the zero-eligible-supply boundary into random sequences; subsequent claims
    /// and buys must restore eligibility without losing either historical or queued rewards.
    function exitAllAndQueue(uint256 amountSeed) external {
        for (uint256 i; i < 4; ++i) {
            _transfer(i, POOL, balances[i], false);
        }
        _transfer(POOL, BURN, _amount(amountSeed, balances[POOL]), false);
    }

    function claim(uint256 holderSeed) external {
        _claim(holderSeed % 4);
    }

    function rejectUnapprovedSpend(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        uint256 from = fromSeed % 4;
        uint256 amount = bound(amountSeed, 1, SUPPLY);
        // This handler revokes its approvals after every authorized delegated transfer.
        vm.expectRevert(
            abi.encodeWithSelector(SIMDTESTToken.ERC20InsufficientAllowance.selector, address(this), 0, amount)
        );
        token.transferFrom(accounts[from], accounts[toSeed % accounts.length], amount);
    }

    function rejectExcludedClaim(uint256 seed) external {
        vm.prank(accounts[POOL + seed % (accounts.length - POOL)]);
        vm.expectRevert(SIMDTESTToken.NoDividends.selector);
        token.claim();
    }

    /// @dev Called at the end of every invariant run, including when every current holder sold.
    function drainAllClaims() external {
        for (uint256 i; i < 4; ++i) {
            _claim(i);
            // The first claim may release queued fees if it recreated eligible supply.
            _claim(i);
        }
    }

    function eligible() public view returns (uint256 result) {
        for (uint256 i; i < 4; ++i) {
            result += balances[i];
        }
    }

    function _claim(uint256 who) private {
        uint256 due = token.claimableDividends(accounts[who]);
        assertApproxEqAbs(paid[who] + due, earnedScaled[who] / PRECISION, 1, "claim entitlement differs from model");
        if (due == 0) {
            vm.prank(accounts[who]);
            vm.expectRevert(SIMDTESTToken.NoDividends.selector);
            token.claim();
            return;
        }
        vm.prank(accounts[who]);
        uint256 received = token.claim();
        assertEq(received, due, "claim return differs from promised payout");
        paid[who] += received;
        claims += received;
        balances[RESERVE] -= received;
        balances[who] += received;
        _allocate();
    }

    function _transfer(uint256 from, uint256 to, uint256 amount, bool delegated) private {
        uint256 fee = from == POOL && to != POOL ? amount * 3 / 100 : 0;
        fees += fee;
        queued += fee;
        _allocate();
        balances[from] -= amount;
        balances[to] += amount - fee;
        balances[RESERVE] += fee;
        _allocate();

        if (delegated) {
            // Exercise both finite and unlimited allowances while authorizing the GROSS amount.
            uint256 approval = amount % 2 == 0 ? amount : type(uint256).max;
            vm.prank(accounts[from]);
            token.approve(address(this), approval);
            assertTrue(token.transferFrom(accounts[from], accounts[to], amount));
            assertEq(token.allowance(accounts[from], address(this)), approval == amount ? 0 : approval);
            vm.prank(accounts[from]);
            token.approve(address(this), 0);
        } else {
            vm.prank(accounts[from]);
            assertTrue(token.transfer(accounts[to], amount));
        }
    }

    function _allocate() private {
        uint256 supply = eligible();
        if (queued == 0 || supply == 0) return;
        for (uint256 i; i < 4; ++i) {
            earnedScaled[i] += queued * balances[i] * PRECISION / supply;
        }
        queued = 0;
        ++distributions;
    }

    function _amount(uint256 seed, uint256 maximum) private pure returns (uint256) {
        // Deliberately mix full exits and fee-rounding boundaries with uniform bounded amounts.
        if (seed % 6 == 0) return maximum;
        if (seed % 6 == 1) return 0;
        if (seed % 6 == 2) return maximum < 1 ? maximum : 1;
        if (seed % 6 == 3) return maximum < 33 ? maximum : 33;
        if (seed % 6 == 4) return maximum < 34 ? maximum : 34;
        return seed % (maximum + 1);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract DividendModelInvariantTest is StdInvariant, Test {
    DividendModelHandler internal handler;
    SIMDTESTToken internal token;

    function setUp() public {
        vm.chainId(1);
        handler = new DividendModelHandler();
        handler.initialize();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = DividendModelHandler.buy.selector;
        selectors[1] = DividendModelHandler.move.selector;
        selectors[2] = DividendModelHandler.exitAllAndQueue.selector;
        selectors[3] = DividendModelHandler.claim.selector;
        selectors[4] = DividendModelHandler.rejectUnapprovedSpend.selector;
        selectors[5] = DividendModelHandler.rejectExcludedClaim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantBalancesAndRewardsMatchIndependentLedger() public view {
        uint256 sum;
        uint256 debt = handler.queued();
        for (uint256 i; i < 9; ++i) {
            address account = handler.accounts(i);
            uint256 held = token.balanceOf(account);
            assertEq(held, handler.balances(i), "token balance differs from independent ledger");
            sum += held;
            uint256 due = token.claimableDividends(account);
            if (i < 4) {
                // At most 96 actions: both independent rounding errors are much less than
                // one minor unit (96 * totalSupply / 2**128 < 1). The final floor can differ by 1.
                assertApproxEqAbs(
                    handler.paid(i) + due,
                    handler.earnedScaled(i) / handler.PRECISION(),
                    1,
                    "historical proportional rewards differ from independent ledger"
                );
                debt += due;
            } else {
                assertTrue(token.isExcludedFromDividends(account), "launch account lost its exclusion");
                assertEq(due, 0, "excluded account earned dividends");
            }
        }
        assertEq(sum, handler.SUPPLY());
        assertEq(token.totalSupply(), handler.SUPPLY());
        assertEq(token.FACTORY(), address(handler));
        assertEq(token.LAUNCH_NUMBER(), 1);
        assertEq(token.dividendDistributor(), handler.accounts(8));
        assertEq(token.eligibleSupply(), handler.eligible());
        assertEq(token.pendingDividends(), handler.queued());
        assertEq(token.totalFeesCollected(), handler.fees());
        assertEq(token.totalDividendsClaimed(), handler.claims());
        assertLe(debt + handler.claims(), handler.fees(), "fees do not cover all accrued obligations");
        assertLe(debt, token.balanceOf(address(token)), "reserve cannot pay every holder");
    }

    function afterInvariant() public {
        handler.drainAllClaims();
        invariantBalancesAndRewardsMatchIndependentLedger();
        for (uint256 i; i < 4; ++i) {
            assertEq(token.claimableDividends(handler.accounts(i)), 0, "holder could not redeem all whole units");
        }
    }
}
