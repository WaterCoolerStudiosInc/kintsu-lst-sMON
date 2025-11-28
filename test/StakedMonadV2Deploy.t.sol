// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./StakedMonad.t.sol";
import {StakedMonadV2, Initializable} from "../src/StakedMonadV2.sol";
import {DeployV2} from "../script/DeployV2.s.sol";

contract StakedMonadV2DeployTest is StakedMonadTest, DeployV2 {
    function run() public override(DeployV1, DeployV2) {}
    function writeArtifacts(string memory, string memory, address) internal override(DeployV1, DeployV2) {}

    function setUp() public override(StakedMonadTest) {
        // Deploy v1
        super.setUp();

        // Deploy v2 directly
        (address proxy,) = DeployV2.deployV2(ADMIN);

        // Overwrite previously deployed v1 to run tests against v2
        stakedMonad = StakedMonad(payable(proxy));
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
