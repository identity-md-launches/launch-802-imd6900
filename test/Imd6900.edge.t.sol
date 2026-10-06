// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Imd6900} from "src/Imd6900.sol";

contract TokenSpenderProbe {
    function pull(Imd6900 token, address owner, address recipient, uint256 amount) external returns (bool) {
        return token.transferFrom(owner, recipient, amount);
    }
}

/// @dev Regression cases supplementing the existing metadata, launch, and transfer tests.
/// forge-config: default.fuzz.runs = 1000
contract Imd6900EdgeTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);
    address private constant STRANGER = address(0xBAD);

    Imd6900 private token;

    function setUp() public {
        token = new Imd6900();
    }

    function test_largestFiniteApprovalIsConsumed() public {
        token.approve(SPENDER, type(uint256).max - 1);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 1));
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max - 2);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_infiniteApprovalCanBeRevokedAndReplaced() public {
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 1));
        token.approve(SPENDER, 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 1);

        token.approve(SPENDER, 1);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 1));
        assertEq(token.allowance(address(this), SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 2);
        assertEq(token.balanceOf(address(this)), SUPPLY - 2);
    }

    function testFuzz_failedTransferFromCanUsePreservedAllowanceAfterFunding(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY - 1);
        amount = bound(amount, balance + 1, SUPPLY);
        token.transfer(ALICE, balance);
        vm.prank(ALICE);
        token.approve(SPENDER, amount);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, balance, amount));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, amount);
        assertEq(token.allowance(ALICE, SPENDER), amount);
        assertEq(token.balanceOf(ALICE), balance);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - balance);

        // Retrying the identical call succeeds once the only missing precondition is supplied.
        token.transfer(ALICE, amount - balance);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, amount));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_allowancesAreIsolatedByOwnerAndSpender() public {
        token.transfer(ALICE, 100);
        token.transfer(BOB, 100);
        vm.startPrank(ALICE);
        token.approve(SPENDER, 5);
        token.approve(BOB, 9);
        vm.stopPrank();
        vm.prank(BOB);
        token.approve(SPENDER, 7);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, STRANGER, 0, 1));
        vm.prank(STRANGER);
        token.transferFrom(ALICE, STRANGER, 1);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, SPENDER, 3));
        assertEq(token.allowance(ALICE, SPENDER), 2);
        assertEq(token.allowance(BOB, SPENDER), 7);
        assertEq(token.allowance(ALICE, BOB), 9);
        assertEq(token.allowance(ALICE, STRANGER), 0);

        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, BOB, 9));
        assertEq(token.allowance(ALICE, BOB), 0);
        assertEq(token.allowance(ALICE, SPENDER), 2);
        assertEq(token.allowance(BOB, SPENDER), 7);
        assertEq(token.balanceOf(ALICE), 88);
        assertEq(token.balanceOf(BOB), 109);
        assertEq(token.balanceOf(SPENDER), 3);
        assertEq(token.balanceOf(STRANGER), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - 200);
    }

    function test_ownerCallingTransferFromStillNeedsSelfApproval() public {
        token.transfer(ALICE, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(BOB), 0);

        vm.startPrank(ALICE);
        token.approve(ALICE, 1);
        assertTrue(token.transferFrom(ALICE, BOB, 1));
        vm.stopPrank();
        assertEq(token.allowance(ALICE, ALICE), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 1);
    }

    function test_approvalBelongsToImmediateCallerNotTransactionOrigin() public {
        TokenSpenderProbe relay = new TokenSpenderProbe();
        token.transfer(ALICE, 10);
        vm.prank(ALICE);
        token.approve(SPENDER, 10);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(relay), 0, 10));
        vm.prank(SPENDER, SPENDER);
        relay.pull(token, ALICE, BOB, 10);
        assertEq(token.allowance(ALICE, SPENDER), 10);
        assertEq(token.balanceOf(ALICE), 10);
        assertEq(token.balanceOf(BOB), 0);

        vm.prank(ALICE);
        token.approve(address(relay), 10);
        vm.prank(SPENDER, SPENDER);
        assertTrue(relay.pull(token, ALICE, BOB, 10));
        assertEq(token.allowance(ALICE, address(relay)), 0);
        assertEq(token.allowance(ALICE, SPENDER), 10);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 10);
    }

    function test_maximumTransferRevertsWithoutWrappingBalances() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(ALICE, type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maximumDelegatedTransferRevertsEvenWithInfiniteApproval() public {
        token.approve(SPENDER, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, type(uint256).max);
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferStillRequiresEnoughBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(address(this), SUPPLY + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromToZeroRevertsWithoutAnApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), 0);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroSpenderRejectsZeroAndMaximumApprovals() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), type(uint256).max);
        assertEq(token.allowance(address(this), address(0)), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_splitTransferAndRoundTripHaveNoFee(uint256 amount, uint256 firstPart) public {
        amount = bound(amount, 0, SUPPLY);
        firstPart = bound(firstPart, 0, amount);
        // A single transfer and a partition into two transfers must deliver the same amount.
        assertTrue(token.transfer(ALICE, amount));
        vm.prank(ALICE);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);

        assertTrue(token.transfer(ALICE, firstPart));
        assertTrue(token.transfer(ALICE, amount - firstPart));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        vm.prank(ALICE);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
