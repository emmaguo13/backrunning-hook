// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {SelfArb} from "../SelfArb.sol";

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";

import "forge-std/console.sol";

contract SelfArbImplementation is SelfArb {
    constructor(IPoolManager poolManager, SelfArb addressToEtch, address _token0, address _token1, address _token2)
        SelfArb(poolManager, _token0, _token1, _token2)
    {
        Hooks.validateHookAddress(addressToEtch, getHooksCalls());
    }

    // make this a no-op in testing
    function validateHookAddress(BaseHook _this) internal pure override {}
}
