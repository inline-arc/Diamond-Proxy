// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {HookDiamond} from "../src/hook-v4/HookDiamond.sol";
import {DiamondCutFacet} from "../src/facets/DiamondCutFacet.sol";
import {SwapFacet} from "../src/facets/SwapFacet.sol";
import {IDiamondCut} from "../src/interfaces/IDiamondCut.sol";

/// @dev TEST-ONLY facet. Proves the diamond routes hook callbacks to a facet.
///      Counters live in a namespaced slot because facets share the diamond's storage.
contract ObserverFacet {
    bytes32 private constant SLOT = keccak256("test.observer.facet.storage");

    struct Layout {
        uint256 beforeCount;
        uint256 afterCount;
        bool blocked;
    }

    function _l() private pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly {
            l.slot := s
        }
    }

    // hook callbacks (signatures must match IHooks exactly)
    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        require(!_l().blocked, "ObserverFacet: blocked");
        _l().beforeCount++;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        returns (bytes4, int128)
    {
        _l().afterCount++;
        return (IHooks.afterSwap.selector, 0);
    }

    // helpers reached through HookDiamond.fallback
    function setBlocked(bool b) external {
        _l().blocked = b;
    }

    function beforeCount() external view returns (uint256) {
        return _l().beforeCount;
    }

    function afterCount() external view returns (uint256) {
        return _l().afterCount;
    }
}

contract HookDiamondTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    HookDiamond hook;
    ObserverFacet observer;
    SwapFacet swapFacet;

    function setUp() public {
        // PoolManager, test routers, two funded currencies (from v4-core Deployers)
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        // ---- deploy the diamond hook at an address whose bits match its permissions ----
        DiamondCutFacet cutFacet = new DiamondCutFacet();

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        );
        address hookAddr = address(flags ^ (uint160(0x4444) << 144)); // namespace so it can't clash
        deployCodeTo("HookDiamond.sol:HookDiamond", abi.encode(manager, address(this), address(cutFacet)), hookAddr);
        hook = HookDiamond(payable(hookAddr));

        // ---- register facets through diamondCut (we are the owner) ----
        observer = new ObserverFacet();
        swapFacet = new SwapFacet(manager);

        bytes4[] memory obsSel = new bytes4[](5);
        obsSel[0] = IHooks.beforeSwap.selector;
        obsSel[1] = IHooks.afterSwap.selector;
        obsSel[2] = ObserverFacet.setBlocked.selector;
        obsSel[3] = ObserverFacet.beforeCount.selector;
        obsSel[4] = ObserverFacet.afterCount.selector;

        bytes4[] memory swapSel = new bytes4[](3);
        swapSel[0] = SwapFacet.executeSwap.selector;
        swapSel[1] = SwapFacet.unlockCallback.selector; // PoolManager calls this on the diamond
        swapSel[2] = SwapFacet.withdraw.selector;

        IDiamondCut.FacetCut[] memory cut = new IDiamondCut.FacetCut[](2);
        cut[0] = IDiamondCut.FacetCut(address(observer), IDiamondCut.FacetCutAction.Add, obsSel);
        cut[1] = IDiamondCut.FacetCut(address(swapFacet), IDiamondCut.FacetCutAction.Add, swapSel);
        IDiamondCut(address(hook)).diamondCut(cut, address(0), "");

        // ---- pool that uses the diamond as its hook, plus liquidity ----
        (key,) = initPool(currency0, currency1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // ---------------------------------------------------------------
    // Layer 2/3: hook routing
    // ---------------------------------------------------------------

    function test_userSwap_isRoutedToFacet() public {
        assertEq(ObserverFacet(address(hook)).beforeCount(), 0);

        swap(key, true, -1e15, ZERO_BYTES); // a normal user swap through the test router

        assertEq(ObserverFacet(address(hook)).beforeCount(), 1, "beforeSwap facet not called");
        assertEq(ObserverFacet(address(hook)).afterCount(), 1, "afterSwap facet not called");
    }

    function test_facetRevert_blocksSwap() public {
        ObserverFacet(address(hook)).setBlocked(true);

        vm.expectRevert(); // reverts only because HookDiamond now bubbles facet reverts
        swap(key, true, -1e15, ZERO_BYTES);
    }

    function test_unknownSelector_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(HookDiamond.FunctionNotFound.selector, bytes4(0xdeadbeef)));
        (bool ok,) = address(hook).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
        ok; // silence unused warning
    }

    // ---------------------------------------------------------------
    // Layer 5: SwapFacet (the diamond itself swaps)
    // ---------------------------------------------------------------

    function test_executeSwap_fromDiamondBalance() public {
        // fund the diamond with the input token
        IERC20Minimal(Currency.unwrap(currency0)).transfer(address(hook), 1e18);
        uint256 in0Before = currency0.balanceOf(address(hook));
        uint256 out1Before = currency1.balanceOf(address(hook));

        SwapFacet(address(hook)).executeSwap(key, true, -1e15, 0, 0, ZERO_BYTES);

        assertEq(currency0.balanceOf(address(hook)), in0Before - 1e15, "input not spent");
        assertGt(currency1.balanceOf(address(hook)), out1Before, "no output received");

        // v4 skips hook callbacks when the hook itself is the swap caller
        assertEq(ObserverFacet(address(hook)).beforeCount(), 0);
    }

    function test_executeSwap_revertsForNonOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        SwapFacet(address(hook)).executeSwap(key, true, -1e15, 0, 0, ZERO_BYTES);
    }

    function test_executeSwap_revertsOnSlippage() public {
        IERC20Minimal(Currency.unwrap(currency0)).transfer(address(hook), 1e18);

        vm.expectRevert(); // asks for far more output than 1e15 in can buy
        SwapFacet(address(hook)).executeSwap(key, true, -1e15, 0, 1e18, ZERO_BYTES);
    }

    function test_unlockCallback_onlyPoolManager() public {
        vm.expectRevert();
        SwapFacet(address(hook)).unlockCallback("");
    }
}