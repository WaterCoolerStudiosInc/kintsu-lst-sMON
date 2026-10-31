// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/src/Test.sol";
import "./StakedMonad.t.sol";
import {StakedMonadV4Tests} from "./StakedMonadV4Deploy.t.sol";
import {StakedMonadV4, UUPSUpgradeable} from "../src/StakedMonadV4.sol";
import {UpgradeV2FromV1} from "../script/UpgradeV2FromV1.s.sol";
import {UpgradeV3FromV2} from "../script/UpgradeV3FromV2.s.sol";
import {UpgradeV4FromV3} from "../script/UpgradeV4FromV3.s.sol";
import {StakedMonadV3} from "../src/StakedMonadV3.sol";

/// @notice Runs the full V1 + V3 + V4 suite against a proxy upgraded V1 -> V2 -> V3 -> V4
contract StakedMonadV4UpgradeTest is StakedMonadV4Tests, UpgradeV2FromV1, UpgradeV3FromV2, UpgradeV4FromV3 {
    function run() public override(DeployV1, UpgradeV2FromV1, UpgradeV3FromV2, UpgradeV4FromV3) {}

    function setUp() public override(StakedMonadTest) {
        // Deploy v1
        super.setUp();

        vm.startPrank(ADMIN);
        UpgradeV2FromV1.upgradeV2FromV1(address(stakedMonad));
        UpgradeV3FromV2.upgradeV3FromV2(address(stakedMonad), new uint64[](0));
        UpgradeV4FromV3.upgradeV4FromV3(address(stakedMonad));
        vm.stopPrank();
    }

    function test_cannot_initialize_again() public {
        vm.expectRevert("Expected a different version");
        StakedMonadV4(payable(stakedMonad)).initialize(ALICE);
    }

    function test_cannot_call_initializeFromV3_again() public {
        vm.prank(ADMIN);
        vm.expectRevert("Expected a different version");
        StakedMonadV4(payable(stakedMonad)).initializeFromV3();
    }
}

/// @notice Upgrade safety: state carried across, and the role grant cannot be front-run
contract StakedMonadV4UpgradeSafetyTest is Test, StakerFaker, DeployV1, UpgradeV2FromV1, UpgradeV3FromV2 {
    StakedMonad public stakedMonad;
    address payable public ADMIN = payable(vm.addr(100));
    address payable public ALICE = payable(vm.addr(101));
    address payable public MALLORY = payable(vm.addr(105));

    function run() public override(DeployV1, UpgradeV2FromV1, UpgradeV3FromV2) {}

    function setUp() public {
        vm.deal(ADMIN, 1_000_000 ether);
        vm.deal(ALICE, 1_000_000 ether);
        (address proxy,) = DeployV1.deployV1(ADMIN);
        stakedMonad = StakedMonad(payable(proxy));

        vm.startPrank(ADMIN);
        UpgradeV2FromV1.upgradeV2FromV1(address(stakedMonad));
        UpgradeV3FromV2.upgradeV3FromV2(address(stakedMonad), new uint64[](0));
        stakedMonad.addNode(1);
        Registry.WeightDelta[] memory weightDeltas = new Registry.WeightDelta[](1);
        weightDeltas[0] = Registry.WeightDelta({nodeId: 1, delta: 100, isIncreasing: true});
        stakedMonad.updateWeights(weightDeltas);
        vm.stopPrank();
    }

    function test_upgrade_preserves_balances_and_unlock_requests() public {
        vm.startPrank(ALICE);
        uint96 shares = stakedMonad.deposit{value: 10 ether}(0, ALICE);
        stakedMonad.requestUnlock(shares / 2, 0);
        vm.stopPrank();

        uint256 balanceBefore = stakedMonad.balanceOf(ALICE);
        uint256 supplyBefore = stakedMonad.totalSupply();
        uint96 pooledBefore = stakedMonad.totalPooled();
        uint40 batchBefore = stakedMonad.currentBatchId();
        StakedMonadV3.UnlockRequest memory requestBefore = StakedMonadV3(payable(stakedMonad)).getAllUserUnlockRequests(ALICE)[0];

        _upgradeAsAdmin();

        StakedMonadV4 v4 = StakedMonadV4(payable(stakedMonad));
        assertEq(v4.balanceOf(ALICE), balanceBefore, "Balance preserved");
        assertEq(v4.totalSupply(), supplyBefore, "Supply preserved");
        assertEq(v4.totalPooled(), pooledBefore, "totalPooled preserved");
        assertEq(v4.currentBatchId(), batchBefore, "Batch id preserved");
        StakedMonadV4.UnlockRequest memory requestAfter = v4.getAllUserUnlockRequests(ALICE)[0];
        assertEq(requestAfter.shares, requestBefore.shares, "Unlock shares preserved");
        assertEq(requestAfter.spotValue, requestBefore.spotValue, "Unlock value preserved");
        assertEq(requestAfter.batchId, requestBefore.batchId, "Unlock batch preserved");
        assertFalse(v4.isFrozen(ALICE), "Nobody starts frozen");
        assertTrue(v4.hasRole(v4.ROLE_UNPAUSE(), ADMIN), "Upgrading admin becomes unpauser");
        assertTrue(v4.hasRole(v4.ROLE_FREEZER(), ADMIN), "Upgrading admin becomes freezer");
        assertTrue(v4.hasRole(v4.ROLE_UNFREEZER(), ADMIN), "Upgrading admin becomes unfreezer");
        assertTrue(v4.hasRole(v4.ROLE_SEIZER(), ADMIN), "Upgrading admin becomes seizer");
    }

    /// @notice If the implementation is swapped without the init call, a stranger still cannot claim the roles
    function test_initializeFromV3_cannot_be_front_run() public {
        address impl = address(new StakedMonadV4());
        vm.prank(ADMIN);
        UUPSUpgradeable(address(stakedMonad)).upgradeToAndCall(impl, "");

        StakedMonadV4 v4 = StakedMonadV4(payable(stakedMonad));
        bytes32 defaultAdmin = v4.DEFAULT_ADMIN_ROLE();
        vm.prank(MALLORY);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, MALLORY, defaultAdmin));
        v4.initializeFromV3();

        assertFalse(v4.hasRole(v4.ROLE_UNPAUSE(), MALLORY));
        assertFalse(v4.hasRole(v4.ROLE_FREEZER(), MALLORY));
        assertFalse(v4.hasRole(v4.ROLE_UNFREEZER(), MALLORY));
        assertFalse(v4.hasRole(v4.ROLE_SEIZER(), MALLORY));

        // The admin can still finish the upgrade
        vm.prank(ADMIN);
        v4.initializeFromV3();
        assertTrue(v4.hasRole(v4.ROLE_UNPAUSE(), ADMIN));
        assertTrue(v4.hasRole(v4.ROLE_FREEZER(), ADMIN));
        assertTrue(v4.hasRole(v4.ROLE_UNFREEZER(), ADMIN));
    }

    function test_only_upgrader_can_upgrade_to_v4() public {
        address impl = address(new StakedMonadV4());
        bytes32 upgradeRole = stakedMonad.ROLE_UPGRADE();
        vm.prank(MALLORY);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, MALLORY, upgradeRole));
        UUPSUpgradeable(address(stakedMonad)).upgradeToAndCall(impl, abi.encodeCall(StakedMonadV4.initializeFromV3, ()));
    }

    function _upgradeAsAdmin() internal {
        address impl = address(new StakedMonadV4());
        vm.prank(ADMIN);
        UUPSUpgradeable(address(stakedMonad)).upgradeToAndCall(impl, abi.encodeCall(StakedMonadV4.initializeFromV3, ()));
    }
}
