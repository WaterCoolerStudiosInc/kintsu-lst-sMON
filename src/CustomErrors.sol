// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/**
 * @title CustomErrors
 * @author Brandon Mino <https://github.com/bmino>
 * @notice Central location for defining errors across the protocol
 */
interface CustomErrors {
    /// @notice Thrown when trying to interact with a node that is still active (not disabled)
    error ActiveNode();

    /// @notice Thrown when trying to redeem from a batch that hasn't been submitted
    error BatchNotSubmitted();

    /// @notice Thrown when trying to cancel an unlock request outside the cancellation window
    error CancellationWindowClosed();

    /// @notice Thrown when deposit amount exceeds uint96 maximum value
    error DepositOverflow();

    /// @notice Thrown when trying to interact with a node that is disabled
    error DisabledNode();

    /// @notice Thrown when trying to duplicate a currently existing node
    error DuplicateNode();

    /// @notice Thrown when trying to submit an empty batch (no deposits or withdrawals)
    error EmptyBatch();

    /// @notice Thrown when trying to set a fee percentage above the maximum allowed
    error FeeTooLarge();

    /// @notice Thrown when trying to interact or lookup a node that does not currently exist
    error InvalidNode();

    /// @notice Thrown when trying to submit a batch before the minimum submission delay
    error MinimumBatchDelay();

    /// @notice Thrown when trying to contribute to the protocol when sufficient TVL has not been reached
    error MinimumContributeThreshold();

    /// @notice Thrown when minted shares would not meet the user provided threshold
    error MinimumDeposit();

    /// @notice Thrown when unlock amount would not meet the user provided threshold
    error MinimumUnlock();

    /// @notice Thrown when an action will have no effect and should fail fast
    error NoChange();

    /// @notice Thrown when trying to remove a node while withdrawals are still pending
    error PendingWithdrawals();

    /// @notice Thrown when a transfer of ETH fails
    error TransferFailed();

    /// @notice Thrown when trying to redeem from a batch that hasn't completed its withdraw delay
    error WithdrawDelay();

    /// @notice Thrown when total weight is zero during bonding operations
    error ZeroTotalWeight();
}
