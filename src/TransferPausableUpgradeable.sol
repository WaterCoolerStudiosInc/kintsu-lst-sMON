// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {CustomErrors} from "./CustomErrors.sol";

/**
 * @title TransferPausableUpgradeable
 * @notice Token-level pause for holder-to-holder transfers, separate from the protocol pause
 * @dev The inheriting contract decides who may pause/unpause transfers (via the `_authorize*` hooks) and which
 *      entrypoints are blocked (via `_requireTransfersNotPaused()`)
 * @dev State lives in ERC-7201 namespaced storage, so this contract adds no slots to the inheriting contract's
 *      linear layout and may sit anywhere in its inheritance list
 */
abstract contract TransferPausableUpgradeable is Initializable, CustomErrors {
    event TransfersPaused(address account);
    event TransfersUnpaused(address account);

    error EnforcedTransferPause();

    // keccak256(abi.encode(uint256(keccak256("wcs.kintsu.storage.TransferPausable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TransferPausableStorageLocation = 0xab9b5668e0826be23c18256031522208d965f285fc3542f7a2463e296fc4b300;

    /// @custom:storage-location erc7201:wcs.kintsu.storage.TransferPausable
    struct TransferPausableStorage {
        bool transfersPaused;
    }

    function _getTransferPausableStorage() private pure returns (TransferPausableStorage storage $) {
        assembly {
            $.slot := TransferPausableStorageLocation
        }
    }

    function __TransferPausable_init() internal onlyInitializing {}
    function __TransferPausable_init_unchained() internal onlyInitializing {}

    function _authorizePauseTransfers() internal virtual;
    function _authorizeUnpauseTransfers() internal virtual;

    function transfersPaused() public view returns (bool) {
        return _getTransferPausableStorage().transfersPaused;
    }

    /// @notice Halt holder-to-holder transfers
    function pauseTransfers() external {
        _authorizePauseTransfers();
        _pauseTransfers();
    }

    /// @notice Resume holder-to-holder transfers
    function unpauseTransfers() external {
        _authorizeUnpauseTransfers();

        TransferPausableStorage storage $ = _getTransferPausableStorage();
        if (!$.transfersPaused) revert NoChange();
        $.transfersPaused = false;
        emit TransfersUnpaused(msg.sender);
    }

    /// @dev Unauthenticated; callers must authorize first
    function _pauseTransfers() internal {
        TransferPausableStorage storage $ = _getTransferPausableStorage();
        if ($.transfersPaused) revert NoChange();
        $.transfersPaused = true;
        emit TransfersPaused(msg.sender);
    }

    function _requireTransfersNotPaused() internal view {
        if (_getTransferPausableStorage().transfersPaused) revert EnforcedTransferPause();
    }
}
