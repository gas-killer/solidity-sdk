// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.29;

import {Test, console2} from "forge-std/Test.sol";
import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {StateUpdateType} from "../src/StateChangeHandlerLib.sol";
import {AcceptAll} from "./SettlementGas.t.sol";
import {GasKillerOutgoingRateLimit} from "../src/extensions/GasKillerOutgoingRateLimit.sol";
import {GasKillerTokenRateLimit} from "../src/extensions/GasKillerTokenRateLimit.sol";
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

/// A typical small policy: no self-calls, and a value cap.
contract PolicedCaller is DefaultCaller {
    error SelfCall(uint256 index);

    constructor(address registry) DefaultCaller(registry) {}

    function _authorizeCall(bytes4, uint256 index, StateUpdateType, address target, uint256, bytes memory)
        internal
        view
        override
    {
        if (target == address(this)) revert SelfCall(index);
    }

    function _maxOutgoingValue(bytes4) internal pure override returns (uint256) {
        return 1 ether;
    }
}

/// The drop-in rate limit.
contract RateLimitedCaller is GasKillerOutgoingRateLimit {
    constructor(address registry) GasKillerOutgoingRateLimit(1 ether, 1 hours) {
        _setSchnorrRegistry(registry);
    }
}

/// @notice Whole-settlement gas through `verifyAndUpdate` for the counter copy plus m zero-value
///         CALLs to one warm contract, with the default call policy (`_authorizeCall` and
///         `_maxOutgoingValue` not overridden) and with the small one above.
///
///         Reference measurements (forge 1.5.1, solc 0.8.33, cancun). "Before" is the same
///         settlement before the call policy (#108's tree, 0944508):
///
///           m   | before | default policy  | small policy
///           1   | 33,576 | +415 (+1.2%)    | +453 (+1.3%)
///           8   | 47,166 | +1,497 (+3.2%)  | +1,815 (+3.8%)
///           32  | 94,129 | +5,203 (+5.5%)  | +6,481 (+6.9%)
///
///         About 155 gas per CALL with the default policy, about 205 with the small one, and about
///         260 fixed per program (building the policy and reading the cap). A program of STOREs
///         only pays the fixed part and about 3 gas per op (`SettlementGas.t.sol`). Against a
///         real CALL, which pays a cold account access (2,600) and the callee's own work, the
///         share is smaller than against this empty, warm callee.
///
///         `test_rateLimit`: the same with 1-wei CALLs, without and with `GasKillerOutgoingRateLimit`
///         (1 ether per hour):
///
///           m   | default | rate limited
///           1   |  40,864 | +627 (+1.5%)
///           8   | 103,444 | +4,932 (+4.8%)
///           32  | 318,369 | +19,692 (+6.2%)
///
///         About 615 gas per op that sends value. The consumer is deployed in the same transaction,
///         so the budget slot is already warm here; a real settlement also pays about 5,000 once,
///         for the first read (2,100, cold) and write (2,900) of the slot.
///
///         `test_tokenLimit`: the counter copy plus one ERC-20 `transfer`, for a consumer with no
///         limits (59,144) and for `GasKillerTokenRateLimit` listing k tokens: k = 0 +4,190 (+7.1%),
///         k = 1 +9,273 (+15.7%), k = 4 +20,532 (+34.7%). Each listed token costs two `balanceOf`
///         calls and a budget read and write; a program that runs no code reads no balances.
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
            a[i] = abi.encode(address(sink), uint256(0), "");
        }
        return abi.encode(t, a);
    }

    /// @dev External and called through `this`, so each row starts from fresh memory.
    function settleGas(bool policed, uint256 m) external returns (uint256 used) {
        GasKillerSDK target =
            policed ? GasKillerSDK(new PolicedCaller(address(registry))) : new DefaultCaller(address(registry));
        bytes memory updates = _updates(m);
        bytes32 h = target.getMessageHash(0, FN, updates);
        address[] memory none = new address[](0);
        uint32 ref = uint32(block.number - 1);
        uint256 g = gasleft();
        target.verifyAndUpdate(h, ref, updates, 0, FN, 1, address(1), none);
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
            a[i] = abi.encode(address(sink), uint256(1), "");
        }
        bytes memory updates = abi.encode(t, a);
        bytes32 h = target.getMessageHash(0, FN, updates);
        address[] memory none = new address[](0);
        uint32 ref = uint32(block.number - 1);
        uint256 g = gasleft();
        target.verifyAndUpdate(h, ref, updates, 0, FN, 1, address(1), none);
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

    /// @dev The counter copy plus one `transfer` of the first token, for a consumer with no
    ///      limits (`k` = none) or the drop-in limiting `k` tokens.
    function tokenGas(bool limited, uint256 k) external returns (uint256 used) {
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
        StateUpdateType[] memory t = new StateUpdateType[](2);
        bytes[] memory a = new bytes[](2);
        a[0] = abi.encode(TRACKER_SLOT, bytes32(uint256(1)));
        t[1] = StateUpdateType.CALL;
        a[1] = abi.encode(tokens[0], uint256(0), abi.encodeCall(IERC20.transfer, (address(sink), 1)));
        bytes memory updates = abi.encode(t, a);
        bytes32 h = target.getMessageHash(0, FN, updates);
        address[] memory none = new address[](0);
        uint32 ref = uint32(block.number - 1);
        uint256 g = gasleft();
        target.verifyAndUpdate(h, ref, updates, 0, FN, 1, address(1), none);
        used = g - gasleft();
    }

    function test_tokenLimit() public {
        this.settleGas(false, 1); // warm the registry
        console2.log("settlement gas, counter copy + 1 token transfer");
        console2.log("no limits  |  ", vm.toString(this.tokenGas(false, 0)));
        console2.log("drop-in, k = 0  |  ", vm.toString(this.tokenGas(true, 0)));
        console2.log("drop-in, k = 1  |  ", vm.toString(this.tokenGas(true, 1)));
        console2.log("drop-in, k = 4  |  ", vm.toString(this.tokenGas(true, 4)));
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
