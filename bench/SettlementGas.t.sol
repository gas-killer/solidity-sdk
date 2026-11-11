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

/// Opted out of the check (`_unsafeDisableStorageGuard`).
contract UnguardedConsumer is RangedConsumer0 {
    constructor(address registry) RangedConsumer0(registry) {}

    function _unsafeDisableStorageGuard() internal pure override returns (bool) {
        return true;
    }
}

/// @notice Whole-settlement gas through `verifyAndUpdate`: the SDK's two ranges plus k consumer
///         ranges, or opted out of the check, for a program of the counter copy plus n STOREs to
///         fresh slots, and for a 20-item batch. Each figure is one settlement, measured as a
///         delta around the call, so it includes the cold zero-to-nonzero writes (22,100 each).
///
///         Reference measurements (forge 1.5.1, solc 0.8.33, cancun). "Before" is the same
///         settlement on the tree before protected storage was wired in (49f5c5c):
///
///           n   | before  | opted out      | k = 0           | k = 1           | k = 4
///           1   |  53,513 | +135 (+0.3%)   | +2,075 (+3.9%)  | +2,552 (+4.8%)  | +4,108 (+7.7%)
///           8   | 215,998 | +541 (+0.3%)   | +4,499 (+2.1%)  | +4,978 (+2.3%)  | +6,541 (+3.0%)
///           32  | 773,288 | +1,933 (+0.2%) | +12,820 (+1.7%) | +13,317 (+1.7%) | +14,912 (+1.9%)
///
///         Protected: about 340 gas per STORE, about 500 per declared range per call (building
///         and merging the list; it is validated at deployment, not here), and about 1,400 fixed.
///         Opted out: about 60 per STORE. `test_batch`: a 20-item batch builds the list once,
///         +34,750 (+5.3%) at k = 0, +46,963 (+7.2%) at k = 4 and +8,323 (+1.3%) opted out, over
///         653,659.
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

    /// The `k` that stands for an opted-out consumer.
    uint256 constant OFF = type(uint256).max;

    function _consumer(uint256 k) internal returns (GasKillerSDK) {
        if (k == OFF) return new UnguardedConsumer(address(registry));
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

    function _k(uint256 k) internal pure returns (string memory) {
        return k == OFF ? "off" : vm.toString(k);
    }

    function test_settlement() public {
        uint256[3] memory ns = [uint256(1), 8, 32];
        uint256[4] memory ks = [OFF, 0, 1, 4];
        // One untimed settlement first, so no measured call pays the registry's cold access.
        _settleGas(_consumer(0), 1);
        console2.log("settlement gas, counter copy + n fresh STOREs");
        console2.log("n    k  |  gas");
        for (uint256 ni = 0; ni < 3; ++ni) {
            for (uint256 ki = 0; ki < 4; ++ki) {
                GasKillerSDK c = _consumer(ks[ki]);
                uint256 used = _settleGas(c, ns[ni]);
                console2.log(string.concat(vm.toString(ns[ni]), "  ", _k(ks[ki]), "  |  ", vm.toString(used)));
            }
        }
    }

    /// @dev A batch of `items` transitions, each the counter copy plus one fresh STORE, against a
    ///      fresh consumer with `k` ranges. External and called through `this`, so each batch
    ///      starts from fresh memory: in one frame the submissions of earlier rows would make
    ///      later rows pay for memory expansion, about 1,900 gas at 20 items.
    function batchGas(uint256 k, uint256 items) external returns (uint256 used) {
        GasKillerSDK target = _consumer(k);
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
        uint256[4] memory ks = [OFF, 0, 1, 4];
        _settleGas(_consumer(0), 1); // warm the registry
        console2.log("batch gas, 20 items, each the counter copy + 1 fresh STORE");
        console2.log("k  |  gas");
        for (uint256 ki = 0; ki < 4; ++ki) {
            uint256 used = this.batchGas(ks[ki], 20);
            console2.log(string.concat(_k(ks[ki]), "  |  ", vm.toString(used)));
        }
    }
}
