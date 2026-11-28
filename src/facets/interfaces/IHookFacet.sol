// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title Hook facet interfaces for HookDiamond
/// @notice Each interface is ONE hook callback, with the exact IHooks signature.
/// @dev HookDiamond._beforeSwap etc. look up a facet by IHooks.<hook>.selector and delegatecall it
///      with abi.encodeWithSelector(selector, sender, key, params, ..., hookData).
///      A selector depends only on the function name and parameter TYPES, so these must match
///      IHooks exactly or the diamond will never find / call your facet.
///
///      Rules for every implementation:
///      - delegatecall context: address(this) is the HookDiamond, msg.sender is the PoolManager.
///      - NO state variables. Use a namespaced storage library (a fixed keccak256 slot, like DiamondLib).
///      - Return the matching selector (IHooks.<hook>.selector) or the PoolManager reverts.
///      - A facet only inherits the interfaces for hooks it actually registers via diamondCut.
///        (Solidity forces you to implement everything you inherit, so don't inherit IHookFacet
///        unless you really implement all six.)

interface IBeforeSwapFacet {
    /// @param sender   caller of PoolManager.swap, usually a router (NOT the end user)
    /// @param key      pool key (currency0, currency1, fee, tickSpacing, hooks)
    /// @param params   zeroForOne, amountSpecified (negative = exact input), sqrtPriceLimitX96
    /// @param hookData arbitrary bytes passed in by the swapper
    /// @return selector   must be IHooks.beforeSwap.selector
    /// @return delta      adjustment to swap amounts (needs beforeSwapReturnDelta flag, else ZERO_DELTA)
    /// @return lpFeeOverride  dynamic-fee override (0 = none; pool must be dynamic-fee)
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        external
        returns (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride);
}

interface IAfterSwapFacet {
    /// @param delta final swap result: positive = owed to the caller, negative = owed to the pool
    /// @return selector   must be IHooks.afterSwap.selector
    /// @return hookDeltaUnspecified  amount the hook claims (needs afterSwapReturnDelta flag, else 0)
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4 selector, int128 hookDeltaUnspecified);
}

interface IBeforeAddLiquidityFacet {
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4 selector);
}

interface IAfterAddLiquidityFacet {
    /// @param delta        principal owed for the liquidity added
    /// @param feesAccrued  fees accrued to the position and folded into the delta
    /// @return selector must be IHooks.afterAddLiquidity.selector
    /// @return hookDelta amount the hook claims (needs afterAddLiquidityReturnDelta flag, else 0)
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4 selector, BalanceDelta hookDelta);
}

interface IBeforeRemoveLiquidityFacet {
    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4 selector);
}

interface IAfterRemoveLiquidityFacet {
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4 selector, BalanceDelta hookDelta);
}

/// @notice All six callbacks HookDiamond currently routes. Inherit only if you implement all of them.
interface IHookFacet is
    IBeforeSwapFacet,
    IAfterSwapFacet,
    IBeforeAddLiquidityFacet,
    IAfterAddLiquidityFacet,
    IBeforeRemoveLiquidityFacet,
    IAfterRemoveLiquidityFacet
{}