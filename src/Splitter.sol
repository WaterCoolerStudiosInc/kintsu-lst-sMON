// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Splitter is AccessControl, ReentrancyGuard {

    uint16 private constant BIPS = 10000;
    uint256 private constant MAX_SPLITS = 10;
    uint256 private bipsTotal;

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

    mapping(uint256 => Split) public splits;
    uint256 public splitCount;

    constructor(address initialAdmin) {
        AccessControl._grantRole(AccessControl.DEFAULT_ADMIN_ROLE, initialAdmin);
        AccessControl._grantRole(ROLE_SPLIT_CREATE, initialAdmin);
        AccessControl._grantRole(ROLE_SPLIT_UPDATE, initialAdmin);
        AccessControl._grantRole(ROLE_SPLIT_DELETE, initialAdmin);
    }

    receive() external payable virtual {}

    function updateSplits(uint256[] memory splitIndexes, Split[] memory newSplits) external nonReentrant {
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
