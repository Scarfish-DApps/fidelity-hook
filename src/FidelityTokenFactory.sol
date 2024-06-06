pragma solidity ^0.8.24;

import "openzeppelin-contracts/token/ERC1155/ERC1155.sol";
import "openzeppelin-contracts/access/Ownable.sol";

contract FidelityTokenFactory is ERC1155, Ownable {
    uint256 public nextTokenId;

    constructor(string memory uri) Ownable(msg.sender) ERC1155(uri) {
        nextTokenId = 0;
    }

    function createToken() external onlyOwner returns (uint256) {
        uint256 tokenId = nextTokenId;
        nextTokenId++;
        return tokenId;
    }

    function mint(address account, uint256 tokenId, uint256 amount) external onlyOwner {
        _mint(account, tokenId, amount, "");
    }

    function resetCampaign() external onlyOwner {
        nextTokenId++;
    }
}