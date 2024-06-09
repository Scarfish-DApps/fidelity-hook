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

/* I Characteristics of individual pools:
 * 1. Upper/lower trade volume threshold for fee reduction.
 *     1.1 Trade volume in currency 0 / currency 1. 
 * 2. Time interval for which trade volume is taken into consideration.
 *     2.1 Interval start is fixed for the entire pool.
 *          This should mean that the first liquidity position dictates
 *          the beginning and the end of one, let's call it, trading campaign.
 *     2.2 Interval starts with user's first trade. (seems harder to implement)
 *     NOTE - Fixed interval start may make more sense as there should be a
 *     locking mechanism for liquidity to not rug swapper who might want to
 *     achieve a certain fee reduction percentage, therefore investing lots
 *     of resources into raising the volume inside the pool - in this case,
 *     LPs lock their position for the duration of a trading campaign.
 * 3. Upper/lower fee limits.
 * 4. Infidelity penalty on/off. 
 *     NOTE - Could maybe integrate with Brevis to find out external volume of underlying pair tokens?
 * 5. Swap volume eligible for fee reduction RIGHT AWAY or accounted only in the following swap.
 *     NOTE -  
 *
 * II To be discussed:
 *     - Should new liquidity or new LPs affect the fee reduction amount because the new liquidity
 *     was not effectively used and therefore generated no fees for the LP? Meaning, new liquidity
 *     decreases the efficacy of fee reduction a user reached with its volume beforehand? Or does
 *     a new LP/liquidty submit to the fee reduction percentage a user has already reached?
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
        uint256 timeInterval;  // Represents the timestamp when the campaign will end ?
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

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) revert PoolNotInitialized();

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

        FidelityTokenFactory fidelityTokenFactory = new FidelityTokenFactory("TODO");

        poolConfig[poolId] = PoolConfig({
            timeInterval: interval,
            volumeThreshold: Bound({upper: volUpperThreshold, lower: volLowerThreshold}),
            feeLimits: Bound({upper: uint256(feeUpperLimit), lower: uint256(feeLowerLimit)}),
            fidelityTokenFactory: fidelityTokenFactory,
            initTimestamp: block.timestamp
        });

        return this.beforeInitialize.selector;
    }

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
        updateFidelityTokens(user, volume, poolId);

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

    function calculateSwapVolume(
        IPoolManager.SwapParams calldata swapParams,
        BalanceDelta delta
    ) internal returns(uint256 volume) {
        volume = swapParams.zeroForOne
            ? uint256(int256(-delta.amount0()))
            : uint256(int256(delta.amount0()));
    }

    function updateFidelityTokens(address user, uint256 volume, PoolId pool) internal {
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

        if (fidelityTokens < volThreshold.lower) {
            return uint24(feeLimits.upper);
        }

        if (fidelityTokens > volThreshold.upper) {
            return uint24(feeLimits.lower);
        }
 
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
        int256 delta0;
        int256 delta1;

        delta = manager.modifyLiquidity(data.key, data.params, data.hookData);

        (,, delta0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, delta1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        if(keccak256(data.hookData) != keccak256(ZERO_BYTES)){
            if (delta0 > 0) _take(data.key.currency0, data.sender, int128(delta0), data.withdrawTokens);
            if (delta1 > 0) _take(data.key.currency1, data.sender, int128(delta1), data.withdrawTokens);

            (int24 newLowerTick, int24 newUpperTick) = abi.decode(data.hookData, (int24, int24));
            delta = manager.modifyLiquidity(
                data.key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: newLowerTick,
                    tickUpper: newUpperTick,
                    liquidityDelta: -data.params.liquidityDelta
                }),
                data.hookData
            );

            (,, delta0) = _fetchBalances(data.key.currency0, data.sender, address(this));
            (,, delta1) = _fetchBalances(data.key.currency1, data.sender, address(this));
        }

        if (delta0 < 0) _settle(data.key.currency0, data.sender, int128(delta0), data.settleUsingTransfer);
        if (delta1 < 0) _settle(data.key.currency1, data.sender, int128(delta1), data.settleUsingTransfer);
        if (delta0 > 0) _take(data.key.currency0, data.sender, int128(delta0), data.withdrawTokens);
        if (delta1 > 0) _take(data.key.currency1, data.sender, int128(delta1), data.withdrawTokens);

        return abi.encode(delta);
    }
}