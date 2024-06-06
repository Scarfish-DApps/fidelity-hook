pragma solidity ^0.8.24;

import "openzeppelin-contracts/token/ERC1155/ERC1155.sol";
import "openzeppelin-contracts/access/Ownable.sol";

contract FidelityTokenFactory is ERC1155, Ownable {
    constructor(string memory uri) Ownable(msg.sender) ERC1155(uri) {}

    function mint(address account, uint256 tokenId, uint256 amount) external onlyOwner {
        _mint(account, tokenId, amount, "");
    }
}