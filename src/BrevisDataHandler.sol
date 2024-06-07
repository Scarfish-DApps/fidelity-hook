// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "openzeppelin-contracts/access/Ownable.sol";

import "brevis/sdk/apps/framework/BrevisApp.sol";
import "brevis/sdk/interface/IBrevisProof.sol";

// Traders earn OG status if they have generated a certain amount of volume (defined by the pool initializer) in a certain amount of time before the calculation. 
// They benefit from a discount on the trading fees until the next calculation.
// 
// The pool initializer defines the required volumes per token and the discounts. 
// If multiple discounts are configured on a certain pool, the highest discount is applied.
//
// The Swap event is included into the Brevis proof:
// Swap (index_topic_1 address sender, index_topic_2 address recipient, int256 amount0, int256 amount1, uint160 sqrtPriceX96, uint128 liquidity, int24 tick)
//
// Brevis output:
// address[] users, address[] currencies, uint256[] volumes
// 
// The contract looks up the discount corresponding to the currency (and validates the volume). 
//
// Updates discounts on the hook contract.
contract BrevisDataHandler is BrevisApp, Ownable {

    // event VolumeDataPushed(address indexed userAddr, address indexed currency, uint256 volume);

    bytes32 public vkHash;

    constructor(address brevisProof) BrevisApp(IBrevisProof(brevisProof)) Ownable(msg.sender) {}

    function handleProofResult(
        bytes32 /*_requestId*/,
        bytes32 _vkHash,
        bytes calldata _circuitOutput
    ) internal override {
        require(vkHash == _vkHash, "invalid vk");

        (address[] memory users, address[] memory currencies, uint256[] memory volumes) = decodeOutput(_circuitOutput);

        /// TODO Call the main Hook contract here ...

        // emit VolumeDataPushed(userAddr, currency, volume);
    }

    function decodeOutput(bytes calldata o) internal pure returns (address[] memory, address[] memory, uint256[] memory) {
        // Each record is 72 bytes long
        uint256 recordLength = 72;
        uint256 numberOfRecords = o.length / recordLength;
        
        address[] memory users = new address[](numberOfRecords);
        address[] memory currencies = new address[](numberOfRecords);
        uint256[] memory volumes = new uint256[](numberOfRecords);
        
        uint256 offset = 0;
        
        for (uint256 i = 0; i < numberOfRecords; i++) {
            users[i] = address(bytes20(o[offset:offset + 20]));
            currencies[i] = address(bytes20(o[offset + 20:offset + 40]));
            volumes[i] = bytesToUint256(o[offset + 40:offset + 72]);
            offset += recordLength;
        }
        
        return (users, currencies, volumes);
    }

    function bytesToUint256(bytes memory b) internal pure returns (uint256) {
        require(b.length == 248, "Invalid bytes length for conversion");

        uint256 number;
        for (uint i = 0; i < 32; i++) {
            number = number | (uint256(uint8(b[i])) << (8 * (31 - i)));
        }
        return number;
    }

    function setVkHash(bytes32 _vkHash) external onlyOwner {
        vkHash = _vkHash;
    }

    struct Discount {
        uint256 requiredVolume;
        uint256 discountRate; // In basis points (1% = 100 basis points)
    }

    mapping(address => Discount[]) public discounts;
    mapping(address => uint256) public userDiscounts; // Stores the highest discount for each user

    function setDiscounts(address[] calldata currencies, uint256[] calldata volumes, uint8[] calldata discountsBps) external onlyOwner {
        require(currencies.length == volumes.length, "Input arrays must have the same length");
        require(currencies.length == discountsBps.length, "Input arrays must have the same length");

        for (uint256 i = 0; i < currencies.length; i++) {
            require(discountsBps[i] <= 10000, "Invalid discount rate"); // Max 100%
            discounts[currencies[i]].push(Discount({
                requiredVolume: volumes[i],
                discountRate: discountsBps[i]
            }));
        }
    }

   function getDiscount(address user, address currency, uint256 volume) external view returns (uint256) {
        uint256 highestDiscount = 0;
        for (uint256 i = 0; i < discounts[currency].length; i++) {
            if (volume >= discounts[currency][i].requiredVolume && discounts[currency][i].discountRate > highestDiscount) {
                highestDiscount = discounts[currency][i].discountRate;
            }
        }
        return highestDiscount;
    }
}