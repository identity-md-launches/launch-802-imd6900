// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Imd6900} from "../src/Imd6900.sol";

/// @dev Exercises interleaved approvals and transfers, including expected failures and self-transfers.
/// All balances stay inside a fixed actor set so the sum can be checked independently.
contract TokenHandler is Test {
    Imd6900 public immutable token;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401), address(0xDA7E)];
    // These expectations come from the specified allocation and successful calls, never from
    // reading back the token. Checking the whole ledger also catches changes to uninvolved actors.
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    constructor(Imd6900 token_) {
        token = token_;
        ghostBalance[actors[0]] = 1_000_000_000 * 10 ** 18;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, ghostBalance[from]);
        uint256 toBefore = token.balanceOf(to);
        uint256 fromBefore = token.balanceOf(from);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _moveGhostBalance(from, to, amount);
        assertEq(token.balanceOf(to), toBefore + (from == to ? 0 : amount));
        assertEq(token.balanceOf(from), fromBefore - (from == to ? 0 : amount));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
        assertEq(token.allowance(owner, spender), amount);
    }

    /// @dev Explicitly revisit revocation, infinite approval, and the largest finite approval.
    function approveBoundary(uint256 ownerSeed, uint256 spenderSeed, uint256 mode) external {
        uint256 amount = mode % 3 == 0 ? 0 : (mode % 3 == 1 ? type(uint256).max : type(uint256).max - 1);
        approve(ownerSeed, spenderSeed, amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 balance = ghostBalance[owner];
        uint256 toBefore = token.balanceOf(to);
        uint256 limit = allowed < balance ? allowed : balance;
        // Half the sequences include attempts exceeding the balance or allowance by one unit.
        uint256 amount = amountSeed % 2 == 0 ? bound(amountSeed, 0, limit) : limit + 1;
        vm.prank(spender);
        (bool success, bytes memory result) =
            address(token).call(abi.encodeCall(token.transferFrom, (owner, to, amount)));
        if (amount > limit) {
            assertFalse(success);
            bytes memory expected = amount > allowed
                ? abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
                : abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount);
            assertEq(result, expected, "unexpected delegated-transfer failure");
            assertEq(token.balanceOf(owner), balance);
            assertEq(token.balanceOf(to), toBefore);
            assertEq(token.allowance(owner, spender), allowed);
        } else {
            assertTrue(success);
            assertTrue(abi.decode(result, (bool)));
            _moveGhostBalance(owner, to, amount);
            if (allowed != type(uint256).max) ghostAllowance[owner][spender] -= amount;
            assertEq(token.balanceOf(to), toBefore + (owner == to ? 0 : amount));
            assertEq(token.balanceOf(owner), balance - (owner == to ? 0 : amount));
            assertEq(token.allowance(owner, spender), allowed == type(uint256).max ? allowed : allowed - amount);
        }
    }

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = ghostBalance[from];
        uint256 amount = bound(amountSeed, balance + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        vm.prank(from);
        token.transfer(to, amount);
    }

    /// @dev Force the balance check to fail after allowance validation, with both approval modes.
    function transferFromAboveBalance(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed, bool infinite)
        external
    {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[(ownerSeed % actors.length + 1) % actors.length];
        uint256 balance = ghostBalance[owner];
        uint256 amount = bound(amountSeed, balance + 1, type(uint256).max - 1);
        approve(ownerSeed, spenderSeed, infinite ? type(uint256).max : amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount));
        vm.prank(spender);
        token.transferFrom(owner, to, amount);
        // No ghost update: the failed transfer must preserve the entire allowance and ledger.
    }

    function transferToZero(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, ghostBalance[owner]);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(owner);
        token.transfer(address(0), amount);
    }

    function transferFromToZero(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 balance = ghostBalance[owner];
        uint256 amount = bound(amountSeed, 0, allowed < balance ? allowed : balance);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        vm.prank(owner);
        token.approve(address(0), amount);
    }

    function _moveGhostBalance(address from, address to, uint256 amount) private {
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract Imd6900InvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Imd6900 private token;
    TokenHandler private handler;

    function setUp() public {
        token = new Imd6900();
        handler = new TokenHandler(token);
        assertTrue(token.transfer(handler.actors(0), SUPPLY));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = TokenHandler.transfer.selector;
        selectors[1] = TokenHandler.approve.selector;
        selectors[2] = TokenHandler.transferFrom.selector;
        selectors[3] = TokenHandler.approveBoundary.selector;
        selectors[4] = TokenHandler.transferAboveBalance.selector;
        selectors[5] = TokenHandler.transferFromAboveBalance.selector;
        selectors[6] = TokenHandler.transferToZero.selector;
        selectors[7] = TokenHandler.transferFromToZero.selector;
        selectors[8] = TokenHandler.approveZeroSpender.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_balancesAndAllowancesMatchHistory() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.balanceOf(owner), handler.ghostBalance(owner), "holder balance changed unexpectedly");
            assertEq(token.allowance(owner, address(0)), 0, "zero spender acquired an allowance");
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance changed outside its owner's approval or authorized spend"
                );
            }
        }
    }

    /// @dev Every holder must still be able to move its entire balance after any call sequence.
    function afterInvariant() public {
        address recipient = handler.actors(0);
        for (uint256 i = 1; i < 4; ++i) {
            address holder = handler.actors(i);
            uint256 balance = handler.ghostBalance(holder);
            vm.prank(holder);
            assertTrue(token.transfer(recipient, balance));
            assertEq(token.balanceOf(holder), 0);
        }
        assertEq(token.balanceOf(recipient), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_supplyAndBalancesAreConserved() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }
}
