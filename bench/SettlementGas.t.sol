// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {ISchnorrStakeRegistry} from "../src/interface/ISchnorrStakeRegistry.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {TaskSubmission} from "../src/interface/IGasKillerSDKBatch.sol";
import {StorageGuard} from "../src/libraries/StorageGuard.sol";

contract AcceptAll is ISchnorrStakeRegistry {
    function isValidSignature(bytes32, uint256, address, address[] calldata, uint256) external pure returns (bool) {
        return true;
    }
}

/// A consumer declaring no ranges of its own; the SDK's two still apply.
contract RangedConsumer0 is GasKillerSDK {
    constructor(address registry) {
        _setSchnorrRegistry(registry);
    }
}

/// One single-slot range, above every slot the programs write.
contract RangedConsumer1 is RangedConsumer0 {
    constructor(address registry) RangedConsumer0(registry) {}

    function _protectedRanges() internal pure override returns (StorageGuard.ProtectedRange[] memory r) {
        r = new StorageGuard.ProtectedRange[](1);
        r[0] = StorageGuard.ProtectedRange(1000, 1000, StorageGuard.FULL);
    }
}

/// Four single-slot ranges, above every slot the programs write.
contract RangedConsumer4 is RangedConsumer0 {
    constructor(address registry) RangedConsumer0(registry) {}

    function _protectedRanges() internal pure override returns (StorageGuard.ProtectedRange[] memory r) {
        r = new StorageGuard.ProtectedRange[](4);
        r[0] = StorageGuard.ProtectedRange(1000, 1000, StorageGuard.FULL);
        r[1] = StorageGuard.ProtectedRange(1010, 1010, StorageGuard.FULL);
        r[2] = StorageGuard.ProtectedRange(1020, 1020, StorageGuard.FULL);
        r[3] = StorageGuard.ProtectedRange(1030, 1030, StorageGuard.FULL);
    }
}

/// @notice Whole-settlement gas through `verifyAndUpdate` with protected storage enforced: the
///         SDK's two ranges plus k consumer ranges, for a program of the counter copy plus n
///         STOREs to fresh slots, and for a 20-item batch. Each figure is one settlement, measured as a delta around the
///         call, so it includes the cold zero-to-nonzero writes (22,100 each).
///
///         Reference measurements (forge 1.5.1, solc 0.8.33, cancun). "Before" is the same
///         settlement on the tree before protected storage was wired in (49f5c5c):
///
///           n   | before  | k = 0           | k = 1           | k = 4
///           1   |  53,513 | +2,011 (+3.8%)  | +2,488 (+4.6%)  | +4,044 (+7.6%)
///           8   | 215,998 | +4,393 (+2.0%)  | +4,872 (+2.3%)  | +6,435 (+3.0%)
///           32  | 773,283 | +12,560 (+1.6%) | +13,057 (+1.7%) | +14,653 (+1.9%)
///
///         About 340 gas per STORE for the check, about 500 per declared range per call
///         (building and merging the list; it is validated at deployment, not here), and about
///         1,670 fixed. `test_batch`: a 20-item batch builds the list once, +33,729 (+5.2%) at
///         k = 0 and +45,942 (+7.0%) at k = 4 over 653,750 / 657,603.
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

    function _consumer(uint256 k) internal returns (GasKillerSDK) {
        if (k == 1) return new RangedConsumer1(address(registry));
        if (k == 4) return new RangedConsumer4(address(registry));
        return new RangedConsumer0(address(registry));
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
        _settleGas(_consumer(0), 1);
        console2.log("settlement gas, counter copy + n fresh STOREs");
        console2.log("n    k  |  gas");
        for (uint256 ni = 0; ni < 3; ++ni) {
            for (uint256 ki = 0; ki < 3; ++ki) {
                GasKillerSDK c = _consumer(ks[ki]);
                uint256 used = _settleGas(c, ns[ni]);
                console2.log(string.concat(vm.toString(ns[ni]), "  ", vm.toString(ks[ki]), "  |  ", vm.toString(used)));
            }
        }
    }

    /// @dev A batch of `items` transitions, each the counter copy plus one fresh STORE.
    function _batchGas(GasKillerSDK target, uint256 items) internal returns (uint256 used) {
        TaskSubmission[] memory subs = new TaskSubmission[](items);
        for (uint256 i = 0; i < items; ++i) {
            StateUpdateType[] memory t = new StateUpdateType[](2);
            bytes[] memory a = new bytes[](2);
            a[0] = abi.encode(TRACKER_SLOT, bytes32(i + 1));
            a[1] = abi.encode(bytes32(i + 1), bytes32(i + 1));
            bytes memory updates = abi.encode(t, a);
            subs[i] = TaskSubmission(
                target.getMessageHash(i, FN, updates),
                uint32(block.number - 1),
                updates,
                i,
                FN,
                1,
                address(1),
                new address[](0),
                0
            );
        }
        uint256 g = gasleft();
        target.verifyAndUpdateBatch(subs);
        used = g - gasleft();
    }

    function test_batch() public {
        uint256[3] memory ks = [uint256(0), 1, 4];
        _settleGas(_consumer(0), 1); // warm the registry
        console2.log("batch gas, 20 items, each the counter copy + 1 fresh STORE");
        console2.log("k  |  gas");
        for (uint256 ki = 0; ki < 3; ++ki) {
            uint256 used = _batchGas(_consumer(ks[ki]), 20);
            console2.log(string.concat(vm.toString(ks[ki]), "  |  ", vm.toString(used)));
        }
    }
}
