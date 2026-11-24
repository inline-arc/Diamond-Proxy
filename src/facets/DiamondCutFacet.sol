// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IDiamondCut} from "../interfaces/IDiamondCut.sol";
/// @dev imported the ownership of diamond contract is be stored and called
import {DiamondLib} from "../libraries/DiamondLib.sol";

contract DiamondCutFacet is IDiamondCut { 
    /// @dev diamond cut facet is used to cut the diamond and add/replace/remove any number of functions and optionally execute a function with delegatecall
    /// @notice Add/replace/remove any number of functions and optionally execute
    ///         a function with delegatecall
    /// @param _diamondCut Contains the facet addresses and function selectors
    /// @param _init The address of the contract or facet to execute _calldata
    /// @param _calldata A function call, including function selector and arguments
    ///                  _calldata is executed with delegatecall on _init

    /// @dev function to cut diamond to keep logs of facet ownership of linkedin to diamond and stored in diamond onc contracts
    function diamondCut(
        FacetCut[] calldata _diamondCut,
        address _init,
        bytes calldata _calldata
    ) external override {
        DiamondLib.enforceIsContractOwner();
        DiamondLib.diamondCut(_diamondCut, _init, _calldata);
    }
}
