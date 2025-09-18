// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/src/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StakedMonad, Registry, CustomErrors, IAccessControl} from "../src/StakedMonad.sol";
import {StakerFaker} from "./StakerFaker.sol";

contract RegistryTest is Test, StakerFaker {
    StakedMonad public stakedMonad;

    address payable public ADMIN = payable(vm.addr(100));
    address payable public ALICE = payable(vm.addr(101));
    address payable public BOB = payable(vm.addr(102));
    address payable public CHARLIE = payable(vm.addr(103));

    uint256 public constant FUNDING_AMOUNT = 1_000_000 ether;

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
        ERC1967Proxy stakedMonadProxy = new ERC1967Proxy(
            address(stakedMonadImpl),
            abi.encodeCall(StakedMonad.initialize, (ADMIN))
        );
        stakedMonad = StakedMonad(payable(stakedMonadProxy));
    }

    function test_viewNodeByNodeId_reverts_with_invalid_node() public {
        vm.expectRevert(CustomErrors.InvalidNode.selector);
        stakedMonad.viewNodeByNodeId(404);
    }

    function test_roles() public {
        bytes32[] memory roles = new bytes32[](4);
        roles[0] = stakedMonad.ROLE_ADD_NODE();
        roles[1] = stakedMonad.ROLE_UPDATE_WEIGHTS();
        roles[2] = stakedMonad.ROLE_DISABLE_NODE();
        roles[3] = stakedMonad.ROLE_REMOVE_NODE();

        for (uint256 i; i < 4; ++i) {
            bytes32 role = roles[i];
            vm.startPrank(ADMIN);
            stakedMonad.grantRole(role, ALICE);
            assertTrue(stakedMonad.hasRole(role, ALICE), "Admin can grant role");
            stakedMonad.renounceRole(role, ADMIN);
            assertFalse(stakedMonad.hasRole(role, ADMIN), "Admin can renounce role");
            stakedMonad.grantRole(role, BOB);
            assertTrue(stakedMonad.hasRole(role, BOB), "Admin (without role) can grant role");
            vm.startPrank(ALICE);
            vm.expectRevert(abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                ALICE,
                stakedMonad.DEFAULT_ADMIN_ROLE()
            ));
            stakedMonad.grantRole(role, CHARLIE);
            assertFalse(stakedMonad.hasRole(role, CHARLIE), "Role holder can NOT grant role");
        }

        for (uint256 i; i < 4; ++i) {
            bytes32 role = roles[i];
            vm.startPrank(ADMIN);
            stakedMonad.revokeRole(role, ALICE);
            assertFalse(stakedMonad.hasRole(role, ALICE), "Admin can revoke role");
            vm.startPrank(ALICE);
            vm.expectRevert(abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                ALICE,
                stakedMonad.DEFAULT_ADMIN_ROLE()
            ));
            stakedMonad.revokeRole(role, ADMIN);
        }
    }

    function test_addNode() public {
        vm.startPrank(ADMIN);

        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        Registry.Node[] memory nodes = stakedMonad.getNodes();
        assertEq(nodes.length, 1);
        assertEq(nodes[0].id, nodeId);
        assertEq(nodes[0].weight, 0);
        assertEq(nodes[0].staked, 0);

        uint256[] memory nodeIds = stakedMonad.getNodeIds();
        assertEq(nodeIds.length, 1);
        assertEq(nodeIds[0], nodeId);

        Registry.Node memory node = stakedMonad.viewNodeByNodeId(nodeId);
        assertEq(node.id, nodeId);
        assertEq(node.weight, 0);
        assertEq(node.staked, 0);
    }

    function test_addNode_cannot_add_duplicate_node() public {
        vm.startPrank(ADMIN);

        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        vm.expectRevert(CustomErrors.DuplicateNode.selector);
        stakedMonad.addNode(nodeId);
    }

    function test_addNode_must_have_role() public {
        vm.startPrank(BOB);

        bytes32 role = stakedMonad.ROLE_ADD_NODE();
        assertFalse(stakedMonad.hasRole(role, BOB));

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        stakedMonad.addNode(1);
    }

    function test_updateWeights_can_increase_weight() public {
        vm.startPrank(ADMIN);

        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        assertEq(stakedMonad.viewNodeByNodeId(nodeId).weight, 0);
        assertEq(stakedMonad.totalWeight(), 0);

        // Increase weight by 100e18
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100e18, isIncreasing: true });
        stakedMonad.updateWeights(weightDeltas);

        assertEq(stakedMonad.viewNodeByNodeId(nodeId).weight, 0 + 100e18);
        assertEq(stakedMonad.totalWeight(), 0 + 100e18);
    }

    function test_updateWeights_can_decrease_weight() public {
        vm.startPrank(ADMIN);

        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        // Increase weight by 100e18
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100e18, isIncreasing: true });
        stakedMonad.updateWeights(weightDeltas);

        assertEq(stakedMonad.viewNodeByNodeId(nodeId).weight, 100e18);
        assertEq(stakedMonad.totalWeight(), 100e18);

        // Decrease weight by 25e18
        weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 25e18, isIncreasing: false });
        stakedMonad.updateWeights(weightDeltas);

        assertEq(stakedMonad.viewNodeByNodeId(nodeId).weight, 100e18 - 25e18);
        assertEq(stakedMonad.totalWeight(), 100e18 - 25e18);
    }

    function test_updateWeights_can_decrease_weight_without_underflow() public {
        vm.startPrank(ADMIN);

        uint64 nodeId = 1;
        stakedMonad.addNode(nodeId);

        // Increase weight by 100e18
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100e18, isIncreasing: true });
        stakedMonad.updateWeights(weightDeltas);

        assertEq(stakedMonad.viewNodeByNodeId(nodeId).weight, 100e18);
        assertEq(stakedMonad.totalWeight(), 100e18);

        // Decrease weight by 101e18
        weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 101e18, isIncreasing: false });
        stakedMonad.updateWeights(weightDeltas);

        assertEq(stakedMonad.viewNodeByNodeId(nodeId).weight, 0);
        assertEq(stakedMonad.totalWeight(), 0);
    }

    function test_updateWeights_must_have_role() public {
        uint64 nodeId = 1;

        vm.startPrank(ADMIN);
        stakedMonad.addNode(nodeId);

        vm.startPrank(BOB);
        bytes32 role = stakedMonad.ROLE_UPDATE_WEIGHTS();
        assertFalse(stakedMonad.hasRole(role, BOB));

        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100e18, isIncreasing: true });
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        stakedMonad.updateWeights(weightDeltas);
    }

    function test_updateWeights_cannot_increase_disabled_node() public {
        uint64 nodeId = 1;

        vm.startPrank(ADMIN);
        stakedMonad.addNode(nodeId);

        stakedMonad.disableNode(nodeId);

        // Attempt increasing weight to 100e18
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100e18, isIncreasing: true });

        vm.expectRevert(CustomErrors.ActiveNode.selector);
        stakedMonad.updateWeights(weightDeltas);
    }

    function test_disableNode_sets_weight_to_zero() public {
        uint64 nodeId = 1;

        vm.startPrank(ADMIN);
        stakedMonad.addNode(nodeId);

        // Increase weight to 100e18
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100e18, isIncreasing: true });
        stakedMonad.updateWeights(weightDeltas);

        assertEq(stakedMonad.viewNodeByNodeId(nodeId).weight, 100e18);
        assertEq(stakedMonad.totalWeight(), 100e18);

        stakedMonad.disableNode(nodeId);

        assertEq(stakedMonad.viewNodeByNodeId(nodeId).weight, 0);
        assertEq(stakedMonad.totalWeight(), 0);
    }

    function test_disableNode_must_have_role() public {
        uint64 nodeId = 1;
        vm.startPrank(ADMIN);
        stakedMonad.addNode(nodeId);

        vm.startPrank(BOB);
        bytes32 role = stakedMonad.ROLE_DISABLE_NODE();
        assertFalse(stakedMonad.hasRole(role, BOB));

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        stakedMonad.disableNode(nodeId);
    }

    function test_removeNode_must_have_role() public {
        uint64 nodeId = 1;
        vm.startPrank(ADMIN);
        stakedMonad.addNode(nodeId);

        vm.startPrank(BOB);
        bytes32 role = stakedMonad.ROLE_REMOVE_NODE();
        assertFalse(stakedMonad.hasRole(role, BOB));

        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, BOB, role));
        stakedMonad.removeNode(nodeId);
    }

    function test_removeNode_must_have_no_pending_undelegations() public {
        uint64 nodeId = 1;
        vm.startPrank(ADMIN);
        stakedMonad.addNode(nodeId);

        // Increase weight to 100e18
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100e18, isIncreasing: true });
        stakedMonad.updateWeights(weightDeltas);

        // Stake
        uint96 shares = stakedMonad.deposit{value: 1 ether}(0, ADMIN);
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId, true);
        stakedMonad.submitBatch(); // Batch #1

        // Undelegate but do not withdraw
        stakedMonad.requestUnlock(shares, 0);
        (uint96 withdrawBatch,) = stakedMonad.batchWithdrawRequests(stakedMonad.currentBatchId());
        StakerFaker.mockGetEpoch(2, false);
        StakerFaker.mockUndelegate(nodeId, withdrawBatch, 0, true);
        stakedMonad.submitBatch();  // Batch #2

        vm.expectRevert(CustomErrors.PendingWithdrawals.selector);
        stakedMonad.removeNode(nodeId);
    }

    function test_removeNode_must_have_no_weight() public {
        uint64 nodeId = 1;
        vm.startPrank(ADMIN);
        stakedMonad.addNode(nodeId);

        // Increase weight to 100e18
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100e18, isIncreasing: true });
        stakedMonad.updateWeights(weightDeltas);

        assertGt(stakedMonad.viewNodeByNodeId(nodeId).weight, 0);
        vm.expectRevert(CustomErrors.ActiveNode.selector);
        stakedMonad.removeNode(nodeId);
    }

    function test_removeNode_must_have_no_stake() public {
        uint64 nodeId = 1;
        vm.startPrank(ADMIN);
        stakedMonad.addNode(nodeId);

        // Increase weight to 100e18
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100e18, isIncreasing: true });
        stakedMonad.updateWeights(weightDeltas);

        // Stake
        stakedMonad.deposit{value: 1 ether}(0, ADMIN);
        StakerFaker.mockGetEpoch(1, false);
        StakerFaker.mockDelegate(nodeId, true);
        stakedMonad.submitBatch();

        // Decrease weight to 0
        weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: nodeId, delta: 100e18, isIncreasing: false });
        stakedMonad.updateWeights(weightDeltas);

        assertGt(stakedMonad.viewNodeByNodeId(nodeId).staked, 0);
        vm.expectRevert(CustomErrors.ActiveNode.selector);
        stakedMonad.removeNode(nodeId);
    }
}
