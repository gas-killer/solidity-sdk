// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {
    GasKillerOutgoingRateLimit,
    GasKillerNestedOutgoingRateLimit
} from "../src/extensions/GasKillerOutgoingRateLimit.sol";
import {OutgoingRateLimit} from "../src/libraries/OutgoingRateLimit.sol";
import {TaskSubmission} from "../src/interface/IGasKillerSDKBatch.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {StorageGuard} from "../src/libraries/StorageGuard.sol";
import {AcceptingRegistry} from "./GasKillerSDKProtectedStorage.t.sol";
import {MintableToken, PolicedTreasury} from "./GasKillerSDKCallPolicy.t.sol";

/// A drop-in consumer that may send at most 1 ether per hour through signed programs.
contract RateLimitedTreasury is GasKillerOutgoingRateLimit {
    constructor(address registry) GasKillerOutgoingRateLimit(1 ether, 1 hours) {
        _setSchnorrRegistry(registry);
    }

    receive() external payable {}

    function setLimit(uint256 limit, uint256 period) external {
        _setOutgoingRateLimit(limit, period);
    }
}

/// The nested drop-in.
contract NestedRateLimitedTreasury is GasKillerNestedOutgoingRateLimit {
    constructor(address registry) GasKillerNestedOutgoingRateLimit(1 ether, 1 hours) {
        _setSchnorrRegistry(registry);
    }

    receive() external payable {}
}

/// A consumer that already builds on another SDK base adds the limit through the library, after
/// its own policy.
contract RateLimitedPolicedTreasury is PolicedTreasury {
    constructor(address registry, IERC20 token_, address payee_) PolicedTreasury(registry, token_, payee_) {
        OutgoingRateLimit.set(_outgoingBucket(), 1 ether, 1 hours);
    }

    function _authorizeCall(
        bytes4 targetFunction,
        uint256 index,
        StateUpdateType kind,
        address target,
        uint256 value,
        bytes memory data
    ) internal override {
        super._authorizeCall(targetFunction, index, kind, target, value, data);
        OutgoingRateLimit.spend(_outgoingBucket(), index, value);
    }
}

/// Its budget never set, as a proxy's storage is before its initializer runs.
contract UnsetRateLimitTreasury is GasKillerOutgoingRateLimit {
    constructor(address registry) GasKillerOutgoingRateLimit(1, 1) {
        _setSchnorrRegistry(registry);
        GasKillerSDK.OutgoingBucket storage b = _outgoingBucket();
        (b.limit, b.available, b.period, b.updated) = (0, 0, 0, 0);
    }

    receive() external payable {}
}

/// @notice `GasKillerOutgoingRateLimit`: a shared token bucket over the ETH signed programs send.
contract GasKillerOutgoingRateLimitTest is Test {
    bytes32 constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    bytes32 constant SDK_STORAGE = 0x1d6f9f139320a34a32f3b29eb8638270178e831962a74100c9e8b433f21e1200;
    address constant ATTACKER = address(0xBAD);
    address constant PAYEE = address(0xFEE);
    bytes4 constant FN = bytes4(keccak256("work()"));

    AcceptingRegistry registry;
    MintableToken token;
    RateLimitedTreasury t;

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_700_000_000);
        registry = new AcceptingRegistry();
        token = new MintableToken();
        t = new RateLimitedTreasury(address(registry));
        vm.deal(address(t), 10 ether);
    }

    // ---------------------------------------------------------------- helpers

    struct Program {
        StateUpdateType[] types;
        bytes[] args;
        uint256 n;
    }

    function _tracked(GasKillerSDK target, uint256 capacity) internal view returns (Program memory p) {
        p.types = new StateUpdateType[](capacity + 1);
        p.args = new bytes[](capacity + 1);
        p.args[0] = abi.encode(TRACKER_SLOT, bytes32(target.stateTransitionCount() + 1));
        p.n = 1;
    }

    function _op(Program memory p, StateUpdateType kind, bytes memory arg) internal pure {
        p.types[p.n] = kind;
        p.args[p.n++] = arg;
    }

    function _send(Program memory p, address to, uint256 value) internal pure {
        _op(p, StateUpdateType.CALL, abi.encode(to, value, ""));
    }

    function _encode(Program memory p) internal pure returns (bytes memory) {
        StateUpdateType[] memory ty = new StateUpdateType[](p.n);
        bytes[] memory a = new bytes[](p.n);
        for (uint256 i = 0; i < p.n; ++i) {
            (ty[i], a[i]) = (p.types[i], p.args[i]);
        }
        return abi.encode(ty, a);
    }

    function _settle(GasKillerSDK target, Program memory p, bytes memory revertData) internal {
        bytes memory updates = _encode(p);
        uint256 ti = target.stateTransitionCount();
        bytes32 h = target.getMessageHash(ti, FN, updates);
        if (revertData.length != 0) vm.expectRevert(revertData);
        target.verifyAndUpdate(h, uint32(block.number - 1), updates, ti, FN, 1, address(1), new address[](0));
    }

    /// @dev One transition sending `value` to the attacker.
    function _drain(GasKillerSDK target, uint256 value, bytes memory revertData) internal {
        Program memory p = _tracked(target, 1);
        _send(p, ATTACKER, value);
        _settle(target, p, revertData);
    }

    function _exceeded(uint256 index, uint256 value, uint256 available) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OutgoingRateLimit.OutgoingRateLimitExceeded.selector, index, value, available);
    }

    function _available(GasKillerOutgoingRateLimit target) internal view returns (uint256 a) {
        (a,,) = target.gasKillerOutgoingAllowance();
    }

    // ---------------------------------------------------------------- the budget

    function test_startsFull() public view {
        (uint256 available, uint256 limit, uint256 period) = t.gasKillerOutgoingAllowance();
        assertEq(available, 1 ether);
        assertEq(limit, 1 ether);
        assertEq(period, 1 hours);
    }

    function test_oneProgramCanSpendUpToTheLimit() public {
        Program memory p = _tracked(t, 3);
        _send(p, ATTACKER, 0.5 ether);
        _op(p, StateUpdateType.CREATE, abi.encode(0.3 ether, hex"00"));
        _send(p, ATTACKER, 0.2 ether);
        _settle(t, p, "");
        assertEq(ATTACKER.balance, 0.7 ether);
        assertEq(_available(t), 0);
    }

    function test_opPastTheBudgetRevertsBeforeItRuns() public {
        Program memory p = _tracked(t, 2);
        _send(p, ATTACKER, 0.6 ether);
        _send(p, ATTACKER, 0.6 ether);
        _settle(t, p, _exceeded(2, 0.6 ether, 0.4 ether));
        assertEq(ATTACKER.balance, 0);
        assertEq(_available(t), 1 ether, "the reverted spend left the budget as it was");
    }

    /// The budget is shared across transitions: a drain split over many programs is still capped.
    function test_budgetIsSharedAcrossTransitions() public {
        _drain(t, 0.6 ether, "");
        _drain(t, 0.6 ether, _exceeded(1, 0.6 ether, 0.4 ether));
        _drain(t, 0.4 ether, "");
        assertEq(ATTACKER.balance, 1 ether);
    }

    function test_budgetRefillsOverThePeriod() public {
        _drain(t, 1 ether, "");
        vm.warp(block.timestamp + 15 minutes);
        assertEq(_available(t), 0.25 ether);
        _drain(t, 0.25 ether + 1, _exceeded(1, 0.25 ether + 1, 0.25 ether));
        _drain(t, 0.25 ether, "");
        assertEq(_available(t), 0);
    }

    function test_refillStopsAtTheLimit() public {
        _drain(t, 0.1 ether, "");
        vm.warp(block.timestamp + 30 days);
        assertEq(_available(t), 1 ether);
        _drain(t, 1 ether + 1, _exceeded(1, 1 ether + 1, 1 ether));
    }

    function testFuzz_neverMoreThanLimitPlusRefill(uint256[6] memory amounts, uint32[6] memory gaps) public {
        uint256 start = block.timestamp;
        uint256 sent;
        for (uint256 i = 0; i < 6; ++i) {
            vm.warp(block.timestamp + gaps[i] % 2 hours);
            uint256 v = amounts[i] % 1.2 ether + 1;
            if (v <= _available(t)) _drain(t, v, "");
            sent = ATTACKER.balance;
        }
        uint256 elapsed = block.timestamp - start;
        assertLe(sent, 1 ether + elapsed * 1 ether / 1 hours);
    }

    function test_batchItemsShareTheBudget() public {
        TaskSubmission[] memory subs = new TaskSubmission[](2);
        for (uint256 i = 0; i < 2; ++i) {
            Program memory p;
            p.types = new StateUpdateType[](2);
            p.args = new bytes[](2);
            _op(p, StateUpdateType.STORE, abi.encode(TRACKER_SLOT, bytes32(i + 1)));
            _send(p, ATTACKER, 0.6 ether);
            bytes memory updates = _encode(p);
            subs[i] = TaskSubmission(
                t.getMessageHash(i, FN, updates),
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
        vm.expectRevert(_exceeded(1, 0.6 ether, 0.4 ether));
        t.verifyAndUpdateBatch(subs);
    }

    function test_zeroValueOpsSpendNothing() public {
        Program memory p = _tracked(t, 2);
        _send(p, ATTACKER, 0);
        _op(p, StateUpdateType.CREATE, abi.encode(uint256(0), hex"00"));
        _settle(t, p, "");
        assertEq(_available(t), 1 ether);
    }

    // ---------------------------------------------------------------- protection

    /// The budget is in the SDK's protected namespace: a program can't refill it with a STORE.
    function test_signedProgramCannotRefillTheBudget() public {
        _drain(t, 1 ether, "");
        bytes32 slot = bytes32(uint256(SDK_STORAGE) + 2);
        bytes32 full = vm.load(address(t), slot);
        assertEq(uint96(uint256(full)), 1 ether, "the limit is the low 96 bits of the budget slot");

        Program memory p = _tracked(t, 2);
        // Set `available` (bits 96..191) back to the limit, then spend it.
        _op(p, StateUpdateType.STORE, abi.encode(slot, full | bytes32(uint256(1 ether) << 96)));
        _send(p, ATTACKER, 1 ether);
        _settle(t, p, abi.encodeWithSelector(StorageGuard.ProtectedSlotWrite.selector, 1, slot));
    }

    /// `OutgoingRateLimit` reads and writes the bucket as one packed word; pin its layout.
    function test_bucketPackingMatchesTheStruct() public {
        t.setLimit(0xAAAA, 0xBBBB);
        vm.warp(block.timestamp + 7);
        _drain(t, 0x11, "");
        uint256 word = uint256(vm.load(address(t), bytes32(uint256(SDK_STORAGE) + 2)));
        assertEq(uint96(word), 0xAAAA, "limit");
        assertEq(uint96(word >> 96), 0xAAAA - 0x11, "available");
        assertEq(uint32(word >> 192), 0xBBBB, "period");
        assertEq(word >> 224, block.timestamp, "updated");
    }

    function test_unsetBudgetSendsNothing() public {
        UnsetRateLimitTreasury u = new UnsetRateLimitTreasury(address(registry));
        vm.deal(address(u), 1 ether);
        vm.warp(block.timestamp + 365 days);
        _drain(u, 1, _exceeded(1, 1, 0));
    }

    function test_zeroLimitSendsNothing() public {
        t.setLimit(0, 1 hours);
        vm.warp(block.timestamp + 1 days);
        _drain(t, 1, _exceeded(1, 1, 0));
    }

    function test_resettingTheLimitRefills() public {
        _drain(t, 1 ether, "");
        vm.expectEmit(address(t));
        emit OutgoingRateLimit.OutgoingRateLimitSet(2 ether, 1 days);
        t.setLimit(2 ether, 1 days);
        (uint256 available, uint256 limit, uint256 period) = t.gasKillerOutgoingAllowance();
        assertEq(available, 2 ether);
        assertEq(limit, 2 ether);
        assertEq(period, 1 days);
    }

    function test_invalidLimitsRevert() public {
        vm.expectRevert(OutgoingRateLimit.InvalidOutgoingRateLimit.selector);
        t.setLimit(1 ether, 0);
        vm.expectRevert(OutgoingRateLimit.InvalidOutgoingRateLimit.selector);
        t.setLimit(uint256(type(uint96).max) + 1, 1 hours);
        vm.expectRevert(OutgoingRateLimit.InvalidOutgoingRateLimit.selector);
        t.setLimit(1 ether, uint256(type(uint32).max) + 1);
    }

    // ---------------------------------------------------------------- composition

    function test_composesWithTheConsumersOwnPolicy() public {
        RateLimitedPolicedTreasury c = new RateLimitedPolicedTreasury(address(registry), token, PAYEE);
        vm.deal(address(c), 10 ether);

        Program memory p = _tracked(c, 1);
        _send(p, ATTACKER, 1);
        _settle(c, p, abi.encodeWithSelector(PolicedTreasury.DisallowedCall.selector, 1));

        _drain2(c, PAYEE, 0.7 ether, "");
        _drain2(c, PAYEE, 0.7 ether, _exceeded(1, 0.7 ether, 0.3 ether));
        assertEq(PAYEE.balance, 0.7 ether);
    }

    function test_nestedDropInSpendsOnFlatSettlementToo() public {
        NestedRateLimitedTreasury n = new NestedRateLimitedTreasury(address(registry));
        vm.deal(address(n), 10 ether);
        _drain(n, 0.75 ether, "");
        _drain(n, 0.5 ether, _exceeded(1, 0.5 ether, 0.25 ether));
        (uint256 available,,) = n.gasKillerOutgoingAllowance();
        assertEq(available, 0.25 ether);
    }

    function _drain2(GasKillerSDK target, address to, uint256 value, bytes memory revertData) internal {
        Program memory p = _tracked(target, 1);
        _send(p, to, value);
        _settle(target, p, revertData);
    }
}
