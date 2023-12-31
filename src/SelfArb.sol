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

import {FullMath} from "@uniswap/v4-core/contracts/libraries/FullMath.sol";
import "@uniswap/v4-core/contracts/libraries/FixedPoint128.sol";

import "forge-std/console.sol";

contract SelfArb is BaseHook {
    using PoolIdLibrary for IPoolManager.PoolKey;

    address public immutable token0;
    address public immutable token1;
    address public immutable token2;

    uint160 constant SQRT_RATIO_1_4 = 39614081257132168796771975168;
    uint160 constant SQRT_RATIO_4_1 = 158456325028528675187087900672;
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;
    uint160 constant SQRT_RATIO_1_2 = 56022770974786139918731938227;
    uint160 constant SQRT_RATIO_2_3 = SQRT_RATIO_1_1 * 4 / 5;
    uint160 constant SQRT_RATIO_2_1 = SQRT_RATIO_1_1 * 7 / 5;

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

    function _backRun(IPoolManager.SwapParams memory params) internal returns (BalanceDelta delta) {
        delta = abi.decode(poolManager.lock(abi.encode(CallbackData(address(this), params))), (BalanceDelta));
    }

    function lockAcquired(uint256, bytes calldata rawData) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));

        IPoolManager.PoolKey memory pool0Key =
            IPoolManager.PoolKey(Currency.wrap(token0), Currency.wrap(token1), 0, 60, IHooks(address(this)));
        IPoolManager.PoolKey memory pool1Key =
            IPoolManager.PoolKey(Currency.wrap(token1), Currency.wrap(token2), 0, 60, IHooks(address(0)));
        IPoolManager.PoolKey memory pool2Key =
            IPoolManager.PoolKey(Currency.wrap(token2), Currency.wrap(token0), 0, 60, IHooks(address(0)));

        (uint160 pool0Price,,,,,) = poolManager.getSlot0(pool0Key.toId());
        (uint160 pool1Price,,,,,) = poolManager.getSlot0(pool1Key.toId());
        (uint160 pool2Price,,,,,) = poolManager.getSlot0(pool2Key.toId());

        // why are we giving address this the permission?
        IERC20Minimal(Currency.unwrap(pool0Key.currency0)).approve(address(this), type(uint256).max);
        IERC20Minimal(Currency.unwrap(pool1Key.currency0)).approve(address(this), type(uint256).max);
        IERC20Minimal(Currency.unwrap(pool2Key.currency0)).approve(address(this), type(uint256).max);

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        if (data.params.zeroForOne) {
            //Flash swap token1 for token0 (pool0Id)
            IPoolManager.SwapParams memory token1to0 = IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: data.params.amountSpecified / 2,
                sqrtPriceLimitX96: SQRT_RATIO_1_1
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
            require(-delta1.amount0() >= delta0.amount1(), "Loan not repaid");

            console.log("PROFIT:");
            console.logInt(-delta1.amount0() - delta0.amount1());

            if (delta1.amount0() < 0) {
                poolManager.take(pool1Key.currency0, data.sender, uint128(-delta1.amount0() - delta0.amount1()));
            }

            return abi.encode(delta1);
        } else {
            //Flash swap token0 for token1 (pool0Id)
            IPoolManager.SwapParams memory token0to1 = IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: data.params.amountSpecified / 2,
                sqrtPriceLimitX96: SQRT_RATIO_1_2
            });
            BalanceDelta delta0 = poolManager.swap(pool0Key, token0to1);
            //Swap token1 for token2 (pool1Id)
            IPoolManager.SwapParams memory token1to2 = IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -delta0.amount1(),
                sqrtPriceLimitX96: SQRT_RATIO_1_4
            });
            BalanceDelta delta1 = poolManager.swap(pool1Key, token1to2);
            //Swap token2 for token0 (pool2Id)
            IPoolManager.SwapParams memory token2to0 = IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -delta1.amount1(),
                sqrtPriceLimitX96: SQRT_RATIO_1_4
            });
            BalanceDelta delta2 = poolManager.swap(pool2Key, token2to0);

            //Repay loan on token0
            // if (delta2.amount0() > 0) {
            //     IERC20Minimal(Currency.unwrap(pool2Key.currency0)).transferFrom(
            //         data.sender, address(poolManager), uint128(delta2.amount0())
            //     );
            //     poolManager.settle(pool2Key.currency0);
            // }

            require(-delta2.amount1() >= delta0.amount0(), "Loan not repaid");

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
            afterModifyPosition: true,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function afterModifyPosition(
        address sender,
        IPoolManager.PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata params,
        BalanceDelta
    ) external virtual override returns (bytes4) {
        if (params.liquidityDelta < 0) {
            uint256 token0Hook = IERC20Minimal(Currency.unwrap(key.currency0)).balanceOf(address(this));
            uint256 token1Hook = IERC20Minimal(Currency.unwrap(key.currency1)).balanceOf(address(this));

            console.log("hook amount of token 0 and 1");
            console.log(token0Hook);
            console.log(token1Hook);

            uint256 poolLiq = poolManager.getLiquidity(key.toId());

            uint256 token0Amount = FullMath.mulDiv(uint256(-params.liquidityDelta), token0Hook, poolLiq);
            uint256 token1Amount = FullMath.mulDiv(uint256(-params.liquidityDelta), token1Hook, poolLiq);

            console.log(token1Amount);

            require(token0Amount >= 0 && token1Amount >= 0);

            if (token0Amount > 0) {
                IERC20Minimal(Currency.unwrap(key.currency0)).transferFrom(address(this), sender, uint128(token0Amount));
            }
            if (token1Amount > 0) {
                IERC20Minimal(Currency.unwrap(key.currency1)).transferFrom(address(this), sender, uint128(token1Amount));
            }
        }

        return BaseHook.afterModifyPosition.selector;
    }

    function afterSwap(
        address sender,
        IPoolManager.PoolKey calldata,
        IPoolManager.SwapParams calldata params,
        BalanceDelta
    ) external override returns (bytes4) {
        if (sender != address(this)) {
            _backRun(params);
        }

        return BaseHook.afterSwap.selector;
    }
}
