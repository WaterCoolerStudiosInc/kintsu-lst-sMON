// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Splitter.sol";

contract SplitterFactory {
    event SplitterCreated(address splitter);

    constructor() {}

    function create(address splitterAdmin) external returns (address) {
        Splitter newSplitter = new Splitter(splitterAdmin);
        emit SplitterCreated(address(newSplitter));
        return address(newSplitter);
    }
}
