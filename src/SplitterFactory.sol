// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Splitter.sol";

contract SplitterFactory {
    event SplitterCreated(address splitter);

    constructor() {}

    function create(uint256 maxSplits, address splitterAdmin) external returns (address) {
        Splitter newSplitter = new Splitter(maxSplits, splitterAdmin);
        emit SplitterCreated(address(newSplitter));
        return address(newSplitter);
    }
}
