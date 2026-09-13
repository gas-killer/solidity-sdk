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

// src/examples/onchain-fly/FlySwapPool.sol

/// @notice What the pool reads from the v2 policy: the fly's fill word for one intent
interface IFlySwapPolicyFills {
    function fillOf(uint64 id)
        external
        view
        returns (uint16 feeBps, int16 skewBps, bool rebalance, uint32 epoch, bool decided);
}

/// @title FlySwapPool
/// @notice v2 of the fly AMM (HANDOFF_PER_SWAP §4.1): swaps are escrowed *intents* in a FIFO queue; every
///         intent is priced by its own fly episode (settled through a Gas Killer round into `FlySwapPolicy`)
///         and then executed, in queue order, by the permissionless `applyNext` at the fly-decided fee.
/// @dev NOT a Gas Killer consumer (never inherits the SDK). The quorum-signed diff writes only policy
///      storage; this pool's storage is written only by `submit`, `applyNext` and the LP functions, so
///      nothing the payload writes can be clobbered by pool activity between reference and apply.
///      The fly chooses a fee inside [MIN_FEE, MAX_FEE]; the pool computes the price from its curve.
///      No cancel (double-settlement race, §4.1); traders exit through `expiryEpoch` (refund on apply).
contract FlySwapPool {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ the security boundary
    uint16 public constant MIN_FEE_BPS = 5;
    uint16 public constant MAX_FEE_BPS = 100;
    uint16 public constant MAX_SKEW_BPS = 30;
    uint16 public constant REBAL_SKEW_BPS = 30;
    uint256 public constant OBS_UNIT = 1e12; // quote wei per observation volume unit
    uint256 internal constant BPS = 10_000;

    uint8 public constant PENDING = 0;
    uint8 public constant FILLED = 1;
    uint8 public constant REFUNDED = 2;

    struct Intent {
        address owner;
        bool buyBase;
        uint8 status;
        uint32 expiryEpoch; // 0 = never
        uint128 amountIn;
        uint128 minOut;
    }

    struct Fill {
        uint128 amountOut;
        uint16 feeBps;
        uint32 epoch;
    }

    // ------------------------------------------------------------------ tokens / policy
    IERC20 public immutable base;
    IERC20 public immutable quote;
    address public immutable deployer;
    IFlySwapPolicyFills public policy; // set once after the policy is deployed (it needs this pool's address)

    // ------------------------------------------------------------------ reserves + LP shares
    uint128 public reserveBase;
    uint128 public reserveQuote;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    // ------------------------------------------------------------------ the queue
    uint64 public tail; // last submitted id (ids start at 1)
    uint64 public applied; // last applied id
    mapping(uint64 => Intent) public intents;
    mapping(uint64 => Fill) public fills;

    // ------------------------------------------------------------------ per-epoch statistics the fly sees
    uint64[16] internal buyHist; // fee-paid quote volume per policy epoch, index epoch % 16
    uint64[16] internal sellHist;
    uint32 public histEpoch; // newest epoch with fills applied (0 = none)
    uint64 public volRef; // EMA (α = 1/8) of per-epoch volume
    uint128 public emaSpotQ64; // EMA (α = 1/8) of post-fill spot; seeded at first liquidity
    uint64 internal curFeeIncome; // accumulators for `histEpoch`
    uint64 internal curLpLoss;
    uint64 public lastEpochFeeIncome; // completed-epoch values the fly is rewarded / punished with
    uint64 public lastEpochLpLoss;

    // ------------------------------------------------------------------ events / errors
    event IntentSubmitted(
        uint64 indexed id, address indexed owner, bool buyBase, uint256 amountIn, uint256 minOut, uint32 expiryEpoch
    );
    event Swap(
        uint64 indexed id,
        address indexed owner,
        bool buyBase,
        uint256 amountIn,
        uint256 amountOut,
        uint16 feeBps,
        uint32 epoch
    );
    event IntentRefunded(uint64 indexed id, address indexed owner, uint256 amountIn, string reason);
    event LiquidityAdded(address indexed to, uint256 baseIn, uint256 quoteIn, uint256 lp);
    event LiquidityRemoved(address indexed to, uint256 baseOut, uint256 quoteOut, uint256 lp);
    event EpochRolled(
        uint32 indexed epoch,
        uint64 buy,
        uint64 sell,
        uint64 feeIncome,
        uint64 lpLoss,
        uint64 volRef,
        uint128 emaSpotQ64
    );

    error PolicyAlreadySet();
    error NotDeployer();
    error NothingToApply();
    error NotDecided();
    error NoSuchIntent();
    error InsufficientLiquidity();
    error ZeroAmount();

    constructor(IERC20 _base, IERC20 _quote) {
        base = _base;
        quote = _quote;
        deployer = msg.sender;
    }

    /// @notice One-shot wiring of the fly policy (which needs this pool's address at its construction)
    function setPolicy(IFlySwapPolicyFills _policy) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (address(policy) != address(0)) revert PolicyAlreadySet();
        policy = _policy;
    }

    // ================================================================== intents

    /// @notice Escrow `amountIn` and join the queue. The fly prices this intent in a later round.
    function submit(bool buyBase, uint256 amountIn, uint256 minOut, uint32 expiryEpoch) external returns (uint64 id) {
        if (amountIn == 0) revert ZeroAmount();
        (buyBase ? quote : base).safeTransferFrom(msg.sender, address(this), amountIn);
        id = ++tail;
        intents[id] = Intent({
            owner: msg.sender,
            buyBase: buyBase,
            status: PENDING,
            expiryEpoch: expiryEpoch,
            amountIn: uint128(amountIn),
            minOut: uint128(minOut)
        });
        emit IntentSubmitted(id, msg.sender, buyBase, amountIn, minOut, expiryEpoch);
    }

    /// @notice Execute the next intent in queue order at its fly-decided fee (or refund it). Permissionless.
    function applyNext() public returns (uint64 id) {
        id = applied + 1;
        if (id > tail) revert NothingToApply();
        (uint16 fee, int16 skew, bool rebal, uint32 epoch, bool decided) = policy.fillOf(id);
        if (!decided) revert NotDecided();
        Intent storage it = intents[id];
        uint16 eff = _clampFee(fee, skew, rebal, it.buyBase, reserveBase, reserveQuote);
        applied = id;
        _rollEpoch(epoch);
        if (it.expiryEpoch != 0 && epoch > it.expiryEpoch) return _refund(id, it, "expired");
        _execute(id, eff, epoch);
    }

    /// @dev x·y=k at the current reserves with the clamped fee; refunds on minOut / empty pool
    function _execute(uint64 id, uint16 eff, uint32 epoch) internal {
        Intent storage it = intents[id];
        uint256 amountIn = it.amountIn;
        uint256 rB = reserveBase;
        uint256 rQ = reserveQuote;
        if (rB == 0 || rQ == 0) {
            _refund(id, it, "no liquidity");
            return;
        }
        uint256 inAfter = amountIn * (BPS - eff) / BPS;
        uint256 out;
        uint256 feeQuote;
        if (it.buyBase) {
            out = rB * inAfter / (rQ + inAfter);
            if (out < it.minOut || out >= rB) {
                _refund(id, it, "minOut");
                return;
            }
            reserveQuote = uint128(rQ + amountIn);
            reserveBase = uint128(rB - out);
            feeQuote = amountIn - inAfter;
            base.safeTransfer(it.owner, out);
            buyHist[epoch % 16] = _sat64(uint256(buyHist[epoch % 16]) + amountIn / OBS_UNIT);
        } else {
            out = rQ * inAfter / (rB + inAfter);
            if (out < it.minOut || out >= rQ) {
                _refund(id, it, "minOut");
                return;
            }
            feeQuote = ((amountIn - inAfter) * ((rQ << 64) / rB)) >> 64;
            reserveBase = uint128(rB + amountIn);
            reserveQuote = uint128(rQ - out);
            quote.safeTransfer(it.owner, out);
            sellHist[epoch % 16] = _sat64(uint256(sellHist[epoch % 16]) + out / OBS_UNIT);
        }
        it.status = FILLED;
        fills[id] = Fill({amountOut: uint128(out), feeBps: eff, epoch: epoch});
        _afterFill(rB, rQ, feeQuote);
        emit Swap(id, it.owner, it.buyBase, amountIn, out, eff, epoch);
    }

    /// @notice Keeper convenience: apply up to `n` intents, stopping at the first undecided one
    function applyUpTo(uint64 n) external returns (uint64 count) {
        while (count < n) {
            uint64 id = applied + 1;
            if (id > tail) break;
            (,,,, bool decided) = policy.fillOf(id);
            if (!decided) break;
            applyNext();
            ++count;
        }
    }

    function _refund(uint64 id, Intent storage it, string memory reason) internal returns (uint64) {
        it.status = REFUNDED;
        (it.buyBase ? quote : base).safeTransfer(it.owner, it.amountIn);
        emit IntentRefunded(id, it.owner, it.amountIn, reason);
        return id;
    }

    /// @dev Exactly v1 `effectiveFee`: band clamp, skew cap, rebalance override against the EMA spot
    function _clampFee(uint16 fee, int16 skew, bool rebal, bool buyBase, uint256 rB, uint256 rQ)
        internal
        view
        returns (uint16)
    {
        int256 f = int256(uint256(fee));
        if (f < int256(uint256(MIN_FEE_BPS))) f = int256(uint256(MIN_FEE_BPS));
        if (f > int256(uint256(MAX_FEE_BPS))) f = int256(uint256(MAX_FEE_BPS));
        int256 s = skew;
        if (s > int256(uint256(MAX_SKEW_BPS))) s = int256(uint256(MAX_SKEW_BPS));
        if (s < -int256(uint256(MAX_SKEW_BPS))) s = -int256(uint256(MAX_SKEW_BPS));
        if (rebal && rB != 0 && emaSpotQ64 != 0) {
            uint256 spot = (rQ << 64) / rB;
            s = spot > emaSpotQ64 ? int256(uint256(REBAL_SKEW_BPS)) : -int256(uint256(REBAL_SKEW_BPS));
        }
        f += buyBase ? s : -s;
        if (f < int256(uint256(MIN_FEE_BPS))) f = int256(uint256(MIN_FEE_BPS));
        if (f > int256(uint256(MAX_FEE_BPS))) f = int256(uint256(MAX_FEE_BPS));
        return uint16(uint256(f));
    }

    /// @dev First fill of a newer epoch: freeze the previous epoch's outcome (reward/punish inputs), zero skipped slots
    function _rollEpoch(uint32 epoch) internal {
        uint32 prev = histEpoch;
        if (epoch <= prev) return;
        if (prev != 0) {
            uint256 vol = uint256(buyHist[prev % 16]) + sellHist[prev % 16];
            volRef = _sat64(volRef == 0 ? vol : uint256(volRef) + vol / 8 - uint256(volRef) / 8);
            lastEpochFeeIncome = curFeeIncome;
            lastEpochLpLoss = curLpLoss;
            emit EpochRolled(prev, buyHist[prev % 16], sellHist[prev % 16], curFeeIncome, curLpLoss, volRef, emaSpotQ64);
        }
        uint256 gap = epoch - prev;
        if (gap > 16) gap = 16;
        for (uint256 g = 1; g <= gap; ++g) {
            buyHist[(prev + g) % 16] = 0;
            sellHist[(prev + g) % 16] = 0;
        }
        curFeeIncome = 0;
        curLpLoss = 0;
        histEpoch = epoch;
    }

    /// @dev LP loss vs the EMA spot before the fill, fee income, then the EMA update
    function _afterFill(uint256 rB0, uint256 rQ0, uint256 feeQuote) internal {
        uint256 P = emaSpotQ64;
        uint256 v0 = ((rB0 * P) >> 64) + rQ0;
        uint256 v1 = ((uint256(reserveBase) * P) >> 64) + reserveQuote;
        if (v0 > v1) curLpLoss = _sat64(uint256(curLpLoss) + (v0 - v1) / OBS_UNIT);
        curFeeIncome = _sat64(uint256(curFeeIncome) + feeQuote / OBS_UNIT);
        uint256 spot = (uint256(reserveQuote) << 64) / reserveBase;
        emaSpotQ64 = uint128(P == 0 ? spot : P + spot / 8 - P / 8);
    }

    // ================================================================== liquidity (immediate, untracked)

    function addLiquidity(uint256 baseIn, uint256 quoteIn, address to) external returns (uint256 lp) {
        if (baseIn == 0 || quoteIn == 0) revert ZeroAmount();
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
        if (emaSpotQ64 == 0) emaSpotQ64 = uint128((uint256(reserveQuote) << 64) / reserveBase);
        emit LiquidityAdded(to, baseIn, quoteIn, lp);
    }

    function removeLiquidity(uint256 lp, address to) external returns (uint256 baseOut, uint256 quoteOut) {
        if (lp == 0) revert ZeroAmount();
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

    // ================================================================== the fly's view (storage only)

    /// @notice Raw observation of intent `id`: the histogram ring is UNrotated (index = epoch % 16) and
    ///         `epoch` carries `histEpoch`; `FlySwapPolicy` rotates it for the observed epoch (D-2).
    function observeIntent(uint64 id) external view returns (FlyTypes.SwapObservation memory o) {
        if (id == 0 || id > tail) revert NoSuchIntent();
        Intent storage it = intents[id];
        uint256 rB = reserveBase;
        uint256 rQ = reserveQuote;
        uint256 rIn = it.buyBase ? rQ : rB;
        uint256 rOut = it.buyBase ? rB : rQ;
        o.id = id;
        o.buyBase = it.buyBase;
        o.sizeBps = uint64(rIn == 0 ? BPS : _min(BPS, uint256(it.amountIn) * BPS / rIn));
        if (it.minOut != 0 && rIn != 0 && rOut != 0) {
            uint256 q = rOut * uint256(it.amountIn) / (rIn + uint256(it.amountIn));
            o.maxSlipBps = uint64(q > it.minOut ? (q - it.minOut) * BPS / q : 0);
        }
        o.queueDepth = tail - applied;
        o.epoch = histEpoch;
        o.buyQuote = buyHist;
        o.sellQuote = sellHist;
        o.volRef = volRef;
        o.spotQ64 = uint128(rB == 0 ? 0 : (rQ << 64) / rB);
        o.emaSpotQ64 = emaSpotQ64;
        o.feeIncomeQuote = lastEpochFeeIncome;
        o.lpLossQuote = lastEpochLpLoss;
    }

    function pendingRange() external view returns (uint64, uint64) {
        return (applied, tail);
    }

    function spotQ64() external view returns (uint128) {
        return reserveBase == 0 ? 0 : uint128((uint256(reserveQuote) << 64) / reserveBase);
    }

    // ================================================================== helpers

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

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
