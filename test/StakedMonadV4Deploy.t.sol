// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./StakedMonadV3Deploy.t.sol";
import {StakedMonadV4} from "../src/StakedMonadV4.sol";
import {DeployV4} from "../script/DeployV4.s.sol";

/// @notice Shared V4 suite. Inherits every V1 and V3 test so they also run against V4.
abstract contract StakedMonadV4Tests is StakedMonadV3Tests {
    uint64 internal constant NODE_ID = 1;
    uint96 internal constant DEPOSIT = 10 ether;

    address payable internal RECOVERY = payable(vm.addr(104));

    function v4() internal view returns (StakedMonadV4) {
        return StakedMonadV4(payable(address(stakedMonad)));
    }

    function test_freeze_and_seize_roles_granted_to_admin() public view {
        assertTrue(v4().hasRole(v4().ROLE_FREEZER(), ADMIN), "Admin should be a freezer");
        assertTrue(v4().hasRole(v4().ROLE_SEIZER(), ADMIN), "Admin should be a seizer");
    }

    function test_freeze_and_seize_roles_managed_by_default_admin() public {
        bytes32 freezer = v4().ROLE_FREEZER();
        bytes32 seizer = v4().ROLE_SEIZER();
        bytes32 defaultAdmin = v4().DEFAULT_ADMIN_ROLE();
        assertEq(v4().getRoleAdmin(freezer), defaultAdmin);
        assertEq(v4().getRoleAdmin(seizer), defaultAdmin);

        // A freezer cannot hand out the role on its own
        vm.prank(ADMIN);
        v4().grantRole(freezer, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ALICE, defaultAdmin));
        v4().grantRole(freezer, BOB);
    }

    function test_only_freezer_can_freeze_and_unfreeze() public {
        bytes32 role = v4().ROLE_FREEZER();
        vm.startPrank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        v4().freeze(ALICE);

        vm.startPrank(ADMIN);
        v4().freeze(ALICE);

        vm.startPrank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        v4().unfreeze(ALICE);
    }

    function test_only_seizer_can_seize() public {
        _depositAs(ALICE, DEPOSIT);
        vm.prank(ADMIN);
        v4().freeze(ALICE);

        bytes32 role = v4().ROLE_SEIZER();
        vm.startPrank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        v4().seize(ALICE, BOB);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        v4().seizeUnlockRequest(ALICE, 0, BOB);
    }

    function test_freeze_rejects_zero_address_and_contract() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(StakedMonadV4.InvalidAccount.selector);
        v4().freeze(address(0));
        vm.expectRevert(StakedMonadV4.InvalidAccount.selector);
        v4().freeze(address(stakedMonad));
    }

    function test_freeze_and_unfreeze_state_and_events() public {
        vm.startPrank(ADMIN);
        vm.expectEmit(true, false, false, true, address(stakedMonad));
        emit StakedMonadV4.Frozen(ALICE);
        v4().freeze(ALICE);
        assertTrue(v4().isFrozen(ALICE));

        vm.expectRevert(CustomErrors.NoChange.selector);
        v4().freeze(ALICE);

        vm.expectEmit(true, false, false, true, address(stakedMonad));
        emit StakedMonadV4.Unfrozen(ALICE);
        v4().unfreeze(ALICE);
        assertFalse(v4().isFrozen(ALICE));

        vm.expectRevert(CustomErrors.NoChange.selector);
        v4().unfreeze(ALICE);
    }

    function test_frozen_account_cannot_send_or_receive() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);
        _depositAs(BOB, DEPOSIT);

        vm.prank(ADMIN);
        v4().freeze(ALICE);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountFrozen.selector, ALICE));
        stakedMonad.transfer(BOB, shares);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountFrozen.selector, ALICE));
        stakedMonad.transfer(ALICE, 1);

        // Deposits cannot mint to a frozen receiver either
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountFrozen.selector, ALICE));
        stakedMonad.deposit{value: 1 ether}(0, ALICE);

        // Unfreezing restores normal transfers
        vm.prank(ADMIN);
        v4().unfreeze(ALICE);
        vm.prank(ALICE);
        stakedMonad.transfer(BOB, shares);
        assertEq(stakedMonad.balanceOf(ALICE), 0);
    }

    function test_frozen_spender_cannot_use_existing_allowance() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);

        // Alice approved a drainer before it was flagged
        vm.prank(ALICE);
        stakedMonad.approve(CHARLIE, shares);

        vm.prank(ADMIN);
        v4().freeze(CHARLIE);

        vm.prank(CHARLIE);
        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountFrozen.selector, CHARLIE));
        stakedMonad.transferFrom(ALICE, BOB, shares);
        assertEq(stakedMonad.balanceOf(ALICE), shares, "Alice keeps her shares");
    }

    function test_cannot_approve_frozen_spender_but_can_revoke() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);
        vm.prank(ALICE);
        stakedMonad.approve(CHARLIE, shares);

        vm.prank(ADMIN);
        v4().freeze(CHARLIE);

        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountFrozen.selector, CHARLIE));
        stakedMonad.approve(CHARLIE, 1);

        // Revoking the old approval still works
        stakedMonad.approve(CHARLIE, 0);
        assertEq(stakedMonad.allowance(ALICE, CHARLIE), 0);
    }

    function test_frozen_account_cannot_approve() public {
        _depositAs(ALICE, DEPOSIT);
        vm.prank(ADMIN);
        v4().freeze(ALICE);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountFrozen.selector, ALICE));
        stakedMonad.approve(BOB, 1);
    }

    function test_pause_blocks_transfers() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);

        vm.prank(ADMIN);
        stakedMonad.pause();

        vm.prank(ALICE);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stakedMonad.transfer(BOB, shares);

        vm.prank(ADMIN);
        stakedMonad.unpause();

        vm.prank(ALICE);
        stakedMonad.transfer(BOB, shares);
        assertEq(stakedMonad.balanceOf(BOB), shares);
    }

    function test_frozen_account_cannot_request_or_cancel_unlock() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);

        vm.prank(ALICE);
        stakedMonad.requestUnlock(shares / 2, 0);

        vm.prank(ADMIN);
        v4().freeze(ALICE);

        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountFrozen.selector, ALICE));
        stakedMonad.requestUnlock(shares / 2, 0);

        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountFrozen.selector, ALICE));
        stakedMonad.cancelUnlockRequest(0);
    }

    function test_frozen_account_cannot_redeem() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);
        vm.prank(ALICE);
        stakedMonad.requestUnlock(shares, 0);
        _submitBatchAndPassWithdrawDelay();

        vm.prank(ADMIN);
        v4().freeze(ALICE);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountFrozen.selector, ALICE));
        stakedMonad.redeem(0, ALICE);
    }

    function test_cannot_redeem_to_frozen_receiver() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);
        vm.prank(ALICE);
        stakedMonad.requestUnlock(shares, 0);
        _submitBatchAndPassWithdrawDelay();

        vm.prank(ADMIN);
        v4().freeze(CHARLIE);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountFrozen.selector, CHARLIE));
        stakedMonad.redeem(0, CHARLIE);
    }

    function test_seize_moves_full_balance_to_recovery() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);
        uint256 supplyBefore = stakedMonad.totalSupply();
        uint256 ratioBefore = stakedMonad.convertToAssets(1 ether);

        vm.startPrank(ADMIN);
        v4().freeze(ALICE);
        vm.expectEmit(true, true, false, true, address(stakedMonad));
        emit StakedMonadV4.Seized(ALICE, RECOVERY, shares);
        v4().seize(ALICE, RECOVERY);

        assertEq(stakedMonad.balanceOf(ALICE), 0, "Frozen account emptied");
        assertEq(stakedMonad.balanceOf(RECOVERY), shares, "Recovery receives the shares");
        assertEq(stakedMonad.totalSupply(), supplyBefore, "Seizing must not burn");
        assertEq(stakedMonad.convertToAssets(1 ether), ratioBefore, "Redemption ratio unchanged");
        assertTrue(v4().isFrozen(ALICE), "Account stays frozen");
    }

    function test_seize_requires_frozen_account() public {
        _depositAs(ALICE, DEPOSIT);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountNotFrozen.selector, ALICE));
        v4().seize(ALICE, RECOVERY);
    }

    function test_seize_rejects_bad_recipients() public {
        _depositAs(ALICE, DEPOSIT);
        vm.startPrank(ADMIN);
        v4().freeze(ALICE);
        v4().freeze(CHARLIE);

        vm.expectRevert(StakedMonadV4.InvalidAccount.selector);
        v4().seize(ALICE, address(0));
        vm.expectRevert(StakedMonadV4.InvalidAccount.selector);
        v4().seize(ALICE, address(stakedMonad));
        vm.expectRevert(StakedMonadV4.InvalidAccount.selector);
        v4().seize(ALICE, ALICE);
        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountFrozen.selector, CHARLIE));
        v4().seize(ALICE, CHARLIE);
    }

    function test_seize_reverts_on_empty_balance() public {
        vm.startPrank(ADMIN);
        v4().freeze(ALICE);
        vm.expectRevert(CustomErrors.NoChange.selector);
        v4().seize(ALICE, RECOVERY);
    }

    function test_freeze_and_seize_work_while_paused() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);

        vm.startPrank(ADMIN);
        stakedMonad.pause();
        v4().freeze(ALICE);
        v4().seize(ALICE, RECOVERY);
        v4().unfreeze(ALICE);
        assertEq(stakedMonad.balanceOf(RECOVERY), shares);
    }

    /// @notice Request still in the open batch: cancel it and hand every escrowed share (fee included) to recovery
    function test_seizeUnlockRequest_open_batch_returns_shares() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);
        vm.prank(ALICE);
        stakedMonad.requestUnlock(shares, 0);

        uint40 batchId = stakedMonad.currentBatchId();
        StakedMonadV4.UnlockRequest memory request = v4().getAllUserUnlockRequests(ALICE)[0];
        assertGt(stakedMonad.getExitFeeBips(), 0, "Test setup: exit fee should apply");

        vm.startPrank(ADMIN);
        v4().freeze(ALICE);
        vm.expectEmit(true, true, false, true, address(stakedMonad));
        emit StakedMonadV4.UnlockRequestSeized(ALICE, 0, RECOVERY, shares, request.spotValue, false);
        v4().seizeUnlockRequest(ALICE, 0, RECOVERY);

        assertEq(stakedMonad.balanceOf(RECOVERY), shares, "Recovery receives all escrowed shares");
        assertEq(v4().getAllUserUnlockRequests(ALICE).length, 0, "Request removed from frozen account");
        assertEq(v4().getAllUserUnlockRequests(RECOVERY).length, 0, "Open request is cancelled, not moved");
        (uint96 batchAssets, uint96 batchShares) = stakedMonad.batchWithdrawRequests(batchId);
        assertEq(batchAssets, 0, "Batch assets reversed");
        assertEq(batchShares, 0, "Batch shares reversed");
        assertEq(stakedMonad.balanceOf(address(stakedMonad)), 0, "Nothing left in escrow");
    }

    /// @notice Request already submitted (unbonding): recovery takes over the claim and redeems the MON
    function test_seizeUnlockRequest_submitted_batch_reassigns_claim() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);
        vm.prank(ALICE);
        stakedMonad.requestUnlock(shares, 0);
        StakedMonadV4.UnlockRequest memory request = v4().getAllUserUnlockRequests(ALICE)[0];
        _submitBatchAndPassWithdrawDelay();

        vm.startPrank(ADMIN);
        v4().freeze(ALICE);
        vm.expectEmit(true, true, false, true, address(stakedMonad));
        emit StakedMonadV4.UnlockRequestSeized(ALICE, 0, RECOVERY, request.shares, request.spotValue, true);
        v4().seizeUnlockRequest(ALICE, 0, RECOVERY);
        vm.stopPrank();

        assertEq(v4().getAllUserUnlockRequests(ALICE).length, 0, "Claim removed from frozen account");
        StakedMonadV4.UnlockRequest[] memory moved = v4().getAllUserUnlockRequests(RECOVERY);
        assertEq(moved.length, 1, "Recovery holds the claim");
        assertEq(moved[0].spotValue, request.spotValue, "Same MON owed");
        assertEq(moved[0].batchId, request.batchId, "Same batch");

        // Recovery redeems the MON as a normal user would
        uint256 balanceBefore = RECOVERY.balance;
        vm.prank(RECOVERY);
        stakedMonad.redeem(0, RECOVERY);
        assertEq(RECOVERY.balance - balanceBefore, request.spotValue, "Recovery receives the unbonded MON");

        // The thief has nothing left to redeem
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountFrozen.selector, ALICE));
        stakedMonad.redeem(0, ALICE);
    }

    function test_seizeUnlockRequest_requires_frozen_and_valid_recipient() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);
        vm.prank(ALICE);
        stakedMonad.requestUnlock(shares, 0);

        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(StakedMonadV4.AccountNotFrozen.selector, ALICE));
        v4().seizeUnlockRequest(ALICE, 0, RECOVERY);

        v4().freeze(ALICE);
        vm.expectRevert(StakedMonadV4.InvalidAccount.selector);
        v4().seizeUnlockRequest(ALICE, 0, ALICE);
        vm.expectRevert(stdError.indexOOBError);
        v4().seizeUnlockRequest(ALICE, 1, RECOVERY);
    }

    function test_seizeUnlockRequest_keeps_other_requests() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);
        vm.startPrank(ALICE);
        stakedMonad.requestUnlock(shares / 4, 0);
        stakedMonad.requestUnlock(shares / 2, 0);
        vm.stopPrank();
        uint96 secondShares = v4().getAllUserUnlockRequests(ALICE)[1].shares;

        vm.startPrank(ADMIN);
        v4().freeze(ALICE);
        v4().seizeUnlockRequest(ALICE, 0, RECOVERY);

        StakedMonadV4.UnlockRequest[] memory remaining = v4().getAllUserUnlockRequests(ALICE);
        assertEq(remaining.length, 1, "Only the seized request is removed");
        assertEq(remaining[0].shares, secondShares, "Other request intact");
    }

    function test_cancelUnlockRequest_unchanged_for_normal_users() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);
        vm.startPrank(ALICE);
        stakedMonad.requestUnlock(shares, 0);
        stakedMonad.cancelUnlockRequest(0);
        assertEq(stakedMonad.balanceOf(ALICE), shares, "Cancelling returns every share");
        assertEq(v4().getAllUserUnlockRequests(ALICE).length, 0);
    }

    function _depositAs(address user, uint96 amount) internal returns (uint96 shares) {
        if (!_nodeAdded) {
            vm.startPrank(ADMIN);
            stakedMonad.addNode(NODE_ID);
            Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
            weightDeltas[0] = Registry.WeightDelta({nodeId: NODE_ID, delta: 100, isIncreasing: true});
            stakedMonad.updateWeights(weightDeltas);
            vm.stopPrank();
            _nodeAdded = true;
        }
        vm.prank(user);
        shares = stakedMonad.deposit{value: amount}(0, user);
    }

    function _submitBatchAndPassWithdrawDelay() internal {
        uint64 submissionEpoch = 1;
        StakerFaker.mockGetEpoch(submissionEpoch, false);
        StakerFaker.mockDelegate(NODE_ID, true);
        stakedMonad.submitBatch();
        StakerFaker.mockGetEpoch(submissionEpoch + 1 + WITHDRAW_DELAY_EPOCHS, false);
    }

    bool private _nodeAdded;
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
        vm.prank(ADMIN);
        vm.expectRevert("Expected a different version");
        StakedMonadV4(payable(stakedMonad)).initializeFromV3();
    }
}
