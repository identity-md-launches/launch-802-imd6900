// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Imd6900} from "../src/Imd6900.sol";

contract TokenFactoryProbe {
    function deploy(bytes32 salt) external returns (Imd6900) {
        return new Imd6900{salt: salt}();
    }
}

contract RejectingReceiver {
    fallback() external {
        revert("No callbacks accepted");
    }
}

contract Imd6900Test is Test {
    uint256 private constant SUPPLY = 1_000_000_000 * 10 ** 18;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5EED);

    Imd6900 private token;

    function setUp() public {
        token = new Imd6900();
    }

    function test_metadataAndInitialSupply() public view {
        assertEq(token.name(), "Imd6900");
        assertEq(token.symbol(), "IMD6900");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.allowance(address(this), SPENDER), 0);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), address(this), SUPPLY);
        new Imd6900();
    }

    function test_directDeploymentMintsToEOA() public {
        vm.prank(ALICE);
        Imd6900 deployed = new Imd6900();
        assertEq(deployed.balanceOf(ALICE), SUPPLY);
        assertEq(deployed.balanceOf(address(this)), 0);
    }

    function test_create2MintsToFactoryAndLaunchTransfersArriveWhole() public {
        TokenFactoryProbe factory = new TokenFactoryProbe();
        bytes32 salt = keccak256("IMD6900 deployment");
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(type(Imd6900).creationCode))
                    )
                )
            )
        );
        Imd6900 launched = factory.deploy(salt);
        assertEq(address(launched), predicted);
        assertEq(launched.balanceOf(address(factory)), SUPPLY);
        assertEq(launched.balanceOf(address(this)), 0);

        // Token-side launch flows; these addresses do not implement a DEX or distributor.
        address distributor = address(0xD157);
        address poolManager = address(0x9001);
        uint256 swarm = SUPPLY / 10;
        uint256 seed = SUPPLY / 2;
        vm.startPrank(address(factory));
        assertTrue(launched.transfer(distributor, swarm));
        assertTrue(launched.transfer(poolManager, seed));
        assertTrue(launched.transfer(BOB, SUPPLY - swarm - seed));
        vm.stopPrank();
        assertEq(launched.balanceOf(address(factory)), 0);
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(poolManager), seed);
        assertEq(launched.balanceOf(BOB), SUPPLY - swarm - seed);

        vm.prank(distributor);
        assertTrue(launched.transfer(ALICE, swarm));
        assertEq(launched.balanceOf(distributor), 0);
        assertEq(launched.balanceOf(ALICE), swarm);
        vm.prank(poolManager);
        assertTrue(launched.transfer(ALICE, 123 ether));
        assertEq(launched.balanceOf(ALICE), swarm + 123 ether);
        vm.prank(ALICE);
        assertTrue(launched.transfer(poolManager, 123 ether));
        assertEq(launched.balanceOf(poolManager), seed);
        assertEq(launched.balanceOf(ALICE), swarm);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    function testFuzz_transferIsExactAndConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), ALICE, amount);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.balanceOf(ALICE), amount);

        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, amount));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_fullSupplyCanBeTransferred() public {
        assertTrue(token.transfer(ALICE, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(ALICE), SUPPLY);
    }

    function test_singleSmallestUnitArrivesWhole() public {
        assertTrue(token.transfer(ALICE, 1));
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
    }

    function testFuzz_selfTransferPreservesBalance(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransfersSucceedWithoutBalanceOrAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 0));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_contractRecipientReceivesWithoutCallback() public {
        RejectingReceiver receiver = new RejectingReceiver();
        assertTrue(token.transfer(address(receiver), 100 ether));
        assertEq(token.balanceOf(address(receiver)), 100 ether);
    }

    function test_approveEmitsEventAndCanBeReplacedOrRevoked() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), SPENDER, 50 ether);
        assertTrue(token.approve(SPENDER, 50 ether));
        assertEq(token.allowance(address(this), SPENDER), 50 ether);
        assertTrue(token.approve(SPENDER, 20 ether));
        assertEq(token.allowance(address(this), SPENDER), 20 ether);
        assertTrue(token.approve(SPENDER, 0));
        assertEq(token.allowance(address(this), SPENDER), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_transferFromDeliversExactAmountAndConsumesAllowance(uint256 allowance_, uint256 amount) public {
        allowance_ = bound(allowance_, 0, SUPPLY);
        amount = bound(amount, 0, allowance_);
        assertTrue(token.approve(SPENDER, allowance_));
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), ALICE, amount);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.allowance(address(this), SPENDER), allowance_ - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromSelfConsumesAllowanceWithoutChangingBalance() public {
        token.approve(SPENDER, 5 ether);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), address(this), 5 ether));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), SPENDER), 0);
    }

    function test_maximumApprovalIsNotReducedByTransferFrom() public {
        assertTrue(token.approve(SPENDER, type(uint256).max));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, SUPPLY));
        assertEq(token.allowance(address(this), SPENDER), type(uint256).max);
        assertEq(token.balanceOf(ALICE), SUPPLY);
    }

    function test_spentAllowanceCannotBeReused() public {
        token.approve(SPENDER, 1);
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(address(this), ALICE, 1));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, 1);
        assertEq(token.balanceOf(ALICE), 1);
    }

    function test_deployerCannotSpendHolderTokensWithoutApproval() public {
        token.transfer(ALICE, 10 ether);
        token.approve(SPENDER, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(ALICE, BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
        assertEq(token.balanceOf(ALICE), 10 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testFuzz_transferAboveBalanceRevertsWithoutChanges(uint256 balance) public {
        balance = bound(balance, 0, SUPPLY);
        token.transfer(ALICE, balance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, balance, balance + 1)
        );
        vm.prank(ALICE);
        token.transfer(BOB, balance + 1);
        assertEq(token.balanceOf(ALICE), balance);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromAboveAllowanceRevertsWithoutChanges(uint256 allowed) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        token.approve(SPENDER, allowed);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, allowed, allowed + 1)
        );
        vm.prank(SPENDER);
        token.transferFrom(address(this), ALICE, allowed + 1);
        assertEq(token.allowance(address(this), SPENDER), allowed);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function test_transferFromInsufficientBalanceRollsBackAllowance() public {
        vm.prank(ALICE);
        token.approve(SPENDER, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 10 ether));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 10 ether);
        assertEq(token.allowance(ALICE, SPENDER), 10 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToZeroRevertsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromToZeroRollsBackAllowance() public {
        token.approve(SPENDER, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(address(this), address(0), 1);
        assertEq(token.allowance(address(this), SPENDER), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_commonMintBurnAndAdminCallsRevertForDeployerAndStranger() public {
        token.transfer(ALICE, 10 ether);
        string[24] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)",
            "burn(uint256)",
            "rebase(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, uint256(1));
            (bool deployerSucceeded,) = address(token).call(data);
            assertFalse(deployerSucceeded, signatures[i]);
            vm.prank(SPENDER);
            (bool strangerSucceeded,) = address(token).call(data);
            assertFalse(strangerSucceeded, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(ALICE), 10 ether);
            assertEq(token.balanceOf(SPENDER), 0);
        }
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 10 ether));
        assertEq(token.balanceOf(BOB), 10 ether);
    }

    function test_runtimeHasNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 opcode = uint8(runtime[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
            } else {
                assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
            }
        }
    }
}
