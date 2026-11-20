// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {GasKillerCallAllowList} from "../src/extensions/GasKillerCallAllowList.sol";
import {GasKillerTokenRateLimit} from "../src/extensions/GasKillerTokenRateLimit.sol";
import {CallAllowList} from "../src/libraries/CallAllowList.sol";
import {TokenRateLimit} from "../src/libraries/TokenRateLimit.sol";
import {IGasKillerNested} from "../src/interface/IGasKillerNested.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {AcceptingRegistry} from "./GasKillerSDKProtectedStorage.t.sol";
import {MintableToken} from "./GasKillerSDKCallPolicy.t.sol";

/// May `transfer` its token and send plain ETH to its payee, call `ping` on itself, and nothing
/// else. Deployments are allowed only if set at construction.
contract ListedTreasury is GasKillerCallAllowList {
    IERC20 public immutable token;
    address public immutable payee;
    bool public immutable deployments;
    uint256 public pings;

    constructor(address registry, IERC20 token_, address payee_, bool deployments_) {
        _setSchnorrRegistry(registry);
        token = token_;
        payee = payee_;
        deployments = deployments_;
    }

    receive() external payable {}

    function ping() external {
        ++pings;
    }

    function _isAllowedCall(address target, bytes4 selector) internal view override returns (bool) {
        return (target == address(token) && selector == IERC20.transfer.selector)
            || (target == payee && selector == bytes4(0));
    }

    function _allowDeployments() internal view override returns (bool) {
        return deployments;
    }

    function _allowSelfCall(bytes4 selector) internal pure override returns (bool) {
        return selector == this.ping.selector;
    }
}

/// A `ListedTreasury` that also caps each op's value at 1 ether, through the policy hook.
contract CappedListedTreasury is ListedTreasury {
    constructor(address registry, IERC20 token_, address payee_) ListedTreasury(registry, token_, payee_, false) {}

    function _authorizeAllowedCall(uint256, StateUpdateType, address, uint256 value, bytes memory)
        internal
        pure
        override
    {
        require(value <= 1 ether, "cap");
    }
}

/// The allow-list together with the token rate limit: 100 tokens an hour. The rate-limit hooks
/// are final, so the list is checked from `_authorizeLimitedCall` rather than inherited.
contract ListedLimitedTreasury is GasKillerTokenRateLimit {
    IERC20 public immutable token;

    constructor(address registry, IERC20 token_) GasKillerTokenRateLimit(type(uint96).max, 1 hours) {
        _setSchnorrRegistry(registry);
        token = token_;
        _setTokenRateLimit(address(token_), 100, 1 hours);
    }

    function _isAllowedCall(address target, bytes4 selector) internal view returns (bool) {
        return target == address(token) && selector == IERC20.transfer.selector;
    }

    function _authorizeLimitedCall(uint256 index, StateUpdateType kind, address target, uint256, bytes memory data)
        internal
        view
        override
    {
        CallAllowList.check(index, kind, target, data, _isAllowedCall, CallAllowList.noDeployments);
    }
}

/// Runs `CallAllowList.check` directly, for the op kinds a flat settlement can't reach.
contract AllowListHarness {
    address public immutable listed;

    constructor(address listed_) {
        listed = listed_;
    }

    function check(StateUpdateType kind, address target, bytes memory data) external view {
        CallAllowList.check(0, kind, target, data, _isAllowed, CallAllowList.noDeployments);
    }

    function _isAllowed(address target, bytes4 selector) private view returns (bool) {
        return target == listed && selector == IGasKillerNested.applyNested.selector;
    }
}

/// @notice `GasKillerCallAllowList`: default-deny `(target, selector)` pairs for signed programs.
contract GasKillerCallAllowListTest is Test {
    bytes32 constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    address constant ATTACKER = address(0xBAD);
    address constant PAYEE = address(0xFEE);
    bytes4 constant FN = bytes4(keccak256("work()"));

    AcceptingRegistry registry;
    MintableToken token;

    function setUp() public {
        vm.roll(1000);
        vm.warp(1_700_000_000);
        registry = new AcceptingRegistry();
        token = new MintableToken();
    }

    // ---------------------------------------------------------------- helpers

    /// Settles the counter copy plus one op.
    function _settle(GasKillerSDK target, StateUpdateType kind, bytes memory arg, bytes memory revertData) internal {
        StateUpdateType[] memory types = new StateUpdateType[](2);
        bytes[] memory args = new bytes[](2);
        uint256 ti = target.stateTransitionCount();
        args[0] = abi.encode(TRACKER_SLOT, bytes32(ti + 1));
        (types[1], args[1]) = (kind, arg);
        bytes memory updates = abi.encode(types, args);
        bytes32 h = target.getMessageHash(ti, FN, updates);
        if (revertData.length != 0) vm.expectRevert(revertData);
        target.verifyAndUpdate(h, uint32(block.number - 1), updates, ti, FN, 1, address(1), new address[](0));
    }

    function _call(GasKillerSDK target, address to, uint256 value, bytes memory data, bytes memory revertData)
        internal
    {
        _settle(target, StateUpdateType.CALL, abi.encode(to, value, data), revertData);
    }

    function _notAllowed(address target, bytes4 selector) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CallAllowList.CallNotAllowed.selector, 1, target, selector);
    }

    function _treasury(bool deployments) internal returns (ListedTreasury t) {
        t = new ListedTreasury(address(registry), IERC20(address(token)), PAYEE, deployments);
        vm.deal(address(t), 10 ether);
        token.mint(address(t), 1000);
    }

    // ---------------------------------------------------------------- CALL

    /// `_authorizeAllowedCall` adds policy on top of the list, which still applies first.
    function test_policyHookRunsAfterTheList() public {
        CappedListedTreasury t = new CappedListedTreasury(address(registry), IERC20(address(token)), PAYEE);
        vm.deal(address(t), 10 ether);
        _call(t, PAYEE, 1 ether, "", "");
        assertEq(PAYEE.balance, 1 ether);
        _call(t, PAYEE, 2 ether, "", bytes("cap"));
        _call(t, ATTACKER, 2 ether, "", _notAllowed(ATTACKER, bytes4(0)));
    }

    function test_listedCallSettles() public {
        ListedTreasury t = _treasury(false);
        _call(t, address(token), 0, abi.encodeCall(IERC20.transfer, (PAYEE, 10)), "");
        assertEq(token.balanceOf(PAYEE), 10);
    }

    function test_unlistedSelectorOnAListedTargetIsRejected() public {
        ListedTreasury t = _treasury(false);
        _call(
            t,
            address(token),
            0,
            abi.encodeCall(IERC20.approve, (ATTACKER, 10)),
            _notAllowed(address(token), IERC20.approve.selector)
        );
    }

    function test_unlistedTargetIsRejected() public {
        ListedTreasury t = _treasury(false);
        MintableToken other = new MintableToken();
        _call(
            t,
            address(other),
            0,
            abi.encodeCall(IERC20.transfer, (PAYEE, 10)),
            _notAllowed(address(other), IERC20.transfer.selector)
        );
    }

    /// Selector zero lists plain ETH transfers to a target.
    function test_plainEthOnlyToAListedRecipient() public {
        ListedTreasury t = _treasury(false);
        _call(t, PAYEE, 1 ether, "", "");
        assertEq(PAYEE.balance, 1 ether);

        _call(t, ATTACKER, 1 ether, "", _notAllowed(ATTACKER, bytes4(0)));
        _call(t, PAYEE, 0, hex"12345678", _notAllowed(PAYEE, bytes4(0x12345678)));
    }

    /// Calldata that would land in a fallback isn't the plain-ETH case, even for a listed target.
    function test_malformedCalldataIsRejected() public {
        ListedTreasury t = _treasury(false);
        _call(t, PAYEE, 0, hex"aabbcc", _notAllowed(PAYEE, bytes4(0xaabbcc00)));
        _call(t, PAYEE, 0, abi.encodePacked(bytes4(0), uint256(1)), _notAllowed(PAYEE, bytes4(0)));
    }

    /// Self-calls are governed by `_allowSelfCall`, not listed again.
    function test_allowedSelfCallNeedsNoListing() public {
        ListedTreasury t = _treasury(false);
        _call(t, address(t), 0, abi.encodeCall(ListedTreasury.ping, ()), "");
        assertEq(t.pings(), 1);
    }

    // ---------------------------------------------------------------- deployments and NESTED

    function test_deploymentsRejectedUnlessAllowed() public {
        bytes memory create = abi.encode(uint256(0), hex"00");
        _settle(
            _treasury(false),
            StateUpdateType.CREATE,
            create,
            abi.encodeWithSelector(CallAllowList.DeploymentNotAllowed.selector, 1)
        );
        _settle(
            _treasury(false),
            StateUpdateType.CREATE2,
            abi.encode(bytes32(0), uint256(0), hex"00"),
            abi.encodeWithSelector(CallAllowList.DeploymentNotAllowed.selector, 1)
        );
        _settle(_treasury(true), StateUpdateType.CREATE, create, "");
    }

    /// A NESTED op is checked as `(callee, applyNested.selector)`.
    function test_nestedOpIsCheckedAsApplyNested() public {
        address callee = address(0xCA11EE);
        AllowListHarness h = new AllowListHarness(callee);
        h.check(StateUpdateType.NESTED, callee, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                CallAllowList.CallNotAllowed.selector, 0, ATTACKER, IGasKillerNested.applyNested.selector
            )
        );
        h.check(StateUpdateType.NESTED, ATTACKER, "");
    }

    // ---------------------------------------------------------------- with the token rate limit

    /// The list decides what may be called; the rate limit decides how much may leave.
    function test_combinesWithTheTokenRateLimit() public {
        ListedLimitedTreasury t = new ListedLimitedTreasury(address(registry), IERC20(address(token)));
        token.mint(address(t), 1000);

        _call(t, address(token), 0, abi.encodeCall(IERC20.transfer, (ATTACKER, 100)), "");
        _call(
            t,
            address(token),
            0,
            abi.encodeCall(IERC20.transfer, (ATTACKER, 1)),
            abi.encodeWithSelector(TokenRateLimit.TokenRateLimitExceeded.selector, address(token), 1, 0)
        );
        _call(
            t,
            address(token),
            0,
            abi.encodeCall(IERC20.approve, (ATTACKER, 1)),
            _notAllowed(address(token), IERC20.approve.selector)
        );
        assertEq(token.balanceOf(ATTACKER), 100);
    }

    /// A `NESTED` op to the contract itself opens its own frame, whose ops are checked one by one;
    /// it isn't listed.
    function test_selfNestedIsNotListed() public {
        AllowListHarness h = new AllowListHarness(address(0xCAFE));
        h.check(StateUpdateType.NESTED, address(h), "");
        vm.expectRevert(
            abi.encodeWithSelector(
                CallAllowList.CallNotAllowed.selector, 0, address(0xBEEF), IGasKillerNested.applyNested.selector
            )
        );
        h.check(StateUpdateType.NESTED, address(0xBEEF), "");
    }
}
