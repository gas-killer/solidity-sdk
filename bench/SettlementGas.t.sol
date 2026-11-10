// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {ISchnorrStakeRegistry} from "../src/interface/ISchnorrStakeRegistry.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {StorageGuard} from "../src/libraries/StorageGuard.sol";

contract AcceptAll is ISchnorrStakeRegistry {
    function isValidSignature(bytes32, uint256, address, address[] calldata, uint256) external pure returns (bool) {
        return true;
    }
}

/// Declares `k` (0, 1 or 4) single-slot ranges at 1000, 1010, ..., above every slot the programs
/// write.
contract RangedConsumer is GasKillerSDK {
    uint256 public immutable k;

    constructor(address registry, uint256 k_) {
        _setSchnorrRegistry(registry);
        k = k_;
    }

    /// @dev Literal lists, as a consumer would write them.
    function _protectedRanges() internal view override returns (StorageGuard.ProtectedRange[] memory r) {
        r = new StorageGuard.ProtectedRange[](k);
        if (k >= 1) r[0] = StorageGuard.ProtectedRange(1000, 1000, StorageGuard.FULL);
        if (k >= 4) {
            r[1] = StorageGuard.ProtectedRange(1010, 1010, StorageGuard.FULL);
            r[2] = StorageGuard.ProtectedRange(1020, 1020, StorageGuard.FULL);
            r[3] = StorageGuard.ProtectedRange(1030, 1030, StorageGuard.FULL);
        }
    }
}

/// @notice Whole-settlement gas through `verifyAndUpdate` with protected storage enforced: the
///         SDK's two ranges plus k consumer ranges, for a program of the counter copy plus n
///         STOREs to fresh slots. Each figure is one settlement, measured as a delta around the
///         call, so it includes the cold zero-to-nonzero writes (22,100 each).
///
///         Reference measurements (forge 1.5.1, solc 0.8.33, cancun). "Before" is the same
///         settlement on the tree before protected storage was wired in (49f5c5c), where k has
///         no effect:
///
///           n   | before  | k = 0           | k = 1           | k = 4
///           1   |  53,513 | +3,107 (+5.8%)  | +3,924 (+7.3%)  | +6,469 (+12%)
///           8   | 215,998 | +5,505 (+2.5%)  | +6,325 (+2.9%)  | +8,879 (+4.1%)
///           32  | 773,283 | +13,727 (+1.8%) | +14,558 (+1.9%) | +17,143 (+2.2%)
///
///         About 340 gas per STORE for the check, about 820 per declared range per settlement
///         (building, merging and validating the list), and about 2,800 fixed (the SDK's two
///         ranges, and the counter copy's SLOAD to confirm it changes nothing).
///
///         Run with `FOUNDRY_PROFILE=gas forge test -vv`.
contract SettlementGasTest is Test {
    bytes32 constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    bytes4 constant FN = bytes4(keccak256("work()"));

    AcceptAll registry;

    function setUp() public {
        vm.roll(1000);
        registry = new AcceptAll();
    }

    function _updates(uint256 n) internal pure returns (bytes memory) {
        StateUpdateType[] memory t = new StateUpdateType[](n + 1);
        bytes[] memory a = new bytes[](n + 1);
        a[0] = abi.encode(TRACKER_SLOT, bytes32(uint256(1)));
        for (uint256 i = 1; i <= n; ++i) {
            a[i] = abi.encode(bytes32(i), bytes32(i));
        }
        return abi.encode(t, a);
    }

    function _settleGas(GasKillerSDK target, uint256 n) internal returns (uint256 used) {
        bytes memory updates = _updates(n);
        bytes32 h = target.getMessageHash(0, FN, updates);
        address[] memory none = new address[](0);
        uint32 ref = uint32(block.number - 1);
        uint256 g = gasleft();
        target.verifyAndUpdate(h, ref, updates, 0, FN, 1, address(1), none);
        used = g - gasleft();
    }

    function test_settlement() public {
        uint256[3] memory ns = [uint256(1), 8, 32];
        uint256[3] memory ks = [uint256(0), 1, 4];
        // One untimed settlement first, so no measured call pays the registry's cold access.
        _settleGas(new RangedConsumer(address(registry), 0), 1);
        console2.log("settlement gas, counter copy + n fresh STOREs");
        console2.log("n    k  |  gas");
        for (uint256 ni = 0; ni < 3; ++ni) {
            for (uint256 ki = 0; ki < 3; ++ki) {
                RangedConsumer c = new RangedConsumer(address(registry), ks[ki]);
                uint256 used = _settleGas(c, ns[ni]);
                console2.log(string.concat(vm.toString(ns[ni]), "  ", vm.toString(ks[ki]), "  |  ", vm.toString(used)));
            }
        }
    }
}
