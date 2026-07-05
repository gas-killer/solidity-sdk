// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {GasKillerSDK} from "../../src/GasKillerSDK.sol";

contract GasKillerSDKExposed is GasKillerSDK {
    constructor(address _avsAddress, address _ecdsaStakeRegistry) {
        _setAvsAddress(_avsAddress);
        _setECDSAStakeRegistry(_ecdsaStakeRegistry);
    }

    function stateChangeHandlerExternal(bytes calldata storageUpdates) external {
        super._stateChangeHandler(storageUpdates);
    }

    function setTrustedForwarderExternal(address forwarder, bool trusted) external {
        _setTrustedForwarder(forwarder, trusted);
    }
}
