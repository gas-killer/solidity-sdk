// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {AcceptAll} from "./SettlementGas.t.sol";
import {GasKillerOutgoingRateLimit} from "../src/extensions/GasKillerOutgoingRateLimit.sol";
import {GasKillerTokenRateLimit} from "../src/extensions/GasKillerTokenRateLimit.sol";
import {GasKillerCallAllowList} from "../src/extensions/GasKillerCallAllowList.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract BenchToken is ERC20 {
    constructor() ERC20("Bench", "B") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// The drop-in with `k` token limits (ETH effectively unlimited).
contract TokenLimitedCaller is GasKillerTokenRateLimit {
    constructor(address registry, address[] memory tokens) GasKillerTokenRateLimit(type(uint96).max, 1) {
        _setSchnorrRegistry(registry);
        for (uint256 i = 0; i < tokens.length; ++i) {
            _setTokenRateLimit(tokens[i], 1e30, 1 hours);
        }
    }
}

/// Accepts any call.
contract Sink {
    fallback() external payable {}
}

/// No policy: the default hook and cap.
contract DefaultCaller is GasKillerSDK {
    constructor(address registry) {
        _setSchnorrRegistry(registry);
    }
}

/// A typical small policy: one denied target, and a value cap.
contract PolicedCaller is DefaultCaller {
    error Denied(uint256 index);

    constructor(address registry) DefaultCaller(registry) {}

    function _authorizeCall(uint256 index, StateUpdateType, address target, uint256, bytes memory)
        internal
        pure
        override
    {
        if (target == address(0xdead)) revert Denied(index);
    }

    function _maxOutgoingValue() internal pure override returns (uint256) {
        return 1 ether;
    }
}

/// Lets a signed program call its own `ping`, through a one-selector allow-list or by allowing
/// every self-call.
contract SelfCaller is DefaultCaller {
    bool public immutable allowAll;
    uint256 public pings;

    constructor(address registry, bool allowAll_) DefaultCaller(registry) {
        allowAll = allowAll_;
    }

    function ping() external {
        ++pings;
    }

    function _allowSelfCall(bytes4 selector) internal view override returns (bool) {
        return allowAll || selector == this.ping.selector;
    }
}

/// Allows plain calls to one sink, as the CALLs in `settleGas` are.
contract ListedCaller is GasKillerCallAllowList {
    address public immutable sink;

    constructor(address registry, address sink_) {
        _setSchnorrRegistry(registry);
        sink = sink_;
    }

    function _isAllowedCall(address target, bytes4 selector) internal view override returns (bool) {
        return target == sink && selector == bytes4(0);
    }
}

/// An ETH vault paying out with and without `limitsOutflow`.
contract BenchVault is GasKillerOutgoingRateLimit {
    constructor(address registry) GasKillerOutgoingRateLimit(type(uint96).max, 1 hours) {
        _setSchnorrRegistry(registry);
    }

    receive() external payable {}

    function pay(address to, uint256 amount) external {
        (bool ok,) = to.call{value: amount}("");
        require(ok);
    }

    function payLimited(address to, uint256 amount) external limitsOutflow {
        (bool ok,) = to.call{value: amount}("");
        require(ok);
    }
}

/// A token vault paying out with and without `limitsOutflow`, listing `k` tokens.
contract BenchTokenVault is GasKillerTokenRateLimit {
    constructor(address registry, address[] memory tokens) GasKillerTokenRateLimit(type(uint96).max, 1 hours) {
        _setSchnorrRegistry(registry);
        for (uint256 i = 0; i < tokens.length; ++i) {
            _setTokenRateLimit(tokens[i], 1e30, 1 hours);
        }
    }

    function pay(IERC20 token, address to, uint256 amount) external {
        require(token.transfer(to, amount));
    }

    function payLimited(IERC20 token, address to, uint256 amount) external limitsOutflow {
        require(token.transfer(to, amount));
    }
}

/// The drop-in rate limit.
contract RateLimitedCaller is GasKillerOutgoingRateLimit {
    constructor(address registry) GasKillerOutgoingRateLimit(1 ether, 1 hours) {
        _setSchnorrRegistry(registry);
    }
}

/// @notice Whole-settlement gas through `verifyAndUpdate` for the counter copy plus m zero-value
///         CALLs to one warm contract, with the default call policy (`_authorizeCall`,
///         `_maxOutgoingValue` and `_allowSelfCall` not overridden) and with the small one above.
///
///         Reference measurements (forge 1.5.1, solc 0.8.33, cancun). "Before" is the same
///         settlement before the call policy (0944508):
///
///           m   | before | default policy  | small policy
///           1   | 33,576 | +446 (+1.3%)    | +488 (+1.5%)
///           8   | 47,166 | +1,738 (+3.7%)  | +2,088 (+4.4%)
///           32  | 94,129 | +6,164 (+6.5%)  | +7,570 (+8.0%)
///
///         About 185 gas per CALL with the default policy (about 43 of it the self-call address
///         check), about 230 with the small one, and about 260 fixed per program (building the
///         policy and reading the cap). A program of STOREs only pays the fixed part and about 3
///         gas per op (`SettlementGas.t.sol`). Against a real CALL, which pays a cold account
///         access (2,600) and the callee's own work, the share is smaller than against this empty,
///         warm callee.
///
///         `test_rateLimit`: the same with 1-wei CALLs, without and with `GasKillerOutgoingRateLimit`
///         (1 ether per hour):
///
///           m   | default | rate limited
///           1   |  40,946 | +678 (+1.7%)
///           8   | 104,296 | +5,340 (+5.1%)
///           32  | 321,861 | +21,324 (+6.6%)
///
///         About 665 gas per op that sends value. The consumer is deployed in the same transaction,
///         so the budget slot is already warm here; a real settlement also pays about 5,000 once,
///         for the first read (2,100, cold) and write (2,900) of the slot.
///
///         `test_tokenLimit`: the counter copy plus m ERC-20 `transfer`s, for a consumer with no
///         limits and for `GasKillerTokenRateLimit` listing k tokens:
///
///           m   | no limits | k = 0            | k = 1            | k = 4
///           1   |  62,091   | +4,407 (+7.1%)   | +10,179 (+16.4%) | +22,102 (+35.6%)
///           8   |  99,612   | +10,475 (+10.5%) | +26,939 (+27.0%) | +62,237 (+62.5%)
///           32  | 229,014   | +31,408 (+13.7%) | +84,530 (+36.9%) | +199,970 (+87.3%)
///
///         Each listed token costs a `balanceOf` read per op that runs code (about 1,200 to 1,500
///         gas), one more at the end and a budget read and write; a program that runs no
///         code reads no balances.
///
///         `test_selfCalls`: the counter copy plus m allowed CALLs to the consumer's own `ping()`,
///         allowing every self-call or a one-selector list:
///
///           m   | allow all | one-selector list
///           1   |  56,889   | +37
///           8   |  78,234   | +296
///           32  | 151,931   | +1,184
///
///         About 37 gas per self-call to compare the selector with a one-entry list, on top of
///         about 90 to reject malformed calldata before the hook is asked.
///
///         `test_allowList`: the zero-value CALLs above, for a consumer with a one-entry
///         `GasKillerCallAllowList`: +476 (m = 1), +3,031 (m = 8), +11,791 (m = 32) over the
///         default policy, about 365 gas per CALL.
///
///         `test_payouts`: one payout through the contract's own function, without and with
///         `limitsOutflow` (budget slot warm): ETH 7,849 +1,018; a token, 26,566 +4,029 with no
///         tokens listed, +9,107 with one, +26,363 with four.
///
///         Run with `FOUNDRY_PROFILE=gas forge test --match-contract CallPolicyGas -vv`.
contract CallPolicyGasTest is Test {
    bytes32 constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;
    bytes4 constant FN = bytes4(keccak256("work()"));

    AcceptAll registry;
    Sink sink;

    function setUp() public {
        vm.roll(1000);
        registry = new AcceptAll();
        sink = new Sink();
    }

    function _updates(uint256 m) internal view returns (bytes memory) {
        StateUpdateType[] memory t = new StateUpdateType[](m + 1);
        bytes[] memory a = new bytes[](m + 1);
        a[0] = abi.encode(TRACKER_SLOT, bytes32(uint256(1)));
        for (uint256 i = 1; i <= m; ++i) {
            t[i] = StateUpdateType.CALL;
            a[i] = abi.encode(address(sink), uint256(0), "", bytes32(0), type(uint256).max);
        }
        return abi.encode(t, a);
    }

    /// @dev External and called through `this`, so each row starts from fresh memory.
    function settleGas(bool policed, uint256 m) external returns (uint256 used) {
        GasKillerSDK target =
            policed ? GasKillerSDK(new PolicedCaller(address(registry))) : new DefaultCaller(address(registry));
        bytes memory updates = _updates(m);
        address[] memory none = new address[](0);
        uint32 ref = uint32(block.number - 1);
        uint256 g = gasleft();
        target.verifyAndUpdate(ref, updates, 0, FN, 1, address(1), none);
        used = g - gasleft();
    }

    /// @dev The counter copy plus m CALLs of 1 wei each, without and with the rate limit.
    function valueGas(bool limited, uint256 m) external returns (uint256 used) {
        GasKillerSDK target = limited
            ? GasKillerSDK(new RateLimitedCaller(address(registry)))
            : GasKillerSDK(new DefaultCaller(address(registry)));
        vm.deal(address(target), 1 ether);
        StateUpdateType[] memory t = new StateUpdateType[](m + 1);
        bytes[] memory a = new bytes[](m + 1);
        a[0] = abi.encode(TRACKER_SLOT, bytes32(uint256(1)));
        for (uint256 i = 1; i <= m; ++i) {
            t[i] = StateUpdateType.CALL;
            a[i] = abi.encode(address(sink), uint256(1), "", bytes32(0), type(uint256).max);
        }
        bytes memory updates = abi.encode(t, a);
        address[] memory none = new address[](0);
        uint32 ref = uint32(block.number - 1);
        uint256 g = gasleft();
        target.verifyAndUpdate(ref, updates, 0, FN, 1, address(1), none);
        used = g - gasleft();
    }

    function test_rateLimit() public {
        uint256[3] memory ms = [uint256(1), 8, 32];
        this.settleGas(false, 1); // warm the registry
        console2.log("settlement gas, counter copy + m 1-wei CALLs");
        console2.log("m  |  default  |  rate limited");
        for (uint256 i = 0; i < 3; ++i) {
            uint256 d = this.valueGas(false, ms[i]);
            uint256 r = this.valueGas(true, ms[i]);
            console2.log(string.concat(vm.toString(ms[i]), "  |  ", vm.toString(d), "  |  ", vm.toString(r)));
        }
    }

    /// @dev The counter copy plus `m` `transfer`s of the first token, for a consumer with no
    ///      limits (`k` = none) or the drop-in limiting `k` tokens.
    function tokenGas(bool limited, uint256 k, uint256 m) external returns (uint256 used) {
        address[] memory tokens = new address[](k == 0 ? 1 : k);
        for (uint256 i = 0; i < tokens.length; ++i) {
            tokens[i] = address(new BenchToken());
        }
        address[] memory listed = new address[](k);
        for (uint256 i = 0; i < k; ++i) {
            listed[i] = tokens[i];
        }
        GasKillerSDK target = limited
            ? GasKillerSDK(new TokenLimitedCaller(address(registry), listed))
            : GasKillerSDK(new DefaultCaller(address(registry)));
        for (uint256 i = 0; i < tokens.length; ++i) {
            BenchToken(tokens[i]).mint(address(target), 1000);
        }
        StateUpdateType[] memory t = new StateUpdateType[](m + 1);
        bytes[] memory a = new bytes[](m + 1);
        a[0] = abi.encode(TRACKER_SLOT, bytes32(uint256(1)));
        for (uint256 i = 1; i <= m; ++i) {
            t[i] = StateUpdateType.CALL;
            a[i] = abi.encode(tokens[0], uint256(0), abi.encodeCall(IERC20.transfer, (address(sink), 1)), bytes32(0), type(uint256).max);
        }
        bytes memory updates = abi.encode(t, a);
        address[] memory none = new address[](0);
        uint32 ref = uint32(block.number - 1);
        uint256 g = gasleft();
        target.verifyAndUpdate(ref, updates, 0, FN, 1, address(1), none);
        used = g - gasleft();
    }

    function test_tokenLimit() public {
        this.settleGas(false, 1); // warm the registry
        uint256[3] memory ms = [uint256(1), 8, 32];
        console2.log("settlement gas, counter copy + m token transfers");
        console2.log("m  |  no limits  |  k = 0  |  k = 1  |  k = 4");
        for (uint256 i = 0; i < 3; ++i) {
            console2.log(
                string.concat(
                    vm.toString(ms[i]),
                    "  |  ",
                    vm.toString(this.tokenGas(false, 0, ms[i])),
                    "  |  ",
                    vm.toString(this.tokenGas(true, 0, ms[i])),
                    "  |  ",
                    vm.toString(this.tokenGas(true, 1, ms[i])),
                    "  |  ",
                    vm.toString(this.tokenGas(true, 4, ms[i]))
                )
            );
        }
    }

    /// @dev The counter copy plus m CALLs to the consumer's own `ping`.
    function selfGas(bool allowAll, uint256 m) external returns (uint256 used) {
        GasKillerSDK target = new SelfCaller(address(registry), allowAll);
        StateUpdateType[] memory t = new StateUpdateType[](m + 1);
        bytes[] memory a = new bytes[](m + 1);
        a[0] = abi.encode(TRACKER_SLOT, bytes32(uint256(1)));
        for (uint256 i = 1; i <= m; ++i) {
            t[i] = StateUpdateType.CALL;
            a[i] = abi.encode(address(target), uint256(0), abi.encodeCall(SelfCaller.ping, ()), bytes32(0), type(uint256).max);
        }
        bytes memory updates = abi.encode(t, a);
        address[] memory none = new address[](0);
        uint32 ref = uint32(block.number - 1);
        uint256 g = gasleft();
        target.verifyAndUpdate(ref, updates, 0, FN, 1, address(1), none);
        used = g - gasleft();
    }

    function test_selfCalls() public {
        uint256[3] memory ms = [uint256(1), 8, 32];
        this.settleGas(false, 1); // warm the registry
        console2.log("settlement gas, counter copy + m allowed self-calls to ping()");
        console2.log("m  |  allow all  |  one-selector list");
        for (uint256 i = 0; i < 3; ++i) {
            uint256 all = this.selfGas(true, ms[i]);
            uint256 one = this.selfGas(false, ms[i]);
            console2.log(string.concat(vm.toString(ms[i]), "  |  ", vm.toString(all), "  |  ", vm.toString(one)));
        }
    }

    /// @dev The same settlement as `settleGas` for a consumer with a one-entry allow-list.
    function listedGas(uint256 m) external returns (uint256 used) {
        GasKillerSDK target = new ListedCaller(address(registry), address(sink));
        bytes memory updates = _updates(m);
        address[] memory none = new address[](0);
        uint32 ref = uint32(block.number - 1);
        uint256 g = gasleft();
        target.verifyAndUpdate(ref, updates, 0, FN, 1, address(1), none);
        used = g - gasleft();
    }

    function test_allowList() public {
        uint256[3] memory ms = [uint256(1), 8, 32];
        this.settleGas(false, 1); // warm the registry
        console2.log("settlement gas, counter copy + m zero-value CALLs");
        console2.log("m  |  default  |  one-entry allow-list");
        for (uint256 i = 0; i < 3; ++i) {
            uint256 d = this.settleGas(false, ms[i]);
            uint256 l = this.listedGas(ms[i]);
            console2.log(string.concat(vm.toString(ms[i]), "  |  ", vm.toString(d), "  |  ", vm.toString(l)));
        }
    }

    /// @dev One ETH payout through the vault's own function, without and with `limitsOutflow`.
    ///      The vault is deployed in this call, so its budget slot is warm.
    function payoutGas(bool limited) external returns (uint256 used) {
        BenchVault v = new BenchVault(address(registry));
        vm.deal(address(v), 1 ether);
        uint256 g = gasleft();
        if (limited) v.payLimited(address(sink), 1);
        else v.pay(address(sink), 1);
        used = g - gasleft();
    }

    /// @dev One token payout, without and with `limitsOutflow`, listing `k` tokens.
    function tokenPayoutGas(bool limited, uint256 k) external returns (uint256 used) {
        address[] memory tokens = new address[](k == 0 ? 1 : k);
        for (uint256 i = 0; i < tokens.length; ++i) {
            tokens[i] = address(new BenchToken());
        }
        address[] memory listed = new address[](k);
        for (uint256 i = 0; i < k; ++i) {
            listed[i] = tokens[i];
        }
        BenchTokenVault v = new BenchTokenVault(address(registry), listed);
        BenchToken(tokens[0]).mint(address(v), 1000);
        uint256 g = gasleft();
        if (limited) v.payLimited(IERC20(tokens[0]), address(sink), 1);
        else v.pay(IERC20(tokens[0]), address(sink), 1);
        used = g - gasleft();
    }

    function test_payouts() public {
        this.payoutGas(false); // warm the sink
        console2.log("one payout through the contract's own function");
        console2.log("ETH  |  ", vm.toString(this.payoutGas(false)), "  |  ", vm.toString(this.payoutGas(true)));
        console2.log(
            "token, k = 0  |  ",
            vm.toString(this.tokenPayoutGas(false, 0)),
            "  |  ",
            vm.toString(this.tokenPayoutGas(true, 0))
        );
        console2.log(
            "token, k = 1  |  ",
            vm.toString(this.tokenPayoutGas(false, 1)),
            "  |  ",
            vm.toString(this.tokenPayoutGas(true, 1))
        );
        console2.log(
            "token, k = 4  |  ",
            vm.toString(this.tokenPayoutGas(false, 4)),
            "  |  ",
            vm.toString(this.tokenPayoutGas(true, 4))
        );
    }

    function test_calls() public {
        uint256[3] memory ms = [uint256(1), 8, 32];
        this.settleGas(false, 1); // warm the registry
        console2.log("settlement gas, counter copy + m zero-value CALLs");
        console2.log("m  |  default  |  small policy");
        for (uint256 i = 0; i < 3; ++i) {
            uint256 d = this.settleGas(false, ms[i]);
            uint256 p = this.settleGas(true, ms[i]);
            console2.log(string.concat(vm.toString(ms[i]), "  |  ", vm.toString(d), "  |  ", vm.toString(p)));
        }
    }
}
