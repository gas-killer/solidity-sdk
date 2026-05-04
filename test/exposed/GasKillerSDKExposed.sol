// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {GasKillerSDK} from "../../src/GasKillerSDK.sol";

contract GasKillerSDKExposed is GasKillerSDK {
    constructor(address _avsAddress, address _blsSignatureChecker) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSignatureChecker);
    }

    function stateChangeHandlerExternal(bytes calldata storageUpdates) external payable {
        super._stateChangeHandler(storageUpdates);
    }
}
