// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Splitter.sol";

contract SplitterFactory {
    event SplitterCreated(address splitter);

    constructor() {}

    function create(uint256 maxSplits, address splitterAdmin) external returns (address payable) {
        Splitter newSplitter = new Splitter(maxSplits, splitterAdmin, new Splitter.Split[](0));
        emit SplitterCreated(address(newSplitter));
        return payable(newSplitter);
    }

    function createAndUpdateSplits(
        uint256 maxSplits,
        address splitterAdmin,
        Splitter.Split[] memory initialSplits
    ) external returns (address payable) {
        Splitter newSplitter = new Splitter(maxSplits, splitterAdmin, initialSplits);
        emit SplitterCreated(address(newSplitter));
        return payable(newSplitter);
    }
}
