// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {DiamondLib} from "../libraries/DiamondLib.sol";
import {IDiamondCut} from "../interfaces/IDiamondCut.sol";

/// @title HookDiamond
/// @notice A Uniswap v4 hook that IS a diamond proxy, allowing modular hook logic via facets
/// @dev Two entry paths:
///      1. Hook callbacks (PoolManager -> beforeSwap/afterSwap/...) -> _beforeSwap etc. -> facet lookup by IHooks selector
///      2. Everything else (owner/keeper calls, unlockCallback) -> fallback() -> facet lookup by msg.sig
///      Facets run via delegatecall, so they execute in THIS contract's storage and context.
contract HookDiamond is BaseHook {
    /// @notice Thrown when a call hits a selector that no facet implements
    error FunctionNotFound(bytes4 selector);

    /// @notice Thrown when a facet reverts without any revert data
    error FacetCallFailed(address facet, bytes4 selector);

    constructor(IPoolManager _poolManager, address _contractOwner, address _diamondCutFacet) BaseHook(_poolManager) {
        DiamondLib.transferOwnership(_contractOwner);

        // Register diamondCut -> DiamondCutFacet so the owner can add the other facets later
        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](1);
        bytes4[] memory functionSelectors = new bytes4[](1);
        functionSelectors[0] = IDiamondCut.diamondCut.selector;
        cut[0] = IDiamondCut.FacetCut({
            facetAddress: _diamondCutFacet,
            action: IDiamondCut.FacetCutAction.Add,
            functionSelectors: functionSelectors
        });
        DiamondLib.diamondCut(cut, address(0), "");
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------
    // Hook callbacks: look up a facet by the IHooks selector and delegatecall it.
    // No facet registered -> default no-op values. Facet reverts are BUBBLED UP.
    // ---------------------------------------------------------------

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bytes4 sel = IHooks.beforeSwap.selector;
        bytes memory ret = _delegateToFacet(sel, abi.encodeWithSelector(sel, sender, key, params, hookData));
        if (ret.length > 0) return abi.decode(ret, (bytes4, BeforeSwapDelta, uint24));
        return (sel, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        bytes4 sel = IHooks.afterSwap.selector;
        bytes memory ret = _delegateToFacet(sel, abi.encodeWithSelector(sel, sender, key, params, delta, hookData));
        if (ret.length > 0) return abi.decode(ret, (bytes4, int128));
        return (sel, 0);
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        bytes4 sel = IHooks.beforeAddLiquidity.selector;
        bytes memory ret = _delegateToFacet(sel, abi.encodeWithSelector(sel, sender, key, params, hookData));
        if (ret.length > 0) return abi.decode(ret, (bytes4));
        return sel;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        bytes4 sel = IHooks.afterAddLiquidity.selector;
        bytes memory ret =
            _delegateToFacet(sel, abi.encodeWithSelector(sel, sender, key, params, delta, feesAccrued, hookData));
        if (ret.length > 0) return abi.decode(ret, (bytes4, BalanceDelta));
        return (sel, BalanceDelta.wrap(0));
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        bytes4 sel = IHooks.beforeRemoveLiquidity.selector;
        bytes memory ret = _delegateToFacet(sel, abi.encodeWithSelector(sel, sender, key, params, hookData));
        if (ret.length > 0) return abi.decode(ret, (bytes4));
        return sel;
    }

    function _afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        bytes4 sel = IHooks.afterRemoveLiquidity.selector;
        bytes memory ret =
            _delegateToFacet(sel, abi.encodeWithSelector(sel, sender, key, params, delta, feesAccrued, hookData));
        if (ret.length > 0) return abi.decode(ret, (bytes4, BalanceDelta));
        return (sel, BalanceDelta.wrap(0));
    }

    // ---------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------

    /// @notice Facet address registered for a selector, or address(0)
    function _getFacet(bytes4 selector) internal view returns (address facet) {
        facet = DiamondLib.diamondStorage().selectorToFacetAndPosition[selector].facetAddress;
    }

    /// @dev Delegatecalls the facet registered for `selector`.
    ///      Returns empty bytes if no facet is registered. Reverts (bubbling the facet's
    ///      revert data) if the facet call fails, so facet checks actually block the action.
    function _delegateToFacet(bytes4 selector, bytes memory data) internal returns (bytes memory ret) {
        address facet = _getFacet(selector);
        if (facet == address(0)) return ret;

        bool ok;
        (ok, ret) = facet.delegatecall(data);
        if (!ok) {
            if (ret.length == 0) revert FacetCallFailed(facet, selector);
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    // ---------------------------------------------------------------
    // Diamond proxy
    // ---------------------------------------------------------------

    /// @notice Routes any non-hook call (executeSwap, unlockCallback, loupe, ownership...) to its facet
    fallback() external payable {
        address facet = _getFacet(msg.sig);
        if (facet == address(0)) revert FunctionNotFound(msg.sig);

        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), facet, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    receive() external payable {}
}