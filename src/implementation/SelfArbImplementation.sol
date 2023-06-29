// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SelfArb} from "../SelfArb.sol";

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";

contract SelfArbImplementation is SelfArb {
    constructor(IPoolManager poolManager, SelfArb addressToEtch, address token0, address token1, address token2) SelfArb(poolManager, token0, token1, token2) {
        Hooks.validateHookAddress(addressToEtch, getHooksCalls());
        
    }

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}
