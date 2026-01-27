// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Splitter
 * @notice Distributes received MON to multiple targets based on configurable percentage allocations
 * @dev Uses basis points (bips) for percentage calculations where 10000 bips = 100%
 */
contract Splitter is AccessControl, ReentrancyGuard {

    uint16 private constant BIPS = 10000;
    uint256 private bipsTotal;

    /**
     * @notice Configuration for a single split recipient
     * @param bips Percentage allocation in basis points (1 bip = 0.01%)
     * @param _target Address to receive funds
     * @param _calldata Optional calldata to execute on the target when withdrawing
     */
    struct Split {
        uint16 bips;
        address _target;
        bytes _calldata;
    }

    event SplitCreated(uint256 index, Split split);
    event SplitUpdated(uint256 index, Split oldSplit, Split newSplit);
    event SplitDeleted(uint256 index, Split oldSplit);
    event SplitApplied(uint256 index, address _target, bytes _calldata, uint256 _value);

    bytes32 public constant ROLE_SPLIT_CREATE = keccak256("ROLE_SPLIT_CREATE");
    bytes32 public constant ROLE_SPLIT_UPDATE = keccak256("ROLE_SPLIT_UPDATE");
    bytes32 public constant ROLE_SPLIT_DELETE = keccak256("ROLE_SPLIT_DELETE");

    /// @notice Mapping of split index to split configuration
    mapping(uint256 => Split) public splits;

    /// @notice Number of active splits
    uint256 public splitCount;

    /// @notice Maximum number of splits allowed
    uint256 public immutable MAX_SPLITS;

    /**
     * @notice Creates a new Splitter contract
     * @param maxSplits Maximum number of splits allowed (must be 1-32)
     * @param initialAdmin Address to receive all admin and split management roles
     * @param initialSplits Optional array of splits to configure at deployment (bips must sum to 10000)
     */
    constructor(
        uint256 maxSplits,
        address initialAdmin,
        Split[] memory initialSplits
    ) {
        require(maxSplits > 0, "Not enough splits");
        require(maxSplits <= 32, "Too many splits");
        MAX_SPLITS = maxSplits;

        AccessControl._grantRole(AccessControl.DEFAULT_ADMIN_ROLE, initialAdmin);
        AccessControl._grantRole(ROLE_SPLIT_CREATE, initialAdmin);
        AccessControl._grantRole(ROLE_SPLIT_UPDATE, initialAdmin);
        AccessControl._grantRole(ROLE_SPLIT_DELETE, initialAdmin);

        uint256 initialSplitsLength = initialSplits.length;
        if (initialSplitsLength > 0) {
            bool isMsgSenderAdmin = msg.sender == initialAdmin;

            if (!isMsgSenderAdmin) {
                AccessControl._grantRole(ROLE_SPLIT_CREATE, msg.sender);
            }

            uint256[] memory initialSplitIndexes = new uint256[](initialSplitsLength);
            for (uint256 i; i < initialSplitsLength; ++i) {
                initialSplitIndexes[i] = i;
            }
            updateSplits(initialSplitIndexes, initialSplits);

            if (!isMsgSenderAdmin) {
                AccessControl._revokeRole(ROLE_SPLIT_CREATE, msg.sender);
            }
        }
    }

    receive() external payable virtual {}

    /**
     * @notice Returns all active splits and their indexes
     * @return indexes Array of indexes where splits are configured
     * @return activeSplits Array of split configurations
     */
    function getActiveSplits() external view returns (uint256[] memory indexes, Split[] memory activeSplits) {
        indexes = new uint256[](splitCount);
        activeSplits = new Split[](splitCount);
        uint256 j;
        for (uint256 i; i < MAX_SPLITS; ++i) {
            if (splits[i].bips > 0) {
                indexes[j] = i;
                activeSplits[j] = splits[i];
                ++j;
            }
        }
    }

    /**
     * @notice Returns the next available split index
     * @return The first index where no split is configured
     */
    function getNextAvailableIndex() external view returns (uint256) {
        for (uint256 i; i < MAX_SPLITS; ++i) {
            if (splits[i].bips == 0) return i;
        }
        revert("No available index");
    }

    /**
     * @notice Creates, updates, or deletes splits in a single transaction
     * @dev Requires appropriate role for each operation. Total bips must equal 10000 after all changes.
     * @param splitIndexes Array of split indexes to modify
     * @param newSplits Array of new split configurations (use bips=0 to delete)
     */
    function updateSplits(uint256[] memory splitIndexes, Split[] memory newSplits) public {
        uint256 n = splitIndexes.length;
        require(newSplits.length == n, "Mismatched arguments");

        uint256 _bipsTotal = bipsTotal; // shadow

        for (uint256 i; i < n; ++i) {
            uint256 splitIndex = splitIndexes[i];
            require(splitIndex < MAX_SPLITS, "Invalid split index");

            Split memory newSplit = newSplits[i];
            require(newSplit.bips <= BIPS, "Invalid split bips");

            Split memory oldSplit = splits[splitIndex];
            _bipsTotal = _bipsTotal - oldSplit.bips + newSplit.bips;

            if (newSplit.bips > 0 && oldSplit.bips == 0) {
                // Create new split
                AccessControl._checkRole(ROLE_SPLIT_CREATE, msg.sender);
                splits[splitIndex] = newSplit;
                ++splitCount;
                emit SplitCreated(splitIndex, newSplit);
            } else if (newSplit.bips == 0 && oldSplit.bips > 0) {
                // Delete existing split
                AccessControl._checkRole(ROLE_SPLIT_DELETE, msg.sender);
                delete splits[splitIndex];
                --splitCount;
                emit SplitDeleted(splitIndex, oldSplit);
            } else if (oldSplit.bips > 0 && newSplit.bips > 0) {
                // Updating existing split
                AccessControl._checkRole(ROLE_SPLIT_UPDATE, msg.sender);
                splits[splitIndex] = newSplit;
                emit SplitUpdated(splitIndex, oldSplit, newSplit);
            } else {
                revert("Invalid update");
            }
        }

        require(_bipsTotal == BIPS, "Insufficient allocations");
        bipsTotal = _bipsTotal;
    }

    /**
     * @notice Distributes the contract's MON balance to all configured splits
     * @dev Each split receives (balance * bips / 10000). Reverts if any transfer fails.
     */
    function withdraw() external nonReentrant {
        uint256 _balance = address(this).balance;
        uint256 _splitCount = splitCount; // shadow
        uint256 splitsApplied;

        for (uint256 i; i < MAX_SPLITS; ++i) {
            Split memory split = splits[i];

            // Skip invalid (empty) splits
            if (split.bips == 0) continue;

            uint256 value = _balance * split.bips / BIPS;
            (bool success, bytes memory responseData) = split._target.call{value: value}(split._calldata);
            if (!success) {
                if (responseData.length == 0) {
                    revert("Transaction execution reverted");
                } else {
                    assembly {
                        revert(add(32, responseData), mload(responseData))
                    }
                }
            }
            emit SplitApplied(i, split._target, split._calldata, value);

            // No need to check more splits if we have found them all
            if (++splitsApplied >= _splitCount) return;
        }
    }
}
