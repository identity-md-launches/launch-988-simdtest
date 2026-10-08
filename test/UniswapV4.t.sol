// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SIMDTESTToken} from "../src/SIMDTESTToken.sol";
import {LaunchLiquidity} from "../src/LaunchLiquidity.sol";
import {PoolInitializationGuard} from "../src/PoolInitializationGuard.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @dev Local pair-token fixture; the live IMD contract is never called by these tests.
contract PairFixture {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Fault-injection pair with the same balance storage as PairFixture. It makes a
/// settlement arrive one minor unit short, exercising the helper's explicit failure path.
contract ShortPaymentPairFixture {
    mapping(address => uint256) public balanceOf;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount - 1;
        return true;
    }
}

/// @dev Test-only stand-in for the external launch factory, not a manifest application.
contract FactoryFixture is IUnlockCallback {
    address private immutable controller = msg.sender;
    IPoolManager private immutable manager;
    mapping(uint64 => address) public distributorOf;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    modifier onlyController() {
        require(msg.sender == controller, "fixture controller only");
        _;
    }

    function deploy(bytes32 salt) external onlyController returns (SIMDTESTToken) {
        return new SIMDTESTToken{salt: salt}(1);
    }

    function registerDistributor(address distributor) external onlyController {
        distributorOf[1] = distributor;
    }

    function guard() external onlyController returns (PoolInitializationGuard) {
        return new PoolInitializationGuard(address(manager));
    }

    function initialize(PoolKey calldata key, uint160 price) external onlyController {
        manager.initialize(key, price);
    }

    function move(SIMDTESTToken token, address to, uint256 amount) external onlyController {
        require(token.transfer(to, amount));
    }

    function seed(LaunchLiquidity.Seed calldata seed_) external onlyController {
        manager.unlock(abi.encode(seed_));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        LaunchLiquidity.settleSeed(manager, data);
        return "";
    }
}

/// @dev A local direct-settlement trader; buy output is intentionally checked NET of token fees.
contract TraderFixture is IUnlockCallback {
    IPoolManager private immutable manager;
    PoolKey private key;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function claimDividends(SIMDTESTToken token) external returns (uint256) {
        return token.claim();
    }

    function swap(PoolKey calldata key_, bool zeroForOne, int256 amount, bool skipPayment)
        external
        returns (BalanceDelta)
    {
        key = key_;
        return abi.decode(manager.unlock(abi.encode(zeroForOne, amount, skipPayment)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (bool zeroForOne, int256 amount, bool skipPayment) = abi.decode(data, (bool, int256, bool));
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        BalanceDelta delta = manager.swap(key, SwapParams(zeroForOne, amount, limit), "");
        if (!skipPayment || delta.amount0() > 0) LaunchLiquidity.settle(manager, key.currency0, delta.amount0());
        if (!skipPayment || delta.amount1() > 0) LaunchLiquidity.settle(manager, key.currency1, delta.amount1());
        return abi.encode(delta);
    }
}

/// @dev Settles swaps entirely as ERC-6909 claims except for the initial IMD payment.
contract ClaimsTraderFixture is IUnlockCallback {
    IPoolManager private immutable manager;
    PoolKey private key;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey calldata key_, bool buy, uint256 amount) external returns (BalanceDelta) {
        key = key_;
        return abi.decode(manager.unlock(abi.encode(buy, amount)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (bool buy, uint256 amount) = abi.decode(data, (bool, uint256));
        BalanceDelta delta = manager.swap(
            key, SwapParams(!buy, -int256(amount), buy ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1), ""
        );
        if (buy) {
            manager.mint(address(this), key.currency0.toId(), uint128(delta.amount0()));
            LaunchLiquidity.settle(manager, key.currency1, delta.amount1());
        } else {
            manager.burn(address(this), key.currency0.toId(), uint128(-delta.amount0()));
            manager.mint(address(this), key.currency1.toId(), uint128(delta.amount1()));
        }
        return abi.encode(delta);
    }
}

contract UniswapV4Test is Test {
    using TransientStateLibrary for IPoolManager;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    address internal constant MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    // Test-only hook placement with exactly the BEFORE_INITIALIZE address flag.
    address internal constant GUARD = address(0x2000);
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant POOL_BUDGET = 900_000_000 ether;
    uint256 internal constant OPENING_CAP = 2500 ether;

    IPoolManager internal manager;
    FactoryFixture internal factory;
    PairFixture internal pair;
    SIMDTESTToken internal token;
    TraderFixture internal trader;
    PoolKey internal key;
    address internal distributor = makeAddr("external Merkle distributor");

    function setUp() public {
        vm.chainId(1);
        // Execute the real constructor at the specified address so NoDelegateCall's immutable
        // original address is correct. Merely copying an existing manager runtime would fail.
        vm.etch(MANAGER, abi.encodePacked(type(PoolManager).creationCode, abi.encode(address(this))));
        (bool ok, bytes memory runtime) = MANAGER.call("");
        require(ok && runtime.length > 0, "manager construction failed");
        vm.etch(MANAGER, runtime);
        manager = IPoolManager(MANAGER);
        factory = new FactoryFixture(manager);
        vm.etch(IMD, address(new PairFixture()).code);
        pair = PairFixture(IMD);
        vm.etch(GUARD, address(factory.guard()).code);
        assertTrue(HookFlags.matches(GUARD, HookFlags.BEFORE_INITIALIZE));
    }

    function testSeedBuyAndSellWithTokenAsCurrency0() public {
        _launch(true);
        _roundTrip(true);
    }

    function testSeedBuyAndSellWithTokenAsCurrency1() public {
        _launch(false);
        _roundTrip(false);
    }

    function testExactOutputBuyIsGrossAndBuyerReceives97Percent() public {
        _launch(true);
        BalanceDelta delta = trader.swap(key, false, int256(1_000 ether), false);
        assertEq(delta.amount0(), int128(1_000 ether));
        assertEq(token.balanceOf(address(trader)), 970 ether);
        assertEq(token.balanceOf(address(token)), 30 ether);
        _assertSettled();
    }

    function testERC6909RoundTripDoesNotTriggerAnERC20TransferFee() public {
        _launch(true);
        ClaimsTraderFixture claimsTrader = new ClaimsTraderFixture(manager);
        pair.mint(address(claimsTrader), 10 ether);
        uint256 poolBefore = token.balanceOf(MANAGER);
        BalanceDelta buy = claimsTrader.swap(key, true, 10 ether);
        uint256 bought = uint128(buy.amount0());
        assertGt(bought, 0);
        assertEq(manager.balanceOf(address(claimsTrader), key.currency0.toId()), bought);
        assertEq(token.balanceOf(MANAGER), poolBefore);
        assertEq(token.balanceOf(address(claimsTrader)), 0);
        assertEq(token.totalFeesCollected(), 0);
        assertEq(manager.currencyDelta(address(claimsTrader), key.currency0), 0);
        assertEq(manager.currencyDelta(address(claimsTrader), key.currency1), 0);
        _assertSettled();

        BalanceDelta sell = claimsTrader.swap(key, false, bought);
        assertEq(manager.balanceOf(address(claimsTrader), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(claimsTrader), key.currency1.toId()), uint128(sell.amount1()));
        assertGt(sell.amount1(), 0);
        assertLt(sell.amount1(), int128(10 ether));
        assertEq(token.balanceOf(MANAGER), poolBefore);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.totalFeesCollected(), 0);
        assertEq(token.claimableDividends(address(claimsTrader)), 0);
        assertEq(manager.currencyDelta(address(claimsTrader), key.currency0), 0);
        assertEq(manager.currencyDelta(address(claimsTrader), key.currency1), 0);
        _assertSettled();
    }

    function testUnpaidSwapRevertsWithCurrencyNotSettledAndRollsBackFee() public {
        _launch(true);
        uint256 beforePool = token.balanceOf(MANAGER);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        trader.swap(key, false, -int256(0.01 ether), true);
        assertEq(token.balanceOf(MANAGER), beforePool);
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.totalFeesCollected(), 0);
        _assertSettled();
    }

    function testSeveralRealBuysFundClaimableSwarmHolderDividends() public {
        _launch(true);
        address holder = makeAddr("swarm beneficiary");
        vm.prank(distributor);
        token.transfer(holder, 100_000_000 ether);
        for (uint256 i; i < 3; ++i) {
            trader.swap(key, false, -int256(0.01 ether), false);
            _assertSettled();
        }
        uint256 due = token.claimableDividends(holder);
        assertGt(due, 0);
        uint256 beforeReserve = token.balanceOf(address(token));
        vm.prank(holder);
        assertEq(token.claim(), due);
        assertEq(token.balanceOf(holder), 100_000_000 ether + due);
        assertEq(token.balanceOf(address(token)), beforeReserve - due);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testOnlyManagerAndFactoryCanInvokeInitializationGuard() public {
        PoolKey memory emptyKey;
        vm.expectRevert(PoolInitializationGuard.UnauthorizedInitialization.selector);
        PoolInitializationGuard(GUARD).beforeInitialize(address(factory), emptyKey, 1 << 96);
        vm.prank(MANAGER);
        vm.expectRevert(PoolInitializationGuard.UnauthorizedInitialization.selector);
        PoolInitializationGuard(GUARD).beforeInitialize(address(this), emptyKey, 1 << 96);
        vm.prank(MANAGER);
        assertEq(
            PoolInitializationGuard(GUARD).beforeInitialize(address(factory), emptyKey, 1 << 96),
            IHooks.beforeInitialize.selector
        );
        vm.expectRevert(PoolInitializationGuard.InvalidPoolManager.selector);
        new PoolInitializationGuard(address(0));
    }

    function testUnlockCallbacksRejectArbitraryCallers() public {
        trader = new TraderFixture(manager);
        vm.expectRevert("manager only");
        trader.unlockCallback("");
        vm.expectRevert("manager only");
        factory.unlockCallback("");
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzzMultipleTradersBuyClaimAndSellInBothCurrencyOrders(
        bool tokenIsZero,
        uint96 firstRaw,
        uint96 secondRaw,
        uint8 roundsRaw
    ) public {
        _launch(tokenIsZero);
        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 3000, "mandatory launch pool fee");
        assertEq(key.tickSpacing, 60);
        assertEq(Currency.unwrap(tokenIsZero ? key.currency1 : key.currency0), IMD);

        TraderFixture other = new TraderFixture(manager);
        pair.mint(address(other), 10 ether);
        uint256 firstAmount = bound(firstRaw, 1e12, 0.1 ether);
        uint256 secondAmount = bound(secondRaw, 1e12, 0.1 ether);
        uint256 rounds = bound(roundsRaw, 1, 4);
        uint256 collected;
        for (uint256 i; i < rounds; ++i) {
            collected += _buyAndCheck(trader, tokenIsZero, firstAmount);
            collected += _buyAndCheck(other, tokenIsZero, secondAmount);
            _claimTraderDividends(trader);
            _claimTraderDividends(other);
        }
        assertEq(token.totalFeesCollected(), collected);
        assertGt(token.totalDividendsClaimed(), 0, "second buy must reward the first trader");
        _sellAllAndCheck(trader, tokenIsZero);
        _sellAllAndCheck(other, tokenIsZero);
        assertEq(token.totalFeesCollected(), collected, "sell settlement charged a token fee");
        assertEq(token.totalSupply(), SUPPLY);
        uint256 accounted = token.balanceOf(MANAGER) + token.balanceOf(distributor)
            + token.balanceOf(token.BURN_ADDRESS()) + token.balanceOf(address(token));
        assertEq(accounted, SUPPLY, "round trip lost or minted token units");
        assertEq(token.claimableDividends(MANAGER), 0);
        assertEq(token.claimableDividends(address(token)), 0);
    }

    function testUnpaidBuyRestoresExistingRewardsWithTokenAsCurrency0() public {
        _failedBuyRestoresExistingRewards(true);
    }

    function testUnpaidBuyRestoresExistingRewardsWithTokenAsCurrency1() public {
        _failedBuyRestoresExistingRewards(false);
    }

    function testIncomingPairShortfallRevertsAndRollsBackTokenPayout() public {
        // Taking currency0 happens before paying currency1: the failure must revert the
        // already executed token payout, fee accrual and all holder checkpoints as well.
        _launch(true);
        trader.swap(key, false, -int256(0.01 ether), false);
        bytes32 beforeState = _swapStateDigest();
        vm.etch(IMD, address(new ShortPaymentPairFixture()).code);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchLiquidity.SettlementShortfall.selector, uint256(0.01 ether), uint256(0.01 ether - 1)
            )
        );
        trader.swap(key, false, -int256(0.01 ether), false);
        assertEq(_swapStateDigest(), beforeState);
        _assertSettled();
    }

    function testZeroSwapAndLockedTakeCannotMovePoolFunds() public {
        _launch(true);
        bytes32 beforeState = _swapStateDigest();
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        trader.swap(key, false, 0, false);
        assertEq(_swapStateDigest(), beforeState);
        vm.expectRevert(IPoolManager.ManagerLocked.selector);
        manager.take(Currency.wrap(address(token)), address(this), 1 ether);
        assertEq(_swapStateDigest(), beforeState);
        _assertSettled();
    }

    function _buyAndCheck(TraderFixture buyer, bool tokenIsZero, uint256 input) private returns (uint256 fee) {
        uint256 poolBefore = token.balanceOf(MANAGER);
        uint256 beforeBalance = token.balanceOf(address(buyer));
        uint256 beforeDue = token.claimableDividends(address(buyer));
        uint256 eligible = token.eligibleSupply();
        uint256 pairedBefore = pair.balanceOf(address(buyer));
        BalanceDelta delta = buyer.swap(key, !tokenIsZero, -int256(input), false);
        int128 output = tokenIsZero ? delta.amount0() : delta.amount1();
        int128 consumed = tokenIsZero ? delta.amount1() : delta.amount0();
        assertGt(output, 0);
        assertEq(int256(consumed), -int256(input));
        uint256 gross = uint128(output);
        fee = gross * 3 / 100;
        assertEq(token.balanceOf(address(buyer)), beforeBalance + gross - fee);
        assertEq(poolBefore - token.balanceOf(MANAGER), gross);
        assertEq(pairedBefore - pair.balanceOf(address(buyer)), input);
        assertApproxEqAbs(token.claimableDividends(address(buyer)), beforeDue + fee * beforeBalance / eligible, 1);
        _assertActorSettled(address(buyer));
    }

    function _claimTraderDividends(TraderFixture holder) private {
        uint256 due = token.claimableDividends(address(holder));
        if (due == 0) return;
        uint256 balance = token.balanceOf(address(holder));
        uint256 reserve = token.balanceOf(address(token));
        assertEq(holder.claimDividends(token), due);
        assertEq(token.balanceOf(address(holder)), balance + due);
        assertEq(token.balanceOf(address(token)), reserve - due);
        assertEq(token.claimableDividends(address(holder)), 0);
    }

    function _sellAllAndCheck(TraderFixture seller, bool tokenIsZero) private {
        uint256 amount = token.balanceOf(address(seller));
        uint256 poolBefore = token.balanceOf(MANAGER);
        uint256 pairedBefore = pair.balanceOf(address(seller));
        uint256 feesBefore = token.totalFeesCollected();
        BalanceDelta delta = seller.swap(key, tokenIsZero, -int256(amount), false);
        int128 input = tokenIsZero ? delta.amount0() : delta.amount1();
        int128 output = tokenIsZero ? delta.amount1() : delta.amount0();
        assertEq(int256(input), -int256(amount));
        assertGt(output, 0);
        assertEq(token.balanceOf(address(seller)), 0);
        assertEq(token.balanceOf(MANAGER) - poolBefore, amount);
        assertEq(pair.balanceOf(address(seller)) - pairedBefore, uint128(output));
        assertEq(token.totalFeesCollected(), feesBefore);
        _assertActorSettled(address(seller));
    }

    function _failedBuyRestoresExistingRewards(bool tokenIsZero) private {
        _launch(tokenIsZero);
        _buyAndCheck(trader, tokenIsZero, 0.01 ether);
        bytes32 beforeState = _swapStateDigest();
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        trader.swap(key, !tokenIsZero, -int256(0.02 ether), true);
        assertEq(_swapStateDigest(), beforeState, "unpaid swap changed balances, rewards or pool state");
        _assertSettled();
        // A valid trade must still work after the failed unlock.
        _buyAndCheck(trader, tokenIsZero, 0.02 ether);
    }

    function _swapStateDigest() private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(key.toId());
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(key.toId());
        bytes32 poolState = keccak256(abi.encode(price, tick, protocolFee, lpFee, growth0, growth1));
        bytes32 rewards = keccak256(
            abi.encode(
                token.eligibleSupply(),
                token.dividendsPerToken(),
                token.pendingDividends(),
                token.totalFeesCollected(),
                token.totalDividendsClaimed(),
                token.claimableDividends(distributor),
                token.claimableDividends(address(trader))
            )
        );
        return keccak256(
            abi.encode(
                poolState,
                rewards,
                token.balanceOf(MANAGER),
                token.balanceOf(address(trader)),
                token.balanceOf(address(token)),
                pair.balanceOf(MANAGER),
                pair.balanceOf(address(trader))
            )
        );
    }

    function _assertActorSettled(address actor) private view {
        _assertSettled();
        assertEq(manager.currencyDelta(actor, key.currency0), 0);
        assertEq(manager.currencyDelta(actor, key.currency1), 0);
        assertEq(manager.currencyDelta(address(factory), key.currency0), 0);
        assertEq(manager.currencyDelta(address(factory), key.currency1), 0);
    }

    function _launch(bool tokenIsZero) private {
        bytes32 codeHash = keccak256(abi.encodePacked(type(SIMDTESTToken).creationCode, abi.encode(uint64(1))));
        // Choose a real CREATE2 deployment in each currency order; never etch the token.
        for (uint256 i; i < 1000; ++i) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, codeHash)))));
            if ((predicted < IMD) == tokenIsZero) {
                token = factory.deploy(salt);
                break;
            }
        }
        require(address(token) != address(0), "CREATE2 search exhausted");
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        factory.registerDistributor(distributor);
        factory.move(token, distributor, SUPPLY / 10);
        (Currency c0, Currency c1) = tokenIsZero
            ? (Currency.wrap(address(token)), Currency.wrap(IMD))
            : (Currency.wrap(IMD), Currency.wrap(address(token)));
        key = PoolKey(c0, c1, 3000, 60, IHooks(GUARD));

        // Derive price from the economics, respecting the deployed currency order.
        uint256 ratioX192 = tokenIsZero
            ? FullMath.mulDiv(OPENING_CAP, 1 << 192, SUPPLY)
            : FullMath.mulDiv(SUPPLY, 1 << 192, OPENING_CAP);
        uint160 price = uint160(_sqrt(ratioX192));
        if (tokenIsZero) assertEq(price, 125270724187523965593206900);
        factory.initialize(key, price);
        (int24 lower, int24 upper, uint128 liquidity) = _singleSidedRange(price, tokenIsZero);
        factory.seed(LaunchLiquidity.Seed(key, lower, upper, liquidity));

        uint256 seeded = token.balanceOf(MANAGER);
        assertGt(seeded, 0);
        assertLe(seeded, POOL_BUDGET);
        assertEq(pair.balanceOf(address(factory)), 0);
        assertEq(pair.balanceOf(MANAGER), 0);
        assertEq(token.totalFeesCollected(), 0);
        assertEq(token.balanceOf(distributor), 100_000_000 ether);
        assertEq(token.eligibleSupply(), 0);
        assertTrue(token.isExcludedFromDividends(distributor));
        uint256 remainder = token.balanceOf(address(factory));
        assertEq(remainder, POOL_BUDGET - seeded);
        factory.move(token, token.BURN_ADDRESS(), remainder);
        assertEq(token.balanceOf(address(factory)), 0);

        trader = new TraderFixture(manager);
        pair.mint(address(trader), 10 ether);
        _assertSettled();
    }

    function _roundTrip(bool tokenIsZero) private {
        uint256 poolBefore = token.balanceOf(MANAGER);
        BalanceDelta buy = trader.swap(key, !tokenIsZero, -int256(0.01 ether), false);
        int128 output = tokenIsZero ? buy.amount0() : buy.amount1();
        assertGt(output, 0);
        uint256 gross = uint128(output);
        uint256 fee = gross * 3 / 100;
        uint256 bought = token.balanceOf(address(trader));
        assertEq(bought, gross - fee);
        assertEq(poolBefore - token.balanceOf(MANAGER), gross);
        assertEq(token.balanceOf(address(token)), fee);
        _assertSettled();
        uint256 beforeSell = token.balanceOf(MANAGER);
        uint256 pairedBeforeSell = pair.balanceOf(address(trader));
        trader.swap(key, tokenIsZero, -int256(bought), false);
        assertEq(token.balanceOf(address(trader)), 0);
        assertEq(token.balanceOf(MANAGER) - beforeSell, bought);
        assertEq(token.totalFeesCollected(), fee);
        assertGt(pair.balanceOf(address(trader)), pairedBeforeSell);
        _assertSettled();
    }

    function _assertSettled() private view {
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertFalse(manager.isUnlocked());
        assertEq(manager.currencyDelta(address(trader), key.currency0), 0);
        assertEq(manager.currencyDelta(address(trader), key.currency1), 0);
    }

    function _singleSidedRange(uint160 price, bool tokenIsZero)
        private
        pure
        returns (int24 lower, int24 upper, uint128 liquidity)
    {
        int24 tick = TickMath.getTickAtSqrtPrice(price);
        if (tokenIsZero) {
            lower = (tick / 60) * 60;
            if (TickMath.getSqrtPriceAtTick(lower) < price) lower += 60;
            upper = TickMath.maxUsableTick(60);
        } else {
            lower = TickMath.minUsableTick(60);
            upper = (tick / 60) * 60;
            if (TickMath.getSqrtPriceAtTick(upper) > price) upper -= 60;
        }
        uint160 a = TickMath.getSqrtPriceAtTick(lower);
        uint160 b = TickMath.getSqrtPriceAtTick(upper);
        uint256 value = tokenIsZero
            ? FullMath.mulDiv(POOL_BUDGET, FullMath.mulDiv(a, b, 1 << 96), b - a)
            : FullMath.mulDiv(POOL_BUDGET, 1 << 96, b - a);
        require(value <= type(uint128).max);
        liquidity = uint128(value);
    }

    function _sqrt(uint256 value) private pure returns (uint256 result) {
        result = value;
        uint256 next = value / 2 + 1;
        while (next < result) {
            result = next;
            next = (value / next + next) / 2;
        }
    }
}
