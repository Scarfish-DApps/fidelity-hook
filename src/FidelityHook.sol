pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapFeeLibrary} from "v4-core/src/libraries/SwapFeeLibrary.sol";
import {FidelityTokenFactory} from "./FidelityTokenFactory.sol";

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
contract FidelityHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using SwapFeeLibrary for uint24;

    struct LastTradeInfo {
        uint256 token0;
        uint256 token1;
        uint256 executionTimestamp;
        uint256 totalVolume;
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
    mapping(address => LastTradeInfo) public lastRegisteredBalances;

    error MustUseDynamicFee();
    error CampaignNotEnded(); //TODO: use the custom error

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

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
        // Retrieve user's trading volume for current campaign provided by Brevis
        uint256 volume = getUserVolume(user, poolId);

        // Update user's trading volume within current campaign with the new registered value
        updateVolume(user, poolId);

        // Burn the fidelity tokens of last campaign if new one started
        burnLastCampaignTokens();

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

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        virtual
        override
        returns (bytes4)
    {
        // Only allow new liquidity or recentering of existing ones.
        onlyAllowRecentering();

        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external virtual override returns (bytes4) {
        // Only allow LPs to withdraw liquidity if the campaign in which they locked passed.
        checkIfCampaignPassed();

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

    function getUserVolume(address user, PoolId pool) internal returns(uint256 volume){

    }

    function updateVolume(address user, PoolId pool) internal {
        checkNewCampaignAndResetVolume();
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

    function checkNewCampaignAndResetVolume() internal {

    }

    function checkIfCampaignPassed() internal returns(bool) {

    }

    function onlyAllowRecentering() internal returns(bool) {

    }

    function burnLastCampaignTokens() internal {

    }

    mapping(address => mapping(bytes32 => uint16)) public userDiscounts; // User => (PoolId => HighestDiscount)

    function setOgDiscounts(address[] memory eligibleUsers, bytes32[] memory poolIds, uint16[] memory disounts) external {
        require(eligibleUsers.length == poolIds.length, "Input arrays must have the same length");
        require(eligibleUsers.length == disounts.length, "Input arrays must have the same length");

        for (uint256 i = 0; i < eligibleUsers.length; i++) {
            userDiscounts[eligibleUsers[i]][poolIds[i]] = disounts[i];
        }
    } 

    function getUserDiscount(address user, bytes32 poolId) external view returns (uint256) {
        return userDiscounts[user][poolId];
    }
}