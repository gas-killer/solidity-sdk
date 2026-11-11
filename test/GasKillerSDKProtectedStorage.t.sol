// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {ISchnorrStakeRegistry} from "../src/interface/ISchnorrStakeRegistry.sol";
import {TaskSubmission} from "../src/interface/IGasKillerSDKBatch.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {StorageGuard} from "../src/libraries/StorageGuard.sol";

/// Accepts every signature, so these tests exercise what settlement does with a program the
/// quorum signed, including a malicious one.
contract AcceptingRegistry is ISchnorrStakeRegistry {
    function isValidSignature(bytes32, uint256, address, address[] calldata, uint256) external pure returns (bool) {
        return true;
    }
}

/// A consumer that packs its owner with a counter in slot 0 and protects only the owner bits.
/// Ownership can change legitimately, through `claimOwnership` by the pending owner.
contract GuardedVault is GasKillerSDK {
    address public owner; // slot 0, low 160 bits (protected)
    uint96 public nonce; // slot 0, high 96 bits (free)
    uint256 public value; // slot 1
    address public pendingOwner; // slot 2

    bytes32 internal constant OWNER_BITS = bytes32(uint256(type(uint160).max));

    constructor(address registry, address owner_, address pendingOwner_) {
        _setSchnorrRegistry(registry);
        _setAvsAddress(address(0xA75));
        owner = owner_;
        pendingOwner = pendingOwner_;
    }

    function claimOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function _protectedRanges() internal pure override returns (StorageGuard.ProtectedRange[] memory r) {
        r = new StorageGuard.ProtectedRange[](1);
        r[0] = StorageGuard.ProtectedRange(0, 0, OWNER_BITS);
    }
}

/// Claims a vault's ownership when a program CALLs it: a legitimate change to protected storage
/// made by native code in the middle of a program.
contract Claimer {
    function claim(GuardedVault v) external {
        v.claimOwnership();
    }
}

/// The same vault, opted out of the check: its declared owner range and the SDK's own ranges no
/// longer apply.
contract UnguardedVault is GuardedVault {
    constructor(address registry, address owner_, address pendingOwner_)
        GuardedVault(registry, owner_, pendingOwner_)
    {}

    function _unsafeDisableStorageGuard() internal pure override returns (bool) {
        return true;
    }
}

/// A consumer that declares nothing: it still gets the SDK's own protection.
contract PlainConsumer is GasKillerSDK {
    constructor(address registry) {
        _setSchnorrRegistry(registry);
    }
}

/// Fills every field of the SDK's config struct through the SDK's own setters.
contract LayoutProbe is GasKillerSDK {
    constructor(address registry) {
        _setSchnorrRegistry(registry);
    }

    function fill() external {
        _setAvsAddress(address(type(uint160).max));
        _setSchnorrRegistry(address(type(uint160).max));
        _setBlockStaleMeasure(type(uint96).max);
    }
}

/// A consumer with a tracked function that changes the SDK's config, which the setters' NatSpec
/// warns can never settle.
contract TunableConsumer is GasKillerSDK {
    constructor(address registry) {
        _setSchnorrRegistry(registry);
    }

    function setStaleWindow(uint256 blocks) external trackState {
        _setBlockStaleMeasure(blocks);
    }
}

/// Re-declares the transition counter, which the SDK already protects.
contract OverlappingConsumer is GasKillerSDK {
    function _protectedRanges() internal pure override returns (StorageGuard.ProtectedRange[] memory r) {
        r = new StorageGuard.ProtectedRange[](2);
        r[0] = StorageGuard.ProtectedRange(0, 0, StorageGuard.FULL);
        r[1] = StorageGuard.ProtectedRange(
            0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf,
            0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf,
            StorageGuard.FULL
        );
    }
}

/// Declares its ranges in descending order.
contract DescendingConsumer is GasKillerSDK {
    function _protectedRanges() internal pure override returns (StorageGuard.ProtectedRange[] memory r) {
        r = new StorageGuard.ProtectedRange[](2);
        r[0] = StorageGuard.ProtectedRange(5, 5, StorageGuard.FULL);
        r[1] = StorageGuard.ProtectedRange(0, 0, StorageGuard.FULL);
    }
}

/// @notice Protected storage enforced by settlement: the SDK's own slots for every consumer, the
///         consumer's declared slots, exact judgement after a CALL, and fail-closed handling of a
///         malformed list. Nested settlement is covered in `examples/NestedCycle.t.sol`.
contract GasKillerSDKProtectedStorageTest is Test {
    bytes32 constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    bytes32 constant SDK_STORAGE = 0x1d6f9f139320a34a32f3b29eb8638270178e831962a74100c9e8b433f21e1200;
    address constant OWNER = address(0xA11CE);
    address constant ATTACKER = address(0xBAD);
    bytes4 constant FN = bytes4(keccak256("work()"));

    AcceptingRegistry registry;
    Claimer claimer;
    GuardedVault vault;

    function setUp() public {
        vm.roll(1000);
        registry = new AcceptingRegistry();
        claimer = new Claimer();
        vault = new GuardedVault(address(registry), OWNER, address(claimer));
    }

    // ---------------------------------------------------------------- helpers

    struct Program {
        StateUpdateType[] types;
        bytes[] args;
        uint256 n;
    }

    function _program(uint256 capacity) internal pure returns (Program memory p) {
        p.types = new StateUpdateType[](capacity);
        p.args = new bytes[](capacity);
    }

    function _store(Program memory p, bytes32 slot, bytes32 v) internal pure {
        p.types[p.n] = StateUpdateType.STORE;
        p.args[p.n++] = abi.encode(slot, v);
    }

    function _call(Program memory p, address target, bytes memory data) internal pure {
        p.types[p.n] = StateUpdateType.CALL;
        p.args[p.n++] = abi.encode(target, uint256(0), data);
    }

    function _encode(Program memory p) internal pure returns (bytes memory) {
        StateUpdateType[] memory t = new StateUpdateType[](p.n);
        bytes[] memory a = new bytes[](p.n);
        for (uint256 i = 0; i < p.n; ++i) {
            (t[i], a[i]) = (p.types[i], p.args[i]);
        }
        return abi.encode(t, a);
    }

    /// @dev A program as gas-analyzer emits it: the counter copy first, then the given ops.
    function _tracked(GasKillerSDK target, uint256 capacity) internal view returns (Program memory p) {
        p = _program(capacity + 1);
        _store(p, TRACKER_SLOT, bytes32(target.stateTransitionCount() + 1));
    }

    function _settle(GasKillerSDK target, Program memory p) internal {
        _settle(target, p, "");
    }

    /// @dev Settles `p`, expecting `revertData` when it is nonempty. Every view call happens
    ///      before `vm.expectRevert`, which applies to the next external call only.
    function _settle(GasKillerSDK target, Program memory p, bytes memory revertData) internal {
        bytes memory updates = _encode(p);
        uint256 ti = target.stateTransitionCount();
        bytes32 h = target.getMessageHash(ti, FN, updates);
        if (revertData.length != 0) vm.expectRevert(revertData);
        target.verifyAndUpdate(h, uint32(block.number - 1), updates, ti, FN, 1, address(1), new address[](0));
    }

    function _ownerSlot(address owner_, uint96 nonce_) internal pure returns (bytes32) {
        return bytes32((uint256(nonce_) << 160) | uint160(owner_));
    }

    function _rejection(uint256 index, bytes32 slot) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(StorageGuard.ProtectedSlotWrite.selector, index, slot);
    }

    // ---------------------------------------------------------------- honest programs

    function test_honestProgramSettles() public {
        Program memory p = _tracked(vault, 2);
        _store(p, bytes32(uint256(1)), bytes32(uint256(42))); // value
        _store(p, bytes32(0), _ownerSlot(OWNER, 5)); // nonce bump, owner kept
        _settle(vault, p);

        assertEq(vault.value(), 42);
        assertEq(vault.nonce(), 5);
        assertEq(vault.owner(), OWNER);
        assertEq(vault.stateTransitionCount(), 1);
    }

    function test_counterCopyPassesOnEveryTransition() public {
        for (uint256 i = 0; i < 3; ++i) {
            Program memory p = _tracked(vault, 1);
            _store(p, bytes32(uint256(1)), bytes32(i));
            _settle(vault, p);
        }
        assertEq(vault.stateTransitionCount(), 3);
    }

    // ---------------------------------------------------------------- the SDK's own slots

    function test_counterRewriteRejected() public {
        Program memory p = _program(1);
        _store(p, TRACKER_SLOT, bytes32(uint256(7)));
        _settle(vault, p, _rejection(0, TRACKER_SLOT));
    }

    function test_sdkConfigRewriteRejected() public {
        for (uint256 k = 0; k < 2; ++k) {
            bytes32 slot = bytes32(uint256(SDK_STORAGE) + k);
            Program memory p = _tracked(vault, 1);
            _store(p, slot, bytes32(uint256(uint160(ATTACKER))));
            _settle(vault, p, _rejection(1, slot));
        }
        assertEq(vault.schnorrRegistry(), address(registry));
        assertEq(vault.avsAddress(), address(0xA75));
    }

    /// @notice Every slot of the config struct's namespace is protected, not just the two the
    ///         struct uses today, so a field added later is covered. The slot just past the
    ///         namespace is not, so the range is exactly the namespace.
    function testFuzz_wholeConfigNamespaceIsProtected(uint8 offset) public {
        bytes32 slot = bytes32(uint256(SDK_STORAGE) + offset);
        Program memory p = _tracked(vault, 1);
        _store(p, slot, bytes32(uint256(1)));
        _settle(vault, p, _rejection(1, slot));
    }

    function test_slotPastTheConfigNamespaceIsNotProtected() public {
        Program memory p = _tracked(vault, 1);
        _store(p, bytes32(uint256(SDK_STORAGE) + 256), bytes32(uint256(1)));
        _settle(vault, p);
    }

    /// @notice Ties the protected range to the struct's real layout. Writes every field of the
    ///         config struct through the SDK's own setters with all-ones values, then requires
    ///         that every slot it occupies is inside the protected config range. A new field
    ///         needs its setter added to `LayoutProbe.fill`; the namespace-wide range protects
    ///         it either way.
    function test_configStructLayoutIsInsideTheProtectedRange() public {
        // The location is ERC-7201: its derivation, with the low byte cleared, so the namespace
        // is the 256-slot block starting there.
        assertEq(
            SDK_STORAGE,
            keccak256(abi.encode(uint256(keccak256("gaskiller.SchnorrGasKillerSDK.storage")) - 1))
                & ~bytes32(uint256(0xff))
        );

        LayoutProbe probe = new LayoutProbe(address(registry));
        StorageGuard.ProtectedRange[] memory rs = probe.gasKillerProtectedRanges();
        (uint256 start, uint256 end) = (rs[0].start, rs[0].end);
        assertEq(start, uint256(SDK_STORAGE));

        probe.fill();
        uint256 used;
        for (uint256 slot = uint256(SDK_STORAGE); slot < uint256(SDK_STORAGE) + 512; ++slot) {
            if (vm.load(address(probe), bytes32(slot)) == bytes32(0)) continue;
            assertLe(slot, end, "a config field lives outside the protected range");
            ++used;
        }
        // Tripwire, not protection: when the struct grows, add the new field's setter to
        // `LayoutProbe.fill` and update this count, so the check above covers it.
        assertEq(used, 2, "config struct changed: add its setter to LayoutProbe.fill and update this count");
        // Nothing below the namespace either.
        assertEq(vm.load(address(probe), bytes32(uint256(SDK_STORAGE) - 1)), bytes32(0));
    }

    function test_consumerWithNoRangesStillGetsSdkProtection() public {
        PlainConsumer plain = new PlainConsumer(address(registry));
        StorageGuard.ProtectedRange[] memory rs = plain.gasKillerProtectedRanges();
        assertEq(rs.length, 2);

        Program memory p = _tracked(plain, 1);
        _store(p, bytes32(uint256(SDK_STORAGE) + 1), bytes32(uint256(uint160(ATTACKER))));
        _settle(plain, p, _rejection(1, bytes32(uint256(SDK_STORAGE) + 1)));
    }

    /// @notice Pins what the config setters' NatSpec says: a tracked function that changes the
    ///         config can't settle, and one that stores the current value can. The program is
    ///         built the way gas-analyzer would: run the function natively, read the slot it
    ///         wrote, then undo it.
    function test_trackedFunctionThatChangesConfigCannotSettle() public {
        TunableConsumer tunable = new TunableConsumer(address(registry));
        bytes32 slot = bytes32(uint256(SDK_STORAGE) + 1); // registry + blockStaleMeasure, packed
        bytes32 current = vm.load(address(tunable), slot);

        uint256 snapshot = vm.snapshotState();
        tunable.setStaleWindow(50);
        bytes32 written = vm.load(address(tunable), slot);
        vm.revertToState(snapshot);
        assertTrue(written != current, "the native call changed the config slot");

        Program memory p = _tracked(tunable, 1);
        _store(p, slot, written);
        _settle(tunable, p, _rejection(1, slot));

        p = _tracked(tunable, 1);
        _store(p, slot, current); // same value: nothing changes
        _settle(tunable, p);
        assertEq(tunable.blockStaleMeasure(), 300, "still the default");
    }

    // ---------------------------------------------------------------- the consumer's slots

    function test_ownerRewriteRejected() public {
        Program memory p = _tracked(vault, 1);
        _store(p, bytes32(0), _ownerSlot(ATTACKER, 0));
        _settle(vault, p, _rejection(1, bytes32(0)));
        assertEq(vault.owner(), OWNER);
    }

    /// @dev The inline check judges each STORE against storage at that moment. A CALL that
    ///      legitimately moves ownership is fine; a later STORE that restores the old owner is
    ///      not; a later STORE that keeps the new owner is.
    function test_writesAfterALegitimateOwnerChangeAreJudgedExactly() public {
        bytes memory claim = abi.encodeCall(Claimer.claim, (vault));
        uint256 snapshot = vm.snapshotState();

        Program memory p = _tracked(vault, 2);
        _call(p, address(claimer), claim);
        _store(p, bytes32(0), _ownerSlot(OWNER, 1)); // put the old owner back
        _settle(vault, p, _rejection(2, bytes32(0)));

        vm.revertToState(snapshot);
        p = _tracked(vault, 2);
        _call(p, address(claimer), claim);
        _store(p, bytes32(0), _ownerSlot(address(claimer), 1)); // nonce bump under the new owner
        _settle(vault, p);
        assertEq(vault.owner(), address(claimer));
        assertEq(vault.nonce(), 1);
    }

    // ---------------------------------------------------------------- the list itself

    function test_protectedRangesIsTheMergedValidList() public view {
        StorageGuard.ProtectedRange[] memory rs = vault.gasKillerProtectedRanges();
        assertEq(rs.length, 3);
        assertEq(rs[0].start, 0);
        assertEq(rs[0].end, 0);
        assertEq(rs[0].mask, bytes32(uint256(type(uint160).max)));
        assertEq(rs[1].start, uint256(SDK_STORAGE));
        assertEq(rs[1].end, uint256(SDK_STORAGE) + 255, "the config struct's whole ERC-7201 namespace");
        assertEq(rs[2].start, uint256(TRACKER_SLOT));
        assertEq(rs[2].end, uint256(TRACKER_SLOT));
        StorageGuard.validateRanges(rs);
    }

    /// @notice A malformed list fails at deployment, before any settlement can be attempted.
    function test_malformedConsumerListRevertsDeployment() public {
        vm.expectRevert(StorageGuard.InvalidRanges.selector);
        new OverlappingConsumer();
        vm.expectRevert(StorageGuard.InvalidRanges.selector);
        new DescendingConsumer();
    }

    // ---------------------------------------------------------------- opting out

    /// @notice Protection is on unless the consumer overrides the hook: every guarded contract
    ///         reports the SDK's ranges, and the rejection tests above run against the default.
    function test_guardIsOnByDefault() public {
        assertEq(new PlainConsumer(address(registry)).gasKillerProtectedRanges().length, 2);
        assertEq(vault.gasKillerProtectedRanges().length, 3);
    }

    /// @notice An opted-out consumer applies writes the guard would reject: its owner, the SDK's
    ///         config and the transition counter. Its reported list is empty.
    function test_optedOutConsumerAppliesProtectedWrites() public {
        UnguardedVault open = new UnguardedVault(address(registry), OWNER, address(claimer));
        assertEq(open.gasKillerProtectedRanges().length, 0);

        Program memory p = _tracked(open, 3);
        _store(p, bytes32(0), _ownerSlot(ATTACKER, 0));
        _store(p, SDK_STORAGE, bytes32(uint256(uint160(ATTACKER)))); // avsAddress
        _store(p, TRACKER_SLOT, bytes32(uint256(7)));
        _settle(open, p);

        assertEq(open.owner(), ATTACKER);
        assertEq(open.avsAddress(), ATTACKER);
        assertEq(open.stateTransitionCount(), 7);
    }

    function test_optedOutConsumerAppliesProtectedWritesInABatch() public {
        UnguardedVault open = new UnguardedVault(address(registry), OWNER, address(claimer));
        TaskSubmission[] memory subs = new TaskSubmission[](2);
        for (uint256 i = 0; i < 2; ++i) {
            Program memory p = _program(2);
            _store(p, TRACKER_SLOT, bytes32(i + 1));
            _store(p, bytes32(0), _ownerSlot(ATTACKER, uint96(i)));
            bytes memory updates = _encode(p);
            subs[i] = TaskSubmission(
                open.getMessageHash(i, FN, updates),
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
        open.verifyAndUpdateBatch(subs);
        assertEq(open.owner(), ATTACKER);
        assertEq(open.nonce(), 1);
        assertEq(open.stateTransitionCount(), 2);
    }

    // ---------------------------------------------------------------- batches

    function test_batchWithOneMaliciousTransitionRevertsWhole() public {
        TaskSubmission[] memory subs = new TaskSubmission[](2);
        for (uint256 i = 0; i < 2; ++i) {
            Program memory p = _program(2);
            _store(p, TRACKER_SLOT, bytes32(i + 1));
            if (i == 0) _store(p, bytes32(uint256(1)), bytes32(uint256(42)));
            else _store(p, bytes32(0), _ownerSlot(ATTACKER, 0));
            bytes memory updates = _encode(p);
            subs[i] = TaskSubmission(
                vault.getMessageHash(i, FN, updates),
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
        vm.expectRevert(_rejection(1, bytes32(0)));
        vault.verifyAndUpdateBatch(subs);
        assertEq(vault.value(), 0, "the honest transition rolled back with the batch");
        assertEq(vault.owner(), OWNER);
    }
}
