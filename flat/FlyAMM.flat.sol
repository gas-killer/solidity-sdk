// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0 ^0.8.1 ^0.8.13;

// lib/openzeppelin-contracts/contracts/utils/Address.sol

// OpenZeppelin Contracts (last updated v4.9.0) (utils/Address.sol)

/**
 * @dev Collection of functions related to the address type
 */
library Address {
    /**
     * @dev Returns true if `account` is a contract.
     *
     * [IMPORTANT]
     * ====
     * It is unsafe to assume that an address for which this function returns
     * false is an externally-owned account (EOA) and not a contract.
     *
     * Among others, `isContract` will return false for the following
     * types of addresses:
     *
     *  - an externally-owned account
     *  - a contract in construction
     *  - an address where a contract will be created
     *  - an address where a contract lived, but was destroyed
     *
     * Furthermore, `isContract` will also return true if the target contract within
     * the same transaction is already scheduled for destruction by `SELFDESTRUCT`,
     * which only has an effect at the end of a transaction.
     * ====
     *
     * [IMPORTANT]
     * ====
     * You shouldn't rely on `isContract` to protect against flash loan attacks!
     *
     * Preventing calls from contracts is highly discouraged. It breaks composability, breaks support for smart wallets
     * like Gnosis Safe, and does not provide security since it can be circumvented by calling from a contract
     * constructor.
     * ====
     */
    function isContract(address account) internal view returns (bool) {
        // This method relies on extcodesize/address.code.length, which returns 0
        // for contracts in construction, since the code is only stored at the end
        // of the constructor execution.

        return account.code.length > 0;
    }

    /**
     * @dev Replacement for Solidity's `transfer`: sends `amount` wei to
     * `recipient`, forwarding all available gas and reverting on errors.
     *
     * https://eips.ethereum.org/EIPS/eip-1884[EIP1884] increases the gas cost
     * of certain opcodes, possibly making contracts go over the 2300 gas limit
     * imposed by `transfer`, making them unable to receive funds via
     * `transfer`. {sendValue} removes this limitation.
     *
     * https://consensys.net/diligence/blog/2019/09/stop-using-soliditys-transfer-now/[Learn more].
     *
     * IMPORTANT: because control is transferred to `recipient`, care must be
     * taken to not create reentrancy vulnerabilities. Consider using
     * {ReentrancyGuard} or the
     * https://solidity.readthedocs.io/en/v0.8.0/security-considerations.html#use-the-checks-effects-interactions-pattern[checks-effects-interactions pattern].
     */
    function sendValue(address payable recipient, uint256 amount) internal {
        require(address(this).balance >= amount, "Address: insufficient balance");

        (bool success, ) = recipient.call{value: amount}("");
        require(success, "Address: unable to send value, recipient may have reverted");
    }

    /**
     * @dev Performs a Solidity function call using a low level `call`. A
     * plain `call` is an unsafe replacement for a function call: use this
     * function instead.
     *
     * If `target` reverts with a revert reason, it is bubbled up by this
     * function (like regular Solidity function calls).
     *
     * Returns the raw returned data. To convert to the expected return value,
     * use https://solidity.readthedocs.io/en/latest/units-and-global-variables.html?highlight=abi.decode#abi-encoding-and-decoding-functions[`abi.decode`].
     *
     * Requirements:
     *
     * - `target` must be a contract.
     * - calling `target` with `data` must not revert.
     *
     * _Available since v3.1._
     */
    function functionCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, "Address: low-level call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`], but with
     * `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        return functionCallWithValue(target, data, 0, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but also transferring `value` wei to `target`.
     *
     * Requirements:
     *
     * - the calling contract must have an ETH balance of at least `value`.
     * - the called Solidity function must be `payable`.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(address target, bytes memory data, uint256 value) internal returns (bytes memory) {
        return functionCallWithValue(target, data, value, "Address: low-level call with value failed");
    }

    /**
     * @dev Same as {xref-Address-functionCallWithValue-address-bytes-uint256-}[`functionCallWithValue`], but
     * with `errorMessage` as a fallback revert reason when `target` reverts.
     *
     * _Available since v3.1._
     */
    function functionCallWithValue(
        address target,
        bytes memory data,
        uint256 value,
        string memory errorMessage
    ) internal returns (bytes memory) {
        require(address(this).balance >= value, "Address: insufficient balance for call");
        (bool success, bytes memory returndata) = target.call{value: value}(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(address target, bytes memory data) internal view returns (bytes memory) {
        return functionStaticCall(target, data, "Address: low-level static call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a static call.
     *
     * _Available since v3.3._
     */
    function functionStaticCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        (bool success, bytes memory returndata) = target.staticcall(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(address target, bytes memory data) internal returns (bytes memory) {
        return functionDelegateCall(target, data, "Address: low-level delegate call failed");
    }

    /**
     * @dev Same as {xref-Address-functionCall-address-bytes-string-}[`functionCall`],
     * but performing a delegate call.
     *
     * _Available since v3.4._
     */
    function functionDelegateCall(
        address target,
        bytes memory data,
        string memory errorMessage
    ) internal returns (bytes memory) {
        (bool success, bytes memory returndata) = target.delegatecall(data);
        return verifyCallResultFromTarget(target, success, returndata, errorMessage);
    }

    /**
     * @dev Tool to verify that a low level call to smart-contract was successful, and revert (either by bubbling
     * the revert reason or using the provided one) in case of unsuccessful call or if target was not a contract.
     *
     * _Available since v4.8._
     */
    function verifyCallResultFromTarget(
        address target,
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal view returns (bytes memory) {
        if (success) {
            if (returndata.length == 0) {
                // only check isContract if the call was successful and the return data is empty
                // otherwise we already know that it was a contract
                require(isContract(target), "Address: call to non-contract");
            }
            return returndata;
        } else {
            _revert(returndata, errorMessage);
        }
    }

    /**
     * @dev Tool to verify that a low level call was successful, and revert if it wasn't, either by bubbling the
     * revert reason or using the provided one.
     *
     * _Available since v4.3._
     */
    function verifyCallResult(
        bool success,
        bytes memory returndata,
        string memory errorMessage
    ) internal pure returns (bytes memory) {
        if (success) {
            return returndata;
        } else {
            _revert(returndata, errorMessage);
        }
    }

    function _revert(bytes memory returndata, string memory errorMessage) private pure {
        // Look for revert reason and bubble it up if present
        if (returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(returndata)
                revert(add(32, returndata), returndata_size)
            }
        } else {
            revert(errorMessage);
        }
    }
}

// src/examples/onchain-fly/FlyTypes.sol

/// @title FlyTypes
/// @notice Shared value types of the fly-connectome AMM (HANDOFF §3.5, §4.2, §4.5, §4.7; HANDOFF_PER_SWAP §4–§5)
library FlyTypes {
    // ------------------------------------------------------------------ v1 (window policy loop)

    /// @notice What the v1 pool exposes to the fly: the last CLOSED window, storage reads only
    struct Observation {
        uint32 windowId;
        uint64[16] buyQuote;
        uint64[16] sellQuote;
        uint64 volRef;
        uint128 spotQ64;
        uint128 twapQ64;
        uint64 feeIncomeQuote;
        uint64 lpLossQuote;
    }

    /// @notice Reinforcement pulses applied from step 0 of an episode
    struct Stimulus {
        uint16 punishSteps;
        uint16 rewardSteps;
    }

    /// @notice Decoder outputs of one episode
    struct Readout {
        uint32[4] rateMilliHz;
        uint32[4] spikesLast30ms;
        uint32[14] windowCounts;
        uint64 totalSpikes;
    }

    /// @notice The v1 per-round consumer state (lives in the log; its packed word lives in FLY_SLOT)
    struct FlyState {
        bytes32 prevWord;
        uint32 epoch;
        uint32 windowId;
        uint16 feeBps;
        int16 skewBps;
        uint8 flags;
        uint32[4] rateMilliHz;
        bytes32 memoryRoot;
    }

    // ------------------------------------------------------------------ v2 (per-swap intents)

    /// @notice One queued intent as the fly sees it (HANDOFF_PER_SWAP §5.1). Storage reads only; the
    ///         histogram is already rotated so index 15 is epoch−1 and the strips use `epoch`.
    struct SwapObservation {
        uint64 id;
        bool buyBase;
        uint64 sizeBps; // amountIn relative to the input-side reserve, bps, saturating at 10_000
        uint64 maxSlipBps; // implied by minOut vs the curve quote at current reserves (0 if minOut == 0)
        uint64 queueDepth; // tail − applied at the reference block
        uint32 epoch; // policy epoch the observation is taken for (prev.epoch + 1)
        uint64[16] buyQuote; // per-epoch fee-paid quote volume, oldest..newest (OBS_UNIT)
        uint64[16] sellQuote;
        uint64 volRef;
        uint128 spotQ64;
        uint128 emaSpotQ64;
        uint64 feeIncomeQuote; // last applied epoch's fee income → REWARD pulse
        uint64 lpLossQuote; // last applied epoch's LP loss vs emaSpot → PUNISH pulse
    }

    /// @notice The v2 chained consumer state (fee/skew live per intent in `fills`, not here)
    struct FlyStateV2 {
        bytes32 prevWord;
        uint32 epoch;
        uint64 decidedThrough;
        uint8 flags;
        uint32[4] rateMilliHz;
        bytes32 memoryRoot;
    }
}

// lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol

// OpenZeppelin Contracts (last updated v4.9.0) (token/ERC20/IERC20.sol)

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `from` to `to` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol

// OpenZeppelin Contracts (last updated v4.9.0) (token/ERC20/extensions/IERC20Permit.sol)

/**
 * @dev Interface of the ERC20 Permit extension allowing approvals to be made via signatures, as defined in
 * https://eips.ethereum.org/EIPS/eip-2612[EIP-2612].
 *
 * Adds the {permit} method, which can be used to change an account's ERC20 allowance (see {IERC20-allowance}) by
 * presenting a message signed by the account. By not relying on {IERC20-approve}, the token holder account doesn't
 * need to send a transaction, and thus is not required to hold Ether at all.
 */
interface IERC20Permit {
    /**
     * @dev Sets `value` as the allowance of `spender` over ``owner``'s tokens,
     * given ``owner``'s signed approval.
     *
     * IMPORTANT: The same issues {IERC20-approve} has related to transaction
     * ordering also apply here.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `deadline` must be a timestamp in the future.
     * - `v`, `r` and `s` must be a valid `secp256k1` signature from `owner`
     * over the EIP712-formatted function arguments.
     * - the signature must use ``owner``'s current nonce (see {nonces}).
     *
     * For more information on the signature format, see the
     * https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
     * section].
     */
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /**
     * @dev Returns the current nonce for `owner`. This value must be
     * included whenever a signature is generated for {permit}.
     *
     * Every successful call to {permit} increases ``owner``'s nonce by one. This
     * prevents a signature from being used multiple times.
     */
    function nonces(address owner) external view returns (uint256);

    /**
     * @dev Returns the domain separator used in the encoding of the signature for {permit}, as defined by {EIP712}.
     */
    // solhint-disable-next-line func-name-mixedcase
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

// lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol

// OpenZeppelin Contracts (last updated v4.9.0) (token/ERC20/utils/SafeERC20.sol)

/**
 * @title SafeERC20
 * @dev Wrappers around ERC20 operations that throw on failure (when the token
 * contract returns false). Tokens that return no value (and instead revert or
 * throw on failure) are also supported, non-reverting calls are assumed to be
 * successful.
 * To use this library you can add a `using SafeERC20 for IERC20;` statement to your contract,
 * which allows you to call the safe operations as `token.safeTransfer(...)`, etc.
 */
library SafeERC20 {
    using Address for address;

    /**
     * @dev Transfer `value` amount of `token` from the calling contract to `to`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transfer.selector, to, value));
    }

    /**
     * @dev Transfer `value` amount of `token` from `from` to `to`, spending the approval given by `from` to the
     * calling contract. If `token` returns no value, non-reverting calls are assumed to be successful.
     */
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        _callOptionalReturn(token, abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
    }

    /**
     * @dev Deprecated. This function has issues similar to the ones found in
     * {IERC20-approve}, and its usage is discouraged.
     *
     * Whenever possible, use {safeIncreaseAllowance} and
     * {safeDecreaseAllowance} instead.
     */
    function safeApprove(IERC20 token, address spender, uint256 value) internal {
        // safeApprove should only be called when setting an initial allowance,
        // or when resetting it to zero. To increase and decrease it, use
        // 'safeIncreaseAllowance' and 'safeDecreaseAllowance'
        require(
            (value == 0) || (token.allowance(address(this), spender) == 0),
            "SafeERC20: approve from non-zero to non-zero allowance"
        );
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, value));
    }

    /**
     * @dev Increase the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeIncreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        uint256 oldAllowance = token.allowance(address(this), spender);
        _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, oldAllowance + value));
    }

    /**
     * @dev Decrease the calling contract's allowance toward `spender` by `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful.
     */
    function safeDecreaseAllowance(IERC20 token, address spender, uint256 value) internal {
        unchecked {
            uint256 oldAllowance = token.allowance(address(this), spender);
            require(oldAllowance >= value, "SafeERC20: decreased allowance below zero");
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, oldAllowance - value));
        }
    }

    /**
     * @dev Set the calling contract's allowance toward `spender` to `value`. If `token` returns no value,
     * non-reverting calls are assumed to be successful. Compatible with tokens that require the approval to be set to
     * 0 before setting it to a non-zero value.
     */
    function forceApprove(IERC20 token, address spender, uint256 value) internal {
        bytes memory approvalCall = abi.encodeWithSelector(token.approve.selector, spender, value);

        if (!_callOptionalReturnBool(token, approvalCall)) {
            _callOptionalReturn(token, abi.encodeWithSelector(token.approve.selector, spender, 0));
            _callOptionalReturn(token, approvalCall);
        }
    }

    /**
     * @dev Use a ERC-2612 signature to set the `owner` approval toward `spender` on `token`.
     * Revert on invalid signature.
     */
    function safePermit(
        IERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        uint256 nonceBefore = token.nonces(owner);
        token.permit(owner, spender, value, deadline, v, r, s);
        uint256 nonceAfter = token.nonces(owner);
        require(nonceAfter == nonceBefore + 1, "SafeERC20: permit did not succeed");
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     */
    function _callOptionalReturn(IERC20 token, bytes memory data) private {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We use {Address-functionCall} to perform this call, which verifies that
        // the target address contains contract code and also asserts for success in the low-level call.

        bytes memory returndata = address(token).functionCall(data, "SafeERC20: low-level call failed");
        require(returndata.length == 0 || abi.decode(returndata, (bool)), "SafeERC20: ERC20 operation did not succeed");
    }

    /**
     * @dev Imitates a Solidity high-level call (i.e. a regular function call to a contract), relaxing the requirement
     * on the return value: the return value is optional (but if data is returned, it must not be false).
     * @param token The token targeted by the call.
     * @param data The call data (encoded using abi.encode or one of its variants).
     *
     * This is a variant of {_callOptionalReturn} that silents catches all reverts and returns a bool instead.
     */
    function _callOptionalReturnBool(IERC20 token, bytes memory data) private returns (bool) {
        // We need to perform a low level call here, to bypass Solidity's return data size checking mechanism, since
        // we're implementing it ourselves. We cannot use {Address-functionCall} here since this should return false
        // and not revert is the subcall reverts.

        (bool success, bytes memory returndata) = address(token).call(data);
        return
            success && (returndata.length == 0 || abi.decode(returndata, (bool))) && Address.isContract(address(token));
    }
}

// src/examples/onchain-fly/FlyAMM.sol

/// @notice What the pool reads from the fly policy (one SLOAD on the policy side)
interface IFlyPolicyParams {
    function params()
        external
        view
        returns (uint16 feeBps, int16 skewBps, bool rebalance, uint32 windowId, uint32 epoch);
}

/// @title FlyAMM
/// @notice A plain x·y = k pool whose fee and directional skew are read from `FlyPolicy` under hard
///         clamps (HANDOFF §4.1, §4.6, §4.7). NOT a Gas Killer consumer: it never inherits the SDK,
///         so a colluding operator quorum can at worst pin the fee inside [MIN_FEE, MAX_FEE] — never
///         touch reserves.
/// @dev Windows are WINDOW_BLOCKS long. The first pool interaction in a new window CLOSES the previous
///      one: its buy/sell quote volume lands in a 16-window histogram ring, and its TWAP, fee income,
///      LP loss and closing spot are snapshotted. `observe()` returns ONLY closed-window data from
///      storage, so the fly's input is identical at every reference block inside a window and reads no
///      block environment. Volumes in the observation are in units of OBS_UNIT quote wei so they fit
///      the uint64 fields of the handoff's `Observation`.
contract FlyAMM {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ the security boundary
    uint16 public constant MIN_FEE_BPS = 5;
    uint16 public constant MAX_FEE_BPS = 100;
    uint16 public constant MAX_SKEW_BPS = 30;
    uint16 public constant REBAL_SKEW_BPS = 30;
    uint16 public constant DEFAULT_FEE_BPS = 30;
    uint32 public constant MAX_LAG_WINDOWS = 2;
    uint32 public constant WINDOW_BLOCKS = 25;
    uint256 public constant OBS_UNIT = 1e12; // quote wei per observation volume unit
    uint256 internal constant BPS = 10_000;

    // ------------------------------------------------------------------ tokens / policy
    IERC20 public immutable base;
    IERC20 public immutable quote;
    address public immutable deployer;
    IFlyPolicyParams public policy; // set once after the policy is deployed (it needs this pool's address)

    // ------------------------------------------------------------------ reserves + LP shares
    uint128 public reserveBase;
    uint128 public reserveQuote;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // ------------------------------------------------------------------ open window accumulators
    uint32 public curWindowId; // 0 = never opened
    uint64 internal curBuy; // OBS_UNIT quote units
    uint64 internal curSell;
    uint64 internal curFee;
    uint128 internal openBase;
    uint128 internal openQuote;
    uint256 internal openCum;
    uint64 internal openBlock;
    uint256 internal priceCumQ64; // Σ spotQ64 × blocks
    uint64 internal lastCumBlock;

    // ------------------------------------------------------------------ closed window
    struct Closed {
        uint32 windowId;
        uint64 volRef;
        uint128 spotQ64;
        uint128 twapQ64;
        uint64 feeIncomeQuote;
        uint64 lpLossQuote;
    }

    Closed public closed;
    uint64[16] internal buyHist; // indexed by windowId % 16
    uint64[16] internal sellHist;

    // ------------------------------------------------------------------ events / errors
    event Swap(
        address indexed sender, address indexed to, bool buyBase, uint256 amountIn, uint256 amountOut, uint16 feeBps
    );
    event LiquidityAdded(address indexed to, uint256 baseIn, uint256 quoteIn, uint256 lp);
    event LiquidityRemoved(address indexed to, uint256 baseOut, uint256 quoteOut, uint256 lp);
    event WindowClosed(
        uint32 indexed windowId,
        uint64 buy,
        uint64 sell,
        uint64 feeIncome,
        uint64 lpLoss,
        uint128 twapQ64,
        uint64 volRef
    );

    error PolicyAlreadySet();
    error NotDeployer();
    error InsufficientOutput();
    error InsufficientLiquidity();
    error ZeroAmount();

    constructor(IERC20 _base, IERC20 _quote) {
        base = _base;
        quote = _quote;
        deployer = msg.sender;
    }

    /// @notice One-shot wiring of the fly policy (which needs this pool's address at its construction)
    function setPolicy(IFlyPolicyParams _policy) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(policy) != address(0)) revert PolicyAlreadySet();
        policy = _policy;
    }

    // ================================================================== trading

    /// @notice Swap `amountIn` of quote for base (`buyBase`) or base for quote
    function swap(bool buyBase, uint256 amountIn, uint256 minOut, address to) external returns (uint256 out) {
        if (amountIn == 0) revert ZeroAmount();
        _touch();
        uint16 fee = effectiveFee(buyBase);
        uint256 rB = reserveBase;
        uint256 rQ = reserveQuote;
        if (rB == 0 || rQ == 0) revert InsufficientLiquidity();
        uint256 inAfter = amountIn * (BPS - fee) / BPS;
        if (buyBase) {
            quote.safeTransferFrom(msg.sender, address(this), amountIn);
            out = rB * inAfter / (rQ + inAfter);
            if (out < minOut || out >= rB) revert InsufficientOutput();
            reserveQuote = uint128(rQ + amountIn);
            reserveBase = uint128(rB - out);
            base.safeTransfer(to, out);
            curBuy = _sat64(uint256(curBuy) + amountIn / OBS_UNIT);
            curFee = _sat64(uint256(curFee) + (amountIn - inAfter) / OBS_UNIT);
        } else {
            base.safeTransferFrom(msg.sender, address(this), amountIn);
            out = rQ * inAfter / (rB + inAfter);
            if (out < minOut || out >= rQ) revert InsufficientOutput();
            uint256 spotBefore = (rQ << 64) / rB;
            reserveBase = uint128(rB + amountIn);
            reserveQuote = uint128(rQ - out);
            quote.safeTransfer(to, out);
            curSell = _sat64(uint256(curSell) + out / OBS_UNIT);
            curFee = _sat64(uint256(curFee) + (((amountIn - inAfter) * spotBefore) >> 64) / OBS_UNIT);
        }
        emit Swap(msg.sender, to, buyBase, amountIn, out, fee);
    }

    function addLiquidity(uint256 baseIn, uint256 quoteIn, address to) external returns (uint256 lp) {
        if (baseIn == 0 || quoteIn == 0) revert ZeroAmount();
        _touch();
        base.safeTransferFrom(msg.sender, address(this), baseIn);
        quote.safeTransferFrom(msg.sender, address(this), quoteIn);
        uint256 supply = totalSupply;
        if (supply == 0) {
            lp = _sqrt(baseIn * quoteIn);
        } else {
            uint256 a = baseIn * supply / reserveBase;
            uint256 b = quoteIn * supply / reserveQuote;
            lp = a < b ? a : b;
        }
        if (lp == 0) revert InsufficientLiquidity();
        reserveBase += uint128(baseIn);
        reserveQuote += uint128(quoteIn);
        totalSupply = supply + lp;
        balanceOf[to] += lp;
        emit LiquidityAdded(to, baseIn, quoteIn, lp);
    }

    function removeLiquidity(uint256 lp, address to) external returns (uint256 baseOut, uint256 quoteOut) {
        if (lp == 0) revert ZeroAmount();
        _touch();
        uint256 supply = totalSupply;
        baseOut = lp * reserveBase / supply;
        quoteOut = lp * reserveQuote / supply;
        balanceOf[msg.sender] -= lp;
        totalSupply = supply - lp;
        reserveBase -= uint128(baseOut);
        reserveQuote -= uint128(quoteOut);
        base.safeTransfer(to, baseOut);
        quote.safeTransfer(to, quoteOut);
        emit LiquidityRemoved(to, baseOut, quoteOut, lp);
    }

    // ================================================================== the fly's view

    /// @notice The last CLOSED window, storage reads only (no block environment): the fly's input
    function observe() external view returns (FlyTypes.Observation memory o) {
        Closed memory c = closed;
        o.windowId = c.windowId;
        for (uint256 k = 0; k < 16; ++k) {
            if (uint256(c.windowId) + k < 15) continue; // window would be negative
            uint256 w = uint256(c.windowId) + k - 15;
            if (w == 0) continue;
            o.buyQuote[k] = buyHist[w % 16];
            o.sellQuote[k] = sellHist[w % 16];
        }
        o.volRef = c.volRef;
        o.spotQ64 = c.spotQ64;
        o.twapQ64 = c.twapQ64;
        o.feeIncomeQuote = c.feeIncomeQuote;
        o.lpLossQuote = c.lpLossQuote;
    }

    /// @notice The fee a trade pays now: clamps FlyPolicy.params(), staleness, rebalance override (§4.7)
    function effectiveFee(bool buyBase) public view returns (uint16) {
        if (address(policy) == address(0)) return DEFAULT_FEE_BPS;
        (uint16 fee, int16 skew, bool rebal, uint32 wid,) = policy.params();
        uint32 now_ = _windowId();
        if (wid > now_ || now_ - wid > MAX_LAG_WINDOWS || fee < MIN_FEE_BPS || fee > MAX_FEE_BPS) {
            return DEFAULT_FEE_BPS;
        }
        int256 s = skew;
        if (s > int256(uint256(MAX_SKEW_BPS))) s = int256(uint256(MAX_SKEW_BPS));
        if (s < -int256(uint256(MAX_SKEW_BPS))) s = -int256(uint256(MAX_SKEW_BPS));
        if (rebal && closed.windowId != 0 && reserveBase != 0) {
            // surcharge the direction that moves spot AWAY from the last closed TWAP
            uint256 spot = (uint256(reserveQuote) << 64) / reserveBase;
            s = spot > closed.twapQ64 ? int256(uint256(REBAL_SKEW_BPS)) : -int256(uint256(REBAL_SKEW_BPS));
        }
        int256 f = int256(uint256(fee)) + (buyBase ? s : -s);
        if (f < int256(uint256(MIN_FEE_BPS))) f = int256(uint256(MIN_FEE_BPS));
        if (f > int256(uint256(MAX_FEE_BPS))) f = int256(uint256(MAX_FEE_BPS));
        return uint16(uint256(f));
    }

    /// @notice Current spot price, quote per base, Q64
    function spotQ64() public view returns (uint128) {
        if (reserveBase == 0) return 0;
        return uint128((uint256(reserveQuote) << 64) / reserveBase);
    }

    function currentWindowId() external view returns (uint32) {
        return _windowId();
    }

    // ================================================================== windows

    function _windowId() internal view returns (uint32) {
        return uint32(block.number / WINDOW_BLOCKS);
    }

    /// @dev Accrue the TWAP accumulator and roll the window if the block moved into a new one
    function _touch() internal {
        uint32 w = _windowId();
        uint256 spot = spotQ64();
        if (lastCumBlock != 0 && block.number > lastCumBlock) {
            priceCumQ64 += spot * (block.number - lastCumBlock);
        }
        lastCumBlock = uint64(block.number);
        if (curWindowId == 0) {
            curWindowId = w;
            _openWindow();
            return;
        }
        if (w != curWindowId) {
            _closeWindow(spot);
            curWindowId = w;
            _openWindow();
        }
    }

    function _openWindow() internal {
        openBase = reserveBase;
        openQuote = reserveQuote;
        openCum = priceCumQ64;
        openBlock = uint64(block.number);
        curBuy = 0;
        curSell = 0;
        curFee = 0;
    }

    function _closeWindow(uint256 spot) internal {
        uint32 wid = curWindowId;
        uint256 blocks = block.number - openBlock;
        uint256 twap = blocks == 0 ? spot : (priceCumQ64 - openCum) / blocks;
        // volRef: EMA of window volume, α = 1/8 (first window seeds it)
        uint256 vol = uint256(curBuy) + curSell;
        uint256 volRef = closed.windowId == 0 ? vol : uint256(closed.volRef) + vol / 8 - uint256(closed.volRef) / 8;
        // LP loss at the window TWAP: max(0, x0·P + y0 − x1·P − y1), in OBS_UNIT quote units
        uint256 v0 = ((uint256(openBase) * twap) >> 64) + openQuote;
        uint256 v1 = ((uint256(reserveBase) * twap) >> 64) + reserveQuote;
        uint256 lpLoss = v0 > v1 ? (v0 - v1) / OBS_UNIT : 0;
        // zero histogram slots of windows that never closed (no activity) since the previous close
        uint256 prevWid = closed.windowId;
        if (prevWid != 0 && wid > prevWid + 1) {
            uint256 gap = wid - prevWid - 1;
            if (gap > 16) gap = 16;
            for (uint256 g = 1; g <= gap; ++g) {
                buyHist[(prevWid + g) % 16] = 0;
                sellHist[(prevWid + g) % 16] = 0;
            }
        }
        buyHist[wid % 16] = curBuy;
        sellHist[wid % 16] = curSell;
        closed = Closed({
            windowId: wid,
            volRef: _sat64(volRef),
            spotQ64: uint128(spot),
            twapQ64: uint128(twap),
            feeIncomeQuote: curFee,
            lpLossQuote: _sat64(lpLoss)
        });
        emit WindowClosed(wid, curBuy, curSell, curFee, _sat64(lpLoss), uint128(twap), _sat64(volRef));
    }

    // ================================================================== helpers

    function _sat64(uint256 x) internal pure returns (uint64) {
        return x > type(uint64).max ? type(uint64).max : uint64(x);
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
