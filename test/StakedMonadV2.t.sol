// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./StakedMonad.t.sol";
import "../src/StakedMonadV2.sol";

contract StakedMonadV2Test is StakedMonadTest {
    function setUp() public override(StakedMonadTest) {
        // Setup StakedMonad (v1)
        super.setUp();

        // Deploy StakedMonadV2
        StakedMonadV2 newImplementation = new StakedMonadV2();

        // Upgrade v1 to v2
        vm.startPrank(ADMIN);
        stakedMonad.upgradeToAndCall(
            address(newImplementation),
            abi.encodeCall(StakedMonadV2.initializeFromV1, ())
        );
    }
}
