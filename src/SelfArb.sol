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

contract SelfArb is BaseHook {

    using PoolIdLibrary for IPoolManager.PoolKey;

    address token0;
    address token1;
    address token2;

    constructor(IPoolManager _poolManager, address _token0, address _token1, address _token2) BaseHook(_poolManager) {
        token0 = _token0;
        token1 = _token1;
        token2 = _token2;
    }

    struct CallbackData {
        address sender;
        IPoolManager.PoolKey key;
        IPoolManager.SwapParams params;
        TestSettings testSettings;
    }
    
    struct TestSettings {
        bool withdrawTokens;
        bool settleUsingTransfer;
    }

    function swap(
        IPoolManager.PoolKey memory key,
        IPoolManager.SwapParams memory params,
        TestSettings memory testSettings
    ) external payable returns (BalanceDelta delta) {
        delta =
            abi.decode(poolManager.lock(abi.encode(CallbackData(msg.sender, key, params, testSettings))), (BalanceDelta));
    }

    function lockAcquired(uint256, bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));

        PoolId pool0Id = IPoolManager.PoolKey(Currency.wrap(token0), Currency.wrap(token1), 3000, 60, IHooks(address(this))).toId();
        PoolId pool1Id = IPoolManager.PoolKey(Currency.wrap(token1), Currency.wrap(token2), 3000, 60, IHooks(address(0))).toId();
        PoolId pool2Id = IPoolManager.PoolKey(Currency.wrap(token2), Currency.wrap(token0), 3000, 60, IHooks(address(0))).toId();

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        if (data.params.zeroForOne) {
            //Flash swap token1 for token0 (pool0Id)
            IPoolManager.SwapParams token1to0 = IPoolManager.SwapParams({
                zeroForOne: false, 
                amountSpecified: 5,
                sqrtPriceLimitX96: 0
            });
            BalanceDelta delta0 = poolManager.swap(pool0Id, token1to0);

            //Swap token0 for token2 (pool2Id)
            IPoolManager.SwapParams token0to2 = IPoolManager.SwapParams({
                zeroForOne: false, 
                amountSpecified: delta0.amount0,
                sqrtPriceLimitX96: 0
            });
            BalanceDelta delta2 = poolManager.swap(pool1Id, token0to2);

            //Swap token2 for token1 (pool1Id)
            IPoolManager.SwapParams token2to1 = IPoolManager.SwapParams({
                zeroForOne: false, 
                amountSpecified: delta0.amount0,
                sqrtPriceLimitX96: 0
            });
            BalanceDelta delta1 = poolManager.swap(pool2Id, token2to1);

            //Repay loan on token 1
        }
        else{
            //Flash swap token0 for token1 (pool1Id)
            IPoolManager.SwapParams token0to1 = IPoolManager.SwapParams({
                zeroForOne: true, 
                amountSpecified: 5,
                sqrtPriceLimitX96: 0
            });
            BalanceDelta delta1 = poolManager.swap(pool0Id, token0to1);
            //Swap token1 for token2 (pool2Id)
            IPoolManager.SwapParams token1to2 = IPoolManager.SwapParams({
                zeroForOne: true, 
                amountSpecified: delta0.amount1,
                sqrtPriceLimitX96: 0
            });
            BalanceDelta delta2 = poolManager.swap(pool1Id, token1to2);
            //Swap token2 for token0 (pool0Id)
            IPoolManager.SwapParams token2to0 = IPoolManager.SwapParams({
                zeroForOne: true, 
                amountSpecified: delta2.amount1,
                sqrtPriceLimitX96: 0
            });
            delta1 = poolManager.swap(pool2Id, token2to0);

            //Repay loan on token0
        }


        if (data.params.zeroForOne) {
            if (delta1.amount0() > 0) {
                if (data.testSettings.settleUsingTransfer) {
                    IERC20Minimal(Currency.unwrap(data.key.currency0)).transferFrom(
                        data.sender, address(poolManager), uint128(delta1.amount0())
                    );
                    poolManager.settle(data.key.currency0);
                } else {
                    // the received hook on this transfer will burn the tokens
                    poolManager.safeTransferFrom(
                        data.sender,
                        address(poolManager),
                        uint256(uint160(Currency.unwrap(data.key.currency0))),
                        uint128(delta1.amount0()),
                        ""
                    );
                }
            }
            if (delta1.amount1() < 0) {
                if (data.testSettings.withdrawTokens) {
                    poolManager.take(data.key.currency1, data.sender, uint128(-delta1.amount1()));
                } else {
                    poolManager.mint(data.key.currency1, data.sender, uint128(-delta1.amount1()));
                }
            }
        } else {
            if (delta1.amount1() > 0) {
                if (data.testSettings.settleUsingTransfer) {
                    IERC20Minimal(Currency.unwrap(data.key.currency1)).transferFrom(
                        data.sender, address(poolManager), uint128(delta1.amount1())
                    );
                    poolManager.settle(data.key.currency1);
                } else {
                    // the received hook on this transfer will burn the tokens
                    poolManager.safeTransferFrom(
                        data.sender,
                        address(poolManager),
                        uint256(uint160(Currency.unwrap(data.key.currency1))),
                        uint128(delta1.amount1()),
                        ""
                    );
                }
            }
            if (delta1.amount0() < 0) {
                if (data.testSettings.withdrawTokens) {
                    poolManager.take(data.key.currency0, data.sender, uint128(-delta1.amount0()));
                } else {
                    poolManager.mint(data.key.currency0, data.sender, uint128(-delta1.amount0()));
                }
            }
        }

        return abi.encode(delta1);
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

    function afterSwap(address, IPoolManager.PoolKey calldata, IPoolManager.SwapParams calldata params, BalanceDelta)
        external
        override
        returns (bytes4)
    {
        //get the pools to check
        
        //check for the routes
        lockAcquired(null, rawData);

        //execute
        
        return BaseHook.afterSwap.selector;
    }
}
