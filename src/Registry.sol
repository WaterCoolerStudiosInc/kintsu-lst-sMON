// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "./CustomErrors.sol";

/**
 * @title Registry
 * @author Brandon Mino <brandon@kintsu.xyz>
 * @notice Maintains a list of nodes and their respective weights
 */
abstract contract Registry is CustomErrors {
    using EnumerableSet for EnumerableSet.UintSet;

    struct Node {
        uint64 id;     //  8 bytes
        uint96 weight; // 12 bytes
        uint96 staked; // 12 bytes
    }

    struct WeightDelta {
        uint64 nodeId;
        uint96 delta;
        bool isIncreasing;
    }

    event NodeAdded(uint64 nodeId, uint256 index);
    event NodeUpdated(uint64 indexed nodeId, uint256 newWeight);
    event NodeDisabled(uint64 nodeId);
    event NodeRemoved(uint64 nodeId);

    EnumerableSet.UintSet private _nodeIds;
    mapping(uint64 => uint256) private _nodeIdToOffsetIndex;

    /// @notice List of currently managed nodes. Order is NOT guaranteed to remain constant
    Node[] public nodes;

    /// @notice Sum of node relative weights
    uint256 public totalWeight;

    /// @dev Tracks if a node has been disabled
    mapping(uint64 => bool) public isNodeDisabled;

    /// @dev Reserve storage slots to avoid clashes if adding extra variables
    uint256[64] private __gap;

    function _authorizeAddNode() internal virtual;
    function _authorizeUpdateWeight() internal virtual;
    function _authorizeDisableNode() internal virtual;
    function _authorizeRemoveNode(uint64 nodeId) internal virtual;

    /**
     * @notice View all unique node ids in their current order
     * @dev The order is not guaranteed to remain constant between calls
     * @dev The order is not guaranteed to correlate to a position in `getNodes()`
     */
    function getNodeIds() external view returns (uint256[] memory) {
        return _nodeIds.values();
    }

    /**
     * @notice View all nodes in their current order
     * @dev The order is not guaranteed to remain constant between calls
     */
    function getNodes() external view returns (Node[] memory) {
        return nodes;
    }

    /// @notice View a node by its unique node id
    function viewNodeByNodeId(uint64 nodeId) external view returns (Node memory node) {
        return getNodeByNodeId(nodeId);
    }

    /**
     * @notice Adds a new node
     * @dev Cannot add a node that already exists
     */
    function addNode(uint64 nodeId) external {
        _authorizeAddNode();

        if (_nodeIds.add(nodeId) == false) revert DuplicateNode();

        // Add to list
        Node memory newNode;
        newNode.id = nodeId;
        nodes.push(newNode);

        /// Using array length will "include" the +1 offset
        uint256 offsetIndex = nodes.length;

        // Add lookup
        _nodeIdToOffsetIndex[nodeId] = offsetIndex;

        emit NodeAdded(nodeId, offsetIndex);
    }

    /**
     * @notice Modifies node weights by incrementing/decrementing
     * @dev Cannot increase weight of a node that has been disabled
     * @dev Decreasing weight below 0 will not underflow and instead remains at 0
     * @dev Decreasing weight of a node that has been disabled is effectively a no-op
     * @dev Updating a deleted or non-existent node is effectively a no-op
     */
    function updateWeights(WeightDelta[] calldata weightDeltas) external {
        _authorizeUpdateWeight();

        uint256 _totalWeight = totalWeight; // shadow

        uint256 len = weightDeltas.length;
        for (uint256 i; i < len; ++i) {
            if (weightDeltas[i].isIncreasing) {
                Node storage node = getNodeByNodeId(weightDeltas[i].nodeId);
                if (isNodeDisabled[node.id]) revert ActiveNode();
                uint96 oldWeight = node.weight;
                uint96 newWeight = oldWeight + weightDeltas[i].delta;

                node.weight = newWeight;
                _totalWeight = _totalWeight - oldWeight + newWeight;
                emit NodeUpdated(weightDeltas[i].nodeId, newWeight);
            } else {
                // Lookup node without `getNodeByNodeId()`
                uint256 offsetIndex = _nodeIdToOffsetIndex[weightDeltas[i].nodeId];
                if (offsetIndex == 0) continue; // No-op: node does not exist
                Node storage node = nodes[offsetIndex - 1];
                uint96 oldWeight = node.weight; // shadow
                uint96 newWeight;

                if (oldWeight == 0) continue; // No-op: zero weight and potentially disabled
                uint96 weightDelta = weightDeltas[i].delta;

                // Partially decreasing weight, otherwise new weight is 0
                if (weightDelta < oldWeight) {
                    newWeight = oldWeight - weightDelta;
                }

                node.weight = newWeight;
                _totalWeight = _totalWeight - oldWeight + newWeight;
                emit NodeUpdated(weightDeltas[i].nodeId, newWeight);
            }
        }

        totalWeight = _totalWeight;
    }

    /**
     * @notice Permanently set node weight to 0
     * @dev Intended to prepare a node for removal via `Registry.removeNode()`
     * @dev Once disabled, node cannot be assigned a weight
     */
    function disableNode(uint64 nodeId) external {
        _authorizeDisableNode();

        if (isNodeDisabled[nodeId]) revert NoChange();

        Node storage node = getNodeByNodeId(nodeId);
        totalWeight -= node.weight;
        node.weight = 0;

        isNodeDisabled[nodeId] = true;

        emit NodeDisabled(nodeId);
    }

    /**
     * @notice Removes a node from storage
     * @dev Intended to prevent storage bloat
     */
    function removeNode(uint64 nodeId) external {
        _authorizeRemoveNode(nodeId);

        uint256 offsetIndex = _nodeIdToOffsetIndex[nodeId];
        if (offsetIndex == 0) revert InvalidNode();

        Node memory node = nodes[offsetIndex - 1]; // shadow (SLOAD 1 slot)
        if (node.weight > 0) revert ActiveNode();
        if (node.staked > 0) revert ActiveNode();

        Node storage lastNode = nodes[nodes.length - 1];

        // Replace the element being removed with the last element
        _nodeIdToOffsetIndex[lastNode.id] = offsetIndex;
        nodes[offsetIndex - 1] = lastNode;

        // Remove the last element
        delete _nodeIdToOffsetIndex[nodeId];
        nodes.pop();

        // Allow this node to be added again via `addNode()`
        _nodeIds.remove(nodeId);

        emit NodeRemoved(nodeId);
    }

    /**
     * @notice Returns a storage reference to a node by its unique node id
     * @dev If the node does not exist, throws an exception
     */
    function getNodeByNodeId(uint64 nodeId) internal view returns (Node storage node) {
        uint256 i = _nodeIdToOffsetIndex[nodeId];
        if (i == 0) revert InvalidNode();
        node = nodes[i - 1];
    }
}
