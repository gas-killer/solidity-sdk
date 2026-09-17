// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.4;

import {GkVm} from "../../src/gkvm/GkVm.sol";

contract GkVmExposed {
    function execExternal(address gkvm, bytes32 programHash, bytes32 artifactRoot, bytes memory payload)
        external
        view
        returns (bytes memory)
    {
        return GkVm.exec(gkvm, programHash, artifactRoot, payload);
    }
}
