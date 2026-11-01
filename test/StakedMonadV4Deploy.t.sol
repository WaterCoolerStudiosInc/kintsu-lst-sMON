// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./StakedMonadV3Deploy.t.sol";
import {StakedMonadV4} from "../src/StakedMonadV4.sol";
import {FreezableUpgradeable} from "../src/FreezableUpgradeable.sol";
import {TransferPausableUpgradeable} from "../src/TransferPausableUpgradeable.sol";
import {DeployV4} from "../script/DeployV4.s.sol";

/// @notice Shared V4 suite. Inherits every V1 and V3 test so they also run against V4.
abstract contract StakedMonadV4Tests is StakedMonadV3Tests {
    uint64 internal constant NODE_ID = 1;
    uint96 internal constant DEPOSIT = 10 ether;

    address payable internal RECOVERY = payable(vm.addr(104));

    function v4() internal view returns (StakedMonadV4) {
        return StakedMonadV4(payable(address(stakedMonad)));
    }

    function _pauseProtocol() internal override {
        v4().pauseProtocol();
    }

    function _unpauseProtocol() internal override {
        v4().unpauseProtocol();
    }

    function test_pause_roles_granted_to_admin() public view {
        assertTrue(v4().hasRole(v4().ROLE_PAUSE(), ADMIN), "Admin should be a pauser");
        assertTrue(v4().hasRole(v4().ROLE_UNPAUSE(), ADMIN), "Admin should be an unpauser");
    }

    function test_pause_roles_managed_by_default_admin() public {
        bytes32 unpauser = v4().ROLE_UNPAUSE();
        bytes32 defaultAdmin = v4().DEFAULT_ADMIN_ROLE();
        assertEq(v4().getRoleAdmin(v4().ROLE_PAUSE()), defaultAdmin);
        assertEq(v4().getRoleAdmin(unpauser), defaultAdmin);

        // An unpauser cannot hand out its own role
        vm.prank(ADMIN);
        v4().grantRole(unpauser, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ALICE, defaultAdmin));
        v4().grantRole(unpauser, BOB);
    }

    function test_only_unpauser_can_unpause() public {
        vm.prank(ADMIN);
        v4().pauseProtocol();

        bytes32 role = v4().ROLE_UNPAUSE();
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        v4().unpauseProtocol();
    }

    /// @notice A pauser-only key (e.g. a fast monitoring bot) cannot resume the contract
    function test_pauser_cannot_unpause() public {
        bytes32 pauser = v4().ROLE_PAUSE();
        bytes32 unpauser = v4().ROLE_UNPAUSE();
        vm.prank(ADMIN);
        v4().grantRole(pauser, CHARLIE);

        vm.prank(CHARLIE);
        v4().pauseProtocol();

        vm.prank(CHARLIE);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, CHARLIE, unpauser));
        v4().unpauseProtocol();
        assertTrue(stakedMonad.paused(), "Still paused");
    }

    /// @notice An unpauser-only key cannot pause
    function test_unpauser_cannot_pause() public {
        bytes32 pauser = v4().ROLE_PAUSE();
        bytes32 unpauser = v4().ROLE_UNPAUSE();
        vm.prank(ADMIN);
        v4().grantRole(unpauser, CHARLIE);

        vm.prank(CHARLIE);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, CHARLIE, pauser));
        v4().pauseProtocol();

        vm.prank(ADMIN);
        v4().pauseProtocol();
        vm.prank(CHARLIE);
        v4().unpauseProtocol();
        assertFalse(stakedMonad.paused(), "Unpaused by the unpauser");
    }

    function test_freeze_and_seize_roles_granted_to_admin() public view {
        assertTrue(v4().hasRole(v4().ROLE_FREEZE(), ADMIN), "Admin should be a freezer");
        assertTrue(v4().hasRole(v4().ROLE_UNFREEZE(), ADMIN), "Admin should be an unfreezer");
        assertTrue(v4().hasRole(v4().ROLE_SEIZE(), ADMIN), "Admin should be a seizer");
    }

    /// @notice Freeze, unfreeze and seize are all handed out and revoked by the default admin
    function test_freeze_and_seize_roles_managed_by_default_admin() public {
        bytes32 freezer = v4().ROLE_FREEZE();
        bytes32 unfreezer = v4().ROLE_UNFREEZE();
        bytes32 seizer = v4().ROLE_SEIZE();
        bytes32 defaultAdmin = v4().DEFAULT_ADMIN_ROLE();
        assertEq(v4().getRoleAdmin(freezer), defaultAdmin);
        assertEq(v4().getRoleAdmin(unfreezer), defaultAdmin);
        assertEq(v4().getRoleAdmin(seizer), defaultAdmin);

        // A freezer cannot hand out the role on its own
        vm.prank(ADMIN);
        v4().grantRole(freezer, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ALICE, defaultAdmin));
        v4().grantRole(freezer, BOB);

        // A seizer cannot hand out the role on its own, and the admin can revoke it
        vm.prank(ADMIN);
        v4().grantRole(seizer, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ALICE, defaultAdmin));
        v4().grantRole(seizer, BOB);

        vm.prank(ADMIN);
        v4().revokeRole(seizer, ALICE);
        assertFalse(v4().hasRole(seizer, ALICE), "Admin can revoke a compromised seizer");
    }

    /// @notice A compromised freezer key cannot revoke the admin's own freeze power
    function test_freezer_cannot_revoke_the_admin() public {
        bytes32 freezer = v4().ROLE_FREEZE();
        bytes32 defaultAdmin = v4().DEFAULT_ADMIN_ROLE();
        vm.prank(ADMIN);
        v4().grantRole(freezer, CHARLIE);

        vm.prank(CHARLIE);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, CHARLIE, defaultAdmin));
        v4().revokeRole(freezer, ADMIN);
        assertTrue(v4().hasRole(freezer, ADMIN), "Admin keeps the freeze role");

        vm.prank(ADMIN);
        v4().revokeRole(freezer, CHARLIE);
        assertFalse(v4().hasRole(freezer, CHARLIE), "Admin can revoke a compromised freezer");
    }

    function test_only_freezer_can_freeze() public {
        bytes32 role = v4().ROLE_FREEZE();
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        v4().freeze(ALICE);
    }

    function test_only_unfreezer_can_unfreeze() public {
        vm.prank(ADMIN);
        v4().freeze(ALICE);

        bytes32 role = v4().ROLE_UNFREEZE();
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        v4().unfreeze(ALICE);
    }

    /// @notice A freezer-only key (e.g. a fast monitoring bot) cannot release a frozen account
    function test_freezer_cannot_unfreeze() public {
        bytes32 freezer = v4().ROLE_FREEZE();
        bytes32 unfreezer = v4().ROLE_UNFREEZE();
        vm.prank(ADMIN);
        v4().grantRole(freezer, CHARLIE);

        vm.prank(CHARLIE);
        v4().freeze(ALICE);

        vm.prank(CHARLIE);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, CHARLIE, unfreezer));
        v4().unfreeze(ALICE);
        assertTrue(v4().isFrozen(ALICE), "Still frozen");
    }

    /// @notice An unfreezer-only key cannot freeze
    function test_unfreezer_cannot_freeze() public {
        bytes32 freezer = v4().ROLE_FREEZE();
        bytes32 unfreezer = v4().ROLE_UNFREEZE();
        vm.prank(ADMIN);
        v4().grantRole(unfreezer, CHARLIE);

        vm.prank(CHARLIE);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, CHARLIE, freezer));
        v4().freeze(ALICE);

        vm.prank(ADMIN);
        v4().freeze(ALICE);
        vm.prank(CHARLIE);
        v4().unfreeze(ALICE);
        assertFalse(v4().isFrozen(ALICE), "Unfrozen by the unfreezer");
    }

    /// @notice An unfreezer cannot hand out its own role
    function test_unfreezer_cannot_grant_unfreezer() public {
        bytes32 unfreezer = v4().ROLE_UNFREEZE();
        bytes32 defaultAdmin = v4().DEFAULT_ADMIN_ROLE();
        vm.prank(ADMIN);
        v4().grantRole(unfreezer, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ALICE, defaultAdmin));
        v4().grantRole(unfreezer, BOB);
    }

    function test_only_seizer_can_seizeBalance() public {
        _depositAs(ALICE, DEPOSIT);
        vm.prank(ADMIN);
        v4().freeze(ALICE);

        bytes32 role = v4().ROLE_SEIZE();
        vm.startPrank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        v4().seizeBalance(ALICE, BOB);
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
        emit FreezableUpgradeable.Frozen(ALICE);
        v4().freeze(ALICE);
        assertTrue(v4().isFrozen(ALICE));

        vm.expectRevert(CustomErrors.NoChange.selector);
        v4().freeze(ALICE);

        vm.expectEmit(true, false, false, true, address(stakedMonad));
        emit FreezableUpgradeable.Unfrozen(ALICE);
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
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, ALICE));
        stakedMonad.transfer(BOB, shares);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, ALICE));
        stakedMonad.transfer(ALICE, 1);

        // Deposits cannot mint to a frozen receiver either
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, ALICE));
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
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, CHARLIE));
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
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, CHARLIE));
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
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, ALICE));
        stakedMonad.approve(BOB, 1);
    }

    /// @notice The protocol pause no longer touches holder-to-holder transfers (V3 behaviour)
    function test_protocol_pause_does_not_block_transfers() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);

        vm.prank(ADMIN);
        v4().pauseProtocol();

        vm.prank(ALICE);
        stakedMonad.transfer(BOB, shares / 2);
        assertEq(stakedMonad.balanceOf(BOB), shares / 2, "transfer works while the protocol is paused");

        vm.prank(ALICE);
        stakedMonad.approve(CHARLIE, shares / 2);
        vm.prank(CHARLIE);
        stakedMonad.transferFrom(ALICE, BOB, shares / 2);
        assertEq(stakedMonad.balanceOf(BOB), shares, "transferFrom works while the protocol is paused");

        // Protocol entrypoints are still paused
        vm.prank(ALICE);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stakedMonad.deposit{value: DEPOSIT}(0, ALICE);
    }

    function test_protocolPaused_matches_paused() public {
        assertFalse(v4().protocolPaused());

        vm.startPrank(ADMIN);
        v4().pauseProtocol();
        assertTrue(v4().protocolPaused());
        assertTrue(stakedMonad.paused());
        assertFalse(v4().transfersPaused(), "Transfer pause is independent");

        v4().unpauseProtocol();
        assertFalse(v4().protocolPaused());
        assertFalse(stakedMonad.paused());
    }

    function test_pauseTransfers_blocks_transfer_and_transferFrom() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);

        vm.prank(ADMIN);
        vm.expectEmit(false, false, false, true, address(stakedMonad));
        emit TransferPausableUpgradeable.TransfersPaused(ADMIN);
        v4().pauseTransfers();
        assertTrue(v4().transfersPaused());
        assertFalse(v4().protocolPaused(), "Protocol pause is independent");

        // Approvals still work, as with OpenZeppelin's ERC20Pausable
        vm.prank(ALICE);
        stakedMonad.approve(CHARLIE, shares);

        vm.prank(ALICE);
        vm.expectRevert(TransferPausableUpgradeable.EnforcedTransferPause.selector);
        stakedMonad.transfer(BOB, shares);

        vm.prank(CHARLIE);
        vm.expectRevert(TransferPausableUpgradeable.EnforcedTransferPause.selector);
        stakedMonad.transferFrom(ALICE, BOB, shares);

        vm.prank(ADMIN);
        vm.expectEmit(false, false, false, true, address(stakedMonad));
        emit TransferPausableUpgradeable.TransfersUnpaused(ADMIN);
        v4().unpauseTransfers();
        assertFalse(v4().transfersPaused());

        vm.prank(ALICE);
        stakedMonad.transfer(BOB, shares / 2);
        vm.prank(CHARLIE);
        stakedMonad.transferFrom(ALICE, BOB, shares / 2);
        assertEq(stakedMonad.balanceOf(BOB), shares);
    }

    /// @notice Only holder-to-holder movement is halted; every protocol flow keeps working
    function test_pauseTransfers_leaves_protocol_running() public {
        _depositAs(ALICE, DEPOSIT);

        vm.prank(ADMIN);
        v4().pauseTransfers();

        // Deposit (mint)
        uint96 shares = _depositAs(BOB, DEPOSIT);
        assertGt(shares, 0, "Deposit works");

        // Request and cancel an unlock (transfers to and from the contract)
        vm.startPrank(BOB);
        stakedMonad.requestUnlock(shares, 0);
        stakedMonad.cancelUnlockRequest(0);
        assertEq(stakedMonad.balanceOf(BOB), shares, "Cancel returns the shares");
        StakedMonadV4.UnlockRequest memory request;
        stakedMonad.requestUnlock(shares, 0);
        request = v4().getAllUserUnlockRequests(BOB)[0];
        vm.stopPrank();

        // Submit the batch (burn) and redeem
        _submitBatchAndPassWithdrawDelay();
        uint256 balanceBefore = BOB.balance;
        vm.prank(BOB);
        stakedMonad.redeem(0, BOB);
        assertEq(BOB.balance - balanceBefore, request.spotValue, "Redeem works");

        // Claim protocol fees (mint and transfer out of the contract)
        vm.warp(block.timestamp + 30 days);
        vm.prank(ADMIN);
        stakedMonad.claimProtocolFees(RECOVERY);
        assertGt(stakedMonad.balanceOf(RECOVERY), 0, "Fee claim works");
    }

    function test_pauseTransfers_and_unpauseTransfers_revert_on_no_change() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(CustomErrors.NoChange.selector);
        v4().unpauseTransfers();

        v4().pauseTransfers();
        vm.expectRevert(CustomErrors.NoChange.selector);
        v4().pauseTransfers();
    }

    function test_only_pauser_can_pause_transfers() public {
        bytes32 pauser = v4().ROLE_PAUSE();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ALICE, pauser));
        v4().pauseTransfers();
    }

    /// @notice A pauser-only key can halt transfers but not resume them
    function test_pauser_cannot_unpause_transfers() public {
        bytes32 pauser = v4().ROLE_PAUSE();
        bytes32 unpauser = v4().ROLE_UNPAUSE();
        vm.prank(ADMIN);
        v4().grantRole(pauser, CHARLIE);

        vm.startPrank(CHARLIE);
        v4().pauseTransfers();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, CHARLIE, unpauser));
        v4().unpauseTransfers();
        assertTrue(v4().transfersPaused(), "Still paused");
    }

    /// @notice An unpauser-only key can resume transfers but not halt them
    function test_unpauser_cannot_pause_transfers() public {
        bytes32 pauser = v4().ROLE_PAUSE();
        bytes32 unpauser = v4().ROLE_UNPAUSE();
        vm.prank(ADMIN);
        v4().grantRole(unpauser, CHARLIE);

        vm.prank(CHARLIE);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, CHARLIE, pauser));
        v4().pauseTransfers();

        vm.prank(ADMIN);
        v4().pauseTransfers();
        vm.prank(CHARLIE);
        v4().unpauseTransfers();
        assertFalse(v4().transfersPaused(), "Unpaused by the unpauser");
    }

    function test_pauseProtocolAndTransfers_sets_both_pauses() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);

        vm.prank(ADMIN);
        vm.expectEmit(false, false, false, true, address(stakedMonad));
        emit PausableUpgradeable.Paused(ADMIN);
        vm.expectEmit(false, false, false, true, address(stakedMonad));
        emit TransferPausableUpgradeable.TransfersPaused(ADMIN);
        v4().pauseProtocolAndTransfers();

        assertTrue(v4().protocolPaused(), "Protocol paused");
        assertTrue(v4().transfersPaused(), "Transfers paused");

        vm.startPrank(ALICE);
        vm.expectRevert(TransferPausableUpgradeable.EnforcedTransferPause.selector);
        stakedMonad.transfer(BOB, shares);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stakedMonad.requestUnlock(shares, 0);
        vm.stopPrank();
    }

    /// @notice pauseProtocolAndTransfers completes a half-paused state instead of reverting
    function test_pauseProtocolAndTransfers_sets_whichever_is_missing() public {
        vm.startPrank(ADMIN);
        v4().pauseProtocol();
        v4().pauseProtocolAndTransfers();
        assertTrue(v4().transfersPaused(), "Transfer pause added on top of protocol pause");

        v4().unpauseProtocol();
        v4().pauseProtocolAndTransfers();
        assertTrue(stakedMonad.paused(), "Protocol pause added on top of transfer pause");

        vm.expectRevert(CustomErrors.NoChange.selector);
        v4().pauseProtocolAndTransfers();
    }

    /// @notice pauseProtocolAndTransfers needs only ROLE_PAUSE; resuming still needs ROLE_UNPAUSE for each pause
    function test_pauseProtocolAndTransfers_roles() public {
        bytes32 pauser = v4().ROLE_PAUSE();
        bytes32 unpauser = v4().ROLE_UNPAUSE();
        vm.startPrank(ADMIN);
        v4().grantRole(pauser, CHARLIE);
        v4().grantRole(unpauser, BOB);
        vm.stopPrank();

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, pauser));
        v4().pauseProtocolAndTransfers();

        vm.startPrank(CHARLIE);
        v4().pauseProtocolAndTransfers();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, CHARLIE, unpauser));
        v4().unpauseProtocol();
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, CHARLIE, unpauser));
        v4().unpauseTransfers();
        vm.stopPrank();

        vm.startPrank(BOB);
        v4().unpauseProtocol();
        v4().unpauseTransfers();
        assertFalse(stakedMonad.paused());
        assertFalse(v4().transfersPaused());
    }

    function test_frozen_account_cannot_request_or_cancel_unlock() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);

        vm.prank(ALICE);
        stakedMonad.requestUnlock(shares / 2, 0);

        vm.prank(ADMIN);
        v4().freeze(ALICE);

        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, ALICE));
        stakedMonad.requestUnlock(shares / 2, 0);

        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, ALICE));
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
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, ALICE));
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
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, CHARLIE));
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
        v4().seizeBalance(ALICE, RECOVERY);

        assertEq(stakedMonad.balanceOf(ALICE), 0, "Frozen account emptied");
        assertEq(stakedMonad.balanceOf(RECOVERY), shares, "Recovery receives the shares");
        assertEq(stakedMonad.totalSupply(), supplyBefore, "Seizing must not burn");
        assertEq(stakedMonad.convertToAssets(1 ether), ratioBefore, "Redemption ratio unchanged");
        assertTrue(v4().isFrozen(ALICE), "Account stays frozen");
    }

    function test_seize_requires_frozen_account() public {
        _depositAs(ALICE, DEPOSIT);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountNotFrozen.selector, ALICE));
        v4().seizeBalance(ALICE, RECOVERY);
    }

    function test_seize_rejects_bad_recipients() public {
        _depositAs(ALICE, DEPOSIT);
        vm.startPrank(ADMIN);
        v4().freeze(ALICE);
        v4().freeze(CHARLIE);

        vm.expectRevert(StakedMonadV4.InvalidAccount.selector);
        v4().seizeBalance(ALICE, address(0));
        vm.expectRevert(StakedMonadV4.InvalidAccount.selector);
        v4().seizeBalance(ALICE, address(stakedMonad));
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, ALICE));
        v4().seizeBalance(ALICE, ALICE);
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, CHARLIE));
        v4().seizeBalance(ALICE, CHARLIE);
    }

    function test_seize_reverts_on_empty_balance() public {
        vm.startPrank(ADMIN);
        v4().freeze(ALICE);
        vm.expectRevert(CustomErrors.NoChange.selector);
        v4().seizeBalance(ALICE, RECOVERY);
    }

    function test_freeze_and_seize_work_while_paused() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);

        vm.startPrank(ADMIN);
        v4().pauseProtocol();
        v4().freeze(ALICE);
        v4().seizeBalance(ALICE, RECOVERY);
        v4().unfreeze(ALICE);
        assertEq(stakedMonad.balanceOf(RECOVERY), shares);
    }

    function test_freeze_and_seize_work_while_all_paused() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);
        vm.prank(ALICE);
        stakedMonad.requestUnlock(shares / 2, 0);
        uint96 escrowed = v4().getAllUserUnlockRequests(ALICE)[0].shares;

        vm.startPrank(ADMIN);
        v4().pauseProtocolAndTransfers();
        v4().freeze(ALICE);
        v4().seizeBalance(ALICE, RECOVERY);
        v4().seizeUnlockRequest(ALICE, 0, RECOVERY);
        v4().unfreeze(ALICE);
        assertEq(stakedMonad.balanceOf(RECOVERY), shares, "Balance and escrowed unlock both recovered");
        assertEq(stakedMonad.balanceOf(ALICE), 0);
        assertGt(escrowed, 0);
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
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, ALICE));
        stakedMonad.redeem(0, ALICE);
    }

    function test_seizeUnlockRequest_requires_frozen_and_valid_recipient() public {
        uint96 shares = _depositAs(ALICE, DEPOSIT);
        vm.prank(ALICE);
        stakedMonad.requestUnlock(shares, 0);

        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountNotFrozen.selector, ALICE));
        v4().seizeUnlockRequest(ALICE, 0, RECOVERY);

        v4().freeze(ALICE);
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, ALICE));
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
