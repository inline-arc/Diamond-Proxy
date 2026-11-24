// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DiamondLib} from "../libraries/DiamondLib.sol";

contract DiamondDeploy {
    function init() external {
        // Set the contract owner
        DiamondLib.setContractOwner(msg.sender);
    }
}
