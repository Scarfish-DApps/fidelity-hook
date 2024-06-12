// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "openzeppelin-contracts/access/Ownable.sol";

import "brevis/sdk/apps/framework/BrevisApp.sol";
import "brevis/sdk/interface/IBrevisProof.sol";
import "./FidelityHook.sol";
import "forge-std/console.sol";

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
// Updates the hook contract with the discounts applied to each pool and each user.
contract BrevisDataHandler is BrevisApp, Ownable {

    // event VolumeDataPushed(address indexed userAddr, address indexed currency, uint256 volume);

    bytes32 public vkHash;

    FidelityHook public hook;

    constructor(address brevisProof) BrevisApp(IBrevisProof(brevisProof)) Ownable(msg.sender) {}

    struct Discount {
        uint256 requiredVolume;
        uint16 discountRate; // In basis points (1% = 100 basis points)
    }

    mapping(bytes32 => mapping(address => Discount[])) public discounts; // PoolId => (Currency => Discounts)

    bytes32[] public poolIds; // List of all pool IDs

    function setHook(FidelityHook _hook) external onlyOwner {
        hook = _hook;
    }

    function handleProofResult(
        bytes32 /*_requestId*/,
        bytes32 _vkHash,
        bytes calldata _circuitOutput
    ) internal override {
        require(vkHash == _vkHash, "invalid vk");

        (address[] memory users, address[] memory currencies, uint256[] memory volumes) = decodeOutput(_circuitOutput);
        console.logString("EEEEEEEEEEE....");
        console.logAddress(users[0]);
        console.logAddress(currencies[0]);
        console.logUint(volumes[0]);
        console.log("EEEEEEeeEEEEEE.......");

        /// TODO Call the main Hook contract here ...
        (address[] memory eligibleUsers, bytes32[] memory poolIds, uint16[] memory disounts) = getEligibleDiscounts(users, currencies, volumes);
        console.logString("Eligible discounts: GOERGEEEEEE....");
        console.logString("eligibleUsers:");
        console.logAddress(eligibleUsers[0]);
        console.logString("PoolId:");
        console.logBytes32(poolIds[0]);
        console.logString("currencies:");
        console.logAddress(currencies[0]);
        console.logString("discounts:");
        console.logUint(disounts[0]);
        console.log("GOERGEEEEEE.......");
        hook.setOgDiscounts(eligibleUsers, poolIds, disounts);

        // emit VolumeDataPushed(userAddr, currency, volume);
    }

    function decodeOutput(bytes calldata o) internal pure returns (address[] memory, address[] memory, uint256[] memory) {
        // Each record is 72 bytes long
        uint256 recordLength = 72;
        uint256 numberOfRecords = o.length / recordLength;
        
        address[] memory users = new address[](numberOfRecords);
        address[] memory currencies = new address[](numberOfRecords);
        uint256[] memory volumes = new uint256[](numberOfRecords);
        // console.log(users);
        // console.log(currencies);
        // console.log(volumes);
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
        require(b.length == 32, "Invalid bytes length for conversion");

        uint256 number;
        for (uint i = 0; i < 32; i++) {
            number = number | (uint256(uint8(b[i])) << (8 * (31 - i)));
        }
        return number;
    }

    function setVkHash(bytes32 _vkHash) external onlyOwner {
        vkHash = _vkHash;
    }

    function setDiscounts(bytes32 poolId, address[] calldata currencies, uint256[] calldata volumes, uint16[] calldata discountsBps) external onlyOwner {
        require(currencies.length == volumes.length, "Input arrays must have the same length");
        require(currencies.length == discountsBps.length, "Input arrays must have the same length");

        for (uint256 i = 0; i < currencies.length; i++) {
            require(discountsBps[i] <= 10000, "Invalid discount rate"); // Max 100%
            discounts[poolId][currencies[i]].push(Discount({
                requiredVolume: volumes[i],
                discountRate: discountsBps[i]
            }));
        }

        // Ensure the poolId is in the poolIds array
        bool poolIdExists = false;
        for (uint256 i = 0; i < poolIds.length; i++) {
            if (poolIds[i] == poolId) {
                poolIdExists = true;
                break;
            }
        }
        if (!poolIdExists) {
            poolIds.push(poolId);
        }
    }

    function getDiscount(address user, bytes32 poolId, address currency, uint256 volume) external view returns (uint256) {
        uint256 highestDiscount = 0;
        for (uint256 i = 0; i < discounts[poolId][currency].length; i++) {
            if (volume >= discounts[poolId][currency][i].requiredVolume && discounts[poolId][currency][i].discountRate > highestDiscount) {
                highestDiscount = discounts[poolId][currency][i].discountRate;
            }
        }
        return highestDiscount;
    }

    function getEligibleDiscounts(address[] memory users, address[] memory currencies, uint256[] memory volumes)
        public
        view
        returns (address[] memory, bytes32[] memory, uint16[] memory)
    {
        require(users.length == currencies.length, "Input arrays must have the same length");
        require(users.length == volumes.length, "Input arrays must have the same length");

        uint256 count = 0;

        // First pass: calculate the number of eligible discounts to determine array sizes
        for (uint256 i = 0; i < users.length; i++) {
            for (uint256 j = 0; j < poolIds.length; j++) {
                uint16 discountRate = getHighestDiscount(poolIds[j], currencies[i], volumes[i]);
                if (discountRate > 0) {
                    count++;
                }
            }
        }

        console.logString("aaaaaaaaaaaaaaaa....");
        console.logAddress(users[0]);
        console.logAddress(currencies[0]);
        console.logUint(volumes[0]);
        console.logUint(count);
        console.log("aaaaaaaaaaaaaaaaaa.......");

        address[] memory eligibleUsers = new address[](count);
        bytes32[] memory eligiblePoolIds = new bytes32[](count);
        uint16[] memory eligibleDiscountRates = new uint16[](count);

        uint256 index = 0;

        // Second pass: populate the arrays with eligible discounts
        for (uint256 i = 0; i < users.length; i++) {
            for (uint256 j = 0; j < poolIds.length; j++) {
                uint16 discountRate = getHighestDiscount(poolIds[j], currencies[i], volumes[i]);
                if (discountRate > 0) {
                    eligibleUsers[index] = users[i];
                    eligiblePoolIds[index] = poolIds[j];
                    eligibleDiscountRates[index] = discountRate;
                    index++;
                }
            }
        }

        return (eligibleUsers, eligiblePoolIds, eligibleDiscountRates);
    }

    function getHighestDiscount(bytes32 poolId, address currency, uint256 volume) internal view returns (uint16) {
        uint16 highestDiscount = 0;
        for (uint256 i = 0; i < discounts[poolId][currency].length; i++) {
            if (volume >= discounts[poolId][currency][i].requiredVolume && discounts[poolId][currency][i].discountRate > highestDiscount) {
                highestDiscount = discounts[poolId][currency][i].discountRate;
            }
        }
        return highestDiscount;
    }
}
