// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {MockBrevisProof} from "../src/MockBrevisProof.sol";
import {BrevisDataHandler} from "../src/BrevisDataHandler.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {FidelityHook} from "../src/FidelityHook.sol";
import {FidelityTokenFactory} from "../src/FidelityHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {SwapFeeLibrary} from "v4-core/src/libraries/SwapFeeLibrary.sol";
import {ERC1155Holder} from "openzeppelin-contracts/token/ERC1155/utils/ERC1155Holder.sol";

contract BrevisOGTest is Test, Deployers, ERC1155Holder {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    FidelityHook fidelityHook;
    PoolId poolId;
    BrevisDataHandler brevisDataHandler;
    MockBrevisProof mockBrevisProof;
    bytes32 vkHash = 0x1234000000000000000000000000000000000000000000000000000000000000;


    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Deploy our hook with the proper flags
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_FLAG |
                Hooks.AFTER_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        (, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(FidelityHook).creationCode,
            abi.encode(manager)
        );

        fidelityHook = new FidelityHook{salt: salt}(manager);

        // Initialize a pool
        (key, ) = initPool(
            currency0,
            currency1,
            fidelityHook,
            SwapFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
            SQRT_RATIO_1_1,
            abi.encode(7 days, 2 ether, 1 ether, 10000, 2000)
        );

        // Add some liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether
            }),
            ZERO_BYTES
        );

        mockBrevisProof = new MockBrevisProof();
        brevisDataHandler = new BrevisDataHandler(address(mockBrevisProof)); 
        brevisDataHandler.setVkHash(vkHash); // Set a dummy vkHash
        brevisDataHandler.setHook(fidelityHook);
    }

    function test_PoolConfigInitialization() public {
        (
            uint256 interval,
            FidelityHook.Bound memory volThreshold,
            FidelityHook.Bound memory feeLimits,
            ,
        ) = fidelityHook.poolConfig(key.toId());

        assertEq(interval, 7 days);
        assertEq(volThreshold.upper, 2 ether);
        assertEq(volThreshold.lower, 1 ether);
        assertEq(feeLimits.upper, 10000);
        assertEq(feeLimits.lower, 2000);

        // Mock Brevis output
        address[] memory users = new address[](1);
        address[] memory currencies = new address[](1);
        uint256[] memory volumes = new uint256[](1);

        users[0] = address(this);
        currencies[0] =address(uint160(uint(keccak256(abi.encodePacked(currency0.toId())))));

        volumes[0] = 1.5 ether; // Volume above the lower threshold

        bytes memory circuitOutput = abi.encodePacked(
            bytes20(users[0]),
            bytes20(currencies[0]),
            bytes32(volumes[0])
        );
        uint256 discount = fidelityHook.getUserDiscount(address(this), PoolId.unwrap(key.toId()));

        assertEq(discount, 0); // check before

        bytes32 requestId = 0x0000000000000000000000000000000000000000000000000000000000000000;
        mockBrevisProof.setMockOutput(0x0, keccak256(circuitOutput), vkHash);
        // Call the brevisCallback function which should trigger handleProofResult
        brevisDataHandler.brevisCallback(0x0, circuitOutput);

        // Verify discount applied in FidelityHook
        discount = fidelityHook.getUserDiscount(address(this), PoolId.unwrap(key.toId()));
        assertEq(discount, 10000); // Verify discount rate is set correctly
    }

}