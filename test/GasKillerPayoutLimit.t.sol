// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {GasKillerOutgoingRateLimit} from "../src/extensions/GasKillerOutgoingRateLimit.sol";
import {GasKillerTokenRateLimit} from "../src/extensions/GasKillerTokenRateLimit.sol";
import {OutgoingRateLimit} from "../src/libraries/OutgoingRateLimit.sol";
import {TokenRateLimit} from "../src/libraries/TokenRateLimit.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {AcceptingRegistry} from "./GasKillerSDKProtectedStorage.t.sol";
import {MintableToken} from "./GasKillerSDKCallPolicy.t.sol";

/// An ETH vault whose user balances live in a mapping, which protected storage can't cover. At
/// most 1 ether an hour may leave, through signed programs and `withdraw` together.
contract EthVault is GasKillerOutgoingRateLimit {
    mapping(address => uint256) public balances; // slot 0

    constructor(address registry) GasKillerOutgoingRateLimit(1 ether, 1 hours) {
        _setSchnorrRegistry(registry);
    }

    receive() external payable {}

    function withdraw(uint256 amount) external limitsOutflow {
        balances[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send");
    }

    /// The same payout without the modifier: what an unlimited payout path looks like.
    function withdrawUnlimited(uint256 amount) external {
        balances[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send");
    }

    /// Takes a deposit and pays out in one call: only the net outflow counts.
    function swapOut(uint256 amount) external payable limitsOutflow {
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "send");
    }
}

/// A token vault: at most 100 tokens an hour may leave, ETH unlimited.
contract TokenVault is GasKillerTokenRateLimit {
    mapping(address => uint256) public balances; // slot 0
    IERC20 public immutable token;

    constructor(address registry, IERC20 token_) GasKillerTokenRateLimit(type(uint96).max, 1 hours) {
        _setSchnorrRegistry(registry);
        token = token_;
        _setTokenRateLimit(address(token_), 100, 1 hours);
    }

    function withdraw(uint256 amount) external limitsOutflow {
        balances[msg.sender] -= amount;
        require(token.transfer(msg.sender, amount), "transfer");
    }
}

/// @notice `limitsOutflow`: a malicious quorum that credits itself a balance with a `STORE` can
///         only withdraw it as fast as the budget allows, when the payout function is limited.
contract GasKillerPayoutLimitTest is Test {
    bytes32 constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    address constant ATTACKER = address(0xBAD);
    address constant USER = address(0xA11CE);
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

    /// Settles a program that copies the counter, optionally credits `who` with `amount` in the
    /// vault's `balances` mapping (slot 0), and optionally sends `sendValue` wei to `ATTACKER`.
    function _settle(GasKillerSDK vault, address who, uint256 amount, uint256 sendValue, bytes memory revertData)
        internal
    {
        uint256 n = 1 + (who != address(0) ? 1 : 0) + (sendValue != 0 ? 1 : 0);
        StateUpdateType[] memory types = new StateUpdateType[](n);
        bytes[] memory args = new bytes[](n);
        uint256 ti = vault.stateTransitionCount();
        args[0] = abi.encode(TRACKER_SLOT, bytes32(ti + 1));
        uint256 i = 1;
        if (who != address(0)) {
            args[i++] = abi.encode(keccak256(abi.encode(who, uint256(0))), bytes32(amount));
        }
        if (sendValue != 0) {
            types[i] = StateUpdateType.CALL;
            args[i++] = abi.encode(ATTACKER, sendValue, "");
        }
        bytes memory updates = abi.encode(types, args);
        bytes32 h = vault.getMessageHash(ti, FN, updates);
        if (revertData.length != 0) vm.expectRevert(revertData);
        vault.verifyAndUpdate(h, uint32(block.number - 1), updates, ti, FN, 1, address(1), new address[](0));
    }

    function _ethExceeded(uint256 value, uint256 available) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(OutgoingRateLimit.NativeOutflowRateLimitExceeded.selector, value, available);
    }

    function _ethVault() internal returns (EthVault v) {
        v = new EthVault(address(registry));
        vm.deal(address(v), 50 ether);
    }

    // ---------------------------------------------------------------- the gap

    /// Without the modifier, a quorum that credits itself a balance drains it all at once:
    /// the rate limit only sees what program ops send.
    function test_withoutTheModifierACreditedBalanceDrainsEverything() public {
        EthVault v = _ethVault();
        _settle(v, ATTACKER, 50 ether, 0, "");
        vm.prank(ATTACKER);
        v.withdrawUnlimited(50 ether);
        assertEq(ATTACKER.balance, 50 ether);
    }

    // ---------------------------------------------------------------- ETH

    function test_limitedWithdrawOfACreditedBalanceIsCapped() public {
        EthVault v = _ethVault();
        _settle(v, ATTACKER, 50 ether, 0, "");

        vm.prank(ATTACKER);
        vm.expectRevert(_ethExceeded(50 ether, 1 ether));
        v.withdraw(50 ether);

        vm.prank(ATTACKER);
        v.withdraw(1 ether);
        assertEq(ATTACKER.balance, 1 ether);

        vm.prank(ATTACKER);
        vm.expectRevert(_ethExceeded(1, 0));
        v.withdraw(1);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(ATTACKER);
        v.withdraw(1 ether);
        assertEq(ATTACKER.balance, 2 ether);
    }

    /// Signed programs and the contract's own payouts spend one budget.
    function test_programsAndPayoutsShareTheBudget() public {
        EthVault v = _ethVault();
        _settle(v, USER, 1 ether, 0.6 ether, "");
        assertEq(ATTACKER.balance, 0.6 ether);

        vm.prank(USER);
        vm.expectRevert(_ethExceeded(0.5 ether, 0.4 ether));
        v.withdraw(0.5 ether);

        vm.prank(USER);
        v.withdraw(0.4 ether);
        (uint256 available,,) = v.gasKillerOutgoingAllowance();
        assertEq(available, 0);
    }

    /// `msg.value` doesn't count as the vault's own ETH, and what the call brought in offsets what
    /// it sent out.
    function test_onlyNetOutflowIsCharged() public {
        EthVault v = _ethVault();
        vm.deal(USER, 5 ether);
        vm.prank(USER);
        v.swapOut{value: 5 ether}(5.5 ether);
        (uint256 available,,) = v.gasKillerOutgoingAllowance();
        assertEq(available, 0.5 ether, "5.5 out, 5 in: 0.5 charged");
    }

    // ---------------------------------------------------------------- tokens

    function test_limitedTokenWithdrawOfACreditedBalanceIsCapped() public {
        TokenVault v = new TokenVault(address(registry), IERC20(address(token)));
        token.mint(address(v), 10_000);
        _settle(v, ATTACKER, 10_000, 0, "");

        vm.prank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(TokenRateLimit.TokenRateLimitExceeded.selector, address(token), 10_000, 100)
        );
        v.withdraw(10_000);

        vm.prank(ATTACKER);
        v.withdraw(100);
        assertEq(token.balanceOf(ATTACKER), 100);
        (uint256 available,,) = v.gasKillerTokenAllowance(address(token));
        assertEq(available, 0);
    }
}
