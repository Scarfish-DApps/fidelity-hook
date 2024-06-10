pragma solidity ^0.8.24;

import "openzeppelin-contracts/token/ERC1155/ERC1155.sol";
import "openzeppelin-contracts/access/Ownable.sol";

/**
 * @title FidelityTokenFactory
 * @dev This contract is part of the FidelityHook project. It is used to create and manage 
 * fidelity tokens which are rewarded to users based on their trading volume. These tokens 
 * can be used to obtain discounts on swap fees within the Uniswap V4 pools.
 */
contract FidelityTokenFactory is ERC1155, Ownable {

    constructor(string memory uri) Ownable(msg.sender) ERC1155(uri) {}

    /**
     * @notice Mints new fidelity tokens.
     * @dev This function can only be called by the owner of the contract which is FidelityHook in this case.
     * @param account The address to which the minted tokens will be assigned.
     * @param tokenId The ID of the token type to be minted.
     * @param amount The amount of tokens to be minted.
     */
    function mint(address account, uint256 tokenId, uint256 amount) external onlyOwner {
        _mint(account, tokenId, amount, "");
    }
}