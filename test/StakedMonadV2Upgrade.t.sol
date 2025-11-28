// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./StakedMonad.t.sol";
import {StakedMonadV2, Initializable} from "../src/StakedMonadV2.sol";
import {UpgradeV2FromV1} from "../script/UpgradeV2FromV1.s.sol";

contract StakedMonadV2UpgradeTest is StakedMonadTest, UpgradeV2FromV1 {
    function run() public override(DeployV1, UpgradeV2FromV1) {}
    function setUp() public override(StakedMonadTest) {
        // Deploy v1
        super.setUp();

        // Upgrade v1 to v2
        vm.startPrank(ADMIN);
        UpgradeV2FromV1.upgradeV2FromV1(address(stakedMonad));
        vm.stopPrank();
    }

    function test_cannot_initialize_v1_again() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        StakedMonadV2(payable(stakedMonad)).initialize(ALICE);
    }

    function test_cannot_reinitialize_v2_again() public {
        vm.expectRevert("Expected a different version");
        StakedMonadV2(payable(stakedMonad)).initializeFromV1();
    }
}
