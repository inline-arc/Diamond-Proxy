// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DiamondLib} from "../libraries/DiamondLib.sol";

contract DiamondDeploy {
    function init() external view {
        // Reverts unless the caller is already the contract owner.
        DiamondLib.enforceIsContractOwner();
    }
}
