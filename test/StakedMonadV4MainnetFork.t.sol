// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Test} from "forge-std/src/Test.sol";
import {StakerFaker} from "./StakerFaker.sol";
import {StakedMonadV3} from "../src/StakedMonadV3.sol";
import {StakedMonadV4, UUPSUpgradeable} from "../src/StakedMonadV4.sol";
import {FreezableUpgradeable} from "../src/FreezableUpgradeable.sol";

/**
 * @notice Replays the 2026-10-31 kintsu.xyz drain against Monad mainnet state.
 *         A drainer address queued 2,635,884 stolen sMON for unlock in batch 1511 (already submitted).
 *         Upgrading the live proxy to V4 from the admin Safe must let the Safe freeze that address and
 *         redirect the unbonding MON to a recovery address.
 * @dev Skipped unless run against a Monad mainnet fork at the pinned block:
 *      forge test --mc StakedMonadV4MainnetForkTest --fork-url monad_mainnet --fork-block-number 118225087
 *      Foundry only builds a Monad EVM when the fork is chosen on the command line, so the test cannot fork itself.
 * @dev Monad's staking precompile does not exist in the forked EVM, so `getEpoch()` is mocked.
 */
contract StakedMonadV4MainnetForkTest is Test, StakerFaker {
    uint256 internal constant MONAD_MAINNET_CHAIN_ID = 143;

    address payable internal constant PROXY = payable(0xA3227C5969757783154C60bF0bC1944180ed81B9);
    address internal constant ADMIN_SAFE = 0xabe1aDe2f6506D6F9B44d141247eb23060a466F6;
    address internal constant DRAINER = 0x012f89Ff307568F8409Bbe379ca92ED41Bc4D386;
    uint96 internal constant DRAINED_SHARES = 2_635_884_195_434_891_581_563_840;

    address payable internal RECOVERY = payable(vm.addr(0x5eed));

    bool internal forked;

    function setUp() public {
        forked = block.chainid == MONAD_MAINNET_CHAIN_ID;
    }

    function test_rescue_drainer_unlock_request() public {
        vm.skip(!forked);

        StakedMonadV3.UnlockRequest memory stolen = StakedMonadV3(PROXY).getAllUserUnlockRequests(DRAINER)[0];
        assertEq(stolen.batchId, 1511, "Fork setup: drainer request is in batch 1511");
        assertApproxEqAbs(stolen.shares, DRAINED_SHARES, 1 ether, "Fork setup: drainer request holds the stolen sMON");

        uint256 supplyBefore = StakedMonadV3(PROXY).totalSupply();
        uint96 pooledBefore = StakedMonadV3(PROXY).totalPooled();

        // Upgrade exactly as the Safe would
        address impl = address(new StakedMonadV4());
        vm.prank(ADMIN_SAFE);
        UUPSUpgradeable(PROXY).upgradeToAndCall(impl, abi.encodeCall(StakedMonadV4.initializeFromV3, ()));

        StakedMonadV4 v4 = StakedMonadV4(PROXY);
        assertEq(v4.totalSupply(), supplyBefore, "Upgrade preserves supply");
        assertEq(v4.totalPooled(), pooledBefore, "Upgrade preserves totalPooled");

        // Freeze the drainer and take over its unbonding claim (works whether or not sMON is paused)
        vm.startPrank(ADMIN_SAFE);
        v4.freeze(DRAINER);
        v4.seizeUnlockRequest(DRAINER, 0, RECOVERY);

        // sMON was paused on 2026-10-31 to stop the drainer redeeming; resume once the claim is safe
        if (v4.paused()) v4.unpause();
        vm.stopPrank();

        assertEq(v4.getAllUserUnlockRequests(DRAINER).length, 0, "Drainer has no claim left");

        // Withdrawal delay long past
        StakerFaker.mockGetEpoch(2_400, false);

        vm.prank(DRAINER);
        vm.expectRevert(abi.encodeWithSelector(FreezableUpgradeable.AccountFrozen.selector, DRAINER));
        v4.redeem(0, payable(DRAINER));

        uint256 balanceBefore = RECOVERY.balance;
        vm.prank(RECOVERY);
        v4.redeem(0, RECOVERY);
        assertEq(RECOVERY.balance - balanceBefore, stolen.spotValue, "Recovery receives the unbonded MON");
    }
}
