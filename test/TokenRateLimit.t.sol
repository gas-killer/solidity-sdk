// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {GasKillerOutgoingRateLimit} from "../src/extensions/GasKillerOutgoingRateLimit.sol";
import {GasKillerTokenRateLimit, GasKillerNestedTokenRateLimit} from "../src/extensions/GasKillerTokenRateLimit.sol";
import {TaskSubmission} from "../src/interface/IGasKillerSDKBatch.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {StorageGuard} from "../src/libraries/StorageGuard.sol";
import {TokenRateLimit} from "../src/libraries/TokenRateLimit.sol";
import {AcceptingRegistry} from "./GasKillerSDKProtectedStorage.t.sol";
import {MintableToken} from "./GasKillerSDKCallPolicy.t.sol";

/// Moves tokens with an allowance it holds: a router pulling during a signed `CALL`.
contract Puller {
    function pull(IERC20 token, address from, address to, uint256 amount) external {
        token.transferFrom(from, to, amount);
    }
}

/// A vault limiting `token` to 100 per hour, ETH effectively unlimited.
contract TokenVault is GasKillerTokenRateLimit {
    constructor(address registry, address token) GasKillerTokenRateLimit(type(uint96).max, 1) {
        _setSchnorrRegistry(registry);
        _setTokenRateLimit(token, 100, 1 hours);
    }

    /// An approval granted natively, outside any settlement.
    function approveNatively(IERC20 token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }

    function setTokenLimit(address token, uint256 limit, uint256 period) external {
        _setTokenRateLimit(token, limit, period);
    }

    function clearTokenLimit(address token) external {
        _clearTokenRateLimit(token);
    }
}

/// The nested drop-in.
contract NestedTokenVault is GasKillerNestedTokenRateLimit {
    constructor(address registry, address token) GasKillerNestedTokenRateLimit(type(uint96).max, 1) {
        _setSchnorrRegistry(registry);
        _setTokenRateLimit(token, 100, 1 hours);
    }
}

/// Drives the library directly, to check its per-depth bookkeeping for programs that nest.
contract NestingHarness is GasKillerSDK {
    constructor(address token) {
        TokenRateLimit.set(_tokenLimits(), token, 100, 1 hours);
    }

    function nested(IERC20 token, address to) external {
        TokenRateLimit.begin();
        TokenRateLimit.beforeOp(_tokenLimits(), StateUpdateType.CALL, address(0), "");
        token.transfer(to, 10);
        TokenRateLimit.begin();
        TokenRateLimit.beforeOp(_tokenLimits(), StateUpdateType.CALL, address(0), "");
        token.transfer(to, 20);
        TokenRateLimit.endProgram(_tokenLimits()); // the inner program: 20
        TokenRateLimit.endProgram(_tokenLimits()); // the outer one: 10 + 20
    }

    function available(address token) external view returns (uint256 a) {
        (a,,) = TokenRateLimit.allowance(_tokenLimits(), token);
    }
}

/// @notice `TokenRateLimit` through the drop-in: net token outflow and standing allowances per
///         program, charged against a shared per-token budget.
contract TokenRateLimitTest is Test {
    bytes32 constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    bytes32 constant SDK_STORAGE = 0x1d6f9f139320a34a32f3b29eb8638270178e831962a74100c9e8b433f21e1200;
    address constant ATTACKER = address(0xBAD);
    bytes4 constant FN = bytes4(keccak256("work()"));

    AcceptingRegistry registry;
    MintableToken token;
    MintableToken other;
    Puller puller;
    TokenVault v;

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_700_000_000);
        registry = new AcceptingRegistry();
        token = new MintableToken();
        other = new MintableToken();
        puller = new Puller();
        v = new TokenVault(address(registry), address(token));
        token.mint(address(v), 1000);
        other.mint(address(v), 1000);
    }

    // ---------------------------------------------------------------- helpers

    struct Program {
        StateUpdateType[] types;
        bytes[] args;
        uint256 n;
    }

    function _tracked(uint256 capacity) internal view returns (Program memory p) {
        p.types = new StateUpdateType[](capacity + 1);
        p.args = new bytes[](capacity + 1);
        p.args[0] = abi.encode(TRACKER_SLOT, bytes32(v.stateTransitionCount() + 1));
        p.n = 1;
    }

    function _call(Program memory p, address target, bytes memory data) internal pure {
        p.types[p.n] = StateUpdateType.CALL;
        p.args[p.n++] = abi.encode(target, uint256(0), data);
    }

    function _transfer(Program memory p, MintableToken t, address to, uint256 amount) internal pure {
        _call(p, address(t), abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    function _encode(Program memory p) internal pure returns (bytes memory) {
        StateUpdateType[] memory ty = new StateUpdateType[](p.n);
        bytes[] memory a = new bytes[](p.n);
        for (uint256 i = 0; i < p.n; ++i) {
            (ty[i], a[i]) = (p.types[i], p.args[i]);
        }
        return abi.encode(ty, a);
    }

    function _settle(Program memory p, bytes memory revertData) internal {
        bytes memory updates = _encode(p);
        uint256 ti = v.stateTransitionCount();
        bytes32 h = v.getMessageHash(ti, FN, updates);
        if (revertData.length != 0) vm.expectRevert(revertData);
        v.verifyAndUpdate(h, uint32(block.number - 1), updates, ti, FN, 1, address(1), new address[](0));
    }

    function _send(uint256 amount, bytes memory revertData) internal {
        Program memory p = _tracked(1);
        _transfer(p, token, ATTACKER, amount);
        _settle(p, revertData);
    }

    function _exceeded(uint256 amount, uint256 available) internal view returns (bytes memory) {
        return abi.encodeWithSelector(TokenRateLimit.TokenRateLimitExceeded.selector, address(token), amount, available);
    }

    function _available() internal view returns (uint256 a) {
        (a,,) = v.gasKillerTokenAllowance(address(token));
    }

    // ---------------------------------------------------------------- outflow

    function test_transferWithinTheLimitSettles() public {
        _send(60, "");
        assertEq(token.balanceOf(ATTACKER), 60);
        assertEq(_available(), 40);
    }

    /// The charge is the program's total: two transfers under the limit each still add up.
    function test_programTotalIsCharged() public {
        Program memory p = _tracked(2);
        _transfer(p, token, ATTACKER, 60);
        _transfer(p, token, ATTACKER, 60);
        _settle(p, _exceeded(120, 100));
        assertEq(token.balanceOf(ATTACKER), 0);
    }

    function test_budgetIsSharedAcrossTransitions() public {
        _send(60, "");
        _send(60, _exceeded(60, 40));
        _send(40, "");
        assertEq(_available(), 0);
    }

    function test_budgetRefills() public {
        _send(100, "");
        vm.warp(block.timestamp + 30 minutes);
        assertEq(_available(), 50);
        _send(51, _exceeded(51, 50));
        _send(50, "");
    }

    /// Tokens pulled out through an allowance granted before the program are measured too.
    function test_pullThroughAnExistingAllowanceIsCharged() public {
        v.approveNatively(token, address(puller), type(uint256).max);
        Program memory p = _tracked(1);
        _call(p, address(puller), abi.encodeCall(Puller.pull, (token, address(v), ATTACKER, 150)));
        _settle(p, _exceeded(150, 100));
    }

    function test_approvalLeftStandingIsCharged() public {
        Program memory p = _tracked(1);
        _call(p, address(token), abi.encodeCall(IERC20.approve, (ATTACKER, 50)));
        _settle(p, "");
        assertEq(_available(), 50);
    }

    function test_unlimitedApprovalReverts() public {
        Program memory p = _tracked(1);
        _call(p, address(token), abi.encodeCall(IERC20.approve, (ATTACKER, type(uint256).max)));
        _settle(p, _exceeded(type(uint256).max, 100));
    }

    /// Approve a router, which then pulls: charged once, through the balance.
    function test_approvalUsedInTheProgramIsChargedOnce() public {
        Program memory p = _tracked(2);
        _call(p, address(token), abi.encodeCall(IERC20.approve, (address(puller), 80)));
        _call(p, address(puller), abi.encodeCall(Puller.pull, (token, address(v), ATTACKER, 80)));
        _settle(p, "");
        assertEq(_available(), 20);
    }

    function test_approvalWithdrawnInTheProgramIsFree() public {
        Program memory p = _tracked(2);
        _call(p, address(token), abi.encodeCall(IERC20.approve, (ATTACKER, 500)));
        _call(p, address(token), abi.encodeCall(IERC20.approve, (ATTACKER, 0)));
        _settle(p, "");
        assertEq(_available(), 100);
    }

    /// Only the increase over the allowance the spender already had is charged.
    function test_onlyTheAllowanceIncreaseIsCharged() public {
        v.approveNatively(token, ATTACKER, 30);
        Program memory p = _tracked(1);
        _call(p, address(token), abi.encodeCall(IERC20.approve, (ATTACKER, 70)));
        _settle(p, "");
        assertEq(_available(), 60);
    }

    /// The charge is the net outflow: tokens received in the program offset tokens sent.
    function test_inflowOffsetsOutflow() public {
        Program memory p = _tracked(2);
        _transfer(p, token, ATTACKER, 150);
        _call(p, address(token), abi.encodeCall(MintableToken.mint, (address(v), 150)));
        _settle(p, "");
        assertEq(_available(), 100);
    }

    function test_unlistedTokenIsNotLimited() public {
        Program memory p = _tracked(1);
        _transfer(p, other, ATTACKER, 1000);
        _settle(p, "");
        assertEq(other.balanceOf(ATTACKER), 1000);
        (uint256 a, uint256 l, uint256 per) = v.gasKillerTokenAllowance(address(other));
        assertEq(a + l + per, 0);
    }

    /// A program that runs no code can't move tokens, so balances aren't read.
    function test_programWithoutCodeReadsNoBalance() public {
        Program memory p = _tracked(1);
        p.types[1] = StateUpdateType.STORE;
        p.args[p.n++] = abi.encode(bytes32(uint256(7)), bytes32(uint256(1)));
        vm.expectCall(address(token), abi.encodeWithSelector(IERC20.balanceOf.selector), 0);
        _settle(p, "");
    }

    function test_batchItemsShareTheBudget() public {
        TaskSubmission[] memory subs = new TaskSubmission[](2);
        for (uint256 i = 0; i < 2; ++i) {
            Program memory p;
            p.types = new StateUpdateType[](2);
            p.args = new bytes[](2);
            p.args[0] = abi.encode(TRACKER_SLOT, bytes32(i + 1));
            p.n = 1;
            _transfer(p, token, ATTACKER, 60);
            bytes memory updates = _encode(p);
            subs[i] = TaskSubmission(
                v.getMessageHash(i, FN, updates),
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
        vm.expectRevert(_exceeded(60, 40));
        v.verifyAndUpdateBatch(subs);
    }

    /// A program nested in another on the same contract is charged on its own, and again as part
    /// of the program around it.
    function test_nestedProgramsKeepTheirOwnSnapshots() public {
        NestingHarness h = new NestingHarness(address(token));
        token.mint(address(h), 100);
        h.nested(token, ATTACKER);
        assertEq(h.available(address(token)), 100 - 20 - 30);
    }

    function test_nestedDropInChargesToo() public {
        NestedTokenVault n = new NestedTokenVault(address(registry), address(token));
        token.mint(address(n), 1000);
        v = TokenVault(address(n)); // the helpers settle against `v`; the ABI they use is shared
        _send(60, "");
        _send(60, _exceeded(60, 40));
        (uint256 available,,) = n.gasKillerTokenAllowance(address(token));
        assertEq(available, 40);
    }

    // ---------------------------------------------------------------- protection and config

    /// Token budgets are protected storage: a program can't refill one with a STORE.
    function test_signedProgramCannotRefillATokenBudget() public {
        _send(100, "");
        // Slot 3 is `count`; token 0's bucket is slots 4 (token, period, updated) and 5 (limit,
        // available).
        bytes32 slot = bytes32(uint256(SDK_STORAGE) + 5);
        assertEq(uint128(uint256(vm.load(address(v), slot))), 100, "limit in the low 128 bits");
        Program memory p = _tracked(2);
        p.types[1] = StateUpdateType.STORE;
        p.args[p.n++] = abi.encode(slot, bytes32((uint256(100) << 128) | 100));
        _transfer(p, token, ATTACKER, 100);
        _settle(p, abi.encodeWithSelector(StorageGuard.ProtectedSlotWrite.selector, 1, slot));
    }

    function test_clearMovesTheLastEntryDown() public {
        v.setTokenLimit(address(other), 5, 1 hours);
        v.clearTokenLimit(address(token));
        (, uint256 limit,) = v.gasKillerTokenAllowance(address(other));
        assertEq(limit, 5);
        (, limit,) = v.gasKillerTokenAllowance(address(token));
        assertEq(limit, 0);
        _send(1000, "");
    }

    function test_atMostEightTokens() public {
        for (uint160 i = 1; i < 8; ++i) {
            v.setTokenLimit(address(i), 1, 1);
        }
        vm.expectRevert(TokenRateLimit.TooManyRateLimitedTokens.selector);
        v.setTokenLimit(address(9), 1, 1);
        v.setTokenLimit(address(token), 7, 1); // updating an existing entry still works
    }

    function test_invalidLimitsRevert() public {
        vm.expectRevert(TokenRateLimit.InvalidTokenRateLimit.selector);
        v.setTokenLimit(address(0), 1, 1);
        vm.expectRevert(TokenRateLimit.InvalidTokenRateLimit.selector);
        v.setTokenLimit(address(token), 1, 0);
        vm.expectRevert(TokenRateLimit.InvalidTokenRateLimit.selector);
        v.setTokenLimit(address(token), uint256(type(uint128).max) + 1, 1);
    }
}
