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

/// A legacy-style token whose `decreaseAllowance` subtracts unchecked, so it can wrap.
contract WrappingToken is MintableToken {
    function decreaseAllowance(address spender, uint256 subtracted) public override returns (bool) {
        unchecked {
            _approve(msg.sender, spender, allowance(msg.sender, spender) - subtracted);
        }
        return true;
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

    /// `mint` grants no allowance, so it is safe to allow; the inflow tests use it.
    function _allowTokenCall(address, bytes4 selector, bytes memory) internal pure override returns (bool) {
        return selector == MintableToken.mint.selector;
    }
}

/// A consumer policy that allows everything and calls no `super`: the limits still apply,
/// because the drop-in runs them outside the overridable hook.
contract PermissiveTokenVault is GasKillerTokenRateLimit {
    uint256 public seen;

    constructor(address registry, address token) GasKillerTokenRateLimit(type(uint96).max, 1) {
        _setSchnorrRegistry(registry);
        _setTokenRateLimit(token, 100, 1 hours);
    }

    function _authorizeLimitedCall(uint256, StateUpdateType, address, uint256, bytes memory) internal override {
        ++seen;
    }

    function _afterLimitedProgram() internal override {}
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

    /// The outer program sends 50; the inner one pulls 50 in from `user` as a deposit.
    function nestedDeposit(IERC20 token, address user, address to) external {
        TokenRateLimit.begin();
        TokenRateLimit.beforeOp(_tokenLimits(), StateUpdateType.CALL, address(0), "");
        token.transfer(to, 50);
        TokenRateLimit.begin();
        bytes memory pull = abi.encodeCall(IERC20.transferFrom, (user, address(this), 50));
        require(!TokenRateLimit.beforeOp(_tokenLimits(), StateUpdateType.CALL, address(token), pull));
        token.transferFrom(user, address(this), 50);
        TokenRateLimit.endProgram(_tokenLimits()); // the inner program: nothing
        TokenRateLimit.endProgram(_tokenLimits()); // the outer one: 50, not offset
    }

    /// A limit changed while a program is running, as a callback would.
    function setMidProgram(address token) external {
        TokenRateLimit.begin();
        TokenRateLimit.set(_tokenLimits(), token, 50, 1 hours);
    }

    function clearMidProgram(address token) external {
        TokenRateLimit.begin();
        TokenRateLimit.clear(_tokenLimits(), token);
    }

    function available(address token) external view returns (uint256 a) {
        (a,,) = TokenRateLimit.allowance(_tokenLimits(), token);
    }

    /// Wired without `begin`.
    function beforeOpWithoutBegin() external {
        TokenRateLimit.beforeOp(_tokenLimits(), StateUpdateType.CALL, address(0), "");
    }

    function endProgramWithoutBegin() external {
        TokenRateLimit.endProgram(_tokenLimits());
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

    /// Approving the same spender again doesn't charge the allowance left standing twice: 40
    /// pulled plus 40 standing is 80, not 40 + 40 + 40.
    function test_reapprovingASpenderIsChargedOnce() public {
        Program memory p = _tracked(3);
        _call(p, address(token), abi.encodeCall(IERC20.approve, (address(puller), 40)));
        _call(p, address(puller), abi.encodeCall(Puller.pull, (token, address(v), ATTACKER, 40)));
        _call(p, address(token), abi.encodeCall(IERC20.approve, (address(puller), 40)));
        _settle(p, "");
        assertEq(_available(), 20);
    }

    /// Approving twice, then pulling the allowance: only the pull is charged.
    function test_reapprovalThenPullIsChargedOnce() public {
        Program memory p = _tracked(3);
        _call(p, address(token), abi.encodeCall(IERC20.approve, (address(puller), 40)));
        _call(p, address(token), abi.encodeCall(IERC20.approve, (address(puller), 40)));
        _call(p, address(puller), abi.encodeCall(Puller.pull, (token, address(v), ATTACKER, 40)));
        _settle(p, "");
        assertEq(_available(), 60);
    }

    /// A no-op approval first can't lower the charge: the allowance the spender had before the
    /// program, once pulled, isn't still standing, so restoring it is charged.
    function test_extraApprovalCannotLowerTheCharge() public {
        v.approveNatively(token, address(puller), 40);
        Program memory p = _tracked(3);
        _call(p, address(token), abi.encodeCall(IERC20.approve, (address(puller), 40)));
        _call(p, address(puller), abi.encodeCall(Puller.pull, (token, address(v), ATTACKER, 40)));
        _call(p, address(token), abi.encodeCall(IERC20.approve, (address(puller), 40)));
        _settle(p, "");
        assertEq(_available(), 20, "40 pulled plus 40 restored, as without the first approval");
    }

    /// As `OutgoingRateLimit`: frequent small charges don't stop the budget refilling.
    function test_frequentChargesStillRefill() public {
        v.clearTokenLimit(address(token)); // re-added, so it starts full at the new limit
        v.setTokenLimit(address(token), 1000, 1 days);
        for (uint256 i = 0; i < 300; ++i) {
            vm.warp(block.timestamp + 60);
            _send(1, "");
        }
        assertGe(_available(), 1000 - 300 + 208 - 4);
        assertLe(_available(), 1000 - 300 + 208);
    }

    /// Any other function on a listed token could grant an allowance the limit can't see, so it
    /// is rejected: here the older OpenZeppelin `increaseApproval` and ERC-777 `authorizeOperator`.
    function test_unrecognizedTokenCallIsRejected() public {
        bytes4[2] memory selectors =
            [bytes4(keccak256("increaseApproval(address,uint256)")), bytes4(keccak256("authorizeOperator(address)"))];
        for (uint256 i = 0; i < 2; ++i) {
            Program memory p = _tracked(1);
            _call(p, address(token), abi.encodeWithSelector(selectors[i], ATTACKER, type(uint256).max));
            _settle(
                p,
                abi.encodeWithSelector(TokenRateLimit.UnrecognizedTokenCall.selector, 1, address(token), selectors[i])
            );
        }
    }

    /// Calldata too short for a selector reaches the token's fallback, so it is rejected too.
    function test_emptyCalldataToAListedTokenIsRejected() public {
        Program memory p = _tracked(1);
        _call(p, address(token), "");
        _settle(p, abi.encodeWithSelector(TokenRateLimit.UnrecognizedTokenCall.selector, 1, address(token), bytes4(0)));
    }

    /// Unlisted targets aren't restricted: any function may be called on them.
    function test_unrecognizedCallToAnUnlistedTokenIsAllowed() public {
        Program memory p = _tracked(1);
        _call(p, address(other), abi.encodeCall(MintableToken.mint, (ATTACKER, 5)));
        _settle(p, "");
        assertEq(other.balanceOf(ATTACKER), 5);
    }

    /// `decreaseAllowance` is recognized: it only lowers an allowance.
    function test_decreaseAllowanceIsRecognized() public {
        v.approveNatively(token, ATTACKER, 30);
        Program memory p = _tracked(1);
        _call(p, address(token), abi.encodeWithSignature("decreaseAllowance(address,uint256)", ATTACKER, 10));
        _settle(p, "");
        assertEq(token.allowance(address(v), ATTACKER), 20);
        assertEq(_available(), 100, "nothing charged");
    }

    /// A `decreaseAllowance` that raises the allowance is charged like an approval.
    function test_decreaseAllowanceThatRaisesIsCharged() public {
        WrappingToken w = new WrappingToken();
        w.mint(address(v), 1000);
        v.setTokenLimit(address(w), 100, 1 hours);
        Program memory p = _tracked(1);
        _call(p, address(w), abi.encodeWithSignature("decreaseAllowance(address,uint256)", ATTACKER, 1));
        _settle(
            p,
            abi.encodeWithSelector(TokenRateLimit.TokenRateLimitExceeded.selector, address(w), type(uint256).max, 100)
        );
    }

    address constant USER = address(0xA11CE);

    function _approveVault() internal {
        token.mint(USER, 1000);
        vm.prank(USER);
        token.approve(address(v), 1000);
    }

    /// Users who approved the vault can't be drained straight out: a `transferFrom` between two
    /// others is rejected.
    function test_transferFromAUserToAnotherIsRejected() public {
        _approveVault();
        Program memory p = _tracked(1);
        _call(p, address(token), abi.encodeCall(IERC20.transferFrom, (USER, ATTACKER, 1000)));
        _settle(
            p,
            abi.encodeWithSelector(
                TokenRateLimit.UnrecognizedTokenCall.selector, 1, address(token), IERC20.transferFrom.selector
            )
        );
        assertEq(token.balanceOf(USER), 1000);
    }

    /// A deposit, pulling a user's tokens into the vault, settles and is charged nothing.
    function test_depositSettles() public {
        _approveVault();
        Program memory p = _tracked(1);
        _call(p, address(token), abi.encodeCall(IERC20.transferFrom, (USER, address(v), 500)));
        _settle(p, "");
        assertEq(token.balanceOf(address(v)), 1500);
        assertEq(_available(), 100);
    }

    /// Nor through the vault: what a deposit brings in doesn't offset a send.
    function test_depositCannotOffsetASend() public {
        _approveVault();
        Program memory p = _tracked(2);
        _call(p, address(token), abi.encodeCall(IERC20.transferFrom, (USER, address(v), 1000)));
        _transfer(p, token, ATTACKER, 1000);
        _settle(p, _exceeded(1000, 100));
        p = _tracked(2);
        _call(p, address(token), abi.encodeCall(IERC20.transferFrom, (USER, address(v), 1000)));
        _transfer(p, token, ATTACKER, 60);
        _settle(p, "");
        assertEq(_available(), 40);
    }

    /// A `transferFrom` from the vault itself is measured through its balance.
    function test_transferFromTheVaultIsCharged() public {
        v.approveNatively(token, address(v), 1000);
        Program memory p = _tracked(1);
        _call(p, address(token), abi.encodeCall(IERC20.transferFrom, (address(v), ATTACKER, 150)));
        _settle(p, _exceeded(150, 100));
        p = _tracked(1);
        _call(p, address(token), abi.encodeCall(IERC20.transferFrom, (address(v), ATTACKER, 60)));
        _settle(p, "");
        assertEq(_available(), 40);
    }

    /// A consumer's call policy that calls no `super` can't switch the limit off.
    function test_consumerPolicyCannotSkipTheLimit() public {
        PermissiveTokenVault pv = new PermissiveTokenVault(address(registry), address(token));
        token.mint(address(pv), 1000);
        v = TokenVault(address(pv)); // the helpers settle against `v`
        _send(150, _exceeded(150, 100));
        _send(100, "");
        assertEq(pv.seen(), 1, "the consumer's hook still ran");
    }

    /// Updating a listed token's limit keeps what its budget holds, capped at the new limit;
    /// only a newly added token starts full.
    function test_changingATokenLimitKeepsTheBudget() public {
        _send(100, "");
        v.setTokenLimit(address(token), 10, 1 hours);
        assertEq(_available(), 0, "lowering mid-drain hands out nothing");
        _send(1, _exceeded(1, 0));
        v.setTokenLimit(address(token), 1000, 1 hours);
        assertEq(_available(), 0, "raising doesn't refill either");
        vm.warp(block.timestamp + 6 minutes);
        assertEq(_available(), 100, "it refills at the new rate");
        v.setTokenLimit(address(token), 40, 1 hours);
        assertEq(_available(), 40, "capped at a lower limit");
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

    /// A deposit in an inner program doesn't offset a send in the program around it either.
    function test_nestedDepositCannotOffsetAnOuterSend() public {
        NestingHarness h = new NestingHarness(address(token));
        token.mint(address(h), 100);
        token.mint(USER, 50);
        vm.prank(USER);
        token.approve(address(h), 50);
        h.nestedDeposit(token, USER, ATTACKER);
        assertEq(h.available(address(token)), 50);
    }

    /// The list can't change under a running program: a callback could otherwise reorder it
    /// between the snapshots of nested programs, or hand a program a fresh budget.
    function test_limitsCannotChangeMidProgram() public {
        NestingHarness h = new NestingHarness(address(token));
        vm.expectRevert(TokenRateLimit.TokenRateLimitChangedMidProgram.selector);
        h.setMidProgram(address(token));
        vm.expectRevert(TokenRateLimit.TokenRateLimitChangedMidProgram.selector);
        h.clearMidProgram(address(token));
    }

    /// The contract can't list itself: `STORE`s before the snapshot could move its balance.
    function test_contractCannotListItself() public {
        vm.expectRevert(TokenRateLimit.InvalidTokenRateLimit.selector);
        v.setTokenLimit(address(v), 100, 1 hours);
    }

    /// A token with no code would make every program's `balanceOf` read revert.
    function test_tokenWithoutCodeCannotBeListed() public {
        vm.expectRevert(TokenRateLimit.InvalidTokenRateLimit.selector);
        v.setTokenLimit(address(0x1234), 100, 1 hours);
    }

    /// Raising a token's limit doesn't credit the time accrued at the old rate at the new one.
    function test_raisingATokenLimitDoesNotCreditOldTimeAtTheNewRate() public {
        v.setTokenLimit(address(token), 1, 1 days);
        _send(1, "");
        vm.warp(block.timestamp + 23 hours);
        v.setTokenLimit(address(token), 240, 1 days);
        assertEq(_available(), 0);
        vm.warp(block.timestamp + 1 hours);
        assertEq(_available(), 10);
    }

    /// Re-setting a token's limit keeps the refill's carried-over remainder.
    function test_changingATokenLimitKeepsTheRefillRemainder() public {
        v.setTokenLimit(address(token), 10, 1 days);
        _send(10, "");
        vm.warp(block.timestamp + 7776); // 0.09 days: 0.9 tokens
        v.setTokenLimit(address(token), 10, 1 days);
        assertEq(_available(), 0);
        vm.warp(block.timestamp + 7776);
        assertEq(_available(), 1);
    }

    /// Without `begin` there is no program to record into; the library reverts rather than
    /// writing over its depth counter.
    function test_withoutBeginReverts() public {
        NestingHarness h = new NestingHarness(address(token));
        vm.expectRevert(TokenRateLimit.TokenRateLimitNotBegun.selector);
        h.beforeOpWithoutBegin();
        vm.expectRevert(TokenRateLimit.TokenRateLimitNotBegun.selector);
        h.endProgramWithoutBegin();
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
        for (uint256 i = 1; i < 8; ++i) {
            v.setTokenLimit(address(new MintableToken()), 1, 1);
        }
        address ninth = address(new MintableToken());
        vm.expectRevert(TokenRateLimit.TooManyRateLimitedTokens.selector);
        v.setTokenLimit(ninth, 1, 1);
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
