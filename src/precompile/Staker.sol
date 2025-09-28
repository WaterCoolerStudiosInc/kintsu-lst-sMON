// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

interface IPrecompile {
    /// @dev Gas cost ~260850
    function delegate(uint64 val_id) external payable returns (bool);
    /// @dev Gas cost ~147750
    function undelegate(uint64 val_id, uint256 amount, uint8 withdraw_id) external returns (bool);
    /// @dev Gas cost ~285050
    function compound(uint64 val_id) external returns (bool);
    /// @dev Gas cost ~68675
    function withdraw(uint64 val_id, uint8 withdraw_id) external returns (bool);
    /// @dev Gas cost ~155375
    function claimRewards(uint64 val_id) external returns (bool);

    /// @dev Gas cost ~184900
    function getDelegator(
        uint64 val_id,
        address delegator
    ) external returns (
        uint256 stake,
        uint256 acc_reward_per_token,
        uint256 rewards,
        uint256 delta_stake,
        uint256 next_delta_stake,
        uint256 delta_epoch,
        uint256 next_delta_epoch
    );

    /// @dev Gas cost ~16200
    function getEpoch() external returns (uint64 epoch, bool in_epoch_delay_period);
}

abstract contract Staker {
    struct WithdrawIdSummary {
        /// @dev Pointer to the oldest withdraw id within the range of [0, 254]
        uint8 oldest;
        /// @dev Quantity of non-forced withdraw ids being tracked
        uint8 size;
    }

    error PrecompileCallFailed();
    error InsufficientPendingWithdrawals();
    error MaxPendingWithdrawals();

    address private constant PRECOMPILE = 0x0000000000000000000000000000000000001000;

    uint8 private constant PENDING_WITHDRAWALS_CAPACITY = 255; // [0, 254]
    uint8 private constant FORCED_WITHDRAW_ID = 255;

    mapping(uint64 => WithdrawIdSummary) private _withdrawIds;
    mapping(uint64 => bool) private _isForceWithdrawPending;

    /// @dev Reserve storage slots to avoid clashes if adding extra variables
    uint256[64] private __gap;

    /**
     * @notice Determine the current epoch and timing within the epoch (before or after the boundary block)
     * @dev If `in_epoch_delay_period` is false, the boundary block has not been reached yet
            and write operations at that time should be effective for epoch + 1.
            If `in_epoch_delay_period` is true, the network is past the boundary block
            and write operations at that time should be effective for epoch + 2
     * @return epoch - Current epoch number
     * @return in_epoch_delay_period - True when past the boundary block, and False otherwise
     */
    function getEpoch() internal returns (uint64 epoch, bool in_epoch_delay_period) {
        return IPrecompile(PRECOMPILE).getEpoch();
    }

    /**
     * @notice Provides the number of epochs that must pass before an undelegation can be withdrawn
     * @dev TODO: Robustly provide from a reliable source or as a constant
     */
    function getWithdrawDelay() internal view returns (uint8) {
        // Monad Mainnet
        if (block.chainid == 143) return 7;
        // Local network
        if (block.chainid == 31337) return 7;
        return 1;
    }

    /**
     * @notice Creates a delegator account if it does not exist and increments the delegator's balance
     * @dev The delegator stake becomes active:
            - in epoch n+1 if the request is before the boundary block
            - in epoch n+2 otherwise
     * @param val_id - id of the validator that delegator would like to delegate to
     * @param amount - the amount to delegate
     */
    function delegate(uint64 val_id, uint256 amount) internal {
        bool success = IPrecompile(PRECOMPILE).delegate{value: amount}(val_id);
        if (!success) revert PrecompileCallFailed();
    }

    /**
     * @notice Begins the withdraw process for normal undelegation
     * @dev Allocates ids within a relatively large range
     * @dev Range: [0, PENDING_WITHDRAWALS_CAPACITY - 1] => [0, 254]
     * @param val_id - Validator ID
     * @param amount - Amount of MON in wei to undelegate
     * @return withdrawId - Withdraw ID that tracks this undelegation
     */
    function undelegate(uint64 val_id, uint256 amount) internal returns (uint8 withdrawId) {
        WithdrawIdSummary storage withdrawIdSummary = _withdrawIds[val_id];
        WithdrawIdSummary memory _withdrawIdSummary = withdrawIdSummary; // shadow (SLOAD 1 slot)

        if (_withdrawIdSummary.size == PENDING_WITHDRAWALS_CAPACITY) revert MaxPendingWithdrawals();

        // Calculate the next available ID by advancing from the oldest pointer
        withdrawId = _modularAdd(_withdrawIdSummary.oldest, _withdrawIdSummary.size, PENDING_WITHDRAWALS_CAPACITY);

        // Update size in storage
        withdrawIdSummary.size = _withdrawIdSummary.size + 1;

        _undelegate(val_id, amount, withdrawId);
    }

    /**
     * @notice Begins the withdraw process for disabled validators
     * @dev Allocates to FORCED_WITHDRAW_ID (255)
     * @param val_id - Validator ID
     * @param amount - Amount of MON in wei to undelegate
     * @return withdrawId - Withdraw ID that tracks this undelegation
     */
    function undelegateForced(uint64 val_id, uint256 amount) internal returns (uint8 withdrawId) {
        if (_isForceWithdrawPending[val_id]) revert MaxPendingWithdrawals();
        withdrawId = FORCED_WITHDRAW_ID;
        _undelegate(val_id, amount, withdrawId);
        _isForceWithdrawPending[val_id] = true;
    }

    /**
     * @notice Deducts amount from the delegator account and moves it to a withdrawal request object,
               where it remains in a pending state for a predefined number of epochs before the funds are claimable
     * @dev Delegator can only remove stake after it has activated. This is the stake field in the delegator struct
     * @dev The delegator stake becomes inactive:
            - in epoch n+1 if the request is before the boundary block
            - in epoch n+2 otherwise
     * @param val_id - id of the validator to which sender previously delegated, from which we are removing delegation
     * @param amount - amount to unstake, in Monad wei
     * @param withdrawId - id tracking the newly created undelegation
     */
    function _undelegate(uint64 val_id, uint256 amount, uint8 withdrawId) private {
        bool success = IPrecompile(PRECOMPILE).undelegate(val_id, amount, withdrawId);
        if (!success) revert PrecompileCallFailed();
    }

    /**
     * @notice Completes multiple undelegation actions (which started by calling the undelegate function),
               sending the amount to msg.sender, provided that sufficient epochs have passed
     * @dev Let k represent the withdrawal_delay, then a withdrawal request becomes withdrawable and thus unslashable
            - in epoch n+1+k if request is not in the epoch delay period since the undelegate call
            - in epoch n+2+k if request is in the epoch delay period since the undelegate call
     * @param val_id - id of the validator to which sender previously delegated, from which we previously issued an undelegate command
     * @param maxWithdraws - maximum quantity of pending withdrawals to process and remove
     */
    function withdraw(uint64 val_id, uint8 maxWithdraws) internal {
        WithdrawIdSummary memory withdrawIdSummary = _withdrawIds[val_id]; // shadow (SLOAD 1 slot)
        uint8 withdrawCount = withdrawIdSummary.size > maxWithdraws ? maxWithdraws : withdrawIdSummary.size;

        // Cheaply return as a no-op if no withdraw ids will be processed
        if (withdrawCount == 0) return;

        for (uint256 i; i < withdrawCount; ++i) {
            uint8 withdrawId = _modularAdd(withdrawIdSummary.oldest, uint8(i), PENDING_WITHDRAWALS_CAPACITY);
            bool success = IPrecompile(PRECOMPILE).withdraw(val_id, withdrawId);
            if (!success) revert PrecompileCallFailed();
        }

        withdrawIdSummary.oldest = _modularAdd(withdrawIdSummary.oldest, withdrawCount, PENDING_WITHDRAWALS_CAPACITY);
        withdrawIdSummary.size -= withdrawCount;
        _withdrawIds[val_id] = withdrawIdSummary;
    }

    /**
     * @notice Similar to `withdraw()` but only withdraws the FORCED_WITHDRAW_ID for a given validator
     * @dev Will revert if FORCED_WITHDRAW_ID is not pending
     */
    function withdrawForced(uint64 val_id) internal {
        if (!_isForceWithdrawPending[val_id]) revert InsufficientPendingWithdrawals();

        bool success = IPrecompile(PRECOMPILE).withdraw(val_id, FORCED_WITHDRAW_ID);
        if (!success) revert PrecompileCallFailed();

        _isForceWithdrawPending[val_id] = false;
    }

    /**
     * @notice Allows a delegator to claim any rewards instead of redelegating them.
     * @dev `val_id` must correspond to a valid validator to which the sender previously delegated
     * @dev If delegator account does not exist, the call reverts
     * @param val_id - id of the validator to which sender previously delegated, for which we are claiming rewards
     */
    function claimRewards(uint64 val_id) internal {
        bool success = IPrecompile(PRECOMPILE).claimRewards(val_id);
        if (!success) revert PrecompileCallFailed();
    }

    /**
     * @notice Provides a view of the delegator’s stake across execution, consensus, and snapshot contexts
     */
    function getDelegator(uint64 val_id, address delegator) public returns (
        uint256 stake,
        uint256 acc_reward_per_token,
        uint256 rewards,
        uint256 delta_stake,
        uint256 next_delta_stake,
        uint256 delta_epoch,
        uint256 next_delta_epoch
    ) {
        return IPrecompile(PRECOMPILE).getDelegator(val_id, delegator);
    }

    /**
     * @notice Converts the WithdrawIdSummary for a validator into an array of withdraw ids
     * @dev Will not include FORCED_WITHDRAW_ID even if present
     */
    function getWithdrawIds(uint64 val_id) public view returns (uint8[] memory) {
        WithdrawIdSummary memory withdrawIdSummary = _withdrawIds[val_id];
        uint8[] memory withdrawIds = new uint8[](withdrawIdSummary.size);
        for (uint256 i; i < withdrawIdSummary.size; ++i) {
            withdrawIds[i] = _modularAdd(withdrawIdSummary.oldest, uint8(i), PENDING_WITHDRAWALS_CAPACITY);
        }
        return withdrawIds;
    }

    function getWithdrawIdsSize(uint64 val_id) public view returns (uint256) {
        return _withdrawIds[val_id].size;
    }

    function isForceWithdrawPending(uint64 val_id) public view returns (bool) {
        return _isForceWithdrawPending[val_id];
    }

    function _modularAdd(uint8 a, uint8 b, uint8 mod) private pure returns (uint8) {
        return uint8((uint256(a) + uint256(b)) % uint256(mod));
    }
}
