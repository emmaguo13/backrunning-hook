// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";

import "forge-std/console.sol";

contract SelfArb is BaseHook {

    using PoolIdLibrary for IPoolManager.PoolKey;

    address public immutable token0;
    address public immutable token1;
    address public immutable token2;

    uint160 constant SQRT_RATIO_4_1 = 158456325028528675187087900672;

    constructor(IPoolManager _poolManager, address _token0, address _token1, address _token2) BaseHook(_poolManager) {
        token0 = _token0;
        token1 = _token1;
        token2 = _token2;
    }

    struct CallbackData {
        address sender;
        IPoolManager.SwapParams params;
    }
    
    struct TestSettings {
        bool withdrawTokens;
        bool settleUsingTransfer;
    }

    function _backRun(
        IPoolManager.SwapParams memory params
    ) internal returns (BalanceDelta delta) {

        delta =
            abi.decode(poolManager.lock(abi.encode(CallbackData(address(this), params))), (BalanceDelta));
    }

    function lockAcquired(uint256, bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));

        
        IPoolManager.PoolKey memory pool0Key = IPoolManager.PoolKey(Currency.wrap(token0), Currency.wrap(token1), 3000, 60, IHooks(address(this)));
        IPoolManager.PoolKey memory pool1Key = IPoolManager.PoolKey(Currency.wrap(token1), Currency.wrap(token2), 3000, 60, IHooks(address(0)));
        IPoolManager.PoolKey memory pool2Key = IPoolManager.PoolKey(Currency.wrap(token2), Currency.wrap(token0), 3000, 60, IHooks(address(0)));

        // why are we giving address this the permission?
        IERC20Minimal(Currency.unwrap(pool0Key.currency0)).approve(address(this), type(uint256).max);
        IERC20Minimal(Currency.unwrap(pool1Key.currency0)).approve(address(this), type(uint256).max);
        IERC20Minimal(Currency.unwrap(pool2Key.currency0)).approve(address(this), type(uint256).max);

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        if (data.params.zeroForOne) {
            //Flash swap token1 for token0 (pool0Id)
            IPoolManager.SwapParams memory token1to0 = IPoolManager.SwapParams({
                zeroForOne: false, 
                amountSpecified: 0.5 ether,
                sqrtPriceLimitX96: SQRT_RATIO_4_1
            });
            BalanceDelta delta0 = poolManager.swap(pool0Key, token1to0);

            //Swap token0 for token2 (pool2Id)
            IPoolManager.SwapParams memory token0to2 = IPoolManager.SwapParams({
                zeroForOne: false, 
                amountSpecified: -delta0.amount0(),
                sqrtPriceLimitX96: SQRT_RATIO_4_1
            });
            BalanceDelta delta2 = poolManager.swap(pool2Key, token0to2);

            //Swap token2 for token1 (pool1Id)
            IPoolManager.SwapParams memory token2to1 = IPoolManager.SwapParams({
                zeroForOne: false, 
                amountSpecified: -delta2.amount0(),
                sqrtPriceLimitX96: SQRT_RATIO_4_1
            });
            BalanceDelta delta1 = poolManager.swap(pool1Key, token2to1);

            //Repay loan on token 1

            // if (delta1.amount1() > 0) {
            //     IERC20Minimal(Currency.unwrap(pool1Key.currency1)).transferFrom(
            //         data.sender, address(poolManager), uint128(delta1.amount1())
            //     );
            //     poolManager.settle(pool1Key.currency1);
            // } 
            
            // TODO: figure out how to prevent reverts
            require(-delta1.amount0() >= delta0.amount1());

            console.log("PROFIT:");
            console.logInt(-delta1.amount0() - delta0.amount1());

            if (delta1.amount0() < 0) {
                poolManager.take(pool1Key.currency0, data.sender, uint128(-delta1.amount0() - delta0.amount1()));
            }

            return abi.encode(delta1);
        }
        else{
            //Flash swap token0 for token1 (pool0Id)
            IPoolManager.SwapParams memory token0to1 = IPoolManager.SwapParams({
                zeroForOne: true, 
                amountSpecified: 5,
                sqrtPriceLimitX96: SQRT_RATIO_4_1
            });
            BalanceDelta delta0 = poolManager.swap(pool0Key, token0to1);
            //Swap token1 for token2 (pool1Id)
            IPoolManager.SwapParams memory token1to2 = IPoolManager.SwapParams({
                zeroForOne: true, 
                amountSpecified: -delta0.amount1(),
                sqrtPriceLimitX96: SQRT_RATIO_4_1
            });
            BalanceDelta delta1 = poolManager.swap(pool1Key, token1to2);
            //Swap token2 for token0 (pool2Id)
            IPoolManager.SwapParams memory token2to0 = IPoolManager.SwapParams({
                zeroForOne: true, 
                amountSpecified: -delta1.amount1(),
                sqrtPriceLimitX96: SQRT_RATIO_4_1
            });
            BalanceDelta delta2 = poolManager.swap(pool2Key, token2to0);

            //Repay loan on token0
            // if (delta2.amount0() > 0) {
            //     IERC20Minimal(Currency.unwrap(pool2Key.currency0)).transferFrom(
            //         data.sender, address(poolManager), uint128(delta2.amount0())
            //     );
            //     poolManager.settle(pool2Key.currency0);
            // }

            require(-delta2.amount1() >= delta0.amount0());

            console.log("PROFIT:");
            console.logInt(-delta2.amount1() - delta0.amount0());

            if (delta2.amount1() < 0) {
                poolManager.take(pool2Key.currency1, data.sender, uint128(-delta2.amount1() - delta0.amount0()));
            }

            return abi.encode(delta2);
        }
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: false,
            beforeModifyPosition: false,
            afterModifyPosition: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function afterSwap(address sender, IPoolManager.PoolKey calldata, IPoolManager.SwapParams calldata params, BalanceDelta)
        external
        override
        returns (bytes4)
    {

        if (sender != address(this))  {
            _backRun(params);
        }
        
        return BaseHook.afterSwap.selector;
    }
}
