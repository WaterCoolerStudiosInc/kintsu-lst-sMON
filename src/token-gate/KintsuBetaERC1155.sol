// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract KintsuBetaERC1155 is ERC1155, Ownable {

    bool public isTransferEnabled = false;

    constructor(string memory uri) Ownable(msg.sender) ERC1155(uri) {}

    /**
     * @dev Mint tokens to a specific address
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(
        address to,
        uint256 amount
    ) public onlyOwner {
        _mint(to, 0, amount, "");
    }

    /**
     * @dev Mint tokens to multiple addresses in a batch
     * @param to Array of addresses to mint tokens to
     * @param amounts Array of amounts to mint for each token ID
     */
    function mintBatch(
        address[] calldata to,
        uint256[] calldata amounts
    ) external onlyOwner {
        uint256 toLength = to.length;
        require(toLength == amounts.length, "Inputs must have same length");

        for (uint256 i; i < toLength; ++i) {
            _mint(to[i], 0, amounts[i], "");
        }
    }

    /**
     * @dev Mint 1 token to multiple addresses in a batch
     * @param to Array of addresses to mint 1 token to
     */
    function mintSingleBatch(
        address[] calldata to
    ) external onlyOwner {
        uint256 toLength = to.length;
        for (uint256 i; i < toLength; ++i) {
            _mint(to[i], 0, 1, "");
        }
    }

    /**
     * @dev Burn tokens from a specific address (owner only)
     * @param from The address to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burn(
        address from,
        uint256 amount
    ) public onlyOwner {
        _burn(from, 0, amount);
    }

    /**
     * @dev Burn tokens from multiple addresses in a batch (owner only)
     * @param from Array of addresses to burn tokens from
     * @param amounts Array of amounts to burn
     */
    function burnBatch(
        address[] memory from,
        uint256[] memory amounts
    ) public onlyOwner {
        uint256 fromLength = from.length;
        require(fromLength == amounts.length, "Inputs must have same length");

        for (uint256 i; i < fromLength; ++i) {
            _burn(from[i], 0, amounts[i]);
        }
    }

    /**
     * @dev Set a new URI for the contract
     * @param newUri The new URI to set
     */
    function setURI(string memory newUri) external onlyOwner {
        _setURI(newUri);
    }

    /**
     * @dev Toggles the transferability of the NFTs
     */
    function setTransferable(bool isTransferable) external onlyOwner {
        isTransferEnabled = isTransferable;
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes memory data
    ) public virtual override {
        if (isTransferEnabled) {
            super.safeTransferFrom(from, to, id, value, data);
        } else {
            revert("Transfers are not allowed");
        }
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) public virtual override {
        if (isTransferEnabled) {
            super.safeBatchTransferFrom(from, to, ids, values, data);
        } else {
            revert("Batch transfers are not allowed");
        }
    }
}
