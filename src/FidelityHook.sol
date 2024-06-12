pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapFeeLibrary} from "v4-core/src/libraries/SwapFeeLibrary.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolTestBase} from "v4-core/src/test/PoolTestBase.sol";
import {FidelityTokenFactory} from "./FidelityTokenFactory.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

/* 
 * Fidelity Hook rewards persistent traders of the integrating pool 
 * with reduced fees.
 * This is acheived through two features:
 *  1. Tokenized fee discount obtained by swapping in the pool.
 *  2. OG fee discount activated once you surpass a preset trading volume of a certain token across
 *	    All existing pools of the chain(proof by Brevis)
 *
 *  At pool initialization, additional configuration values need to be passed:
 *      - Lower and upper trading volume thresholds
 *      - Lower and upper fee percentages
 *      - Campaign duration
 *      - (Optional) One or more OG discount entries specifying a token and its minimum volume threshold
 *
 *  Swappers get fidelity tokens(FT) equal to the trading volume that reduce the fee percentage paid.
 *  If you have less FTs than the lower volume threshold, you pay the upper fee percentage.
 *  Once FTs surpass the lower volume threshold, your fee percentage will linearly decrease up to a
 *  maximum of the lower fee percentage - meaning that having more FTs than the upper volume threshold
 *  will still only provide you with the lower fee percentage.
 *
 *  A campaign is defined as the period of time in which swappers get to benefit off their FTs
 *  for fee percentage reduction, meaning each campaign will rotate to a new fidelity token.
 *  LPs will have their liquidity locked until the end of the campaign with the possibility
 *  for recentering in order to mitigate scenarios in which swappers might have to grind for 
 *  better market fee percentages by paying higher ones initially. 
 *
 *  The OG fee discount activates once your overall swapping volume of a token
 *  reaches the minimum threshold and is applied on top of the fee percentage dictated by FTs. 
 */
contract FidelityHook is BaseHook, PoolTestBase  {
    using PoolIdLibrary for PoolKey;
    using SwapFeeLibrary for uint24;
    using CurrencyLibrary for Currency;

    error PoolNotInitialized();
    error SenderMustBeHook();

    bytes internal constant ZERO_BYTES = bytes("");

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bytes hookData;
        bool settleUsingTransfer;
        bool withdrawTokens;
    }

    struct Bound {
        uint256 upper;
        uint256 lower;
    }

    struct PoolConfig {
        uint256 timeInterval;  
        Bound volumeThreshold;
        Bound feeLimits;
        FidelityTokenFactory fidelityTokenFactory;
        uint256 initTimestamp;
    }

    mapping(PoolId => PoolConfig) public poolConfig;
    mapping(
        address => mapping(
        PoolId => mapping(
        int24 => mapping(
        int24 => mapping(
        uint256 => int256
    ))))) public userLiqInPoolPerTicksAndCampaign;

    error MustUseDynamicFee();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) PoolTestBase(_poolManager) {}

    // Only way to add liquidity into the pool as you would do through a router.
    function addLiquidity(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams memory params
    ) external {
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        require(params.liquidityDelta > 0, "Can't add negative liqDelta");
        uint256 currentCampaign = getCurrentCampaign(poolId);

        userLiqInPoolPerTicksAndCampaign
        [msg.sender]
        [poolId]
        [params.tickLower]
        [params.tickUpper]
        [currentCampaign] += params.liquidityDelta;

        modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta
            }),
            ZERO_BYTES
        );
    }

    // Only way to remove liquidity into the pool as you would do through a router.
    function removeLiquidity(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams memory params,
        uint256 campaignId
    ) external {
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

        require(params.liquidityDelta < 0, "Can't remove positive liqDelta");
        uint256 currentCampaign = getCurrentCampaign(poolId);
        require(currentCampaign > campaignId, "Liq still locked");

        int256 liqAvailable = userLiqInPoolPerTicksAndCampaign
        [msg.sender]
        [poolId]
        [params.tickLower]
        [params.tickUpper]
        [campaignId];

        require(liqAvailable > 0, "No liq. available");
        require(liqAvailable >= -params.liquidityDelta, "Not enough liquidity");

        userLiqInPoolPerTicksAndCampaign
        [msg.sender]
        [poolId]
        [params.tickLower]
        [params.tickUpper]
        [currentCampaign] -= -params.liquidityDelta;

        modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta
            }),
            ZERO_BYTES
        );
    }

    // Shifts position in another tick interval.
    function recenterPosition(
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams memory params,
        uint256 campaignId,
        int24 newLowerTick,
        int24 newUpperTick
    ) external {
        require(params.liquidityDelta < 0, "Recentering liqDelta not negative");
        require(newLowerTick < newUpperTick, "TickLow > TickUppper");
        require(
            newUpperTick - newLowerTick >=
            params.tickUpper - params.tickLower,
            "New tick interval can't be lower"
        );

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();
        require(
            newLowerTick <= currentTick && currentTick <= newUpperTick,
            "Current tick not contained in new interval"
        );

        int256 liqToRecenter = userLiqInPoolPerTicksAndCampaign
        [msg.sender]
        [poolId]
        [params.tickLower]
        [params.tickUpper]
        [campaignId];

        require(liqToRecenter > 0, "No liq. available");
        require(liqToRecenter >= -params.liquidityDelta, "Not enough liquidity");

        userLiqInPoolPerTicksAndCampaign
        [msg.sender]
        [poolId]
        [params.tickLower]
        [params.tickUpper]
        [campaignId] -= -params.liquidityDelta;

        userLiqInPoolPerTicksAndCampaign
        [msg.sender]
        [poolId]
        [newLowerTick]
        [newUpperTick]
        [campaignId] += -params.liquidityDelta;

        modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: params.tickLower,
                tickUpper: params.tickUpper,
                liquidityDelta: params.liquidityDelta
            }),
            abi.encode(newLowerTick, newUpperTick)
        );
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    // Initializes the pool configuration.
    function beforeInitialize(
        address,
        PoolKey calldata key,
        uint160,
        bytes calldata hookData
    ) external override returns (bytes4) {
        // `.isDynamicFee()` function comes from using
        // the `SwapFeeLibrary` for `uint24`
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();

        (
            uint256 interval,
            uint256 volUpperThreshold,
            uint256 volLowerThreshold,
            uint24 feeUpperLimit,
            uint24 feeLowerLimit
          ) = abi.decode(hookData,(
            uint256,
            uint256,
            uint256,
            uint24,
            uint24
        ));

        PoolId poolId = key.toId();

        FidelityTokenFactory fidelityTokenFactory = new FidelityTokenFactory("FT");

        poolConfig[poolId] = PoolConfig({
            timeInterval: interval,
            volumeThreshold: Bound({upper: volUpperThreshold, lower: volLowerThreshold}),
            feeLimits: Bound({upper: uint256(feeUpperLimit), lower: uint256(feeLowerLimit)}),
            fidelityTokenFactory: fidelityTokenFactory,
            initTimestamp: block.timestamp
        });

        return this.beforeInitialize.selector;
    }

    // Update the swap fee based on the balance of fidelity tokens.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata hookData
    ) external override poolManagerOnly returns (bytes4) {
        address user = abi.decode(hookData, (address));

        PoolId poolId = key.toId();
  
        // Retrieve user's amount of fidelity token
        uint256 fidelityTokens = getUserFidelityTokens(user, poolId);

        // Calculate how much fees to charge based on amount of fidelity token
        uint24 fee = calculateFee(fidelityTokens, poolId);

        // Update swapFee in the manager
        poolManager.updateDynamicSwapFee(key, fee);
        return this.beforeSwap.selector;
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata swapParams, BalanceDelta delta, bytes calldata hookData)
        external
        override
        returns (bytes4)
    {
        address user = abi.decode(hookData, (address));
        PoolId poolId = key.toId();

        // Retrieve user's recorded trading volume
        uint256 volume = calculateSwapVolume(swapParams, delta);

        // Mint fidelity tokens based on user's trading volume
        mintFidelityTokens(user, volume, poolId);

        return BaseHook.afterSwap.selector;
    }

    function beforeAddLiquidity(address sender, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        override
        returns (bytes4)
    {
        if (sender != address(this)) revert SenderMustBeHook();

        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata poolKey,
        IPoolManager.ModifyLiquidityParams calldata liquidityParams,
        bytes calldata
    ) external virtual override returns (bytes4) {
        if (sender != address(this)) revert SenderMustBeHook();

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    // Volume is currently loosely defined as currency0 amount
    // you’re swapping in and that you respectively get by swapping currency1.
    function calculateSwapVolume(
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta
    ) internal returns(uint256 volume) {
        volume = swapParams.zeroForOne
            ? uint256(int256(-delta.amount0()))
            : uint256(int256(delta.amount0()));
    }

    function mintFidelityTokens(address user, uint256 volume, PoolId pool) internal {
        PoolConfig memory config = poolConfig[pool];
        uint256 currentCampaign = getCurrentCampaign(pool);
        FidelityTokenFactory fidelityTokenFactory = config.fidelityTokenFactory;
        fidelityTokenFactory.mint(user, currentCampaign, volume);
    }

    function calculateFee(uint256 fidelityTokens, PoolId pool) internal returns(uint24 fee){
        (
            ,
            FidelityHook.Bound memory volThreshold,
            FidelityHook.Bound memory feeLimits
            ,
            ,  
        ) = this.poolConfig(pool);

        if (fidelityTokens <= volThreshold.lower) {
            return uint24(feeLimits.upper);
        }

        if (fidelityTokens >= volThreshold.upper) {
            return uint24(feeLimits.lower);
        }
 
        // If FT amount is between volume thresholds, calculate fee using linear interpolation
        uint256 deltaFee = feeLimits.upper - feeLimits.lower;
        uint256 feeDifference = (deltaFee * (fidelityTokens - volThreshold.lower))
            / (volThreshold.upper - volThreshold.lower);

        return uint24(feeLimits.upper - feeDifference);
    }

    function getUserFidelityTokens(address user, PoolId pool) internal view returns (uint256 tokenAmount) {
        PoolConfig memory config = poolConfig[pool];
        uint256 currentCampaign = getCurrentCampaign(pool);
        FidelityTokenFactory fidelityTokenFactory = config.fidelityTokenFactory;
        tokenAmount = fidelityTokenFactory.balanceOf(user, currentCampaign);
    }

    function getCurrentCampaign(PoolId pool) internal view returns (uint256 campaignId){
        (
            uint256 timeInterval,
            ,
            ,
            ,
            uint256 initTimestmamp  
        ) = this.poolConfig(pool);

        campaignId = (block.timestamp - initTimestmamp) / timeInterval;
    }

    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params,  bytes memory hookData)
        internal
        returns (BalanceDelta delta)
    {
        delta = abi.decode(poolManager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData, true, true))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        BalanceDelta delta;

        // When recentering, this will remove the user's liquidity from the pool
        delta = manager.modifyLiquidity(data.key, data.params, data.hookData);

        // Only populate hookData when recentering
        if(keccak256(data.hookData) != keccak256(ZERO_BYTES)){
            // Sends the liquidity back to user
            if (delta.amount0() > 0) _take(data.key.currency0, data.sender, int128(delta.amount0()), data.withdrawTokens);
            if (delta.amount1() > 0) _take(data.key.currency1, data.sender, int128(delta.amount1()), data.withdrawTokens);

            (int24 newLowerTick, int24 newUpperTick) = abi.decode(data.hookData, (int24, int24));
            // Adds liquidity in the new tick interval
            delta = manager.modifyLiquidity(
                data.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: newLowerTick,
                    tickUpper: newUpperTick,
                    liquidityDelta: -data.params.liquidityDelta
                }),
                data.hookData
            );
        }

        if (delta.amount0() < 0) _settle(data.key.currency0, data.sender, delta.amount0(), data.settleUsingTransfer);
        if (delta.amount1() < 0) _settle(data.key.currency1, data.sender, delta.amount1(), data.settleUsingTransfer);
        if (delta.amount0() > 0) _take(data.key.currency0, data.sender, delta.amount0(), data.withdrawTokens);
        if (delta.amount1() > 0) _take(data.key.currency1, data.sender, delta.amount1(), data.withdrawTokens);

        return abi.encode(delta);
    }
}