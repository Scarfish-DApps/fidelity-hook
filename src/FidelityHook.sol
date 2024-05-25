pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapFeeLibrary} from "v4-core/src/libraries/SwapFeeLibrary.sol";

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
        uint256 timeInterval;
        Bound volumeThreshold;
        Bound feeLimits;
    }

    mapping(PoolId => PoolConfig) public poolConfig;
    mapping(address => LastTradeInfo) public lastRegisteredBalances;

    error MustUseDynamicFee();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
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

        poolConfig[poolId] = PoolConfig({
            timeInterval: interval,
            volumeThreshold: Bound({upper: volUpperThreshold, lower: volLowerThreshold}),
            feeLimits: Bound({upper: uint256(feeUpperLimit), lower: uint256(feeLowerLimit)})
        });

        return this.beforeInitialize.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) external override poolManagerOnly returns (bytes4) {
        // Calculate how much fees to charge
        //uint24 fee = getFee();

        // Update swapFee in the manager
        //poolManager.updateDynamicSwapFee(key, fee);
        return this.beforeSwap.selector;
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4)
    {
        //Register new balance of swapper as last seen balances
        return BaseHook.afterSwap.selector;
    }

    function updateVolume(address user, PoolId pool) internal {

    } 

    function getFee(address user, PoolId pool) internal returns(uint24 fee){
        
    }
}