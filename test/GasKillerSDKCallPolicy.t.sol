// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {TaskSubmission} from "../src/interface/IGasKillerSDKBatch.sol";
import {StateChangeHandlerLib, StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {AcceptingRegistry} from "./GasKillerSDKProtectedStorage.t.sol";

contract MintableToken is ERC20 {
    constructor() ERC20("Token", "TKN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// A consumer holding ETH and tokens, with a function only it may call: the shape of
/// `try this.foo()` helpers and of self-governed setters.
contract Treasury is GasKillerSDK {
    address public beneficiary; // slot 0

    constructor(address registry) {
        _setSchnorrRegistry(registry);
        _setAvsAddress(address(0xA75));
    }

    receive() external payable {}

    function setBeneficiary(address b) external {
        require(msg.sender == address(this), "only self");
        beneficiary = b;
    }
}

/// The same treasury with a policy: no self-calls, no deployments, tokens and ETH only to its
/// payee, and at most 1 ether out per program.
contract PolicedTreasury is Treasury {
    error SelfCall(uint256 index);
    error NoDeployments(uint256 index);
    error DisallowedCall(uint256 index);

    IERC20 public immutable token;
    address public immutable payee;

    constructor(address registry, IERC20 token_, address payee_) Treasury(registry) {
        token = token_;
        payee = payee_;
    }

    function _authorizeCall(
        bytes4,
        uint256 index,
        StateUpdateType kind,
        address target,
        uint256 value,
        bytes memory data
    ) internal virtual override {
        if (kind == StateUpdateType.CREATE || kind == StateUpdateType.CREATE2) {
            revert NoDeployments(index);
        }
        if (target == address(this)) revert SelfCall(index);
        if (value != 0 && target != payee) revert DisallowedCall(index);
        if (target == address(token)) {
            if (data.length != 0x44 || bytes4(data) != IERC20.transfer.selector) revert DisallowedCall(index);
            address to;
            assembly ("memory-safe") {
                to := mload(add(data, 0x24))
            }
            if (to != payee) revert DisallowedCall(index);
        }
    }

    function _maxOutgoingValue(bytes4) internal pure override returns (uint256) {
        return 1 ether;
    }
}

/// The policed treasury, opted out of protected storage: the call policy still applies.
contract UnguardedPolicedTreasury is PolicedTreasury {
    constructor(address registry, IERC20 token_, address payee_) PolicedTreasury(registry, token_, payee_) {}

    function _unsafeDisableStorageGuard() internal pure override returns (bool) {
        return true;
    }
}

/// Only a value cap, which depends on the signed selector.
contract CappedTreasury is Treasury {
    bytes4 public immutable capped;

    constructor(address registry, bytes4 capped_) Treasury(registry) {
        capped = capped_;
    }

    function _maxOutgoingValue(bytes4 targetFunction) internal view override returns (uint256) {
        return targetFunction == capped ? 1 ether : 0;
    }
}

/// Records every op its hook sees.
contract RecordingTreasury is Treasury {
    struct Seen {
        bytes4 targetFunction;
        uint256 index;
        StateUpdateType kind;
        address target;
        uint256 value;
        bytes32 dataHash;
    }

    Seen[] internal _seen;

    constructor(address registry) Treasury(registry) {}

    function seen() external view returns (Seen[] memory) {
        return _seen;
    }

    function _authorizeCall(
        bytes4 targetFunction,
        uint256 index,
        StateUpdateType kind,
        address target,
        uint256 value,
        bytes memory data
    ) internal override {
        _seen.push(Seen(targetFunction, index, kind, target, value, keccak256(data)));
    }
}

/// @notice The call policy (#109): what a quorum-signed program can do through CALL, CREATE,
///         CREATE2 and NESTED with no policy, and what `_authorizeCall` and
///         `_maxOutgoingValue` stop. Nested settlement is covered in `examples/NestedCycle.t.sol`
///         and `examples/NestedDeposit.t.sol`.
contract GasKillerSDKCallPolicyTest is Test {
    bytes32 constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    address constant ATTACKER = address(0xBAD);
    address constant PAYEE = address(0xFEE);
    bytes4 constant FN = bytes4(keccak256("work()"));
    bytes constant INITCODE = hex"00"; // STOP: deploys an empty account

    AcceptingRegistry registry;
    MintableToken token;

    function setUp() public {
        vm.roll(1000);
        registry = new AcceptingRegistry();
        token = new MintableToken();
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
        p.types[0] = StateUpdateType.STORE;
        p.args[0] = abi.encode(TRACKER_SLOT, bytes32(target.stateTransitionCount() + 1));
        p.n = 1;
    }

    function _call(Program memory p, address target, uint256 value, bytes memory data) internal pure {
        p.types[p.n] = StateUpdateType.CALL;
        p.args[p.n++] = abi.encode(target, value, data);
    }

    function _create(Program memory p, uint256 value) internal pure {
        p.types[p.n] = StateUpdateType.CREATE;
        p.args[p.n++] = abi.encode(value, INITCODE);
    }

    function _create2(Program memory p, bytes32 salt, uint256 value) internal pure {
        p.types[p.n] = StateUpdateType.CREATE2;
        p.args[p.n++] = abi.encode(salt, value, INITCODE);
    }

    function _op(Program memory p, StateUpdateType kind, bytes memory arg) internal pure {
        p.types[p.n] = kind;
        p.args[p.n++] = arg;
    }

    function _encode(Program memory p) internal pure returns (bytes memory) {
        StateUpdateType[] memory t = new StateUpdateType[](p.n);
        bytes[] memory a = new bytes[](p.n);
        for (uint256 i = 0; i < p.n; ++i) {
            (t[i], a[i]) = (p.types[i], p.args[i]);
        }
        return abi.encode(t, a);
    }

    function _settle(GasKillerSDK target, Program memory p) internal {
        _settle(target, p, FN, "");
    }

    function _settle(GasKillerSDK target, Program memory p, bytes memory revertData) internal {
        _settle(target, p, FN, revertData);
    }

    /// @dev Settles `p` for `fn`, expecting `revertData` when it is nonempty.
    function _settle(GasKillerSDK target, Program memory p, bytes4 fn, bytes memory revertData) internal {
        bytes memory updates = _encode(p);
        uint256 ti = target.stateTransitionCount();
        bytes32 h = target.getMessageHash(ti, fn, updates);
        if (revertData.length != 0) vm.expectRevert(revertData);
        target.verifyAndUpdate(h, uint32(block.number - 1), updates, ti, fn, 1, address(1), new address[](0));
    }

    function _funded(Treasury t) internal returns (Treasury) {
        vm.deal(address(t), 10 ether);
        token.mint(address(t), 100);
        return t;
    }

    function _policed() internal returns (PolicedTreasury t) {
        t = new PolicedTreasury(address(registry), token, PAYEE);
        _funded(t);
    }

    function _exceeded(uint256 index, uint256 total, uint256 cap) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(StateChangeHandlerLib.OutgoingValueExceeded.selector, index, total, cap);
    }

    // ---------------------------------------------------------------- without a policy

    /// @notice Pins the default: a consumer that writes no policy runs every probe from #109.
    function test_withoutAPolicyASignedProgramSpendsWithTheConsumersAuthority() public {
        Treasury t = _funded(new Treasury(address(registry)));
        Program memory p = _tracked(t, 5);
        _call(p, address(t), 0, abi.encodeCall(Treasury.setBeneficiary, (ATTACKER)));
        _call(p, address(token), 0, abi.encodeCall(IERC20.transfer, (ATTACKER, 60)));
        _call(p, address(token), 0, abi.encodeCall(IERC20.approve, (ATTACKER, 40)));
        _call(p, ATTACKER, 9 ether, "");
        _create(p, 1 ether);
        _settle(t, p);

        assertEq(t.beneficiary(), ATTACKER, "self-gated function");
        assertEq(token.balanceOf(ATTACKER), 60, "token drain");
        assertEq(token.allowance(address(t), ATTACKER), 40, "approval");
        assertEq(ATTACKER.balance, 9 ether, "ETH sent");
        assertEq(address(t).balance, 0, "the rest left through CREATE");
    }

    // ---------------------------------------------------------------- with a policy

    function test_policyAllowsTheLegitimatePayout() public {
        PolicedTreasury t = _policed();
        Program memory p = _tracked(t, 2);
        _call(p, address(token), 0, abi.encodeCall(IERC20.transfer, (PAYEE, 100)));
        _call(p, PAYEE, 1 ether, "");
        _settle(t, p);
        assertEq(token.balanceOf(PAYEE), 100);
        assertEq(PAYEE.balance, 1 ether);
        assertEq(t.stateTransitionCount(), 1);
    }

    function test_policyRejectsSelfCall() public {
        PolicedTreasury t = _policed();
        Program memory p = _tracked(t, 1);
        _call(p, address(t), 0, abi.encodeCall(Treasury.setBeneficiary, (ATTACKER)));
        _settle(t, p, abi.encodeWithSelector(PolicedTreasury.SelfCall.selector, 1));
        assertEq(t.beneficiary(), address(0));
    }

    function test_policyRejectsTokenTransferToAnyoneElse() public {
        PolicedTreasury t = _policed();
        Program memory p = _tracked(t, 1);
        _call(p, address(token), 0, abi.encodeCall(IERC20.transfer, (ATTACKER, 100)));
        _settle(t, p, abi.encodeWithSelector(PolicedTreasury.DisallowedCall.selector, 1));
        assertEq(token.balanceOf(address(t)), 100);
    }

    function test_policyRejectsApproval() public {
        PolicedTreasury t = _policed();
        Program memory p = _tracked(t, 1);
        _call(p, address(token), 0, abi.encodeCall(IERC20.approve, (PAYEE, 100)));
        _settle(t, p, abi.encodeWithSelector(PolicedTreasury.DisallowedCall.selector, 1));
    }

    function test_policyRejectsEthToAnyoneElse() public {
        PolicedTreasury t = _policed();
        Program memory p = _tracked(t, 1);
        _call(p, ATTACKER, 1, "");
        _settle(t, p, abi.encodeWithSelector(PolicedTreasury.DisallowedCall.selector, 1));
    }

    function test_policyRejectsDeployments() public {
        PolicedTreasury t = _policed();
        Program memory p = _tracked(t, 1);
        _create(p, 0);
        _settle(t, p, abi.encodeWithSelector(PolicedTreasury.NoDeployments.selector, 1));

        p = _tracked(t, 1);
        _create2(p, bytes32(uint256(1)), 0);
        _settle(t, p, abi.encodeWithSelector(PolicedTreasury.NoDeployments.selector, 1));
    }

    /// The policy runs before the op: a rejected program's earlier ops roll back with it.
    function test_rejectedOpRevertsTheWholeTransition() public {
        PolicedTreasury t = _policed();
        Program memory p = _tracked(t, 2);
        _call(p, address(token), 0, abi.encodeCall(IERC20.transfer, (PAYEE, 100)));
        _call(p, address(token), 0, abi.encodeCall(IERC20.approve, (ATTACKER, 1)));
        _settle(t, p, abi.encodeWithSelector(PolicedTreasury.DisallowedCall.selector, 2));
        assertEq(token.balanceOf(PAYEE), 0);
        assertEq(t.stateTransitionCount(), 0);
    }

    function test_policyStillAppliesWhenStorageGuardIsOff() public {
        UnguardedPolicedTreasury t = new UnguardedPolicedTreasury(address(registry), token, PAYEE);
        _funded(t);
        Program memory p = _tracked(t, 1);
        _call(p, address(token), 0, abi.encodeCall(IERC20.transfer, (ATTACKER, 100)));
        _settle(t, p, abi.encodeWithSelector(PolicedTreasury.DisallowedCall.selector, 1));
    }

    // ---------------------------------------------------------------- value cap

    function test_capCountsEveryValueOpInTheProgram() public {
        CappedTreasury t = new CappedTreasury(address(registry), FN);
        _funded(t);
        Program memory p = _tracked(t, 3);
        _call(p, ATTACKER, 0.6 ether, "");
        _call(p, address(token), 0, abi.encodeCall(IERC20.transfer, (ATTACKER, 1)));
        _create(p, 0.5 ether);
        _settle(t, p, _exceeded(3, 1.1 ether, 1 ether));
        assertEq(ATTACKER.balance, 0);
    }

    function test_capIncludesCreate2() public {
        CappedTreasury t = new CappedTreasury(address(registry), FN);
        _funded(t);
        Program memory p = _tracked(t, 2);
        _create(p, 0.5 ether);
        _create2(p, bytes32(uint256(7)), 0.5 ether + 1);
        _settle(t, p, _exceeded(2, 1 ether + 1, 1 ether));
    }

    function test_programExactlyAtTheCapSettles() public {
        CappedTreasury t = new CappedTreasury(address(registry), FN);
        _funded(t);
        Program memory p = _tracked(t, 3);
        _call(p, ATTACKER, 0.6 ether, "");
        _create(p, 0);
        _create2(p, bytes32(uint256(7)), 0.4 ether);
        _settle(t, p);
        assertEq(ATTACKER.balance, 0.6 ether);
        assertEq(address(t).balance, 9 ether);
    }

    function test_capDependsOnTheSignedSelector() public {
        CappedTreasury t = new CappedTreasury(address(registry), FN);
        _funded(t);
        Program memory p = _tracked(t, 2);
        _call(p, ATTACKER, 0, ""); // zero value doesn't count against a zero cap
        _call(p, ATTACKER, 1, "");
        _settle(t, p, bytes4(0x12345678), _exceeded(2, 1, 0));

        p = _tracked(t, 1);
        _call(p, ATTACKER, 1, "");
        _settle(t, p, FN, "");
        assertEq(ATTACKER.balance, 1);
    }

    /// Each transition of a batch starts from zero: two items each at the cap settle together.
    function test_batchCapsEachTransitionOnItsOwn() public {
        CappedTreasury t = new CappedTreasury(address(registry), FN);
        _funded(t);
        TaskSubmission[] memory subs = new TaskSubmission[](2);
        for (uint256 i = 0; i < 2; ++i) {
            Program memory p;
            p.types = new StateUpdateType[](2);
            p.args = new bytes[](2);
            _op(p, StateUpdateType.STORE, abi.encode(TRACKER_SLOT, bytes32(i + 1)));
            _call(p, ATTACKER, 1 ether, "");
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
        t.verifyAndUpdateBatch(subs);
        assertEq(ATTACKER.balance, 2 ether);
        assertEq(t.stateTransitionCount(), 2);
    }

    // ---------------------------------------------------------------- what the hook sees

    function test_hookSeesEveryOpThatRunsCodeOrMovesValue() public {
        RecordingTreasury t = new RecordingTreasury(address(registry));
        _funded(t);
        bytes memory transfer = abi.encodeCall(IERC20.transfer, (PAYEE, 5));
        Program memory p = _tracked(t, 5);
        _call(p, address(token), 0, transfer);
        _op(p, StateUpdateType.LOG0, abi.encode(bytes("hi")));
        _create(p, 2);
        _op(p, StateUpdateType.STORE, abi.encode(bytes32(uint256(9)), bytes32(uint256(1))));
        _create2(p, bytes32(uint256(3)), 4);
        _settle(t, p);

        RecordingTreasury.Seen[] memory s = t.seen();
        assertEq(s.length, 3, "STORE and LOG ops don't reach the hook");
        _assertSeen(s[0], 1, StateUpdateType.CALL, address(token), 0, keccak256(transfer));
        _assertSeen(s[1], 3, StateUpdateType.CREATE, address(0), 2, keccak256(INITCODE));
        _assertSeen(s[2], 5, StateUpdateType.CREATE2, address(0), 4, keccak256(INITCODE));
    }

    function _assertSeen(
        RecordingTreasury.Seen memory s,
        uint256 index,
        StateUpdateType kind,
        address target,
        uint256 value,
        bytes32 dataHash
    ) internal pure {
        assertEq(s.targetFunction, FN, "targetFunction");
        assertEq(s.index, index, "index");
        assertEq(uint8(s.kind), uint8(kind), "kind");
        assertEq(s.target, target, "target");
        assertEq(s.value, value, "value");
        assertEq(s.dataHash, dataHash, "data");
    }
}
