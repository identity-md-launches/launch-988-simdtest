// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDTESTToken} from "src/SIMDTESTToken.sol";

contract TokenAdversarialTest is Test {
    SIMDTESTToken internal token;
    address internal alice = makeAddr("adversarial alice");
    address internal bob = makeAddr("adversarial bob");
    address internal spender = makeAddr("adversarial spender");
    address internal newcomer = makeAddr("adversarial newcomer");
    address internal manager;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event DividendClaimed(address indexed account, uint256 amount);

    function setUp() public {
        vm.chainId(1);
        token = new SIMDTESTToken();
        manager = token.POOL_MANAGER();
        token.transfer(alice, 25_000_000 ether);
        token.transfer(bob, 75_000_000 ether);
        token.transfer(manager, 900_000_000 ether);
    }

    function testFeeRoundingBoundariesEmitTheActualTransfers() public {
        uint256[10] memory amounts = [uint256(0), 1, 32, 33, 34, 66, 67, 99, 100, 101];
        uint256 fees;
        uint256 received;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 fee = amounts[i] * 3 / 100;
            if (fee != 0) {
                vm.expectEmit(true, true, false, true, address(token));
                emit Transfer(manager, address(token), fee);
            }
            vm.expectEmit(true, true, false, true, address(token));
            emit Transfer(manager, newcomer, amounts[i] - fee);
            vm.prank(manager);
            assertTrue(token.transfer(newcomer, amounts[i]));
            fees += fee;
            received += amounts[i] - fee;
            assertEq(token.balanceOf(newcomer), received);
            assertEq(token.balanceOf(address(token)), fees);
            assertEq(token.totalFeesCollected(), fees);
        }
        assertEq(token.balanceOf(manager), 900_000_000 ether - fees - received);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzExistingBuyerEarnsOnlyOnPreBuyBalance(uint256 rawAmount, bool delegated) public {
        uint256 amount = bound(rawAmount, 0, token.balanceOf(manager));
        uint256 fee = amount * 3 / 100;
        if (delegated) {
            vm.prank(manager);
            token.approve(spender, amount);
            vm.prank(spender);
            assertTrue(token.transferFrom(manager, alice, amount));
            assertEq(token.allowance(manager, spender), 0);
        } else {
            vm.prank(manager);
            token.transfer(alice, amount);
        }
        assertEq(token.balanceOf(alice), 25_000_000 ether + amount - fee);
        assertApproxEqAbs(token.claimableDividends(alice), fee / 4, 1);
        assertApproxEqAbs(token.claimableDividends(bob), fee * 3 / 4, 1);
        uint256 paid = _claimIfOwed(alice) + _claimIfOwed(bob);
        assertLe(paid, fee);
        // Two beneficiaries, with less than one minor unit of rounding loss apiece.
        assertLe(fee - paid, 2);
        assertEq(token.balanceOf(address(token)), fee - paid);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzClaimOrderCannotRedistributePastRewards(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 100, token.balanceOf(manager));
        vm.prank(manager);
        token.transfer(newcomer, amount);
        uint256 snapshot = vm.snapshotState();
        uint256 aliceFirst = _claimIfOwed(alice);
        uint256 bobSecond = _claimIfOwed(bob);
        uint256 reserve = token.balanceOf(address(token));
        assertTrue(vm.revertToStateAndDelete(snapshot));
        uint256 bobFirst = _claimIfOwed(bob);
        uint256 aliceSecond = _claimIfOwed(alice);
        assertEq(aliceFirst, aliceSecond);
        assertEq(bobFirst, bobSecond);
        assertEq(token.balanceOf(address(token)), reserve);
        assertEq(token.claimableDividends(newcomer), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzDelegatedFullExitRetainsHistoryAndReceiverEarnsOnlyFutureFees(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 100 ether, 400_000_000 ether);
        vm.prank(manager);
        token.transfer(bob, amount);
        uint256 earned = token.claimableDividends(alice);
        uint256 holding = token.balanceOf(alice);
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(alice, newcomer, holding);
        assertEq(token.claimableDividends(alice), earned);
        assertEq(token.claimableDividends(newcomer), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(alice, spender), type(uint256).max);

        uint256 eligible = token.eligibleSupply();
        vm.prank(manager);
        token.transfer(bob, amount);
        assertEq(token.claimableDividends(alice), earned);
        assertApproxEqAbs(token.claimableDividends(newcomer), (amount * 3 / 100) * holding / eligible, 1);
        assertEq(_claimIfOwed(alice), earned);
        assertEq(token.balanceOf(alice), earned);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzOversizedDelegatedBuyRevertsBeforeFeeMathAndPreservesState(uint256 rawAmount) public {
        _primeDividends();
        uint256 available = token.balanceOf(manager);
        uint256 amount = bound(rawAmount, available + 1, type(uint256).max);
        vm.prank(manager);
        token.approve(spender, amount);
        bytes32 beforeState = _stateDigest();
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(SIMDTESTToken.ERC20InsufficientBalance.selector, manager, available, amount)
        );
        token.transferFrom(manager, alice, amount);
        assertEq(_stateDigest(), beforeState, "revert changed accounting or consumed allowance");
        _claimIfOwed(alice);
        _claimIfOwed(bob);
    }

    function testMaximumTransferRevertsWithBalanceErrorInsteadOfArithmeticPanic() public {
        _primeDividends();
        bytes32 beforeState = _stateDigest();
        uint256 available = token.balanceOf(manager);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                SIMDTESTToken.ERC20InsufficientBalance.selector, manager, available, type(uint256).max
            )
        );
        token.transfer(alice, type(uint256).max);
        assertEq(_stateDigest(), beforeState);
    }

    function testInvalidReceiverRollsBackGrossAllowanceAndExistingDividends() public {
        _primeDividends();
        vm.prank(manager);
        token.approve(spender, 1_000 ether);
        bytes32 beforeState = _stateDigest();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(SIMDTESTToken.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(manager, address(0), 1_000 ether);
        assertEq(_stateDigest(), beforeState);
        // The same approval remains usable for a valid buy after the failed call.
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(spender);
        token.transferFrom(manager, alice, 1_000 ether);
        assertEq(token.balanceOf(alice) - beforeBalance, 970 ether);
        assertEq(token.allowance(manager, spender), 0);
    }

    function testNetOnlyApprovalCannotAuthorizeGrossBuyAndRevocationIsImmediate() public {
        _primeDividends();
        vm.prank(manager);
        token.approve(spender, 970 ether);
        bytes32 beforeState = _stateDigest();
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(SIMDTESTToken.ERC20InsufficientAllowance.selector, spender, 970 ether, 1_000 ether)
        );
        token.transferFrom(manager, alice, 1_000 ether);
        assertEq(_stateDigest(), beforeState);
        vm.startPrank(manager);
        token.approve(spender, type(uint256).max);
        token.approve(spender, 0);
        vm.stopPrank();
        beforeState = _stateDigest();
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(SIMDTESTToken.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(manager, alice, 1);
        assertEq(_stateDigest(), beforeState);
    }

    function testAllowanceDoesNotAuthorizeStealingAnotherHoldersDividend() public {
        _primeDividends();
        vm.prank(alice);
        token.approve(spender, type(uint256).max);
        uint256 earned = token.claimableDividends(alice);
        assertGt(earned, 0);
        bytes32 beforeState = _stateDigest();
        vm.prank(spender);
        vm.expectRevert(SIMDTESTToken.NoDividends.selector);
        token.claim();
        vm.prank(spender);
        (bool ok,) = address(token).call(abi.encodeWithSignature("claim(address)", alice));
        assertFalse(ok);
        assertEq(_stateDigest(), beforeState);
        assertEq(_claimIfOwed(alice), earned);
        assertEq(token.balanceOf(spender), 0);
    }

    function testNoAdminCallerCanRedirectFeeReserveOrChangeExclusions() public {
        _primeDividends();
        bytes[] memory calls = new bytes[](12);
        calls[0] = abi.encodeWithSignature("setBuyFee(uint256)", 0);
        calls[1] = abi.encodeWithSignature("setPoolManager(address)", spender);
        calls[2] = abi.encodeWithSignature("setDividendExcluded(address,bool)", alice, true);
        calls[3] = abi.encodeWithSignature("setBlacklist(address,bool)", alice, true);
        calls[4] = abi.encodeWithSignature("setTransfersEnabled(bool)", false);
        calls[5] = abi.encodeWithSignature("rescueTokens(address,address,uint256)", address(token), spender, 30 ether);
        calls[6] = abi.encodeWithSignature("withdrawDividends(address)", spender);
        calls[7] = abi.encodeWithSignature("claimFor(address)", alice);
        calls[8] = abi.encodeWithSignature("mint(address,uint256)", spender, SUPPLY);
        calls[9] = abi.encodeWithSignature("burnFrom(address,uint256)", alice, 1 ether);
        calls[10] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", spender, bytes(""));
        calls[11] = abi.encodeWithSignature("grantRole(bytes32,address)", bytes32(0), spender);
        address[4] memory callers = [address(this), manager, alice, spender];
        bytes32 beforeState = _stateDigest();
        for (uint256 i; i < callers.length; ++i) {
            for (uint256 j; j < calls.length; ++j) {
                vm.prank(callers[i]);
                (bool ok,) = address(token).call(calls[j]);
                assertFalse(ok, "unexpected privileged selector accepted");
                assertEq(_stateDigest(), beforeState);
            }
        }
        uint256 earned = token.claimableDividends(alice);
        uint256 holding = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(newcomer, holding);
        assertEq(_claimIfOwed(alice), earned);
    }

    function _primeDividends() private {
        vm.prank(manager);
        token.transfer(newcomer, 1_000 ether);
    }

    function _claimIfOwed(address account) private returns (uint256 due) {
        due = token.claimableDividends(account);
        if (due == 0) return 0;
        uint256 held = token.balanceOf(account);
        uint256 reserve = token.balanceOf(address(token));
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(token), account, due);
        vm.expectEmit(true, false, false, true, address(token));
        emit DividendClaimed(account, due);
        vm.prank(account);
        assertEq(token.claim(), due);
        assertEq(token.balanceOf(account), held + due);
        assertEq(token.balanceOf(address(token)), reserve - due);
        assertEq(token.claimableDividends(account), 0);
    }

    function _stateDigest() private view returns (bytes32 digest) {
        digest = keccak256(
            abi.encode(
                token.totalSupply(),
                token.eligibleSupply(),
                token.dividendsPerToken(),
                token.pendingDividends(),
                token.totalFeesCollected(),
                token.totalDividendsClaimed(),
                token.BUY_FEE_BPS(),
                token.POOL_MANAGER()
            )
        );
        address[8] memory accounts =
            [address(this), manager, alice, bob, newcomer, spender, address(token), token.BURN_ADDRESS()];
        for (uint256 i; i < accounts.length; ++i) {
            digest = keccak256(
                abi.encode(
                    digest,
                    token.balanceOf(accounts[i]),
                    token.claimableDividends(accounts[i]),
                    token.allowance(accounts[i], spender),
                    token.isExcludedFromDividends(accounts[i])
                )
            );
        }
    }
}
