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

/// @dev Test-only stand-in for the external launch factory, not a manifest application.
contract FactoryFixture is IUnlockCallback {
    address private immutable controller = msg.sender;
    IPoolManager private immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    modifier onlyController() {
        require(msg.sender == controller, "fixture controller only");
        _;
    }

    function deploy(bytes32 salt) external onlyController returns (SIMDTESTToken) {
        return new SIMDTESTToken{salt: salt}();
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

contract UniswapV4Test is Test {
    using TransientStateLibrary for IPoolManager;

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

    function _launch(bool tokenIsZero) private {
        bytes32 codeHash = keccak256(type(SIMDTESTToken).creationCode);
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
