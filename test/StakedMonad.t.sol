// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, stdError, console} from "forge-std/src/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakedMonad, Registry, Staker, CustomErrors, PausableUpgradeable, IAccessControl} from "../src/StakedMonad.sol";
import {StakerFaker} from "./StakerFaker.sol";

contract StakedMonadTest is Test, StakerFaker {
    StakedMonad public stakedMonad;

    address payable public ADMIN = payable(vm.addr(100));
    address payable public ALICE = payable(vm.addr(101));
    address payable public BOB = payable(vm.addr(102));
    address payable public CHARLIE = payable(vm.addr(103));

    uint256 public constant FUNDING_AMOUNT = 1_000_000 ether;
    uint256 public constant MINIMUM_DEPOSIT = 0.00000001 ether;
    uint16 public constant BIPS = 100_00;
    uint8 public constant WITHDRAW_DELAY_EPOCHS = 7;

    function setUp() public {
        vm.label(ADMIN, "//ADMIN");
        vm.label(ALICE, "//Alice");
        vm.label(BOB, "//Bob");
        vm.label(CHARLIE, "//Charlie");

        vm.deal(ADMIN, FUNDING_AMOUNT);
        vm.deal(ALICE, FUNDING_AMOUNT);
        vm.deal(BOB, FUNDING_AMOUNT);
        vm.deal(CHARLIE, FUNDING_AMOUNT);

        StakedMonad stakedMonadImpl = new StakedMonad();
        ERC1967Proxy stakedMonadProxy = new ERC1967Proxy{value: 0.01 ether}(
            address(stakedMonadImpl),
            abi.encodeCall(StakedMonad.initialize, (ADMIN))
        );
        stakedMonad = StakedMonad(payable(stakedMonadProxy));
    }

    function test_roles_self_managed() public {
        bytes32[] memory roles = new bytes32[](4);
        roles[0] = stakedMonad.ROLE_FEE_SETTER();
        roles[1] = stakedMonad.ROLE_FEE_CLAIMER();
        roles[2] = stakedMonad.ROLE_FEE_EXEMPTION();
        roles[3] = stakedMonad.ROLE_UPGRADE();

        for (uint256 i; i < roles.length; ++i) {
            bytes32 role = roles[i];
            vm.startPrank(ADMIN);
            assertTrue(stakedMonad.hasRole(role, ADMIN), "Admin should have role by default");
            stakedMonad.grantRole(role, ALICE);
            assertTrue(stakedMonad.hasRole(role, ALICE), "Admin should be able to grant role");
            vm.startPrank(ALICE);
            stakedMonad.grantRole(role, BOB);
            assertTrue(stakedMonad.hasRole(role, BOB), "Role holder should be able to grant role");
        }
    }

    function test_deposit_amount_must_be_reasonable() public {
        uint256 maxDeposit = uint256(type(uint96).max);
        vm.deal(ADMIN, maxDeposit + 1 wei);
        vm.startPrank(ADMIN);

        // Deposit more than uint96
        vm.expectRevert(CustomErrors.DepositOverflow.selector);
        stakedMonad.deposit{value: maxDeposit + 1 wei}(0, ADMIN);
    }

    function test_deposit_reverts_when_minimum_shares_is_not_minted(uint96 depositAmount) public {
        vm.assume(depositAmount > 0);
        vm.assume(depositAmount < MINIMUM_DEPOSIT);
        vm.startPrank(ALICE);
        uint96 expectedShares = depositAmount; // 1:1 ratio
        vm.expectRevert(CustomErrors.MinimumDeposit.selector);
        stakedMonad.deposit{value: depositAmount}(expectedShares + 1, ALICE);
    }

    function test_deposit_1_nodes(uint96 depositAmount) public {
        vm.assume(depositAmount >= MINIMUM_DEPOSIT);
        vm.assume(depositAmount < FUNDING_AMOUNT);

        // Add 1 node
        vm.startPrank(ADMIN);
        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        // Set weights
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Cannot deposit when paused
        stakedMonad.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stakedMonad.deposit{value: depositAmount}(0, ADMIN);
        stakedMonad.unpause();

        vm.startPrank(ALICE);
        uint256 sharesAlice = stakedMonad.deposit{value: depositAmount}(0, ALICE);

        assertEq(stakedMonad.balanceOf(ALICE), sharesAlice, "Deposit() should return the shares minted");
        assertEq(stakedMonad.totalPooled(), depositAmount);
        assertEq(stakedMonad.totalPooled(), stakedMonad.totalShares(), "1:1 redemption ratio");
        assertEq(stakedMonad.getMintableProtocolShares(), 0);

        vm.warp(vm.getBlockTimestamp() + 365 days);

        // Initial management fee applied over one year
        uint256 protocolShares = sharesAlice * 2_00 / BIPS;
        assertEq(stakedMonad.getMintableProtocolShares(), protocolShares);
        assertEq(stakedMonad.totalShares(), sharesAlice + protocolShares);
    }

    function test_deposit_2_nodes(uint96 depositAmount) public {
        vm.assume(depositAmount >= MINIMUM_DEPOSIT);
        vm.assume(depositAmount < FUNDING_AMOUNT);

        // Add 2 nodes
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        uint64 nodeId2 = 2;
        stakedMonad.addNode(nodeId1);
        stakedMonad.addNode(nodeId2);

        // Set weights
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 10_000, isIncreasing: true});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 10_000, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Cannot deposit when paused
        stakedMonad.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stakedMonad.deposit{value: depositAmount}(0, ALICE);
        stakedMonad.unpause();

        vm.startPrank(ALICE);
        uint96 sharesAlice = stakedMonad.deposit{value: depositAmount}(0, ALICE);

        assertEq(stakedMonad.balanceOf(ALICE), sharesAlice, "Deposit() should return the shares minted");
        assertEq(stakedMonad.totalPooled(), depositAmount);
        assertEq(stakedMonad.totalPooled(), stakedMonad.totalShares(), "1:1 redemption ratio");
        assertEq(stakedMonad.getMintableProtocolShares(), 0);

        vm.warp(vm.getBlockTimestamp() + 365 days);

        // Initial management fee applied over one year
        uint256 protocolShares = sharesAlice * 2_00 / BIPS;
        assertEq(stakedMonad.getMintableProtocolShares(), protocolShares);
        assertEq(stakedMonad.totalShares(), sharesAlice + protocolShares);
    }

    function test_unstake_1_nodes_1_requests(uint96 depositAmount) public {
        vm.assume(depositAmount >= MINIMUM_DEPOSIT);
        vm.assume(depositAmount < FUNDING_AMOUNT);

        // Add 1 node
        vm.startPrank(ADMIN);
        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        // Set weight to 100
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Alice deposits
        vm.startPrank(ALICE);
        uint96 shares = stakedMonad.deposit{value: depositAmount}(0, ALICE);

        // Alice requests unlock
        stakedMonad.requestUnlock(shares, 0);
        uint96 redemptionQuote = stakedMonad.getAllUserUnlockRequests(ALICE)[0].spotValue;

        // Cannot redeem before batch is submitted
        vm.expectRevert(CustomErrors.BatchNotSubmitted.selector);
        stakedMonad.redeem(0, ALICE);

        // Submit batch (#1) in epoch 1
        uint64 submissionEpoch = 1;
        StakerFaker.mockGetEpoch(submissionEpoch, false);
        StakerFaker.mockDelegate(nodeId, true);
        stakedMonad.submitBatch();

        // Cannot redeem before withdraw delay passes
        vm.expectRevert(CustomErrors.WithdrawDelay.selector);
        stakedMonad.redeem(0, ALICE);

        // Increase current epoch by activation epoch and withdraw delay
        StakerFaker.mockGetEpoch(submissionEpoch + 1 + WITHDRAW_DELAY_EPOCHS, false);

        // TODO: On the real network, calling `sweep(...)` will likely be needed

        // Cannot redeem when paused
        vm.startPrank(ADMIN);
        stakedMonad.pause();
        vm.startPrank(ALICE);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stakedMonad.redeem(0, ALICE);
        vm.startPrank(ADMIN);
        stakedMonad.unpause();
        vm.startPrank(ALICE);

        // Alice successfully redeems
        uint256 balanceBefore = ALICE.balance;
        stakedMonad.redeem(0, ALICE);
        uint256 redeemAmount = ALICE.balance - balanceBefore;

        assertEq(redeemAmount, redemptionQuote);
    }

    function test_unstake_1_nodes_2_requests(uint96 depositAmount) public {
        vm.assume(depositAmount >= MINIMUM_DEPOSIT);
        vm.assume(depositAmount < FUNDING_AMOUNT);

        // Add 1 node
        vm.startPrank(ADMIN);
        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        // Set weight to 100
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Alice deposits
        vm.startPrank(ALICE);
        uint96 shares = stakedMonad.deposit{value: depositAmount}(0, ALICE);

        // Alice requests two unlocks
        uint96 unstake1 = shares * 25_00 / BIPS; // 25%
        uint96 unstake2 = shares - unstake1; // 75%
        stakedMonad.requestUnlock(unstake1, 0);
        stakedMonad.requestUnlock(unstake2, 0);
        uint96 redemptionQuote1 = stakedMonad.getAllUserUnlockRequests(ALICE)[0].spotValue;
        uint96 redemptionQuote2 = stakedMonad.getAllUserUnlockRequests(ALICE)[1].spotValue;

        // Submit batch (#1) in epoch 1
        uint64 submissionEpoch = 1;
        StakerFaker.mockGetEpoch(submissionEpoch, false);
        StakerFaker.mockDelegate(nodeId, true);
        stakedMonad.submitBatch();

        // Increase current epoch by activation epoch and withdraw delay
        StakerFaker.mockGetEpoch(submissionEpoch + 1 + WITHDRAW_DELAY_EPOCHS, false);

        // TODO: On the real network, calling `sweep(...)` will likely be needed

        // Alice redeems first request
        uint256 aliceBalanceBefore = ALICE.balance;
        uint256 redemptionResult = stakedMonad.redeem(0, ALICE);
        uint256 aliceBalanceIncrease = ALICE.balance - aliceBalanceBefore;
        assertEq(aliceBalanceIncrease, redemptionResult);
        assertEq(aliceBalanceIncrease, redemptionQuote1);

        // Alice redeems second request to Bob
        uint256 bobBalanceBefore = BOB.balance;
        redemptionResult = stakedMonad.redeem(0, BOB);
        uint256 bobBalanceIncrease = BOB.balance - bobBalanceBefore;
        assertEq(bobBalanceIncrease, redemptionResult);
        assertEq(bobBalanceIncrease, redemptionQuote2);
    }

    function test_unstake_2_nodes_2_requests(uint96 depositAmount) public {
        vm.assume(depositAmount >= MINIMUM_DEPOSIT);
        vm.assume(depositAmount < FUNDING_AMOUNT);

        // Add 2 nodes
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        uint64 nodeId2 = 2;
        stakedMonad.addNode(nodeId1);
        stakedMonad.addNode(nodeId2);

        // Set weights to 25,000 / 75,000
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 25_000, isIncreasing: true});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 75_000, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Alice deposits
        vm.startPrank(ALICE);
        uint96 shares = stakedMonad.deposit{value: depositAmount}(0, ALICE);

        // Alice requests two unlocks
        uint96 unstake1 = shares * 50_00 / BIPS; // 50%
        uint96 unstake2 = shares * 40_00 / BIPS; // 40%
        stakedMonad.requestUnlock(unstake1, 0);
        stakedMonad.requestUnlock(unstake2, 0);
        uint96 redemptionQuote1 = stakedMonad.getAllUserUnlockRequests(ALICE)[0].spotValue;
        uint96 redemptionQuote2 = stakedMonad.getAllUserUnlockRequests(ALICE)[1].spotValue;

        // Submit batch (#1) in epoch 1
        uint64 submissionEpoch = 1;
        StakerFaker.mockGetEpoch(submissionEpoch, false);
        StakerFaker.mockDelegate(nodeId1, true);
        StakerFaker.mockDelegate(nodeId2, true);
        stakedMonad.submitBatch();

        // Increase current epoch by activation epoch and withdraw delay
        StakerFaker.mockGetEpoch(submissionEpoch + 1 + WITHDRAW_DELAY_EPOCHS, false);

        // TODO: On the real network, calling `sweep(...)` will likely be needed

        // Alice redeems first request
        uint256 aliceBalanceBefore = ALICE.balance;
        uint256 redemptionResult = stakedMonad.redeem(0, ALICE);
        uint256 aliceBalanceIncrease = ALICE.balance - aliceBalanceBefore;
        assertEq(aliceBalanceIncrease, redemptionResult);
        assertEq(aliceBalanceIncrease, redemptionQuote1);

        // Alice redeems second request to Bob
        uint256 bobBalanceBefore = BOB.balance;
        redemptionResult = stakedMonad.redeem(0, BOB);
        uint256 bobBalanceIncrease = BOB.balance - bobBalanceBefore;
        assertEq(bobBalanceIncrease, redemptionResult);
        assertEq(bobBalanceIncrease, redemptionQuote2);
    }

    function test_cancel_unlock_with_exit_fee(uint96 depositAmount) public {
        vm.assume(depositAmount >= MINIMUM_DEPOSIT);
        vm.assume(depositAmount < FUNDING_AMOUNT);

        // Add 1 node
        vm.startPrank(ADMIN);
        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        // Ensure exit fee exists
        assertTrue(stakedMonad.getExitFeeBips() > 0, "Default exit fee is expected");

        // Increase weight to 10,000
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 10_000, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Alice deposits
        vm.startPrank(ALICE);
        uint96 shares = stakedMonad.deposit{value: depositAmount}(0, ALICE);

        assertEq(stakedMonad.getAllUserUnlockRequests(ALICE).length, 0);

        // Alice makes an unlock request with all of her shares
        stakedMonad.requestUnlock(shares, 0);

        assertEq(stakedMonad.balanceOf(address(stakedMonad)), shares, "Shares being unlocked should be in escrow");
        assertEq(stakedMonad.balanceOf(ALICE), 0, "Alice should no longer be holding shares");

        StakedMonad.UnlockRequest[] memory aliceUnlockRequests = stakedMonad.getAllUserUnlockRequests(ALICE);
        assertEq(aliceUnlockRequests.length, 1);
        assertEq(aliceUnlockRequests[0].shares, shares);

        // Cannot cancel invalid index
        vm.expectRevert(stdError.indexOOBError);
        stakedMonad.cancelUnlockRequest(404);

        // Cannot cancel unlock when paused
        vm.startPrank(ADMIN);
        stakedMonad.pause();
        vm.startPrank(ALICE);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        stakedMonad.cancelUnlockRequest(0);
        vm.startPrank(ADMIN);
        stakedMonad.unpause();
        vm.startPrank(ALICE);

        // Successfully cancel unlock request
        stakedMonad.cancelUnlockRequest(0);

        assertEq(stakedMonad.balanceOf(address(stakedMonad)), 0, "No shares should still be in escrow");
        assertEq(stakedMonad.balanceOf(ALICE), shares, "Alice should be holding all her shares again");
    }

    function test_cancel_unlock_with_exit_fee_that_changed_after_request(uint96 depositAmount, uint16 newExitFee) public {
        vm.assume(depositAmount >= MINIMUM_DEPOSIT);
        vm.assume(depositAmount < FUNDING_AMOUNT);
        vm.assume(newExitFee > 0);
        vm.assume(newExitFee <= 50);

        // Add 1 node
        vm.startPrank(ADMIN);
        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        // Ensure exit fee exists and validate new exit fee to apply later
        uint16 defaultExitFee = stakedMonad.getExitFeeBips();
        assertTrue(defaultExitFee > 0, "Default exit fee is expected");
        vm.assume(newExitFee != defaultExitFee);

        // Increase weight to 10,000
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 10_000, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Alice deposits
        vm.startPrank(ALICE);
        uint96 shares = stakedMonad.deposit{value: depositAmount}(0, ALICE);

        // Alice makes an unlock request with all of her shares
        stakedMonad.requestUnlock(shares, 0);

        // Exit fee is changed
        vm.startPrank(ADMIN);
        stakedMonad.setExitFee(newExitFee);

        // Alice successfully cancels unlock request
        vm.startPrank(ALICE);
        stakedMonad.cancelUnlockRequest(0);

        assertEq(stakedMonad.balanceOf(address(stakedMonad)), 0, "No shares should still be in escrow");
        assertEq(stakedMonad.balanceOf(ALICE), shares, "Alice should be holding all her shares again");
    }

    function test_batch_delay_when_not_in_epoch_delay_period() public {
        // Add 1 node
        vm.startPrank(ADMIN);
        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        // Set weight to 100
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Create ingress batch with 100 MON deposit and 0 unlocks
        vm.startPrank(ALICE);
        stakedMonad.deposit{value: 100 ether}(0, ALICE);

        // Batch is submitted in beginning of epoch 1 (not delay period)
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId, true);
        stakedMonad.submitBatch();

        // Create ingress batch with 1 MON deposit
        stakedMonad.deposit{value: 1 ether}(0, ALICE);

        vm.expectRevert(CustomErrors.MinimumBatchDelay.selector);
        stakedMonad.submitBatch();

        // Can submit batch in 1 more epoch
        StakerFaker.mockGetEpoch(1 + 1, false);
        stakedMonad.submitBatch();
    }

    function test_batch_delay_when_in_epoch_delay_period() public {
        // Add 1 node
        vm.startPrank(ADMIN);
        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        // Set weight to 100
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Create ingress batch with 100 MON deposit and 0 unlocks
        vm.startPrank(ALICE);
        stakedMonad.deposit{value: 100 ether}(0, ALICE);

        // Batch is submitted in end of epoch 1 (delay period)
        StakerFaker.mockGetEpoch(1, true);
        StakerFaker.mockDelegate(nodeId, true);
        stakedMonad.submitBatch();

        // Create ingress batch with 1 MON deposit
        stakedMonad.deposit{value: 1 ether}(0, ALICE);

        // Cannot submit batch again in same epoch
        vm.expectRevert(CustomErrors.MinimumBatchDelay.selector);
        stakedMonad.submitBatch();

        // Cannot submit batch again in next epoch
        StakerFaker.mockGetEpoch(1 + 1, false);
        vm.expectRevert(CustomErrors.MinimumBatchDelay.selector);
        stakedMonad.submitBatch();

        // Can submit batch in 2 more epochs
        StakerFaker.mockGetEpoch(1 + 2, false);
        stakedMonad.submitBatch();
    }

    function test_batch_delay_with_neutral_batch() public {
        // Add 1 node
        vm.startPrank(ADMIN);
        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        // Disable exit fee for easier creation of neutral batch
        stakedMonad.setExitFee(0);

        // Set weight to 100
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Create neutral batch with 1 MON deposit and 1 MON worth of unlock
        vm.startPrank(ALICE);
        uint96 shares = stakedMonad.deposit{value: 1 ether}(0, ALICE);
        stakedMonad.requestUnlock(shares, 0);

        // Neutral batch is submitted in epoch 1
        StakerFaker.mockGetEpoch(1, false);
        stakedMonad.submitBatch();

        // Create ingress batch with 1 MON deposit
        stakedMonad.deposit{value: 1 ether}(0, ALICE);

        // Can submit another batch in same epoch
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId, true);
        stakedMonad.submitBatch();
    }

    function test_batch_cannot_be_empty() public {
        // Add 1 node
        vm.startPrank(ADMIN);
        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        // Disable exit fee for easier creation of neutral batch
        stakedMonad.setExitFee(0);

        // Set weight to 100
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Attempt to submit neutral batch with 0 MON deposit and 0 MON worth of unlock
        StakerFaker.mockGetEpoch(1, false);
        vm.expectRevert(CustomErrors.EmptyBatch.selector);
        stakedMonad.submitBatch();
    }

    function test_claimProtocolFees_must_have_role() public {
        bytes32 role = stakedMonad.ROLE_FEE_CLAIMER();

        // Bob (without fee claimer role) cannot call
        vm.startPrank(BOB);
        assertFalse(stakedMonad.hasRole(role, BOB), "Bob should not have role");
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        stakedMonad.claimProtocolFees(BOB);

        // Admin (with fee claimer role) can call
        vm.startPrank(ADMIN);
        assertTrue(stakedMonad.hasRole(role, ADMIN), "Admin should have role");
        stakedMonad.claimProtocolFees(BOB);
    }

    function test_claimProtocolFees_with_management_fee() public {
        assertEq(stakedMonad.getManagementFeeBips(), 2_00, "Management fee should be 2.00%");

        // Add 1 node
        vm.startPrank(ADMIN);
        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        // Generate fees on 100 MON over 365 days
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);
        stakedMonad.deposit{value: 100 ether}(0, ADMIN);
        vm.warp(vm.getBlockTimestamp() + 365 days);

        // Claim protocol fees triggering a mint
        uint256 sharesBeforeClaim = stakedMonad.balanceOf(BOB);
        stakedMonad.claimProtocolFees(BOB);
        uint256 sharesClaimed = stakedMonad.balanceOf(BOB) - sharesBeforeClaim;

        assertEq(sharesClaimed, 2e18, "Should earn a 2% annual fee on 100 MON after 365 days");
    }

    function test_claimProtocolFees_with_management_fee_and_exit_fee() public {
        assertEq(stakedMonad.getManagementFeeBips(), 2_00, "Management fee should be 2.00%");
        assertEq(stakedMonad.getExitFeeBips(), 5, "Exit fee should be 0.05%");

        // Add 1 node
        vm.startPrank(ADMIN);
        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        // Generate management fees on 100 MON over 365 days
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);
        stakedMonad.deposit{value: 100 ether}(0, ADMIN);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        uint96 managementFeeShares = 100e18 * 2_00 / BIPS;

        // Generate exit fees by unlocking 10 shares
        stakedMonad.requestUnlock(10e18, 0);
        StakerFaker.mockGetEpoch(1, true);
        StakerFaker.mockDelegate(nodeId, true);
        stakedMonad.submitBatch();
        uint96 exitFeeShares = 10e18 * 5 / BIPS;

        // Claim protocol fees triggering a mint
        uint256 sharesBeforeClaim = stakedMonad.balanceOf(BOB);
        stakedMonad.claimProtocolFees(BOB);
        uint256 sharesClaimed = stakedMonad.balanceOf(BOB) - sharesBeforeClaim;

        assertEq(sharesClaimed, managementFeeShares + exitFeeShares, "Should claim both management fees and exit fees");
    }

    function test_setExitFee(uint16 newFee) public {
        uint16 maxFee = 50;
        uint16 defaultFee = stakedMonad.getExitFeeBips();

        vm.assume(newFee != defaultFee);
        vm.assume(newFee <= maxFee);

        vm.startPrank(ADMIN);
        stakedMonad.setExitFee(newFee);
        assertEq(stakedMonad.getExitFeeBips(), newFee);

        // Fee cannot be set to the same value
        vm.expectRevert(CustomErrors.NoChange.selector);
        stakedMonad.setExitFee(newFee);

        // Fee cannot be excessive
        vm.expectRevert(CustomErrors.FeeTooLarge.selector);
        stakedMonad.setExitFee(maxFee + 1);
    }

    function test_setManagementFee(uint16 newFee) public {
        uint16 maxFee = 2_00;
        uint16 defaultFee = stakedMonad.getManagementFeeBips();

        vm.assume(newFee != defaultFee);
        vm.assume(newFee <= maxFee);

        vm.startPrank(ADMIN);
        stakedMonad.setManagementFee(newFee);
        assertEq(stakedMonad.getManagementFeeBips(), newFee);

        // Fee cannot be set to the same value
        vm.expectRevert(CustomErrors.NoChange.selector);
        stakedMonad.setManagementFee(newFee);

        // Fee cannot be excessive
        vm.expectRevert(CustomErrors.FeeTooLarge.selector);
        stakedMonad.setManagementFee(maxFee + 1);
    }

    function test_pause_and_unpause_management() public {
        assertFalse(stakedMonad.paused());

        // Non-admin (Bob) cannot pause
        vm.startPrank(BOB);
        assertFalse(stakedMonad.hasRole(stakedMonad.ROLE_PAUSE(), BOB));
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            BOB,
            stakedMonad.ROLE_PAUSE()
        ));
        stakedMonad.pause();

        // Admin can pause
        assertTrue(stakedMonad.hasRole(stakedMonad.ROLE_PAUSE(), ADMIN));
        vm.startPrank(ADMIN);
        stakedMonad.pause();
        assertTrue(stakedMonad.paused());
    }

    function test_bonding_with_underallocation() public {
        uint96 depositAmount = 10 ether;

        // Add 2 nodes
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        uint64 nodeId2 = 2;
        stakedMonad.addNode(nodeId1);
        stakedMonad.addNode(nodeId2);

        // Set weights to 60% / 40%
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 600e18, isIncreasing: true});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 400e18, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Deposit
        stakedMonad.deposit{value: depositAmount}(0, ADMIN);

        // Submit batch (#1) to process deposit
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId1, true);
        StakerFaker.mockDelegate(nodeId2, true);
        stakedMonad.submitBatch();

        Registry.Node memory node1 = stakedMonad.viewNodeByNodeId(nodeId1);
        assertEq(node1.staked, 6 ether);

        Registry.Node memory node2 = stakedMonad.viewNodeByNodeId(nodeId2);
        assertEq(node2.staked, 4 ether);
    }

    function test_bonding_with_overallocation_and_underallocation() public {
        // Add 2 nodes
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        uint64 nodeId2 = 2;
        stakedMonad.addNode(nodeId1);
        stakedMonad.addNode(nodeId2);

        // Set weights to 60% / 40%
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 600e18, isIncreasing: true});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 400e18, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Deposit 10 MON
        stakedMonad.deposit{value: 10 ether}(0, ADMIN);

        // Submit batch (#1) to process deposit
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId1, true);
        StakerFaker.mockDelegate(nodeId2, true);
        stakedMonad.submitBatch();

        // Set weights to 50% / 50%
        // Creates over allocation to node 1
        // Creates under allocation to node 2
        weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 100e18, isIncreasing: false});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 100e18, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Deposit an additional 1 MON (total 11 MON)
        stakedMonad.deposit{value: 1 ether}(0, ADMIN);

        // Submit batch (#2) to process deposit
        StakerFaker.mockGetEpoch(2, false);
        StakerFaker.mockDelegate(nodeId1, true);
        StakerFaker.mockDelegate(nodeId2, true);
        stakedMonad.submitBatch();

        // Only node 2 which was under allocated should receive additional stake
        assertEq(stakedMonad.viewNodeByNodeId(nodeId1).staked, 6 ether + 0 ether, "Node 1 should have received no stake");
        assertEq(stakedMonad.viewNodeByNodeId(nodeId2).staked, 4 ether + 1 ether, "Node 2 should have received 1 MON");

        // Deposit an additional 9 MON (total 20 MON)
        stakedMonad.deposit{value: 9 ether}(0, ADMIN);

        // Submit batch (#3) to process deposit
        StakerFaker.mockGetEpoch(3, false);
        StakerFaker.mockDelegate(nodeId1, true);
        StakerFaker.mockDelegate(nodeId2, true);
        stakedMonad.submitBatch();

        // Both nodes should receive some additional stake
        assertEq(stakedMonad.viewNodeByNodeId(nodeId1).staked, 6 ether + 4 ether, "Node 1 should have received 4 MON");
        assertEq(stakedMonad.viewNodeByNodeId(nodeId2).staked, 5 ether + 5 ether, "Node 2 should have received 5 MON");
    }

    function test_bonding_with_dust() public {
        // Add 2 nodes
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        uint64 nodeId2 = 2;
        stakedMonad.addNode(nodeId1);
        stakedMonad.addNode(nodeId2);

        // Set weights to 50% / 50%
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 500e18, isIncreasing: true});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 500e18, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Deposit
        uint96 depositAmount = 10 ether + 1 wei;
        stakedMonad.deposit{value: depositAmount}(0, ADMIN);

        // Submit batch (#1) to process deposit
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId1, true);
        StakerFaker.mockDelegate(nodeId2, true);
        stakedMonad.submitBatch();

        // Most of the funds are allocated to nodes
        assertEq(stakedMonad.viewNodeByNodeId(nodeId1).staked, 5 ether);
        assertEq(stakedMonad.viewNodeByNodeId(nodeId2).staked, 5 ether);

        // Current batch (#2) should contain the unallocated dust
        (uint96 assets,) = stakedMonad.batchDepositRequests(2);
        assertEq(assets, 1 wei, "Dust should be allocated into the next batch");
    }

    function test_unbonding_with_overallocation_and_underallocation() public {
        // Add 2 nodes
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        uint64 nodeId2 = 2;
        stakedMonad.addNode(nodeId1);
        stakedMonad.addNode(nodeId2);

        // Disable exit fee
        stakedMonad.setExitFee(0);

        // Set weights to 60% / 40%
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 600e18, isIncreasing: true});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 400e18, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Deposit 10 MON
        stakedMonad.deposit{value: 10 ether}(0, ADMIN);

        // Submit batch (#1) to process deposit
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId1, true);
        StakerFaker.mockDelegate(nodeId2, true);
        stakedMonad.submitBatch();

        // Set weights to 50% / 50%
        // Creates over allocation to node 1
        // Creates under allocation to node 2
        weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 100e18, isIncreasing: false});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 100e18, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Request to unbond 0.5 MON worth of shares (1:1 redemption ratio still)
        uint96 expectedUndelegationFromNode1 = stakedMonad.requestUnlock(0.5 ether, 0);

        // Submit batch (#2) to process unbond
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(2, false);
        StakerFaker.mockUndelegate(nodeId1, expectedUndelegationFromNode1, 0, true);
        stakedMonad.submitBatch();

        // Only node 1 which was over allocated should have been unbonded from
        assertEq(stakedMonad.viewNodeByNodeId(nodeId1).staked, 6 ether - 0.5 ether, "Node 1 should have lost 0.5 MON");
        assertEq(stakedMonad.viewNodeByNodeId(nodeId2).staked, 4 ether - 0 ether, "Node 2 should have lost no stake");
    }

    function test_unbonding_with_dust() public {
        // Add 2 nodes
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        uint64 nodeId2 = 2;
        stakedMonad.addNode(nodeId1);
        stakedMonad.addNode(nodeId2);

        // Disable exit fee
        stakedMonad.setExitFee(0);

        // Set weights to 50% / 50%
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 500e18, isIncreasing: true});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 500e18, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Deposit 10 MON
        stakedMonad.deposit{value: 10 ether}(0, ADMIN);

        // Submit batch (#1) to process deposit
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId1, true);
        StakerFaker.mockDelegate(nodeId2, true);
        stakedMonad.submitBatch();

        // Request unlock of shares that will create dust
        uint96 unbondShares = 4 ether + 1 wei;
        uint96 unlockSpotValue = stakedMonad.requestUnlock(unbondShares, 0);
        assertEq(unlockSpotValue, 4 ether + 1 wei, "1:1 redemption ratio should be in effect");

        // Submit batch (#2) to process unbond
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(2, false);
        StakerFaker.mockUndelegate(nodeId1, unlockSpotValue / 2, 0, true);
        StakerFaker.mockUndelegate(nodeId2, unlockSpotValue / 2, 0, true);
        stakedMonad.submitBatch();

        // Most of the funds are unbonded from nodes
        assertEq(stakedMonad.viewNodeByNodeId(nodeId1).staked, 5 ether - 2 ether);
        assertEq(stakedMonad.viewNodeByNodeId(nodeId2).staked, 5 ether - 2 ether);

        // Current batch (#3) should contain the unallocated dust
        (uint96 assets,) = stakedMonad.batchWithdrawRequests(3);
        assertEq(assets, 1 wei, "Dust should be allocated into the next batch");
    }

    function test_unbond_disabled_node_cannot_be_active() public {
        // Add node
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        stakedMonad.addNode(nodeId1);

        // Try to unbond node 1 (still active)
        vm.expectRevert(CustomErrors.ActiveNode.selector);
        stakedMonad.unbondDisableNode(nodeId1);
    }

    function test_unbond_disabled_node_must_have_active_stake() public {
        // Add node
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        stakedMonad.addNode(nodeId1);

        // Disable node
        stakedMonad.disableNode(nodeId1);

        // Try to unbond node (disabled) (no active stake)
        vm.expectRevert(CustomErrors.NoChange.selector);
        stakedMonad.unbondDisableNode(nodeId1);
    }

    function test_unbond_disabled_node_does_not_change_ratio() public {
        // Add nodes
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        uint64 nodeId2 = 2;
        stakedMonad.addNode(nodeId1);
        stakedMonad.addNode(nodeId2);

        // Set weights
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 50_00, isIncreasing: true});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 50_00, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Deposit and delegate 50 MON to each node
        stakedMonad.deposit{value: 100 ether}(0, ADMIN);
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId1, true);
        StakerFaker.mockDelegate(nodeId2, true);
        stakedMonad.submitBatch();

        // Disable node 1
        stakedMonad.disableNode(nodeId1);

        // Allow some management fees to accumulate
        vm.warp(vm.getBlockTimestamp() + 7 days);

        // Force unbond node 1
        uint96 shareValueBefore = stakedMonad.convertToAssets(1e18);
        StakerFaker.mockUndelegate(nodeId1, 50 ether, 255, true);
        stakedMonad.unbondDisableNode(nodeId1);
        uint96 shareValueAfter = stakedMonad.convertToAssets(1e18);

        assertEq(shareValueAfter, shareValueBefore);
    }

    function test_sweep_withdraws_continuous_ids() public {
        // Add node
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        stakedMonad.addNode(nodeId1);

        // Prep vault: set weight, deposit, submit ingress batch
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 100e18, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);
        stakedMonad.deposit{value: 100 ether}(0, ADMIN);
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId1, true);
        stakedMonad.submitBatch();

        // Submit batch (#2) utilizing withdraw id of 0
        uint96 spotValue = stakedMonad.requestUnlock(1e18, 0);
        StakerFaker.mockGetEpoch(2, false);
        StakerFaker.mockUndelegate(nodeId1, spotValue, 0, true);
        stakedMonad.submitBatch();
        assertEq(stakedMonad.getWithdrawIds(nodeId1).length, 1);
        assertEq(stakedMonad.getWithdrawIds(nodeId1)[0], 0);

        // Submit batch (#3) utilizing withdraw id of 1
        spotValue = stakedMonad.requestUnlock(1e18, 0);
        StakerFaker.mockGetEpoch(3, false);
        StakerFaker.mockUndelegate(nodeId1, spotValue, 1, true);
        stakedMonad.submitBatch();
        assertEq(stakedMonad.getWithdrawIds(nodeId1).length, 2);
        assertEq(stakedMonad.getWithdrawIds(nodeId1)[1], 1);

        // Submit batch (#4) utilizing withdraw id of 2
        spotValue = stakedMonad.requestUnlock(1e18, 0);
        StakerFaker.mockGetEpoch(4, false);
        StakerFaker.mockUndelegate(nodeId1, spotValue, 2, true);
        stakedMonad.submitBatch();
        assertEq(stakedMonad.getWithdrawIds(nodeId1).length, 3);
        assertEq(stakedMonad.getWithdrawIds(nodeId1)[2], 2);

        // Warp forward to simulate unlocks becoming withdrawable
        StakerFaker.mockGetEpoch(100, false);

        uint64[] memory nodeIds = new uint64[](1);
        nodeIds[0] = nodeId1;

        // Sweep with limit less than available
        uint8 maxWithdrawals = 1;
        assertLt(maxWithdrawals, stakedMonad.getWithdrawIdsSize(nodeId1));
        StakerFaker.mockWithdraw(nodeId1, 0, true); // withdraw id 0
        stakedMonad.sweep(nodeIds, maxWithdrawals);
        assertEq(stakedMonad.getWithdrawIdsSize(nodeId1), 3 - maxWithdrawals);

        // Sweep with limit more than available
        maxWithdrawals = 100;
        assertGt(maxWithdrawals, stakedMonad.getWithdrawIdsSize(nodeId1));
        StakerFaker.mockWithdraw(nodeId1, 1, true); // withdraw id 1
        StakerFaker.mockWithdraw(nodeId1, 2, true); // withdraw id 2
        stakedMonad.sweep(nodeIds, maxWithdrawals);
        assertEq(stakedMonad.getWithdrawIdsSize(nodeId1), 0);
    }

    function test_sweep_at_withdraw_id_threshold() public {
        // Add node
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        stakedMonad.addNode(nodeId1);

        // Prep vault: set weight, deposit, submit ingress batch
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 100e18, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);
        stakedMonad.deposit{value: 1000 ether}(0, ADMIN);
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId1, true);
        stakedMonad.submitBatch();

        // Create 255 withdraw ids exhausting pending limit
        uint64 nextEpoch = 2;
        uint8 nextWithdrawId = 0;
        for (uint256 i; i < 255; ++i) {
            uint96 spotValue = stakedMonad.requestUnlock(1e18, 0);
            StakerFaker.mockGetEpoch(nextEpoch++, false);
            StakerFaker.mockUndelegate(nodeId1, spotValue, nextWithdrawId++, true);
            stakedMonad.submitBatch();
        }

        assertEq(stakedMonad.getWithdrawIdsSize(nodeId1), 255);
        assertEq(stakedMonad.getWithdrawIds(nodeId1).length, 255);
        assertEq(stakedMonad.getWithdrawIds(nodeId1)[255 - 1], 254, "Last withdrawal id should be 254");

        // Cannot create another withdraw id
        uint96 lastSpotValue = stakedMonad.requestUnlock(1e18, 0);
        StakerFaker.mockGetEpoch(nextEpoch++, false);
        vm.expectRevert(Staker.MaxPendingWithdrawals.selector);
        stakedMonad.submitBatch();

        // Warp forward to simulate unlocks becoming withdrawable
        nextEpoch += 1;
        StakerFaker.mockGetEpoch(nextEpoch, false);

        uint64[] memory nodeIds = new uint64[](1);
        nodeIds[0] = nodeId1;

        // Sweep first withdraw id: [0]
        StakerFaker.mockWithdraw(nodeId1, 0, true); // withdraw id 0
        stakedMonad.sweep(nodeIds, 1);
        assertEq(stakedMonad.getWithdrawIdsSize(nodeId1), 255 - 1, "Tracked ids should have decreased");
        assertEq(stakedMonad.getWithdrawIds(nodeId1)[0], 1, "First withdrawal id should now be 1");

        // Create another withdraw id beginning at 0
        StakerFaker.mockUndelegate(nodeId1, lastSpotValue, 0, true);
        stakedMonad.submitBatch();

        assertEq(stakedMonad.getWithdrawIdsSize(nodeId1), 254 + 1, "Tracked ids should have increased");
        assertEq(stakedMonad.getWithdrawIds(nodeId1).length, 254 + 1, "Tracked ids should have increased");
        assertEq(stakedMonad.getWithdrawIds(nodeId1)[254], 0, "Last withdrawal id should now be 0");

        // Warp forward to simulate latest unlock becoming withdrawable
        nextEpoch += 1;
        StakerFaker.mockGetEpoch(nextEpoch, false);

        // Sweep 255 withdraw ids to iterate over modulo gap: [1, 0]
        for (uint256 i; i < 255; ++i) {
            StakerFaker.mockWithdraw(nodeId1, uint8(i), true);
        }
        stakedMonad.sweep(nodeIds, 255);

        assertEq(stakedMonad.getWithdrawIdsSize(nodeId1), 0, "Should be no tracked ids remaining");
        assertEq(stakedMonad.getWithdrawIds(nodeId1).length, 0, "Should be no tracked ids remaining");
    }

    function test_sweepForced() public {
        // Add node
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        stakedMonad.addNode(nodeId1);

        // Set weight
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 100e18, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Deposit and delegate 100 MON to node
        stakedMonad.deposit{value: 100 ether}(0, ADMIN);
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId1, true);
        stakedMonad.submitBatch();

        // Disable and force unbond node
        stakedMonad.disableNode(nodeId1);
        StakerFaker.mockUndelegate(nodeId1, 100 ether, 255, true);
        stakedMonad.unbondDisableNode(nodeId1);

        // Warp forward to simulate unlocks becoming withdrawable
        StakerFaker.mockGetEpoch(100, false);

        uint64[] memory nodeIds = new uint64[](1);
        nodeIds[0] = nodeId1;

        // Regular sweep will not withdraw node
        assertTrue(stakedMonad.isForceWithdrawPending(nodeId1));
        stakedMonad.sweep(nodeIds, 255);
        assertTrue(stakedMonad.isForceWithdrawPending(nodeId1));

        // Force sweep will withdraw node
        uint96 shareValueBefore = stakedMonad.convertToAssets(1e18);
        StakerFaker.mockWithdraw(nodeId1, 255, true);
        stakedMonad.sweepForced(nodeIds);
        uint96 shareValueAfter = stakedMonad.convertToAssets(1e18);
        assertEq(shareValueAfter, shareValueBefore, "Force sweep should not change the redemption ratio");

        assertFalse(stakedMonad.isForceWithdrawPending(nodeId1));
    }

    function test_compound_reverts_when_no_rewards() public {
        // Add node
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        stakedMonad.addNode(nodeId1);

        uint64[] memory nodeIds = new uint64[](1);
        nodeIds[0] = nodeId1;

        // Mock claim succeeding but transferring no rewards
        StakerFaker.mockClaimRewards(nodeId1, true);

        vm.expectRevert(CustomErrors.NoChange.selector);
        stakedMonad.compound(nodeIds);
    }

    function test_contributeToPool_amount_must_be_reasonable() public {
        uint256 maxContribution = uint256(type(uint96).max);
        vm.deal(ADMIN, maxContribution + 1 wei);
        vm.startPrank(ADMIN);

        // Contribute more than uint96
        vm.expectRevert(CustomErrors.DepositOverflow.selector);
        stakedMonad.contributeToPool{value: maxContribution + 1 wei}(ADMIN);
    }

    function test_contributeToPool_is_prevented_at_low_tvl() public {
        vm.startPrank(ADMIN);

        // Deposit slightly less than threshold
        stakedMonad.deposit{value: stakedMonad.MINIMUM_CONTRIBUTE_THRESHOLD() - 1 wei}(0, ADMIN);

        vm.expectRevert(CustomErrors.MinimumContributeThreshold.selector);
        stakedMonad.contributeToPool{value: 1 ether}(ADMIN);
    }

    function test_contributeToPool_increases_share_value() public {
        vm.startPrank(ADMIN);

        // Deposit enough to satisfy the threshold
        uint256 depositAmount = stakedMonad.MINIMUM_CONTRIBUTE_THRESHOLD();
        stakedMonad.deposit{value: depositAmount}(0, ADMIN);

        uint256 shareValueSnapshot = stakedMonad.convertToAssets(1e18);
        stakedMonad.contributeToPool{value: 1 ether}(ADMIN);
        assertGt(stakedMonad.convertToAssets(1e18), shareValueSnapshot);
    }

    function test_weightImbalance_under_allocation(uint96 depositAmount) public {
        vm.assume(depositAmount >= MINIMUM_DEPOSIT);
        vm.assume(depositAmount < FUNDING_AMOUNT);

        // Add 2 nodes
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        uint64 nodeId2 = 2;
        stakedMonad.addNode(nodeId1);
        stakedMonad.addNode(nodeId2);

        // Set weights to 60% / 40%
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 600e18, isIncreasing: true});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 400e18, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        (,,, uint96[] memory underAllocations) = stakedMonad.getImbalances(depositAmount);

        assertEq(underAllocations[0], depositAmount * 60 / 100, "Node #1 should have 60% of the under allocation");
        assertEq(underAllocations[1], depositAmount * 40 / 100, "Node #2 should have 40% of the under allocation");
    }

    function test_weightImbalance_over_allocation(uint96 depositAmount) public {
        vm.assume(depositAmount >= MINIMUM_DEPOSIT);
        vm.assume(depositAmount < FUNDING_AMOUNT);

        // Add 2 nodes
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        uint64 nodeId2 = 2;
        stakedMonad.addNode(nodeId1);
        stakedMonad.addNode(nodeId2);

        // Set weights to 60% / 40%
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 600e18, isIncreasing: true});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 400e18, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Deposit
        stakedMonad.deposit{value: depositAmount}(0, ADMIN);

        // Submit batch (#1) to process deposit
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId1, true);
        StakerFaker.mockDelegate(nodeId2, true);
        stakedMonad.submitBatch();

        // Note: Excludes dust which is calculated in `_doBonding()`
        Registry.Node[] memory nodes = stakedMonad.getNodes();
        assertApproxEqAbs(nodes[0].staked, depositAmount * 60 / 100, 1e2, "Node #1 should receive 60% of the stake");
        assertApproxEqAbs(nodes[1].staked, depositAmount * 40 / 100, 1e2, "Node #2 should receive 40% of the stake");

        // Remove weight from node 1 so it is over allocated
        // Set weights to 50% / 50%
        Registry.WeightDelta[] memory weightDeltas2 = new Registry.WeightDelta[](1);
        weightDeltas2[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 200e18, isIncreasing: false});
        stakedMonad.updateWeights(weightDeltas2);

        (,, uint96[] memory overAllocations, uint96[] memory underAllocations) = stakedMonad.getImbalances(depositAmount);
        assertApproxEqAbs(overAllocations[0], depositAmount * 10 / 100, 1e4, "Node #1 should have 10% of the over allocation");
        assertEq(underAllocations[0], 0, "Node #1 should have 0% of the under allocation");
        assertEq(overAllocations[1], 0, "Node #2 should have 0% of the over allocation");
        assertApproxEqAbs(underAllocations[1], depositAmount * 10 / 100, 1e4, "Node #2 should have 10% of the under allocation");
    }
}
