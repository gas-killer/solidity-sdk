// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {GasKillerSDK} from "../../src/GasKillerSDK.sol";

contract GasKillerSDKExposed is GasKillerSDK {
    constructor(address _avsAddress, address _blsSignatureChecker) {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSignatureChecker);
    }

    /// @dev Sets the same state the constructor would, for use after `vm.etch` places this code at
    /// a chosen address (etch copies code, not constructor-initialised storage). Test-only.
    function init(address _avsAddress, address _blsSignatureChecker) external {
        _setAvsAddress(_avsAddress);
        _setBlsSignatureChecker(_blsSignatureChecker);
    }

    function stateChangeHandlerExternal(bytes calldata storageUpdates) external {
        super._stateChangeHandler(storageUpdates);
    }
}
