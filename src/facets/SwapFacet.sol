// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {CurrencySettler} from "../../lib/v4-core/test/utils/CurrencySettler.sol";

import {DiamondLib} from "../libraries/DiamondLib.sol";

/// @title SwapFacet
/// @notice Lets the HookDiamond itself perform swaps on a Uniswap v4 pool.
/// @dev Runs via delegatecall, so address(this) == HookDiamond. The diamond is the
///      PoolManager's counterparty: it must hold the input token, and receives the output.
///      Register these selectors on the diamond with diamondCut:
///        executeSwap, unlockCallback, withdraw
///      (unlockCallback is called by the PoolManager on the diamond -> fallback -> here.)
contract SwapFacet is IUnlockCallback {
    using CurrencySettler for Currency;

    IPoolManager public immutable pm; // immutables live in facet bytecode, so they work under delegatecall

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    struct SwapData {
        PoolKey key;
        SwapParams params;
        bytes hookData;
        uint256 limit; // exact-in: minimum output. exact-out: maximum input.
    }

    /// @notice Swap from the diamond's own balance.
    /// @param key               pool (key.hooks should be the diamond if you want hook callbacks)
    /// @param zeroForOne        direction
    /// @param amountSpecified   negative = exact input, positive = exact output
    /// @param sqrtPriceLimitX96 0 = no limit (uses min/max price)
    /// @param limit             exact-in: min output. exact-out: max input.
    /// @param hookData          forwarded to hook callbacks
    function executeSwap(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        uint256 limit,
        bytes calldata hookData
    ) external returns (BalanceDelta delta) {
        DiamondLib.enforceIsContractOwner(); // msg.sender is the real external caller

        if (sqrtPriceLimitX96 == 0) {
            sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }

        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        bytes memory res = pm.unlock(abi.encode(SwapData(key, p, hookData, limit)));
        delta = abi.decode(res, (BalanceDelta));
    }

    /// @notice Called by the PoolManager (on the diamond) inside unlock.
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(pm), "SwapFacet: only PoolManager");
        SwapData memory d = abi.decode(raw, (SwapData));

        BalanceDelta delta = pm.swap(d.key, d.params, d.hookData);

        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();

        // slippage: negative delta = diamond pays, positive = diamond receives
        int128 inDelta = d.params.zeroForOne ? a0 : a1;
        int128 outDelta = d.params.zeroForOne ? a1 : a0;
        if (d.params.amountSpecified < 0) {
            require(outDelta > 0 && uint256(uint128(outDelta)) >= d.limit, "SwapFacet: slippage (min out)");
        } else {
            require(inDelta < 0 && uint256(uint128(-inDelta)) <= d.limit, "SwapFacet: slippage (max in)");
        }

        _settleOrTake(d.key.currency0, a0);
        _settleOrTake(d.key.currency1, a1);

        return abi.encode(delta);
    }

    /// @notice Move swapped tokens out of the diamond.
    function withdraw(Currency currency, address to, uint256 amount) external {
        DiamondLib.enforceIsContractOwner();
        if (currency.isAddressZero()) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "SwapFacet: ETH send failed");
        } else {
            (bool ok, bytes memory ret) =
                Currency.unwrap(currency).call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
            require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "SwapFacet: transfer failed");
        }
    }

    function _settleOrTake(Currency c, int128 amt) internal {
        if (amt < 0) {
            c.settle(pm, address(this), uint256(uint128(-amt)), false); // pay the pool
        } else if (amt > 0) {
            c.take(pm, address(this), uint256(uint128(amt)), false); // collect from the pool
        }
    }
}