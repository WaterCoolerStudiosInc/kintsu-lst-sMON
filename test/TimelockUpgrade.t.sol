// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./StakedMonad.t.sol";
import {StakedMonadV2, Initializable, UUPSUpgradeable} from "../src/StakedMonadV2.sol";
import {DeployV2} from "../script/DeployV2.s.sol";
import {DeployTimelock} from "../script/DeployTimelock.s.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @notice Verifies the timelocked ROLE_UPGRADE flow set up by DeployTimelock.
 *         After setup: direct admin upgrades must revert, and the only path to
 *         upgrade the implementation is schedule -> wait -> execute on the timelock.
 */
contract TimelockUpgradeTest is StakedMonadTest, DeployV2, DeployTimelock {
    TimelockController public timelock;
    uint256 public constant TIMELOCK_DELAY = 48 hours;

    // Override harness entrypoints so inheriting them into a test contract doesn't
    // accidentally try to broadcast or read env vars.
    function run() public override(DeployV1, DeployV2, DeployTimelock) {}
    function writeArtifacts(string memory, string memory, address) internal override(DeployV1, DeployV2) {}
    function writeTimelockArtifact(address) internal override(DeployTimelock) {}

    function setUp() public override(StakedMonadTest) {
        super.setUp();

        // Deploy V2 with ADMIN holding every role (including ROLE_UPGRADE).
        (address proxy,) = DeployV2.deployV2(ADMIN);
        stakedMonad = StakedMonad(payable(proxy));

        // ADMIN is the sole proposer (and, by OZ default, canceller).
        address[] memory proposers = new address[](1);
        proposers[0] = ADMIN;

        // Open executor: anyone may execute once the delay has elapsed.
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        vm.startPrank(ADMIN);
        address timelockAddr = DeployTimelock.deployTimelockAndTransferRole(
            proxy,
            ADMIN,
            TIMELOCK_DELAY,
            proposers,
            executors
        );
        vm.stopPrank();

        timelock = TimelockController(payable(timelockAddr));
    }

    /// @dev ROLE_UPGRADE has been transferred to the timelock, so the base test
    ///      (which expects ADMIN to hold it) no longer applies. Re-verify the
    ///      remaining self-administered roles here, and defer ROLE_UPGRADE
    ///      assertions to the dedicated tests below.
    function test_roles_self_managed() public override {
        bytes32[] memory roles = new bytes32[](3);
        roles[0] = stakedMonad.ROLE_FEE_SETTER();
        roles[1] = stakedMonad.ROLE_FEE_CLAIMER();
        roles[2] = stakedMonad.ROLE_FEE_EXEMPTION();

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

    function _roleUpgrade() private view returns (bytes32) {
        return StakedMonadV2(payable(address(stakedMonad))).ROLE_UPGRADE();
    }

    function test_role_transferred_to_timelock() public view {
        bytes32 role = _roleUpgrade();
        assertFalse(stakedMonad.hasRole(role, ADMIN), "admin should no longer hold ROLE_UPGRADE");
        assertTrue(stakedMonad.hasRole(role, address(timelock)), "timelock should hold ROLE_UPGRADE");
    }

    function test_role_admin_is_self_managed_so_timelock_controls_future_grants() public view {
        // ROLE_UPGRADE remains self-administered; only the timelock can grant/revoke it now.
        bytes32 role = _roleUpgrade();
        assertEq(stakedMonad.getRoleAdmin(role), role, "ROLE_UPGRADE admin must remain self-managed");
    }

    function test_direct_admin_upgrade_reverts() public {
        address newImpl = address(new StakedMonadV2());
        bytes32 role = _roleUpgrade();
        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ADMIN, role));
        UUPSUpgradeable(address(stakedMonad)).upgradeToAndCall(newImpl, "");
    }

    function test_non_proposer_cannot_schedule() public {
        address newImpl = address(new StakedMonadV2());
        bytes memory payload = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImpl, ""));

        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ALICE, timelock.PROPOSER_ROLE()));
        timelock.schedule(address(stakedMonad), 0, payload, bytes32(0), bytes32(0), TIMELOCK_DELAY);
    }

    function test_cannot_execute_before_delay() public {
        address newImpl = address(new StakedMonadV2());
        bytes memory payload = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImpl, ""));
        bytes32 salt = bytes32(0);

        vm.startPrank(ADMIN);
        timelock.schedule(address(stakedMonad), 0, payload, bytes32(0), salt, TIMELOCK_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + TIMELOCK_DELAY - 1);

        vm.expectRevert(); // TimelockUnexpectedOperationState — not yet Ready
        timelock.execute(address(stakedMonad), 0, payload, bytes32(0), salt);
    }

    function test_upgrade_via_timelock_succeeds_after_delay() public {
        address newImpl = address(new StakedMonadV2());
        bytes memory payload = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImpl, ""));
        bytes32 salt = bytes32(0);

        vm.startPrank(ADMIN);
        timelock.schedule(address(stakedMonad), 0, payload, bytes32(0), salt, TIMELOCK_DELAY);
        vm.stopPrank();

        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Open executor: any address may call execute.
        vm.prank(BOB);
        timelock.execute(address(stakedMonad), 0, payload, bytes32(0), salt);

        // Proxy still usable post-upgrade; sanity-check with a cheap view call.
        assertEq(address(stakedMonad).code.length > 0, true);
    }

    function test_cancel_scheduled_upgrade() public {
        address newImpl = address(new StakedMonadV2());
        bytes memory payload = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImpl, ""));
        bytes32 salt = bytes32(0);

        vm.startPrank(ADMIN);
        timelock.schedule(address(stakedMonad), 0, payload, bytes32(0), salt, TIMELOCK_DELAY);
        bytes32 id = timelock.hashOperation(address(stakedMonad), 0, payload, bytes32(0), salt);
        assertTrue(timelock.isOperationPending(id), "op should be pending after schedule");

        timelock.cancel(id);
        assertFalse(timelock.isOperationPending(id), "op should be cleared after cancel");
        vm.stopPrank();

        // Cancelled op cannot be executed even after delay.
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);
        vm.expectRevert();
        timelock.execute(address(stakedMonad), 0, payload, bytes32(0), salt);
    }
}
