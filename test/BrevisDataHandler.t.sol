// // SPDX-License-Identifier: MIT
// pragma solidity ^0.8.25;

// import "forge-std/Test.sol";
// import {BrevisDataHandler} from "../src/BrevisDataHandler.sol";
// import {FidelityHook} from "../src/FidelityHook.sol";
// import {Hooks} from "v4-core/src/libraries/Hooks.sol";
// import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
// import {PoolKey} from "v4-core/src/types/PoolKey.sol";
// import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
// import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
// import {Deployers} from "v4-core/test/utils/Deployers.sol";
// import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
// import {ERC1155Holder} from "openzeppelin-contracts/token/ERC1155/utils/ERC1155Holder.sol";
// import {SwapFeeLibrary} from "v4-core/src/libraries/SwapFeeLibrary.sol";

// contract BrevisDataHandlerTest is Test, Deployers, ERC1155Holder {
//     using PoolIdLibrary for PoolKey;
//     using CurrencyLibrary for Currency;

//     BrevisDataHandler brevisDataHandler;
//     FidelityHook fidelityHook;
//     // PoolKey key;

//     function setUp() public {
//         // Deploy v4-core
//         deployFreshManagerAndRouters();

//         // Deploy, mint tokens, and approve all periphery contracts for two tokens
//         (currency0, currency1) = deployMintAndApprove2Currencies();

//         // Deploy the FidelityHook contract
//         uint160 flags = uint160(
//             Hooks.BEFORE_INITIALIZE_FLAG |
//                 Hooks.BEFORE_SWAP_FLAG |
//                 Hooks.AFTER_SWAP_FLAG |
//                 Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
//                 Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
//         );
//         (, bytes32 salt) = HookMiner.find(
//             address(this),
//             flags,
//             type(FidelityHook).creationCode,
//             abi.encode(manager)
//         );

//         fidelityHook = new FidelityHook{salt: salt}(manager);

//         brevisDataHandler = new BrevisDataHandler(address(this)); // Mock Brevis proof address
//         brevisDataHandler.setVkHash(0x1234000000000000000000000000000000000000000000000000000000000000); // Set a dummy vkHash
//         brevisDataHandler.setHook(fidelityHook);

//         key = PoolKey({
//             currency0: Currency.wrap(address(currency0)),
//             currency1: Currency.wrap(address(currency1)),
//             fee: SwapFeeLibrary.DYNAMIC_FEE_FLAG,
//             tickSpacing: 1
//         });

//         poolManager.initialize(key, SQRT_RATIO_1_1, abi.encode(7 days, 2 ether, 1 ether, 10000, 2000));

//         modifyLiquidityRouter.modifyLiquidity(
//             key,
//             IPoolManager.ModifyLiquidityParams({
//                 tickLower: -60,
//                 tickUpper: 60,
//                 liquidityDelta: 100 ether
//             }),
//             ZERO_BYTES
//         );
//     }

//     function testHandleProofResult() public {
//         // Mock Brevis output
//         address[] memory users = new address[](1);
//         address[] memory currencies = new address[](1);
//         uint256[] memory volumes = new uint256[](1);

//         users[0] = address(this);
//         currencies[0] = address(currency0); 
//         volumes[0] = 1.5 ether;

//         bytes memory circuitOutput = abi.encodePacked(
//             bytes20(users[0]),
//             bytes20(currencies[0]),
//             bytes32(volumes[0])
//         );

//         brevisDataHandler.brevisCallback(0x0, circuitOutput);

//         uint256 discount = fidelityHook.getUserDiscount(address(this), key.toId());
//         assertEq(discount, 10000); 
//     }
// }

// // Mock implementation of IPoolManager
// abstract contract PoolManagerMock is IPoolManager {
//     function getSlot0(bytes32) external pure override returns (uint160, int24, uint16, uint8) {
//         return (1 << 96, 0, 0, 0);
//     }

//     function updateDynamicSwapFee(PoolKey calldata, uint24) external pure override {
//         // Mock implementation
//     }

//     function modifyLiquidity(
//         PoolKey calldata,
//         IPoolManager.ModifyLiquidityParams calldata,
//         bytes calldata
//     ) external pure override returns (BalanceDelta) {
//         return BalanceDelta(0, 0);
//     }

//     function unlock(bytes calldata data) external pure override returns (bytes memory) {
//         return data;
//     }

//     // Implement missing functions from IPoolManager
//     function MAX_TICK_SPACING() external view override returns (int24) {
//         return 0;
//     }

//     function MIN_TICK_SPACING() external view override returns (int24) {
//         return 0;
//     }

//     function MIN_PROTOCOL_FEE_DENOMINATOR() external view override returns (uint8) {
//         return 0;
//     }

//     function getLiquidity(PoolId) external view override returns (uint128) {
//         return 0;
//     }

//     function getLiquidity(PoolId, address, int24, int24) external view override returns (uint128) {
//         return 0;
//     }

//     function getPoolBitmapInfo(PoolId, int16) external view override returns (uint256) {
//         return 0;
//     }

//     function getPoolTickInfo(PoolId, int24) external view override returns (Pool.TickInfo memory) {
//         return Pool.TickInfo(0, 0);
//     }

//     function getPosition(PoolId, address, int24, int24) external view override returns (Position.Info memory) {
//         return Position.Info(0, 0, 0, 0);
//     }

//     function getSlot0(PoolId) external view override returns (Slot0 memory) {
//         return Slot0(0, 0, 0, 0);
//     }

//     function currencyDelta(address, Currency) external view override returns (int256) {
//         return 0;
//     }

//     function getNonzeroDeltaCount() external view override returns (uint256) {
//         return 0;
//     }

//     function isUnlocked() external view override returns (bool) {
//         return true;
//     }

//     function reservesOf(Currency) external view override returns (uint256) {
//         return 0;
//     }

//     function protocolFeesAccrued(Currency) external view override returns (uint256) {
//         return 0;
//     }

//     function mint(address, uint256, uint256) external override {}

//     function burn(address, uint256, uint256) external override {}

//     function approve(address, uint256, uint256) external override returns (bool) {
//         return true;
//     }

//     function allowance(address, address, uint256) external view override returns (uint256) {
//         return 0;
//     }

//     function balanceOf(address, uint256) external view override returns (uint256) {
//         return 0;
//     }

//     function isOperator(address, address) external view override returns (bool) {
//         return true;
//     }

//     function setOperator(address, bool) external override returns (bool) {
//         return true;
//     }

//     function transfer(address, uint256, uint256) external override returns (bool) {
//         return true;
//     }

//     function transferFrom(address, address, uint256, uint256) external override returns (bool) {
//         return true;
//     }

//     function initialize(PoolKey memory, uint160, bytes calldata) external override {}

//     function swap(PoolKey memory, SwapParams memory, bytes calldata) external override returns (int256, int256) {
//         return (0, 0);
//     }

//     function settle(Currency) external payable override returns (uint256) {
//         return 0;
//     }

//     function take(Currency, address, uint256) external override {}

//     function donate(PoolKey memory, uint256, uint256, bytes calldata) external override {}

//     function setProtocolFee(PoolKey memory) external override {}

//     function extsload(bytes32) external view override returns (bytes32) {
//         return bytes32(0);
//     }

//     function extsload(bytes32, uint256) external view override returns (bytes memory) {
//         return bytes("");
//     }
// }