// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./StakedMonad.t.sol";
import {StakedMonadV3} from "../src/StakedMonadV3.sol";
import {DeployV3} from "../script/DeployV3.s.sol";

abstract contract StakedMonadV3Tests is StakedMonadTest {
    uint256 internal constant DUST_THRESHOLD = 1 gwei;

    /**
     * @notice The precompile rejects any single delegation below 1 gwei (`DelegationTooSmall`).
     *         V3 skips such nodes and rolls the unallocated amount forward as dust instead of reverting the batch.
     */
    function test_bonding_skips_sub_gwei_delegation() public {
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        uint64 nodeId2 = 2;
        stakedMonad.addNode(nodeId1);
        stakedMonad.addNode(nodeId2);

        // Node 1 has a ~1e-9 share of the pool, so its share of a 1 MON deposit is just under 1 gwei
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 1, isIncreasing: true});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 1_000_000_000, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        uint96 depositAmount = 1 ether;
        stakedMonad.deposit{value: depositAmount}(0, ADMIN);

        uint96 expectedNode1 = uint96(uint256(depositAmount) * 1 / 1_000_000_001);
        uint96 expectedNode2 = uint96(uint256(depositAmount) * 1_000_000_000 / 1_000_000_001);
        assertLt(expectedNode1, DUST_THRESHOLD, "Test setup: node 1 share must be sub-gwei");

        // Only node 2 is expected to be delegated to. An unmocked delegate() call to node 1 would revert.
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId2, true);
        stakedMonad.submitBatch();

        assertEq(stakedMonad.viewNodeByNodeId(nodeId1).staked, 0, "Sub-gwei delegation should be skipped");
        assertEq(stakedMonad.viewNodeByNodeId(nodeId2).staked, expectedNode2, "Node 2 should receive its share");

        (uint96 dust,) = stakedMonad.batchDepositRequests(2);
        assertEq(dust, depositAmount - expectedNode2, "Skipped amount should roll forward as dust");
        assertEq(stakedMonad.totalPooled(), depositAmount, "totalPooled unchanged by bonding");
    }

    /**
     * @notice A net ingress below 1 gwei cannot produce a single delegation at or above the threshold,
     *         so bonding returns before touching any node and the whole amount rolls forward as dust.
     */
    function test_bonding_rolls_sub_gwei_net_ingress_without_touching_nodes() public {
        uint64 nodeId = 1;
        _bondSingleNode(nodeId, 10 ether);

        // Batch 2: deposit 1 gwei, withdraw 1 wei worth, net ingress of 1 gwei - 1
        uint96 depositAmount = uint96(DUST_THRESHOLD);
        stakedMonad.deposit{value: depositAmount}(0, ADMIN);
        stakedMonad.requestUnlock(1 wei, 0);
        uint40 batchId = stakedMonad.currentBatchId();
        (uint96 deposits,) = stakedMonad.batchDepositRequests(batchId);
        (uint96 withdrawals,) = stakedMonad.batchWithdrawRequests(batchId);
        assertLt(deposits - withdrawals, DUST_THRESHOLD, "Test setup: net ingress must be sub-gwei");

        // No delegate() is mocked: any call to the precompile would revert
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(2, false);
        stakedMonad.submitBatch();

        assertEq(stakedMonad.viewNodeByNodeId(nodeId).staked, 10 ether, "No node touched");
        (uint96 dust,) = stakedMonad.batchDepositRequests(batchId + 1);
        assertEq(dust, deposits - withdrawals, "Whole net ingress rolls forward as dust");
        assertEq(stakedMonad.totalPooled(), 10 ether + depositAmount - withdrawals, "totalPooled tracks the pool");
    }

    /**
     * @notice The precompile would sweep a sub-gwei remainder into the withdrawal and zero the delegator.
     *         V3 unbonds less instead, leaving exactly the dust threshold, and rolls the shortfall forward as
     *         egress dust so `Registry.nodes[i].staked` never drifts from the precompile's view.
     */
    function test_unbonding_leaves_dust_threshold_instead_of_sweeping() public {
        uint64 nodeId = 1;
        uint96 depositAmount = 10 ether;
        _bondSingleNode(nodeId, depositAmount);

        // Unlock everything except half a gwei. Remainder is below the dust threshold.
        uint96 remainder = 0.5 gwei;
        uint96 spotValue = stakedMonad.requestUnlock(depositAmount - remainder, 0);
        assertEq(spotValue, depositAmount - remainder, "1:1 redemption ratio expected");
        uint40 batchId = stakedMonad.currentBatchId();

        // Only up to the threshold is undelegated. An unmocked undelegate() for any other amount would revert.
        uint96 expectedUnbond = depositAmount - uint96(DUST_THRESHOLD);
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(2, false);
        StakerFaker.mockUndelegate(nodeId, expectedUnbond, 0, true);
        stakedMonad.submitBatch();

        assertEq(stakedMonad.viewNodeByNodeId(nodeId).staked, DUST_THRESHOLD, "Exactly the threshold remains staked");
        uint96 shortfall = uint96(DUST_THRESHOLD) - remainder;
        (uint96 dustEgress,) = stakedMonad.batchWithdrawRequests(batchId + 1);
        assertEq(dustEgress, shortfall, "Shortfall rolls forward as egress dust");
        (uint96 dustIngress,) = stakedMonad.batchDepositRequests(batchId + 1);
        assertEq(dustIngress, 0, "Nothing scheduled for re-bonding");
        assertEq(stakedMonad.totalPooled(), remainder + shortfall, "totalPooled keeps the rolled dust");
        assertEq(stakedMonad.totalPooled(), DUST_THRESHOLD, "Everything still in totalPooled is staked");
    }

    /**
     * @notice Rolled egress dust is netted against the next deposit, then a full exit unbonds exactly the node's stake.
     */
    function test_rolled_dust_nets_against_deposit_and_full_exit_succeeds() public {
        uint64 nodeId = 1;
        _bondSingleNode(nodeId, 10 ether);

        uint96 remainder = 0.5 gwei;
        stakedMonad.requestUnlock(10 ether - remainder, 0);
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(2, false);
        StakerFaker.mockUndelegate(nodeId, 10 ether - uint96(DUST_THRESHOLD), 0, true);
        stakedMonad.submitBatch();
        assertEq(stakedMonad.viewNodeByNodeId(nodeId).staked, DUST_THRESHOLD, "Test setup: node at threshold");

        // New deposit nets the rolled dust and bonds the rest
        uint96 dust = uint96(DUST_THRESHOLD) - remainder;
        stakedMonad.deposit{value: 1 ether}(0, ADMIN);
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(3, false);
        StakerFaker.mockDelegate(nodeId, true);
        stakedMonad.submitBatch();
        assertEq(stakedMonad.viewNodeByNodeId(nodeId).staked, 1 ether - dust + DUST_THRESHOLD, "Dust netted, rest bonded");
        assertEq(stakedMonad.totalPooled(), 1 ether + remainder);
        assertEq(stakedMonad.viewNodeByNodeId(nodeId).staked, stakedMonad.totalPooled(), "All pooled MON is staked");

        // Full exit unbonds exactly the node's stake
        uint96 spotValue = stakedMonad.requestUnlock(uint96(stakedMonad.balanceOf(ADMIN)), 0);
        assertEq(spotValue, 1 ether + remainder, "1:1 redemption ratio expected");
        uint40 batchId = stakedMonad.currentBatchId();
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(4, false);
        StakerFaker.mockUndelegate(nodeId, spotValue, 1, true);
        stakedMonad.submitBatch();

        assertEq(stakedMonad.viewNodeByNodeId(nodeId).staked, 0, "Node fully unbonded");
        assertEq(stakedMonad.totalPooled(), 0);
        (uint96 dustEgress,) = stakedMonad.batchWithdrawRequests(batchId + 1);
        assertEq(dustEgress, 0, "No egress dust");
    }

    /**
     * @notice A weight-0 node cannot be drained below the threshold by proportional egress. It stays at exactly
     *         1 gwei across successive egress batches while the dust keeps rolling, and clears on the next ingress.
     */
    function test_weight_zero_node_holds_at_threshold_until_ingress() public {
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        uint64 nodeId2 = 2;
        stakedMonad.addNode(nodeId1);
        stakedMonad.addNode(nodeId2);
        stakedMonad.setExitFee(0);

        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 50_00, isIncreasing: true});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 50_00, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        stakedMonad.deposit{value: 20 ether}(0, ADMIN);
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId1, true);
        StakerFaker.mockDelegate(nodeId2, true);
        stakedMonad.submitBatch();

        // Drop node 2 to weight 0 so egress drains it first
        weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId2, delta: 50_00, isIncreasing: false});
        stakedMonad.updateWeights(weightDeltas);

        // Egress 1: request all of node 2 but half a gwei. Node 2 is left at the threshold.
        uint96 remainder = 0.5 gwei;
        stakedMonad.requestUnlock(10 ether - remainder, 0);
        uint40 batchId = stakedMonad.currentBatchId();
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(2, false);
        StakerFaker.mockUndelegate(nodeId2, 10 ether - uint96(DUST_THRESHOLD), 0, true);
        stakedMonad.submitBatch();
        uint96 dust = uint96(DUST_THRESHOLD) - remainder;
        assertEq(stakedMonad.viewNodeByNodeId(nodeId2).staked, DUST_THRESHOLD);
        (uint96 dustEgress,) = stakedMonad.batchWithdrawRequests(batchId + 1);
        assertEq(dustEgress, dust, "Shortfall rolls forward");

        // Egress 2: only the rolled dust is requested. Node 2 has all the excess but cannot go below the threshold.
        // Nothing is undelegated (no mock needed) and the dust rolls again.
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(3, false);
        stakedMonad.submitBatch();
        assertEq(stakedMonad.viewNodeByNodeId(nodeId2).staked, DUST_THRESHOLD, "Still at threshold");
        (dustEgress,) = stakedMonad.batchWithdrawRequests(batchId + 2);
        assertEq(dustEgress, dust, "Dust rolls again");
        assertEq(stakedMonad.totalPooled(), 10 ether + DUST_THRESHOLD);

        // Ingress: a deposit nets the dust and bonds the rest to node 1 (the only node with a deficit)
        stakedMonad.deposit{value: 1 ether}(0, ADMIN);
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(4, false);
        StakerFaker.mockDelegate(nodeId1, true);
        stakedMonad.submitBatch();
        (dustEgress,) = stakedMonad.batchWithdrawRequests(batchId + 3);
        assertEq(dustEgress, 0, "Dust cleared by netting");
        assertEq(stakedMonad.viewNodeByNodeId(nodeId1).staked, 11 ether - dust);
        assertEq(stakedMonad.viewNodeByNodeId(nodeId2).staked, DUST_THRESHOLD, "Weight-0 node untouched by ingress");
        assertEq(
            stakedMonad.viewNodeByNodeId(nodeId1).staked + stakedMonad.viewNodeByNodeId(nodeId2).staked,
            stakedMonad.totalPooled(),
            "All pooled MON is staked"
        );

        // The documented exit path for the node still works and reaches zero
        stakedMonad.disableNode(nodeId2);
        StakerFaker.mockUndelegate(nodeId2, uint96(DUST_THRESHOLD), 255, true);
        stakedMonad.unbondDisableNode(nodeId2);
        assertEq(stakedMonad.viewNodeByNodeId(nodeId2).staked, 0);
    }

    /**
     * @notice A full exit from a healthy pool leaves zero on every node; a zero remainder is never clamped.
     */
    function test_full_exit_leaves_zero_without_clamping() public {
        uint64 nodeId = 1;
        _bondSingleNode(nodeId, 10 ether);

        uint96 spotValue = stakedMonad.requestUnlock(uint96(stakedMonad.balanceOf(ADMIN)), 0);
        assertEq(spotValue, 10 ether);
        uint40 batchId = stakedMonad.currentBatchId();
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(2, false);
        StakerFaker.mockUndelegate(nodeId, 10 ether, 0, true);
        stakedMonad.submitBatch();

        assertEq(stakedMonad.viewNodeByNodeId(nodeId).staked, 0);
        assertEq(stakedMonad.totalPooled(), 0);
        (uint96 dustEgress,) = stakedMonad.batchWithdrawRequests(batchId + 1);
        assertEq(dustEgress, 0);
    }

    /**
     * @dev Adds `nodeId` at full weight, deposits `amount` and bonds it in batch 1 at epoch 1
     */
    function _bondSingleNode(uint64 nodeId, uint96 amount) internal {
        vm.startPrank(ADMIN);
        stakedMonad.addNode(nodeId);
        stakedMonad.setExitFee(0);

        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        stakedMonad.deposit{value: amount}(0, ADMIN);
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId, true);
        stakedMonad.submitBatch();
        assertEq(stakedMonad.viewNodeByNodeId(nodeId).staked, amount, "Setup: bonded");
    }

    /**
     * @notice After unbondDisableNode() the forced amount is still counted in totalPooled but staked nowhere.
     *         A net-egress batch smaller than that amount finds no node in excess (totalExcess == 0).
     *         V3 keeps V2 behaviour and reverts (division by zero) rather than rolling the egress forward as
     *         dust, which would inflate the share price while its shares are already burned.
     */
    function test_unbond_reverts_with_zero_excess_during_forced_unbond_window() public {
        _bondTwoNodesAndForceUnbondSecond();

        uint96 spotValue = stakedMonad.requestUnlock(10 ether, 0);
        assertEq(spotValue, 10 ether, "1:1 redemption ratio expected");

        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(2, false);
        vm.expectRevert(stdError.divisionError);
        stakedMonad.submitBatch();

        assertEq(stakedMonad.viewNodeByNodeId(1).staked, 50 ether, "Node 1 stake unchanged");
        assertEq(stakedMonad.totalPooled(), 100 ether, "totalPooled unchanged");
    }

    /**
     * @notice While force-unbonded MON awaits `sweepForced` the requested egress can exceed a node's stake.
     *         V3 keeps V2 behaviour and reverts (uint96 underflow) rather than clamping the unbond and rolling
     *         the shortfall forward, which would inflate the share price while its shares are already burned.
     */
    function test_unbond_reverts_when_request_exceeds_node_stake_during_forced_unbond_window() public {
        _bondTwoNodesAndForceUnbondSecond();

        // Target stake is 40 MON so node 1 has 10 MON excess, far less than the 60 MON requested
        uint96 spotValue = stakedMonad.requestUnlock(60 ether, 0);
        assertEq(spotValue, 60 ether, "1:1 redemption ratio expected");

        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(2, false);
        vm.expectRevert(stdError.arithmeticError);
        stakedMonad.submitBatch();

        assertEq(stakedMonad.viewNodeByNodeId(1).staked, 50 ether, "Node 1 stake unchanged");
        assertEq(stakedMonad.totalPooled(), 100 ether, "totalPooled unchanged");
    }

    /**
     * @dev Bonds 100 MON equally across nodes 1 and 2, then disables and force-unbonds node 2.
     *      Leaves 50 MON tracked in totalPooled but staked nowhere until `sweepForced`.
     */
    function _bondTwoNodesAndForceUnbondSecond() internal {
        vm.startPrank(ADMIN);
        uint64 nodeId1 = 1;
        uint64 nodeId2 = 2;
        stakedMonad.addNode(nodeId1);
        stakedMonad.addNode(nodeId2);
        stakedMonad.setExitFee(0);

        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId1, delta: 50_00, isIncreasing: true});
        weightDeltas[1] = Registry.WeightDelta({nodeId: nodeId2, delta: 50_00, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        stakedMonad.deposit{value: 100 ether}(0, ADMIN);
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId1, true);
        StakerFaker.mockDelegate(nodeId2, true);
        stakedMonad.submitBatch();

        stakedMonad.disableNode(nodeId2);
        StakerFaker.mockUndelegate(nodeId2, 50 ether, 255, true);
        stakedMonad.unbondDisableNode(nodeId2);
    }

    /**
     * @notice Unbonding that leaves at least the dust threshold behaves exactly as before
     */
    function test_unbonding_leaves_remainder_at_or_above_gwei() public {
        vm.startPrank(ADMIN);
        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);
        stakedMonad.setExitFee(0);

        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        uint96 depositAmount = 10 ether;
        stakedMonad.deposit{value: depositAmount}(0, ADMIN);

        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId, true);
        stakedMonad.submitBatch();

        uint96 remainder = uint96(DUST_THRESHOLD);
        uint96 spotValue = stakedMonad.requestUnlock(depositAmount - remainder, 0);

        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(2, false);
        StakerFaker.mockUndelegate(nodeId, spotValue, 0, true);
        stakedMonad.submitBatch();

        assertEq(stakedMonad.viewNodeByNodeId(nodeId).staked, remainder, "Exactly 1 gwei may remain staked");
    }
}

contract StakedMonadV3DeployTest is StakedMonadV3Tests, DeployV3 {
    function run() public override(DeployV1, DeployV3) {}
    function writeArtifacts(string memory, string memory, address) internal override(DeployV1, DeployV3) {}

    function setUp() public override(StakedMonadTest) {
        // Deploy v1
        super.setUp();

        // Deploy v3 directly
        (address proxy,) = DeployV3.deployV3(ADMIN);

        // Overwrite previously deployed v1 to run tests against v3
        stakedMonad = StakedMonad(payable(proxy));
    }

    function test_cannot_initialize_again() public {
        vm.expectRevert("Expected a different version");
        StakedMonadV3(payable(stakedMonad)).initialize(ALICE);
    }

    function test_cannot_call_initializeFromV2_on_fresh_deploy() public {
        vm.expectRevert("Expected a different version");
        StakedMonadV3(payable(stakedMonad)).initializeFromV2(new uint64[](0));
    }
}
