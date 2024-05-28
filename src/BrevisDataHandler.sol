// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "openzeppelin-contracts/access/Ownable.sol";

import "brevis/sdk/apps/framework/BrevisApp.sol";
import "brevis/sdk/interface/IBrevisProof.sol";

contract BrevisDataHandler is BrevisApp, Ownable {

    event VolumeDataPushed(address indexed userAddr, uint64 indexed minBlockNum, uint256 sumVolume, bytes32 salt);

    bytes32 public vkHash;

    constructor(address brevisProof) BrevisApp(IBrevisProof(brevisProof)) Ownable(msg.sender) {}

    function handleProofResult(
        bytes32 /*_requestId*/,
        bytes32 _vkHash,
        bytes calldata _circuitOutput
    ) internal override {
        require(vkHash == _vkHash, "invalid vk");

        (bytes32 salt, uint256 sumVolume, uint64 minBlockNum, address userAddr) = decodeOutput(_circuitOutput);

        /// TODO Call the main Hook contract here ...

        emit VolumeDataPushed(userAddr, minBlockNum, sumVolume, salt);
    }

    function decodeOutput(bytes calldata o) internal pure returns (bytes32, uint256, uint64, address) {
        // api.OutputBytes32(Salt)
        bytes32 salt = bytes32(o[0:32]);
	    // api.OutputUint(248, sumVolume)
        uint256 sumVolume = bytesToUint256(o[32:280]);
	    // api.OutputUint(64, minBlockNum)
        uint64 minBlockNum = bytesToUint64(o[280:344]);
	    // api.OutputAddress(c.UserAddr)
        address userAddr = address(bytes20(o[344:364]));
        return (salt, sumVolume, minBlockNum, userAddr);
    }

    function bytesToUint256(bytes memory b) internal pure returns (uint256) {
        require(b.length == 248, "Invalid bytes length for conversion");

        uint256 number;
        for (uint i = 0; i < 32; i++) {
            number = number | (uint256(uint8(b[i])) << (8 * (31 - i)));
        }
        return number;
    }

    function bytesToUint64(bytes memory b) internal pure returns (uint64) {
        require(b.length == 8, "Invalid bytes length for uint64");
        uint64 number;
        for (uint i = 0; i < 8; i++) {
            number = number | (uint64(uint8(b[i])) << (8 * (7 - i)));
        }
        return number;
    }

    function setVkHash(bytes32 _vkHash) external onlyOwner {
        vkHash = _vkHash;
    }
}