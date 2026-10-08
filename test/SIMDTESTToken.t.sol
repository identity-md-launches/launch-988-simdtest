// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SIMDTESTToken} from "../src/SIMDTESTToken.sol";

contract SIMDTESTTokenTest is Test {
    SIMDTESTToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal distributor = makeAddr("external swarm distributor");
    address internal manager;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        vm.chainId(1);
        token = new SIMDTESTToken(1);
        manager = token.POOL_MANAGER();
    }

    function distributorOf(uint64 launchNumber) external view returns (address) {
        require(launchNumber == 1, "wrong launch number");
        return distributor;
    }

    function testConstructorMintsOnlyToDeployer() public view {
        assertEq(token.name(), "SIMDTEST");
        assertEq(token.symbol(), "SIMDTEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(manager), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.eligibleSupply(), 0);
        assertEq(token.FACTORY(), address(this));
        assertEq(token.LAUNCH_NUMBER(), 1);
        assertTrue(token.isExcludedFromDividends(address(this)));
    }

    function testExternalFactoryAllocationAndSwarmClaimArriveWhole() public {
        token.transfer(distributor, SUPPLY / 10);
        token.transfer(manager, SUPPLY * 9 / 10);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(distributor), 100_000_000 ether);
        assertEq(token.balanceOf(manager), 900_000_000 ether);
        assertEq(token.eligibleSupply(), 0);
        assertEq(token.dividendDistributor(), distributor);
        vm.prank(distributor);
        token.transfer(alice, 100_000_000 ether);
        assertEq(token.balanceOf(alice), 100_000_000 ether);
        assertEq(token.eligibleSupply(), 100_000_000 ether);
        assertEq(token.totalFeesCollected(), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testBuyFeesAreNotStrandedOnTheMerkleDistributor() public {
        token.transfer(distributor, 100_000_000 ether);
        token.transfer(manager, 900_000_000 ether);
        vm.prank(manager);
        token.transfer(alice, 10_000_000 ether);
        vm.prank(manager);
        token.transfer(bob, 10_000_000 ether);

        assertEq(token.totalFeesCollected(), 600_000 ether);
        assertEq(token.balanceOf(address(token)), 600_000 ether);
        assertEq(token.claimableDividends(distributor), 0);
        assertEq(token.claimableDividends(address(this)), 0);
        assertApproxEqAbs(
            token.claimableDividends(alice) + token.claimableDividends(bob) + token.pendingDividends(), 600_000 ether, 1
        );
        vm.prank(distributor);
        vm.expectRevert(SIMDTESTToken.NoDividends.selector);
        token.claim();
        _claimAndCheck(alice);
        assertLe(token.balanceOf(address(token)), 1);
    }

    function testSwarmBeneficiaryEarnsOnlyAfterMerkleTransfer() public {
        token.transfer(distributor, 100_000_000 ether);
        token.transfer(manager, 900_000_000 ether);
        vm.prank(manager);
        token.transfer(alice, 1_000 ether);
        uint256 alicePast = token.claimableDividends(alice);
        vm.prank(distributor);
        token.transfer(bob, 20_000_000 ether);
        assertEq(token.balanceOf(distributor), 80_000_000 ether);
        assertEq(token.balanceOf(bob), 20_000_000 ether);
        assertEq(token.claimableDividends(distributor), 0);
        assertEq(token.claimableDividends(bob), 0);
        assertEq(token.claimableDividends(alice), alicePast);
        uint256 eligible = token.eligibleSupply();
        assertEq(eligible, 20_000_000 ether + 970 ether);
        vm.prank(manager);
        token.transfer(carol, 1_000 ether);
        assertApproxEqAbs(token.claimableDividends(bob), 30 ether * 20_000_000 ether / eligible, 1);
        assertEq(token.claimableDividends(distributor), 0);
        _claimAndCheck(bob);
    }

    function testLateRegistrationRemovesPriorBalanceBeforeAnyFee() public {
        address actualDistributor = distributor;
        distributor = address(0); // Test the factory's not-yet-registered state.
        token.transfer(actualDistributor, 100_000_000 ether);
        token.transfer(manager, 900_000_000 ether);
        assertEq(token.eligibleSupply(), 100_000_000 ether);
        vm.prank(manager);
        vm.expectRevert(SIMDTESTToken.DistributorNotRegistered.selector);
        token.transfer(alice, 1_000 ether);
        assertEq(token.totalFeesCollected(), 0);
        assertEq(token.balanceOf(manager), 900_000_000 ether);

        distributor = actualDistributor;
        vm.prank(manager);
        token.transfer(alice, 1_000 ether);
        assertEq(token.dividendDistributor(), actualDistributor);
        assertEq(token.eligibleSupply(), 970 ether);
        assertEq(token.claimableDividends(actualDistributor), 0);
        assertApproxEqAbs(token.claimableDividends(alice), 30 ether, 1);
    }

    function testCachedDistributorCannotBeChangedByFactory() public {
        address actualDistributor = distributor;
        token.transfer(distributor, 100_000_000 ether);
        token.transfer(manager, 900_000_000 ether);
        distributor = alice;
        // No more lookups, even if the factory later reverts or disappears.
        vm.mockCallRevert(address(this), abi.encodeWithSelector(this.distributorOf.selector), "unavailable");
        vm.prank(manager);
        token.transfer(alice, 1_000 ether);
        assertEq(token.dividendDistributor(), actualDistributor);
        assertTrue(token.isExcludedFromDividends(actualDistributor));
        assertFalse(token.isExcludedFromDividends(alice));
        assertApproxEqAbs(token.claimableDividends(alice), 30 ether, 1);
        _claimAndCheck(alice);
    }

    function testBuyDeductsThreePercentAndSellDeliversFullAmount() public {
        token.transfer(manager, 900_000_000 ether);
        vm.prank(manager);
        token.transfer(alice, 1_000 ether);
        assertEq(token.balanceOf(alice), 970 ether);
        assertEq(token.balanceOf(address(token)), 30 ether);
        assertEq(token.totalFeesCollected(), 30 ether);
        assertApproxEqAbs(token.claimableDividends(alice), 30 ether, 1);
        uint256 poolBefore = token.balanceOf(manager);
        vm.prank(alice);
        token.transfer(manager, 970 ether);
        assertEq(token.balanceOf(manager) - poolBefore, 970 ether);
        assertEq(token.totalFeesCollected(), 30 ether);
        assertEq(token.balanceOf(alice), 0);
    }

    function testWalletTransfersAndSelfTransfersAreFree() public {
        token.transfer(alice, 100 ether);
        vm.startPrank(alice);
        token.transfer(bob, 70 ether);
        token.transfer(alice, 30 ether);
        token.transfer(bob, 0);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 30 ether);
        assertEq(token.balanceOf(bob), 70 ether);
        assertEq(token.eligibleSupply(), 100 ether);
        assertEq(token.totalFeesCollected(), 0);
    }

    function testManagerSelfTransferIsUntaxed() public {
        token.transfer(manager, 100 ether);
        vm.prank(manager);
        token.transfer(manager, 100 ether);
        assertEq(token.balanceOf(manager), 100 ether);
        assertEq(token.totalFeesCollected(), 0);
        assertEq(token.eligibleSupply(), 0);
    }

    function testSeveralBuysAccrueProportionallyBeforeEachBuy() public {
        _allocateHolders();
        vm.prank(manager);
        token.transfer(carol, 1_000 ether);
        assertApproxEqAbs(token.claimableDividends(alice), 7.5 ether, 1);
        assertApproxEqAbs(token.claimableDividends(bob), 22.5 ether, 1);
        assertEq(token.claimableDividends(carol), 0);

        uint256 eligible = token.eligibleSupply();
        vm.prank(manager);
        token.transfer(carol, 2_000 ether);
        uint256 expectedAlice = 7.5 ether + 60 ether * 25_000_000 ether / eligible;
        uint256 expectedBob = 22.5 ether + 60 ether * 75_000_000 ether / eligible;
        uint256 expectedCarol = 60 ether * 970 ether / eligible;
        assertApproxEqAbs(token.claimableDividends(alice), expectedAlice, 1);
        assertApproxEqAbs(token.claimableDividends(bob), expectedBob, 1);
        assertApproxEqAbs(token.claimableDividends(carol), expectedCarol, 1);
        _claimAndCheck(alice);
        _claimAndCheck(bob);
        _claimAndCheck(carol);
        assertLe(token.balanceOf(address(token)), 3);
        assertEq(token.totalFeesCollected(), 90 ether);
    }

    function testTransferKeepsPastDividendsWithSender() public {
        _allocateHolders();
        vm.prank(manager);
        token.transfer(carol, 1_000 ether);
        uint256 earned = token.claimableDividends(alice);
        address recipient = makeAddr("new holder");
        uint256 held = token.balanceOf(alice);
        vm.prank(alice);
        token.transfer(recipient, held);
        assertEq(token.claimableDividends(recipient), 0);
        assertEq(token.claimableDividends(alice), earned);
        assertEq(token.balanceOf(alice), 0);
        _claimAndCheck(alice);
        assertEq(token.balanceOf(alice), earned);
        assertEq(token.claimableDividends(recipient), 0);
    }

    function testClaimsCompoundOnlyFutureDividends() public {
        _allocateHolders();
        vm.prank(manager);
        token.transfer(carol, 1_000 ether);
        uint256 claimed = _claimAndCheck(alice);
        uint256 eligible = token.eligibleSupply();
        vm.prank(manager);
        token.transfer(carol, 1_000 ether);
        assertApproxEqAbs(token.claimableDividends(alice), 30 ether * (25_000_000 ether + claimed) / eligible, 1);
    }

    function testZeroAndRepeatClaimRevert() public {
        vm.prank(alice);
        vm.expectRevert(SIMDTESTToken.NoDividends.selector);
        token.claim();
        _allocateHolders();
        vm.prank(manager);
        token.transfer(carol, 1_000 ether);
        _claimAndCheck(alice);
        vm.prank(alice);
        vm.expectRevert(SIMDTESTToken.NoDividends.selector);
        token.claim();
    }

    function testExcludedBalancesNeverEarnAndBurnDoesNotChangeSupply() public {
        token.transfer(alice, 10_000 ether);
        token.transfer(token.BURN_ADDRESS(), 20_000 ether);
        token.transfer(address(token), 30_000 ether);
        token.transfer(manager, SUPPLY - 60_000 ether);
        assertEq(token.eligibleSupply(), 10_000 ether);
        vm.prank(manager);
        token.transfer(bob, 1_000 ether);
        assertApproxEqAbs(token.claimableDividends(alice), 30 ether, 1);
        address[5] memory excluded = [manager, address(token), token.BURN_ADDRESS(), distributor, address(this)];
        for (uint256 i; i < excluded.length; ++i) {
            assertTrue(token.isExcludedFromDividends(excluded[i]));
            assertEq(token.claimableDividends(excluded[i]), 0);
            vm.prank(excluded[i]);
            vm.expectRevert(SIMDTESTToken.NoDividends.selector);
            token.claim();
        }
        uint256 fees = token.totalFeesCollected();
        // Test-only impersonation establishes that the burn address has no special fee rule.
        vm.prank(token.BURN_ADDRESS());
        token.transfer(bob, 1 ether);
        assertEq(token.totalFeesCollected(), fees);
        assertEq(token.claimableDividends(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFeesQueueWhileNoEligibleSupply() public {
        token.transfer(manager, SUPPLY);
        assertEq(token.eligibleSupply(), 0);
        address burn = token.BURN_ADDRESS();
        vm.prank(manager);
        token.transfer(burn, 1_000 ether);
        assertEq(token.pendingDividends(), 30 ether);
        assertEq(token.dividendsPerToken(), 0);
        vm.prank(manager);
        token.transfer(alice, 1_000 ether);
        assertEq(token.pendingDividends(), 0);
        assertEq(token.balanceOf(alice), 970 ether);
        assertApproxEqAbs(token.claimableDividends(alice), 60 ether, 1);
        _claimAndCheck(alice);
    }

    function testPoolWithdrawalToTokenContractRemainsSolvent() public {
        _allocateHolders();
        vm.prank(manager);
        token.transfer(address(token), 1_000 ether);
        assertEq(token.balanceOf(address(token)), 1_000 ether);
        assertEq(token.totalFeesCollected(), 30 ether);
        assertEq(token.eligibleSupply(), 100_000_000 ether);
        _claimAndCheck(alice);
        _claimAndCheck(bob);
        assertGe(token.balanceOf(address(token)), 970 ether);
    }

    function testFormerHolderClaimReleasesZeroSupplyQueue() public {
        token.transfer(alice, 100_000_000 ether);
        token.transfer(manager, 900_000_000 ether);
        address burn = token.BURN_ADDRESS();
        vm.prank(manager);
        token.transfer(burn, 1_000 ether);
        uint256 earned = token.claimableDividends(alice);
        vm.prank(alice);
        token.transfer(manager, 100_000_000 ether);
        assertEq(token.eligibleSupply(), 0);
        vm.prank(manager);
        token.transfer(burn, 1_000 ether);
        assertEq(token.pendingDividends(), 30 ether);
        vm.prank(alice);
        assertEq(token.claim(), earned);
        assertEq(token.balanceOf(alice), earned);
        assertEq(token.eligibleSupply(), earned);
        assertEq(token.pendingDividends(), 0);
        assertApproxEqAbs(token.claimableDividends(alice), 30 ether, 1);
        _claimAndCheck(alice);
        assertLe(token.totalDividendsClaimed(), 60 ether);
    }

    function testTinyEligibleSupplyThenLargeBalanceDoesNotOverflow() public {
        token.transfer(alice, 1);
        token.transfer(manager, SUPPLY - 1);
        vm.prank(manager);
        token.transfer(bob, SUPPLY / 2);
        uint256 fee = SUPPLY / 2 * 3 / 100;
        assertEq(token.claimableDividends(alice), fee);
        assertEq(token.claimableDividends(bob), 0);
        uint256 held = token.balanceOf(bob);
        vm.prank(bob);
        token.transfer(alice, held);
        assertEq(_claimAndCheck(alice), fee);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function testFractionalCreditSurvivesRepeatedCheckpoints() public {
        token.transfer(alice, 1);
        token.transfer(bob, 2);
        token.transfer(manager, SUPPLY - 3);
        address burn = token.BURN_ADDRESS();
        for (uint256 i; i < 4; ++i) {
            vm.prank(manager);
            token.transfer(burn, 34);
            vm.prank(alice);
            token.transfer(alice, 0);
            vm.prank(bob);
            token.transfer(bob, 0);
        }
        assertEq(token.claimableDividends(alice), 1);
        assertEq(token.claimableDividends(bob), 2);
        _claimAndCheck(alice);
        _claimAndCheck(bob);
        assertEq(token.totalFeesCollected(), 4);
    }

    function testAllowanceAndDelegatedBuyUseGrossAmount() public {
        token.transfer(manager, 1_000 ether);
        vm.prank(manager);
        token.approve(bob, 1_000 ether);
        vm.prank(bob);
        token.transferFrom(manager, alice, 1_000 ether);
        assertEq(token.balanceOf(alice), 970 ether);
        assertEq(token.allowance(manager, bob), 0);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(alice, manager, 970 ether);
        assertEq(token.allowance(alice, bob), type(uint256).max);
        assertEq(token.balanceOf(manager), 970 ether);
        assertEq(token.totalFeesCollected(), 30 ether);
    }

    function testInvalidTransfersAndApprovalsRevertAtomically() public {
        vm.expectRevert(abi.encodeWithSelector(SIMDTESTToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(SIMDTESTToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        vm.expectRevert(
            abi.encodeWithSelector(SIMDTESTToken.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(alice, SUPPLY + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SIMDTESTToken.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(alice, bob, 1);
        vm.prank(alice);
        token.approve(bob, 2);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SIMDTESTToken.ERC20InsufficientBalance.selector, alice, 0, 2));
        token.transferFrom(alice, bob, 2);
        assertEq(token.allowance(alice, bob), 2);
        assertEq(token.totalFeesCollected(), 0);
        assertEq(token.eligibleSupply(), 0);
        vm.expectRevert(abi.encodeWithSelector(SIMDTESTToken.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), alice, 0);
    }

    function testNoAdminSelectorsOrMinting() public {
        string[19] memory signatures = [
            "owner()",
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "transferOwnership(address)",
            "setOwner(address)",
            "setMinter(address)",
            "setFee(uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "seize(address)",
            "burnFrom(address,uint256)",
            "initialize(address)",
            "upgradeTo(address)",
            "withdraw()",
            "excludeFromDividends(address)"
        ];
        token.transfer(alice, 100 ether);
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], alice, 100 ether);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(bob);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(alice), 100 ether);
        vm.prank(alice);
        token.transfer(bob, 100 ether);
        assertEq(token.balanceOf(bob), 100 ether);
    }

    function testRuntimeHasNoForbiddenOpcodes() public view {
        bytes memory code = address(token).code;
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }

    function testFuzzBuyFeeConservation(uint256 rawAmount) public {
        token.transfer(manager, SUPPLY * 9 / 10);
        uint256 amount = bound(rawAmount, 0, token.balanceOf(manager));
        uint256 expectedFee = amount * 3 / 100;
        vm.prank(manager);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount - expectedFee);
        assertEq(token.balanceOf(address(token)), expectedFee);
        assertEq(token.balanceOf(manager), SUPPLY * 9 / 10 - amount);
        assertEq(token.eligibleSupply(), amount - expectedFee);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzzWalletTransferConservation(uint256 rawAmount) public {
        token.transfer(alice, SUPPLY);
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        vm.prank(alice);
        token.transfer(bob, amount);
        assertEq(token.balanceOf(alice), SUPPLY - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.eligibleSupply(), SUPPLY);
    }

    function _allocateHolders() internal {
        token.transfer(alice, 25_000_000 ether);
        token.transfer(bob, 75_000_000 ether);
        token.transfer(manager, 900_000_000 ether);
    }

    function _claimAndCheck(address account) internal returns (uint256 due) {
        due = token.claimableDividends(account);
        uint256 beforeBalance = token.balanceOf(account);
        uint256 reserve = token.balanceOf(address(token));
        vm.prank(account);
        assertEq(token.claim(), due);
        assertEq(token.balanceOf(account), beforeBalance + due);
        assertEq(token.balanceOf(address(token)), reserve - due);
        assertEq(token.claimableDividends(account), 0);
    }
}
