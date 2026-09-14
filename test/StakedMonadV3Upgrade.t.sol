// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/src/Test.sol";
import "./StakedMonad.t.sol";
import {StakedMonadV3Tests} from "./StakedMonadV3Deploy.t.sol";
import {StakedMonadV3, UUPSUpgradeable} from "../src/StakedMonadV3.sol";
import {UpgradeV2FromV1} from "../script/UpgradeV2FromV1.s.sol";
import {UpgradeV3FromV2} from "../script/UpgradeV3FromV2.s.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

contract StakedMonadV3UpgradeTest is StakedMonadV3Tests, UpgradeV2FromV1, UpgradeV3FromV2 {
    function run() public override(DeployV1, UpgradeV2FromV1, UpgradeV3FromV2) {}

    function setUp() public override(StakedMonadTest) {
        // Deploy v1
        super.setUp();

        vm.startPrank(ADMIN);
        // Upgrade v1 to v2
        UpgradeV2FromV1.upgradeV2FromV1(address(stakedMonad));

        // Upgrade v2 to v3 with nothing to sync, so the shared suite starts from a clean registry
        UpgradeV3FromV2.upgradeV3FromV2(address(stakedMonad), new uint64[](0));
        vm.stopPrank();
    }

    function test_cannot_initialize_again() public {
        vm.expectRevert("Expected a different version");
        StakedMonadV3(payable(stakedMonad)).initialize(ALICE);
    }

    function test_cannot_call_initializeFromV2_again() public {
        vm.expectRevert("Expected a different version");
        StakedMonadV3(payable(stakedMonad)).initializeFromV2(new uint64[](0));
    }
}

/// @notice Reproduces the mainnet drift on V2 and verifies the V3 upgrade heals it
contract StakedMonadV3UpgradeSyncTest is Test, StakerFaker, DeployV1, UpgradeV2FromV1, UpgradeV3FromV2 {
    StakedMonad public stakedMonad;
    address payable public ADMIN = payable(vm.addr(100));

    uint64 internal constant DRIFTED_NODE_ID = 17;
    uint96 internal constant DRIFTED_STAKE = 3 wei;
    uint64 internal constant HEALTHY_NODE_ID = 1;
    uint96 internal constant HEALTHY_STAKE = 10 ether;

    function run() public override(DeployV1, UpgradeV2FromV1, UpgradeV3FromV2) {}

    function setUp() public {
        vm.deal(ADMIN, 1_000_000 ether);
        (address proxy,) = DeployV1.deployV1(ADMIN);
        stakedMonad = StakedMonad(payable(proxy));

        vm.startPrank(ADMIN);
        UpgradeV2FromV1.upgradeV2FromV1(address(stakedMonad));
        stakedMonad.setExitFee(0);

        // Bond 10 MON to node 17, then unlock all but 3 wei. V2 keeps tracking the 3 wei the precompile swept.
        stakedMonad.addNode(DRIFTED_NODE_ID);
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: DRIFTED_NODE_ID, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);
        stakedMonad.deposit{value: 10 ether}(0, ADMIN);
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(DRIFTED_NODE_ID, true);
        stakedMonad.submitBatch();
        stakedMonad.requestUnlock(10 ether - DRIFTED_STAKE, 0);
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(2, false);
        StakerFaker.mockUndelegate(DRIFTED_NODE_ID, 10 ether - DRIFTED_STAKE, 0, true);
        stakedMonad.submitBatch();
        assertEq(stakedMonad.viewNodeByNodeId(DRIFTED_NODE_ID).staked, DRIFTED_STAKE, "Test setup: drift should exist");

        // Move all weight to a healthy node and stake 10 MON on it
        stakedMonad.addNode(HEALTHY_NODE_ID);
        weightDeltas = new Registry.WeightDelta[](2);
        weightDeltas[0] = Registry.WeightDelta({nodeId: DRIFTED_NODE_ID, delta: 100, isIncreasing: false});
        weightDeltas[1] = Registry.WeightDelta({nodeId: HEALTHY_NODE_ID, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);
        stakedMonad.deposit{value: HEALTHY_STAKE}(0, ADMIN);
        StakerFaker.clearMocks();
        StakerFaker.mockGetEpoch(3, false);
        StakerFaker.mockDelegate(HEALTHY_NODE_ID, true);
        stakedMonad.submitBatch();
        StakerFaker.clearMocks();
        vm.stopPrank();

        assertEq(stakedMonad.viewNodeByNodeId(HEALTHY_NODE_ID).staked, HEALTHY_STAKE);
        assertEq(stakedMonad.totalPooled(), HEALTHY_STAKE + DRIFTED_STAKE, "Test setup: totalPooled counts the drift");
    }

    /// @dev Mainnet shape: the precompile swept node 17's 3 wei, so it holds 0
    function _upgradeToV3() private {
        StakerFaker.mockGetDelegator(DRIFTED_NODE_ID, address(stakedMonad), 0);
        _upgradeToV3(_ids(DRIFTED_NODE_ID));
    }

    /// @dev Caller mocks `getDelegator` for every id first; mocks are cleared afterwards
    function _upgradeToV3(uint64[] memory ids) private {
        vm.startPrank(ADMIN);
        UpgradeV3FromV2.upgradeV3FromV2(address(stakedMonad), ids);
        StakerFaker.clearMocks();
        vm.stopPrank();
    }

    /// @dev Calls `upgradeToAndCall` directly so `expectRevert` targets the upgrade, not the implementation deploy
    function _expectUpgradeToV3Revert(uint64[] memory ids, bytes memory revertData) private {
        vm.startPrank(ADMIN);
        address impl = address(new StakedMonadV3());
        vm.expectRevert(revertData);
        UUPSUpgradeable(address(stakedMonad)).upgradeToAndCall(impl, abi.encodeCall(StakedMonadV3.initializeFromV2, (ids)));
        vm.stopPrank();
    }

    function _ids(uint64 a) private pure returns (uint64[] memory ids) {
        ids = new uint64[](1);
        ids[0] = a;
    }

    function _ids(uint64 a, uint64 b) private pure returns (uint64[] memory ids) {
        ids = new uint64[](2);
        ids[0] = a;
        ids[1] = b;
    }

    function _pendingDeposits() private view returns (uint96 assets) {
        (assets,) = stakedMonad.batchDepositRequests(stakedMonad.currentBatchId());
    }

    /// @dev Mainnet incident: the drifted node makes every net-egress batch revert on V2
    function test_v2_egress_batch_reverts_with_drift() public {
        vm.startPrank(ADMIN);
        uint96 spotValue = stakedMonad.requestUnlock(5 ether, 0);

        // Excess is split pro-rata: healthy node is above its target by `spotValue - 3`, drifted node by 3 wei
        uint256 healthyExcess = uint256(spotValue) - DRIFTED_STAKE;
        uint256 totalExcess = healthyExcess + DRIFTED_STAKE;
        uint256 healthyUnbond = uint256(spotValue) * healthyExcess / totalExcess;
        uint256 dustUnbond = uint256(spotValue) * DRIFTED_STAKE / totalExcess;
        assertGt(dustUnbond, 0, "Test setup: drift must produce a non-zero unbond");

        StakerFaker.mockGetEpoch(4, false);
        StakerFaker.mockUndelegate(HEALTHY_NODE_ID, healthyUnbond, 0, true);
        // Node 17 is asked to undelegate dust it no longer holds, which the precompile rejects
        StakerFaker.mockUndelegate(DRIFTED_NODE_ID, dustUnbond, 1, false);
        vm.expectRevert(StakerUpgradeable.PrecompileCallFailed.selector);
        stakedMonad.submitBatch();
    }

    function test_upgrade_syncs_drifted_node_stake() public {
        _upgradeToV3();
        assertEq(stakedMonad.viewNodeByNodeId(DRIFTED_NODE_ID).staked, 0, "Tracked stake should match precompile");
        assertEq(stakedMonad.viewNodeByNodeId(HEALTHY_NODE_ID).staked, HEALTHY_STAKE, "Other nodes untouched");
        assertEq(stakedMonad.totalPooled(), HEALTHY_STAKE + DRIFTED_STAKE, "totalPooled untouched");
        assertEq(_pendingDeposits(), DRIFTED_STAKE, "Swept dust is re-bonded in the current batch");
    }

    /// @dev Delegations from the last epochs are still pending on the precompile but already tracked by Registry
    function test_upgrade_sync_counts_pending_delegations() public {
        StakerFaker.mockGetDelegator(DRIFTED_NODE_ID, address(stakedMonad), 1 wei, 1 wei, 1 wei);
        _upgradeToV3(_ids(DRIFTED_NODE_ID));

        assertEq(stakedMonad.viewNodeByNodeId(DRIFTED_NODE_ID).staked, DRIFTED_STAKE, "Pending delegations count as stake");
        assertEq(_pendingDeposits(), 0, "Nothing to re-bond");
    }

    /// @dev Stake the precompile holds but Registry never tracked is not swept dust, so the upgrade refuses to guess
    function test_upgrade_reverts_when_precompile_stake_exceeds_tracked() public {
        StakerFaker.mockGetDelegator(DRIFTED_NODE_ID, address(stakedMonad), DRIFTED_STAKE + 1 wei);
        _expectUpgradeToV3Revert(_ids(DRIFTED_NODE_ID), bytes("Precompile stake exceeds tracked"));
    }

    function test_upgrade_with_no_nodes_to_sync_leaves_registry_untouched() public {
        _upgradeToV3(new uint64[](0));
        assertEq(stakedMonad.viewNodeByNodeId(DRIFTED_NODE_ID).staked, DRIFTED_STAKE, "Nothing synced");
        assertEq(stakedMonad.viewNodeByNodeId(HEALTHY_NODE_ID).staked, HEALTHY_STAKE);
        assertEq(_pendingDeposits(), 0);
    }

    function test_upgrade_syncs_multiple_nodes() public {
        StakerFaker.mockGetDelegator(HEALTHY_NODE_ID, address(stakedMonad), HEALTHY_STAKE);
        StakerFaker.mockGetDelegator(DRIFTED_NODE_ID, address(stakedMonad), 0);
        _upgradeToV3(_ids(HEALTHY_NODE_ID, DRIFTED_NODE_ID));

        assertEq(stakedMonad.viewNodeByNodeId(DRIFTED_NODE_ID).staked, 0, "Drifted node synced to zero");
        assertEq(stakedMonad.viewNodeByNodeId(HEALTHY_NODE_ID).staked, HEALTHY_STAKE, "Healthy node unchanged by sync");
        assertEq(_pendingDeposits(), DRIFTED_STAKE);
    }

    function test_upgrade_reverts_for_unknown_node() public {
        _expectUpgradeToV3Revert(_ids(999), abi.encodeWithSelector(CustomErrors.InvalidNode.selector));
    }

    /// @dev Mainnet shape: node 17 was later put back to weight 1 and re-bonded, drift rides on top of the new stake
    function test_upgrade_syncs_drift_on_top_of_rebonded_stake() public {
        vm.startPrank(ADMIN);
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: DRIFTED_NODE_ID, delta: 1, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);

        // Deposit enough that node 17's 1/101 share (~1 MON) is bonded on top of the tracked 3 wei
        uint96 depositAmount = 101 ether;
        stakedMonad.deposit{value: depositAmount}(0, ADMIN);
        StakerFaker.mockGetEpoch(4, false);
        StakerFaker.mockDelegate(DRIFTED_NODE_ID, true);
        StakerFaker.mockDelegate(HEALTHY_NODE_ID, true);
        stakedMonad.submitBatch();
        StakerFaker.clearMocks();
        vm.stopPrank();
        uint96 trackedBefore = stakedMonad.viewNodeByNodeId(DRIFTED_NODE_ID).staked;
        assertGt(trackedBefore, DRIFTED_STAKE, "Test setup: node 17 re-bonded");
        uint96 pendingBefore = _pendingDeposits(); // ingress rounding dust from the bonding above

        // Precompile holds everything delegated since, minus the 3 wei it swept
        StakerFaker.mockGetDelegator(DRIFTED_NODE_ID, address(stakedMonad), trackedBefore - DRIFTED_STAKE);
        _upgradeToV3(_ids(DRIFTED_NODE_ID));

        assertEq(stakedMonad.viewNodeByNodeId(DRIFTED_NODE_ID).staked, trackedBefore - DRIFTED_STAKE, "Synced to precompile");
        assertEq(_pendingDeposits() - pendingBefore, DRIFTED_STAKE, "Only the 3 wei are re-bonded");
        assertEq(stakedMonad.totalPooled(), HEALTHY_STAKE + DRIFTED_STAKE + depositAmount, "totalPooled untouched");
    }

    function test_upgrade_unblocks_egress_batches() public {
        _upgradeToV3();

        vm.startPrank(ADMIN);
        uint96 spotValue = stakedMonad.requestUnlock(5 ether, 0);

        // Only the healthy node is undelegated from, net of the re-bonded dust.
        // Any call for node 17 hits an unmocked selector and reverts.
        StakerFaker.mockGetEpoch(4, false);
        StakerFaker.mockUndelegate(HEALTHY_NODE_ID, spotValue - DRIFTED_STAKE, 0, true);
        stakedMonad.submitBatch();

        assertEq(stakedMonad.viewNodeByNodeId(HEALTHY_NODE_ID).staked, HEALTHY_STAKE - spotValue + DRIFTED_STAKE);
        assertEq(stakedMonad.viewNodeByNodeId(DRIFTED_NODE_ID).staked, 0);
        assertEq(stakedMonad.totalPooled(), HEALTHY_STAKE + DRIFTED_STAKE - spotValue);
    }

    /// @dev Without re-bonding the dust, a full exit would try to unbond 3 wei more than the healthy node holds
    function test_upgrade_full_exit_after_sync() public {
        _upgradeToV3();

        vm.startPrank(ADMIN);
        uint96 spotValue = stakedMonad.requestUnlock(uint96(stakedMonad.balanceOf(ADMIN)), 0);
        assertEq(spotValue, HEALTHY_STAKE + DRIFTED_STAKE, "1:1 redemption ratio expected");
        uint40 batchId = stakedMonad.currentBatchId();

        StakerFaker.mockGetEpoch(4, false);
        StakerFaker.mockUndelegate(HEALTHY_NODE_ID, HEALTHY_STAKE, 0, true);
        stakedMonad.submitBatch();

        assertEq(stakedMonad.viewNodeByNodeId(HEALTHY_NODE_ID).staked, 0, "Healthy node fully unbonded");
        assertEq(stakedMonad.totalPooled(), 0);
        (uint96 dustEgress,) = stakedMonad.batchWithdrawRequests(batchId + 1);
        assertEq(dustEgress, 0, "No egress dust");
    }

    function test_synced_node_can_be_removed() public {
        _upgradeToV3();
        vm.startPrank(ADMIN);
        StakerFaker.mockWithdraw(DRIFTED_NODE_ID, 0, true);
        stakedMonad.sweep(_ids(DRIFTED_NODE_ID), 1);
        stakedMonad.removeNode(DRIFTED_NODE_ID);
        vm.expectRevert(CustomErrors.InvalidNode.selector);
        stakedMonad.viewNodeByNodeId(DRIFTED_NODE_ID);
    }

    /// @dev A registry without node 17 (e.g. testnet) takes the upgrade with an empty sync list
    function test_upgrade_without_node_17_succeeds_with_empty_sync_list() public {
        (address proxy,) = DeployV1.deployV1(ADMIN);
        vm.startPrank(ADMIN);
        UpgradeV2FromV1.upgradeV2FromV1(proxy);
        vm.expectRevert(CustomErrors.InvalidNode.selector);
        StakedMonad(payable(proxy)).viewNodeByNodeId(DRIFTED_NODE_ID);

        address impl = UpgradeV3FromV2.upgradeV3FromV2(proxy, new uint64[](0));

        assertEq(address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT)))), impl, "Upgraded to V3");
    }
}
