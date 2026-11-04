// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {CustomErrors} from "./CustomErrors.sol";

/**
 * @title FreezableUpgradeable
 * @notice Account blacklist for incident response
 * @dev The inheriting contract decides who may freeze/unfreeze (via the `_authorize*` hooks) and which
 *      operations a frozen account is blocked from (via `_requireNotFrozen()`)
 * @dev State lives in ERC-7201 namespaced storage, so this contract adds no slots to the inheriting contract's
 *      linear layout and may sit anywhere in its inheritance list
 */
abstract contract FreezableUpgradeable is Initializable, CustomErrors {
    event Frozen(address indexed account);
    event Unfrozen(address indexed account);

    error AccountFrozen(address account);
    error AccountNotFrozen(address account);

    // keccak256(abi.encode(uint256(keccak256("wcs.kintsu.storage.Freezable")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FreezableStorageLocation = 0x04c714fb5bf75a29910fe47e949fdd24a9443641cfcebc2c1b0249650175fb00;

    /// @custom:storage-location erc7201:wcs.kintsu.storage.Freezable
    struct FreezableStorage {
        mapping(address => bool) isFrozen;
    }

    function _getFreezableStorage() private pure returns (FreezableStorage storage $) {
        assembly {
            $.slot := FreezableStorageLocation
        }
    }

    function __Freezable_init() internal onlyInitializing {}
    function __Freezable_init_unchained() internal onlyInitializing {}

    function _authorizeFreeze(address account) internal virtual;
    function _authorizeUnfreeze(address account) internal virtual;

    function isFrozen(address account) public view returns (bool) {
        return _getFreezableStorage().isFrozen[account];
    }

    /// @notice Add `account` to the frozen set
    function freeze(address account) external {
        _authorizeFreeze(account);

        FreezableStorage storage $ = _getFreezableStorage();
        if ($.isFrozen[account]) revert NoChange();
        $.isFrozen[account] = true;
        emit Frozen(account);
    }

    /// @notice Remove `account` from the frozen set
    function unfreeze(address account) external {
        _authorizeUnfreeze(account);

        FreezableStorage storage $ = _getFreezableStorage();
        if (!$.isFrozen[account]) revert NoChange();
        $.isFrozen[account] = false;
        emit Unfrozen(account);
    }

    function _requireNotFrozen(address account) internal view {
        if (_getFreezableStorage().isFrozen[account]) revert AccountFrozen(account);
    }

    function _requireFrozen(address account) internal view {
        if (!_getFreezableStorage().isFrozen[account]) revert AccountNotFrozen(account);
    }
}
