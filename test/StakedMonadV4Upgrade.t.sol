// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./StakedMonad.t.sol";
import {StakedMonadV4Tests} from "./StakedMonadV4Deploy.t.sol";
import {StakedMonadV4, UUPSUpgradeable} from "../src/StakedMonadV4.sol";
import {UpgradeV2FromV1} from "../script/UpgradeV2FromV1.s.sol";
import {UpgradeV3FromV2} from "../script/UpgradeV3FromV2.s.sol";
import {UpgradeV4FromV3} from "../script/UpgradeV4FromV3.s.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

contract StakedMonadV4UpgradeTest is StakedMonadV4Tests, UpgradeV2FromV1, UpgradeV3FromV2, UpgradeV4FromV3 {
    function run() public override(DeployV1, UpgradeV2FromV1, UpgradeV3FromV2, UpgradeV4FromV3) {}

    function setUp() public override(StakedMonadTest) {
        // Deploy v1
        super.setUp();

        vm.startPrank(ADMIN);
        // Upgrade v1 to v2
        UpgradeV2FromV1.upgradeV2FromV1(address(stakedMonad));

        // Upgrade v2 to v3 with nothing to sync
        UpgradeV3FromV2.upgradeV3FromV2(address(stakedMonad), new uint64[](0));

        // Upgrade v3 to v4
        UpgradeV4FromV3.upgradeV4FromV3(address(stakedMonad));
        vm.stopPrank();
    }

    function test_cannot_initialize_again() public {
        vm.expectRevert("Expected a different version");
        StakedMonadV4(payable(stakedMonad)).initialize(ALICE);
    }

    function test_cannot_call_initializeFromV3_again() public {
        vm.expectRevert("Expected a different version");
        StakedMonadV4(payable(stakedMonad)).initializeFromV3();
    }

    function test_cannot_upgrade_v2_directly_to_v4() public {
        (address proxy,) = DeployV1.deployV1(ADMIN);
        vm.startPrank(ADMIN);
        UpgradeV2FromV1.upgradeV2FromV1(proxy);

        address impl = address(new StakedMonadV4());
        vm.expectRevert("Expected a different version");
        UUPSUpgradeable(proxy).upgradeToAndCall(impl, abi.encodeCall(StakedMonadV4.initializeFromV3, ()));
        vm.stopPrank();
    }

    /// @dev Balances and the pause flag carry across the upgrade, and the new transfer gate applies at once
    function test_upgrade_preserves_state_and_gates_transfers() public {
        (address proxy,) = DeployV1.deployV1(ADMIN);
        StakedMonad v3 = StakedMonad(payable(proxy));
        vm.startPrank(ADMIN);
        UpgradeV2FromV1.upgradeV2FromV1(proxy);
        UpgradeV3FromV2.upgradeV3FromV2(proxy, new uint64[](0));
        vm.stopPrank();

        vm.prank(ALICE);
        v3.deposit{value: 5 ether}(0, ALICE);

        // On V3, transfers go through while paused
        vm.prank(ADMIN);
        v3.pause();
        vm.prank(ALICE);
        assertTrue(v3.transfer(BOB, 1 ether), "V3 does not gate transfers on pause");

        // Upgrade while paused (startPrank: the helper deploys the implementation before calling the proxy)
        vm.startPrank(ADMIN);
        address impl = UpgradeV4FromV3.upgradeV4FromV3(proxy);
        vm.stopPrank();
        assertEq(address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT)))), impl, "Upgraded to V4");

        assertTrue(v3.paused(), "Pause flag survives the upgrade");
        assertEq(v3.balanceOf(ALICE), 4 ether, "Balances survive the upgrade");
        assertEq(v3.balanceOf(BOB), 1 ether);

        vm.prank(ALICE);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        v3.transfer(BOB, 1 ether);

        vm.prank(ADMIN);
        v3.unpause();
        vm.prank(ALICE);
        assertTrue(v3.transfer(BOB, 1 ether));
        assertEq(v3.balanceOf(BOB), 2 ether);
    }
}
