// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Imd6900} from "../src/Imd6900.sol";

/// @dev Exercises interleaved approvals and transfers, including expected failures and self-transfers.
/// All balances stay inside a fixed actor set so the sum can be checked independently.
contract TokenHandler is Test {
    Imd6900 public immutable token;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401), address(0xDA7E)];

    constructor(Imd6900 token_) {
        token = token_;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        uint256 toBefore = token.balanceOf(to);
        uint256 fromBefore = token.balanceOf(from);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), toBefore + (from == to ? 0 : amount));
        assertEq(token.balanceOf(from), fromBefore - (from == to ? 0 : amount));
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = token.allowance(owner, spender);
        uint256 balance = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        uint256 limit = allowed < balance ? allowed : balance;
        // Half the sequences include attempts exceeding the balance or allowance by one unit.
        uint256 amount = amountSeed % 2 == 0 ? bound(amountSeed, 0, limit) : limit + 1;
        vm.prank(spender);
        (bool success, bytes memory result) =
            address(token).call(abi.encodeCall(token.transferFrom, (owner, to, amount)));
        if (amount > limit) {
            assertFalse(success);
            assertEq(token.balanceOf(owner), balance);
            assertEq(token.balanceOf(to), toBefore);
            assertEq(token.allowance(owner, spender), allowed);
        } else {
            assertTrue(success);
            assertTrue(abi.decode(result, (bool)));
            assertEq(token.balanceOf(to), toBefore + (owner == to ? 0 : amount));
            assertEq(token.balanceOf(owner), balance - (owner == to ? 0 : amount));
            assertEq(token.allowance(owner, spender), allowed == type(uint256).max ? allowed : allowed - amount);
        }
    }
}

contract Imd6900InvariantTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    Imd6900 private token;
    TokenHandler private handler;

    function setUp() public {
        token = new Imd6900();
        handler = new TokenHandler(token);
        token.transfer(handler.actors(0), SUPPLY);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = TokenHandler.transfer.selector;
        selectors[1] = TokenHandler.approve.selector;
        selectors[2] = TokenHandler.transferFrom.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
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
