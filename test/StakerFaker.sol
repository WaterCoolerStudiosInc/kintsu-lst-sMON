// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/src/Test.sol";
import {IPrecompile} from "../src/precompile/Staker.sol";

abstract contract StakerFaker is Test {
    address private constant PRECOMPILE = 0x0000000000000000000000000000000000001000;

    function mockGetEpoch(uint64 epoch, bool in_epoch_delay_period) internal {
        vm.mockCall(
            PRECOMPILE,
            abi.encodeWithSelector(IPrecompile.getEpoch.selector),
            abi.encode(epoch, in_epoch_delay_period)
        );
    }

    function mockDelegate(uint64 val_id, bool isSuccess) internal {
        vm.mockCall(
            PRECOMPILE,
            abi.encodeWithSelector(IPrecompile.delegate.selector, val_id),
            abi.encode(isSuccess)
        );
    }

    function mockUndelegate(uint64 val_id, uint256 amount, uint8 withdrawId, bool isSuccess) internal {
        vm.mockCall(
            PRECOMPILE,
            abi.encodeWithSelector(IPrecompile.undelegate.selector, val_id, amount, withdrawId),
            abi.encode(isSuccess)
        );
    }

    // TODO: Manage dealing withdrawn funds
    function mockWithdraw(uint64 val_id, uint8 withdrawId, bool isSuccess) internal {
        vm.mockCall(
            PRECOMPILE,
            abi.encodeWithSelector(IPrecompile.withdraw.selector, val_id, withdrawId),
            abi.encode(isSuccess)
        );
    }

    // TODO: Manage dealing rewards
    function mockClaimRewards(uint64 val_id, bool isSuccess) internal {
        vm.mockCall(
            PRECOMPILE,
            abi.encodeWithSelector(IPrecompile.claimRewards.selector, val_id),
            abi.encode(isSuccess)
        );
    }

    function clearMocks() internal {
        vm.clearMockedCalls();
    }
}
