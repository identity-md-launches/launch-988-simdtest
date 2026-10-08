// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SIMDTESTToken} from "../src/SIMDTESTToken.sol";

contract DividendHandler is Test {
    SIMDTESTToken public token;
    address[4] public holders;
    address public manager;
    address public burn;
    uint256 public observedFees;
    uint256 public observedClaims;
    uint256 public donations;

    function initialize() external {
        require(address(token) == address(0), "already initialized");
        token = new SIMDTESTToken(1);
        manager = token.POOL_MANAGER();
        burn = token.BURN_ADDRESS();
        for (uint256 i; i < holders.length; ++i) {
            holders[i] = address(uint160(0x10000 + i));
            token.transfer(holders[i], 25_000_000 ether);
        }
        token.transfer(manager, 900_000_000 ether);
    }

    function distributorOf(uint64) external pure returns (address) {
        return address(0xD157); // Test-only external distributor, initially empty.
    }

    function buy(uint256 recipientSeed, uint256 amountSeed) external {
        address recipient = _recipient(recipientSeed);
        uint256 amount = bound(amountSeed, 0, token.balanceOf(manager));
        uint256 fee = recipient == manager ? 0 : amount * 3 / 100;
        uint256 beforeBalance = token.balanceOf(recipient);
        vm.prank(manager);
        token.transfer(recipient, amount);
        observedFees += fee;
        if (recipient == address(token)) {
            donations += amount - fee;
            assertEq(token.balanceOf(recipient), beforeBalance + amount);
        } else if (recipient == manager) {
            assertEq(token.balanceOf(recipient), beforeBalance);
        } else {
            assertEq(token.balanceOf(recipient), beforeBalance + amount - fee);
        }
    }

    function move(uint256 senderSeed, uint256 recipientSeed, uint256 amountSeed) external {
        address sender = holders[senderSeed % holders.length];
        address recipient = _recipient(recipientSeed);
        uint256 amount = bound(amountSeed, 0, token.balanceOf(sender));
        uint256 pastSender = token.claimableDividends(sender);
        uint256 pastRecipient = token.claimableDividends(recipient);
        uint256 beforeRecipient = token.balanceOf(recipient);
        vm.prank(sender);
        token.transfer(recipient, amount);
        if (recipient == address(token)) donations += amount;
        assertEq(token.claimableDividends(sender), pastSender);
        assertEq(token.claimableDividends(recipient), pastRecipient);
        assertEq(token.balanceOf(recipient), beforeRecipient + (sender == recipient ? 0 : amount));
    }

    function delegatedMove(uint256 senderSeed, uint256 recipientSeed, uint256 amountSeed) external {
        address sender = holders[senderSeed % holders.length];
        address recipient = _recipient(recipientSeed);
        uint256 amount = bound(amountSeed, 0, token.balanceOf(sender));
        vm.prank(sender);
        token.approve(address(this), amount);
        token.transferFrom(sender, recipient, amount);
        if (recipient == address(token)) donations += amount;
        assertEq(token.allowance(sender, address(this)), 0);
    }

    function claim(uint256 holderSeed) external {
        address holder = holders[holderSeed % holders.length];
        uint256 owed = token.claimableDividends(holder);
        if (owed == 0) {
            vm.prank(holder);
            vm.expectRevert(SIMDTESTToken.NoDividends.selector);
            token.claim();
        } else {
            uint256 beforeBalance = token.balanceOf(holder);
            uint256 queued = token.pendingDividends();
            vm.prank(holder);
            uint256 paid = token.claim();
            observedClaims += paid;
            assertEq(paid, owed);
            assertEq(token.balanceOf(holder), beforeBalance + owed);
            if (queued == 0) assertEq(token.claimableDividends(holder), 0);
            else assertApproxEqAbs(token.claimableDividends(holder), queued, 1);
        }
    }

    function _recipient(uint256 seed) private view returns (address) {
        uint256 index = seed % 9;
        if (index < 4) return holders[index];
        if (index == 4) return manager;
        if (index == 5) return burn;
        if (index == 7) return token.dividendDistributor();
        if (index == 8) return address(this);
        return address(token);
    }
}

contract DividendInvariantTest is StdInvariant, Test {
    DividendHandler internal handler;
    SIMDTESTToken internal token;

    function setUp() public {
        handler = new DividendHandler();
        handler.initialize();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = DividendHandler.buy.selector;
        selectors[1] = DividendHandler.move.selector;
        selectors[2] = DividendHandler.delegatedMove.selector;
        selectors[3] = DividendHandler.claim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariantSupplyAndEligibleBalancesAreConserved() public view {
        uint256 eligible;
        for (uint256 i; i < 4; ++i) {
            eligible += token.balanceOf(handler.holders(i));
        }
        uint256 excluded = token.balanceOf(token.POOL_MANAGER()) + token.balanceOf(token.BURN_ADDRESS())
            + token.balanceOf(address(token)) + token.balanceOf(token.dividendDistributor())
            + token.balanceOf(token.FACTORY());
        assertEq(eligible, token.eligibleSupply());
        assertEq(eligible + excluded, token.totalSupply());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }

    function invariantFeesAndClaimsMatchObservedFlows() public view {
        assertEq(token.totalFeesCollected(), handler.observedFees());
        assertEq(token.totalDividendsClaimed(), handler.observedClaims());
        assertLe(handler.observedClaims(), handler.observedFees());
        assertEq(
            token.balanceOf(address(token)), handler.observedFees() + handler.donations() - handler.observedClaims()
        );
    }

    function invariantOutstandingDividendsAreFullyBacked() public view {
        uint256 owed = token.pendingDividends();
        if (token.eligibleSupply() != 0) assertEq(owed, 0);
        for (uint256 i; i < 4; ++i) {
            owed += token.claimableDividends(handler.holders(i));
        }
        assertLe(owed, token.totalFeesCollected() - token.totalDividendsClaimed());
        assertLe(owed, token.balanceOf(address(token)));
    }

    function invariantExcludedAccountsNeverEarn() public view {
        assertEq(token.claimableDividends(token.POOL_MANAGER()), 0);
        assertEq(token.claimableDividends(token.BURN_ADDRESS()), 0);
        assertEq(token.claimableDividends(address(token)), 0);
        assertEq(token.claimableDividends(token.dividendDistributor()), 0);
        assertEq(token.claimableDividends(token.FACTORY()), 0);
    }
}
