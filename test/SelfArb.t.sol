// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "forge-std/Test.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/contracts/test/PoolDonateTest.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {SelfArb} from "../src/SelfArb.sol";
import {SelfArbImplementation} from "../src/implementation/SelfArbImplementation.sol";

import "forge-std/console.sol";

contract SelfArbTest is Test, Deployers, GasSnapshot {
    using PoolIdLibrary for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;

    TestERC20 token0;
    TestERC20 token1;
    TestERC20 token2;

    SelfArbImplementation selfarb = SelfArbImplementation(
        address(uint160(Hooks.AFTER_SWAP_FLAG))
    );
    PoolManager manager;
    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter; 
    IPoolManager.PoolKey poolKey0;
    PoolId poolId0;
    IPoolManager.PoolKey poolKey1;
    PoolId poolId1;
    IPoolManager.PoolKey poolKey2;
    PoolId poolId2;

    function setUp() public {
        token0 = new TestERC20(2**128);
        token1 = new TestERC20(2**128);
        token2 = new TestERC20(2**128);
        manager = new PoolManager(500000);

        // testing environment requires our contract to override `validateHookAddress`
        // well do that via the Implementation contract to avoid deploying the override with the production contract
        SelfArbImplementation impl = new SelfArbImplementation(manager, selfarb, address(token0), address(token1), address(token2));
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(selfarb), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(selfarb), slot, vm.load(address(impl), slot));
            }
        }

        // Create the pools
        poolKey0 = IPoolManager.PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(selfarb));
        poolId0 = poolKey0.toId();
        manager.initialize(poolKey0, SQRT_RATIO_1_1);

        poolKey1 = IPoolManager.PoolKey(Currency.wrap(address(token1)), Currency.wrap(address(token2)), 3000, 60, IHooks(address(0)));
        poolId1 = poolKey1.toId();
        manager.initialize(poolKey1, SQRT_RATIO_1_1);

        poolKey2 = IPoolManager.PoolKey(Currency.wrap(address(token2)), Currency.wrap(address(token0)), 3000, 60, IHooks(address(0)));
        poolId2 = poolKey2.toId();
        manager.initialize(poolKey2, SQRT_RATIO_1_1);

        // Helpers for interacting with the pool
        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));

        // Provide liquidity to the pool
        token0.approve(address(modifyPositionRouter), 100 ether);
        token1.approve(address(modifyPositionRouter), 100 ether);
        token2.approve(address (modifyPositionRouter), 100 ether);
        token0.mint(address(this), 200 ether);
        token1.mint(address(this), 200 ether);
        token2.mint(address(this), 200 ether);
        
        modifyPositionRouter.modifyPosition(poolKey0, IPoolManager.ModifyPositionParams(-60, 60, 10 ether));
        modifyPositionRouter.modifyPosition(poolKey0, IPoolManager.ModifyPositionParams(-120, 120, 10 ether));
        modifyPositionRouter.modifyPosition(
            poolKey0, IPoolManager.ModifyPositionParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether)
        );

        modifyPositionRouter.modifyPosition(poolKey1, IPoolManager.ModifyPositionParams(-60, 60, 10 ether));
        modifyPositionRouter.modifyPosition(poolKey1, IPoolManager.ModifyPositionParams(-120, 120, 10 ether));
        modifyPositionRouter.modifyPosition(
            poolKey1, IPoolManager.ModifyPositionParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether)
        );

        modifyPositionRouter.modifyPosition(poolKey2, IPoolManager.ModifyPositionParams(-60, 60, 10 ether));
        modifyPositionRouter.modifyPosition(poolKey2, IPoolManager.ModifyPositionParams(-120, 120, 10 ether));
        modifyPositionRouter.modifyPosition(
            poolKey2, IPoolManager.ModifyPositionParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether)
        );

        // Approve for swapping
        token0.approve(address(swapRouter), 1000 ether);
        token1.approve(address(swapRouter), 1000 ether);
        token2.approve(address(swapRouter), 1000 ether);
        token0.approve(address(selfarb), 1000 ether);
        token1.approve(address(selfarb), 1000 ether);
        token2.approve(address(selfarb), 1000 ether);
        token0.approve(address(manager), 1000 ether);
        token1.approve(address(manager), 1000 ether);
        token2.approve(address(manager), 1000 ether);

        // Random Swaps
        // IPoolManager.SwapParams memory params =
        //     IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 15, sqrtPriceLimitX96: SQRT_RATIO_1_2});
        // PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});
        // swapRouter.swap(poolKey0, params, testSettings);

        // params = IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 5, sqrtPriceLimitX96: SQRT_RATIO_1_2});
        // swapRouter.swap(poolKey1, params, testSettings);

        // params = IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 8, sqrtPriceLimitX96: SQRT_RATIO_1_2});
        // swapRouter.swap(poolKey2, params, testSettings);

        // params = IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 20, sqrtPriceLimitX96: SQRT_RATIO_1_2});
        // swapRouter.swap(poolKey2, params, testSettings);

        // params = IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 30, sqrtPriceLimitX96: SQRT_RATIO_1_2});
        // swapRouter.swap(poolKey1, params, testSettings);
        
        // params = IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: SQRT_RATIO_1_2});
        // swapRouter.swap(poolKey2, params, testSettings);

        //Add prints for price
    }

    function testSelfArbHooks() public {
        // Perform a test swap //
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 5 ether, sqrtPriceLimitX96: SQRT_RATIO_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({withdrawTokens: true, settleUsingTransfer: true});
        
        swapRouter.swap(
            poolKey0,
            params,
            testSettings
        );
        // ------------------- //
    }
}
