// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./StakedMonad.t.sol";
import {StakedMonadV3Tests} from "./StakedMonadV3Deploy.t.sol";
import {StakedMonadV4} from "../src/StakedMonadV4.sol";
import {DeployV4} from "../script/DeployV4.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Runs the full V3 suite plus the V4 transfer-pause behaviour
abstract contract StakedMonadV4Tests is StakedMonadV3Tests {
    uint96 internal constant PAUSE_TEST_DEPOSIT = 10 ether;

    /// @dev Alice holds shares; admin pauses. Mocks are left untouched.
    function _depositThenPause() private {
        vm.prank(ALICE);
        stakedMonad.deposit{value: PAUSE_TEST_DEPOSIT}(0, ALICE);
        assertEq(stakedMonad.balanceOf(ALICE), PAUSE_TEST_DEPOSIT, "Test setup: 1:1 mint expected");

        vm.prank(ADMIN);
        stakedMonad.pause();
        assertTrue(stakedMonad.paused(), "Test setup: must be paused");
    }

    function test_transfer_reverts_when_paused() public {
        _depositThenPause();

        vm.prank(ALICE);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stakedMonad.transfer(BOB, 1 ether);

        assertEq(stakedMonad.balanceOf(ALICE), PAUSE_TEST_DEPOSIT, "Balance untouched");
        assertEq(stakedMonad.balanceOf(BOB), 0, "Nothing received");
    }

    function test_transferFrom_reverts_when_paused() public {
        _depositThenPause();

        // Approvals are not blocked by pause, only balance movement is
        vm.prank(ALICE);
        stakedMonad.approve(BOB, 1 ether);
        assertEq(stakedMonad.allowance(ALICE, BOB), 1 ether, "Approve should still work while paused");

        vm.prank(BOB);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stakedMonad.transferFrom(ALICE, CHARLIE, 1 ether);

        assertEq(stakedMonad.balanceOf(ALICE), PAUSE_TEST_DEPOSIT, "Balance untouched");
        assertEq(stakedMonad.balanceOf(CHARLIE), 0, "Nothing received");
        assertEq(stakedMonad.allowance(ALICE, BOB), 1 ether, "Allowance not consumed by a reverted transfer");
    }

    function test_transfer_to_self_reverts_when_paused() public {
        _depositThenPause();

        vm.prank(ALICE);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stakedMonad.transfer(ALICE, 1 ether);
    }

    function test_zero_value_transfer_reverts_when_paused() public {
        _depositThenPause();

        vm.prank(ALICE);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stakedMonad.transfer(BOB, 0);
    }

    function test_transfers_resume_after_unpause() public {
        _depositThenPause();

        vm.prank(ADMIN);
        stakedMonad.unpause();
        assertFalse(stakedMonad.paused());

        vm.prank(ALICE);
        stakedMonad.approve(BOB, 2 ether);

        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true, address(stakedMonad));
        emit IERC20.Transfer(ALICE, BOB, 1 ether);
        assertTrue(stakedMonad.transfer(BOB, 1 ether));

        vm.prank(BOB);
        assertTrue(stakedMonad.transferFrom(ALICE, CHARLIE, 2 ether));

        assertEq(stakedMonad.balanceOf(ALICE), PAUSE_TEST_DEPOSIT - 3 ether);
        assertEq(stakedMonad.balanceOf(BOB), 1 ether);
        assertEq(stakedMonad.balanceOf(CHARLIE), 2 ether);
        assertEq(stakedMonad.allowance(ALICE, BOB), 0);
    }

    function test_transfers_work_while_not_paused() public {
        vm.prank(ALICE);
        stakedMonad.deposit{value: PAUSE_TEST_DEPOSIT}(0, ALICE);
        assertFalse(stakedMonad.paused());

        vm.prank(ALICE);
        assertTrue(stakedMonad.transfer(BOB, 4 ether));
        assertEq(stakedMonad.balanceOf(ALICE), PAUSE_TEST_DEPOSIT - 4 ether);
        assertEq(stakedMonad.balanceOf(BOB), 4 ether);
    }

    /// @dev Share burns in `submitBatch` are already gated by `whenNotPaused`; verify the escrowed shares stay put
    function test_escrowed_shares_untouched_while_paused() public {
        vm.startPrank(ALICE);
        stakedMonad.deposit{value: PAUSE_TEST_DEPOSIT}(0, ALICE);
        stakedMonad.requestUnlock(1 ether, 0);
        vm.stopPrank();
        uint256 escrowBefore = stakedMonad.balanceOf(address(stakedMonad));
        assertEq(escrowBefore, 1 ether, "Test setup: shares escrowed in the vault");

        vm.prank(ADMIN);
        stakedMonad.pause();

        vm.prank(ALICE);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stakedMonad.cancelUnlockRequest(0);

        vm.prank(ALICE);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stakedMonad.transfer(BOB, 1 ether);

        assertEq(stakedMonad.balanceOf(address(stakedMonad)), escrowBefore, "Escrow unchanged");
        assertEq(stakedMonad.totalSupply(), PAUSE_TEST_DEPOSIT, "Supply unchanged");
    }
}

contract StakedMonadV4DeployTest is StakedMonadV4Tests, DeployV4 {
    function run() public override(DeployV1, DeployV4) {}
    function writeArtifacts(string memory, string memory, address) internal override(DeployV1, DeployV4) {}

    function setUp() public override(StakedMonadTest) {
        // Deploy v1
        super.setUp();

        // Deploy v4 directly
        (address proxy,) = DeployV4.deployV4(ADMIN);

        // Overwrite previously deployed v1 to run tests against v4
        stakedMonad = StakedMonad(payable(proxy));
    }

    function test_cannot_initialize_again() public {
        vm.expectRevert("Expected a different version");
        StakedMonadV4(payable(stakedMonad)).initialize(ALICE);
    }

    function test_cannot_call_initializeFromV3_on_fresh_deploy() public {
        vm.expectRevert("Expected a different version");
        StakedMonadV4(payable(stakedMonad)).initializeFromV3();
    }
}
