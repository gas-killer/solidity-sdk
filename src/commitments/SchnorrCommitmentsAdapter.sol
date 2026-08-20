// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import {SchnorrStakeRegistry} from "../schnorr/SchnorrStakeRegistry.sol";
import {IOperatorRegistryMinimal} from "./interfaces/ICommitmentsMinimal.sol";

/// @title SchnorrCommitmentsAdapter
/// @notice The operator-lifecycle authority for a `SchnorrStakeRegistry`, backed by the
///         Commitments protocol instead of EigenLayer. The registry's NatSpec anticipated
///         exactly this layer: "production would layer the operator/AVS registration
///         lifecycle on top, exactly as `ECDSAStakeRegistry` does" — this contract is that
///         layer, with Commitments `OperatorRegistry` stake as the source of truth.
///
///         The adapter is the registry's immutable `owner()`, so it must be deployed
///         BEFORE the registry (the registry's constructor takes the owner address) and
///         pointed at it with the one-shot `setRegistry`.
///
///         Responsibilities:
///           - `join` — a Commitments-registered operator publishes its Schnorr pubkey
///             (with proof of possession, validated by the registry), its BN254 p2p
///             identity, and its socket; the adapter mirrors it into the Schnorr registry
///             with a weight quantized from live Commitments stake.
///           - `syncWeight` — permissionless crank keeping registry weights equal to
///             quantized Commitments stake; drops operators whose stake fell below the
///             registry-side floor.
///           - `eject` — arbiter-only immediate removal (forced path, no notice window):
///             a proven-equivocating key leaves the signer set in the slash transaction,
///             so the >= 1-day forfeit challenge window delays money, not signing power.
///           - `leave` — operator-initiated exit, respecting the notice window when one
///             is configured.
///           - `getOperatorSet` — the single read the off-chain stack bootstraps from
///             (replaces the EigenLayer `EigenStakingClient` event scan).
///
/// @dev Weight quantization: `weight = stake / weightScale`, floored. Deployments that
///      want today's uniform-weight behavior set `weightScale = minOperatorStake` so every
///      minimum-staked operator maps to weight 1. Threshold math on the registry is
///      fractional (`signedWeight/totalWeight >= num/den`), so the scale cancels; only
///      sub-scale dust is uncounted.
///
///      Every registry mutation the adapter performs advances the registry's
///      `effectiveBlock`, transiently fail-closing settlements assembled against earlier
///      reference blocks. Cranks should therefore be driven off material stake changes
///      (delegation created/released/forfeited, `OperatorBelowMinStake`), not per block.
contract SchnorrCommitmentsAdapter {
    /// @notice The Commitments operator registry that is the stake source of truth.
    IOperatorRegistryMinimal public immutable operatorRegistry;

    /// @notice Divisor quantizing raw Commitments stake units into registry `uint96` weight.
    uint256 public immutable weightScale;

    /// @notice Bootstrap/emergency authority: wires the registry and arbiter, and can drive
    ///         the registry's owner surface directly if the mirror ever needs manual repair
    ///         (the registry's `owner` is immutable, so there is no ownership handoff to
    ///         fall back to).
    address public immutable admin;

    /// @notice The `SchnorrStakeRegistry` this adapter owns. One-shot.
    SchnorrStakeRegistry public registry;

    /// @notice The slashing arbiter allowed to call `eject`. One-shot.
    address public arbiter;

    /// @notice Off-chain node identity published at `join` time. The BN254 G2 key is the
    ///         commonware p2p identity; G1 accompanies it for engine-level verification;
    ///         `socket` is the dialable address. None of this is consulted on-chain — it is
    ///         the sidecar the off-chain bootstrap reads in one `eth_call`.
    struct NodeInfo {
        uint256 secpX;
        uint256 secpY;
        uint256[2] blsG1;
        uint256[4] blsG2;
        string socket;
    }

    struct OperatorView {
        address operator;
        uint256 weight; // live registry weight (0 when pending under a notice window)
        NodeInfo info;
    }

    mapping(address => NodeInfo) internal nodeInfo;
    /// Enumerable set of operators the adapter has joined (swap-and-pop on removal).
    address[] internal operatorList;
    /// One-based index into `operatorList`; zero means "not present".
    mapping(address => uint256) internal operatorIndex;

    error NotAdmin();
    error NotArbiter();
    error AlreadyWired();
    error NotWired();
    error ZeroAddress();
    error NotCommitmentsOperator(address operator);
    error KeyIsNotSender(address keyAddress, address sender);
    error StakeBelowScale(uint256 stake, uint256 scale);
    error NotJoined(address operator);

    event RegistryWired(address indexed registry);
    event ArbiterWired(address indexed arbiter);
    event OperatorJoined(address indexed operator, uint256 weight, bool announced);
    event OperatorLeft(address indexed operator, bool announced);
    event OperatorEjected(address indexed operator);
    event WeightSynced(address indexed operator, uint256 oldWeight, uint256 newWeight);
    event OperatorDropped(address indexed operator, uint256 stake);
    event NodeInfoUpdated(address indexed operator);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier whenWired() {
        if (address(registry) == address(0)) revert NotWired();
        _;
    }

    constructor(address _operatorRegistry, uint256 _weightScale, address _admin) {
        if (_operatorRegistry == address(0) || _admin == address(0)) revert ZeroAddress();
        require(_weightScale != 0, "zero scale");
        operatorRegistry = IOperatorRegistryMinimal(_operatorRegistry);
        weightScale = _weightScale;
        admin = _admin;
    }

    /// @notice Point the adapter at the registry it owns. One-shot: the registry is
    ///         constructed with this adapter as its immutable owner, so the deploy order is
    ///         adapter -> registry(owner = adapter) -> `setRegistry`.
    function setRegistry(address _registry) external onlyAdmin {
        if (address(registry) != address(0)) revert AlreadyWired();
        if (_registry == address(0)) revert ZeroAddress();
        registry = SchnorrStakeRegistry(_registry);
        emit RegistryWired(_registry);
    }

    /// @notice Wire the slashing arbiter allowed to `eject`. One-shot.
    function setArbiter(address _arbiter) external onlyAdmin {
        if (arbiter != address(0)) revert AlreadyWired();
        if (_arbiter == address(0)) revert ZeroAddress();
        arbiter = _arbiter;
        emit ArbiterWired(_arbiter);
    }

    // ---------------------------------------------------------------------------------------
    // Operator lifecycle
    // ---------------------------------------------------------------------------------------

    /// @notice Join the Schnorr signer set. Caller must be a registered Commitments operator
    ///         whose address IS the Ethereum address of the submitted Schnorr key (the same
    ///         identity invariant the off-chain node asserts at startup), with quantized
    ///         stake >= 1. Uses the immediate path when the registry has no notice window,
    ///         the announce queue otherwise (commit via `commitNext` once eligible).
    /// @param x       Schnorr (secp256k1) pubkey x-coordinate.
    /// @param y       Schnorr pubkey y-coordinate.
    /// @param popS    proof-of-possession scalar `s` over `registry.popMessage(operator)`.
    /// @param popR    proof-of-possession nonce address `address(R)`.
    /// @param blsG1   BN254 G1 public key (p2p/engine identity), affine coordinates.
    /// @param blsG2   BN254 G2 public key, affine coordinates (x.c1, x.c0, y.c1, y.c0 as
    ///                the commonware string-coordinate order expects).
    /// @param socket  dialable p2p socket, e.g. "node-1:3001".
    function join(
        uint256 x,
        uint256 y,
        uint256 popS,
        address popR,
        uint256[2] calldata blsG1,
        uint256[4] calldata blsG2,
        string calldata socket
    ) external whenWired {
        if (!operatorRegistry.isOperator(msg.sender)) revert NotCommitmentsOperator(msg.sender);
        address id = registry.pointAddress(x, y);
        if (id != msg.sender) revert KeyIsNotSender(id, msg.sender);

        uint256 weight = _quantizedStake(msg.sender);
        if (weight == 0) revert StakeBelowScale(operatorRegistry.getOperatorStake(msg.sender), weightScale);

        bool announced = registry.noticeWindow() != 0;
        if (announced) {
            registry.announceRegister(x, y, weight, popS, popR);
        } else {
            registry.registerOperator(x, y, weight, popS, popR);
        }

        nodeInfo[msg.sender] =
            NodeInfo({secpX: x, secpY: y, blsG1: blsG1, blsG2: blsG2, socket: socket});
        if (operatorIndex[msg.sender] == 0) {
            operatorList.push(msg.sender);
            operatorIndex[msg.sender] = operatorList.length;
        }

        emit OperatorJoined(msg.sender, weight, announced);
    }

    /// @notice Refresh the published p2p sidecar (socket move, key rotation happens via
    ///         leave + rejoin since the Schnorr key is the identity).
    function updateNodeInfo(uint256[2] calldata blsG1, uint256[4] calldata blsG2, string calldata socket)
        external
    {
        if (operatorIndex[msg.sender] == 0) revert NotJoined(msg.sender);
        NodeInfo storage info = nodeInfo[msg.sender];
        info.blsG1 = blsG1;
        info.blsG2 = blsG2;
        info.socket = socket;
        emit NodeInfoUpdated(msg.sender);
    }

    /// @notice Voluntary exit from the signer set. Respects the notice window when one is
    ///         configured (capital exit is separate: `requestUnbond` on the manager).
    function leave() external whenWired {
        if (operatorIndex[msg.sender] == 0) revert NotJoined(msg.sender);

        bool announced = registry.noticeWindow() != 0 && _isRegistered(msg.sender);
        if (announced) {
            registry.announceDeregister(msg.sender);
            // Sidecar is kept until the change commits; `syncWeight` cleans up after.
        } else {
            _forceRemove(msg.sender);
        }
        emit OperatorLeft(msg.sender, announced);
    }

    /// @notice Apply the oldest announced registry change once eligible. Permissionless
    ///         passthrough of `commitNextChange`; cleans the sidecar up when the committed
    ///         change was a deregistration.
    function commitNext() external whenWired {
        registry.commitNextChange();
        // A committed deregistration leaves a joined-but-unregistered operator; sweep it.
        uint256 n = operatorList.length;
        for (uint256 i = 0; i < n;) {
            address op = operatorList[i];
            if (!_isRegistered(op) && registry.pendingChangeIndex(op) == 0) {
                _removeFromList(op);
                n--;
                continue; // swapped element now occupies slot i
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Immediate forced removal of a proven-misbehaving operator — arbiter-only.
    ///         Clears any queued change first (targeted cancel), then force-deregisters,
    ///         with no time gate between them. Idempotent for already-removed operators so
    ///         a slash transaction can never fail on the ejection leg.
    function eject(address operator) external whenWired {
        if (msg.sender != arbiter && msg.sender != admin) revert NotArbiter();
        _forceRemove(operator);
        emit OperatorEjected(operator);
    }

    /// @notice Permissionless crank reconciling one operator's registry weight with its
    ///         live Commitments stake. Deregisters operators that stopped being
    ///         Commitments-registered or whose quantized stake hit zero.
    function syncWeight(address operator) external whenWired {
        if (!_isRegistered(operator)) {
            // Nothing mirrored (or pending under notice window) — only sweep the sidecar
            // if Commitments no longer recognizes the operator and nothing is queued.
            if (
                operatorIndex[operator] != 0 && !operatorRegistry.isOperator(operator)
                    && registry.pendingChangeIndex(operator) == 0
            ) {
                _removeFromList(operator);
                emit OperatorDropped(operator, 0);
            }
            return;
        }

        if (!operatorRegistry.isOperator(operator)) {
            _forceRemove(operator);
            emit OperatorDropped(operator, 0);
            return;
        }

        uint256 stake = operatorRegistry.getOperatorStake(operator);
        uint256 newWeight = stake / weightScale;
        if (newWeight == 0) {
            _forceRemove(operator);
            emit OperatorDropped(operator, stake);
            return;
        }

        (,, uint96 current,,) = registry.operators(operator);
        if (newWeight != current) {
            registry.updateOperatorWeight(operator, newWeight);
            emit WeightSynced(operator, current, newWeight);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Admin escape hatch
    //
    // The registry's `owner` is immutable, so if the mirror logic is ever wrong the fix
    // cannot be "hand ownership back to an EOA". Instead the admin can drive the owner
    // surface directly. Bootstrap flows may also use these before Commitments state exists.
    // ---------------------------------------------------------------------------------------

    function adminRegister(uint256 x, uint256 y, uint256 weight, uint256 popS, address popR)
        external
        onlyAdmin
        whenWired
    {
        registry.registerOperator(x, y, weight, popS, popR);
    }

    function adminDeregister(address operator) external onlyAdmin whenWired {
        registry.deregisterOperator(operator);
        if (operatorIndex[operator] != 0) _removeFromList(operator);
    }

    function adminCancelChange(address operator) external onlyAdmin whenWired {
        registry.cancelChange(operator);
    }

    function adminUpdateWeight(address operator, uint256 weight) external onlyAdmin whenWired {
        registry.updateOperatorWeight(operator, weight);
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    /// @notice The full operator set with p2p sidecar and live registry weights — the one
    ///         read the off-chain bootstrap needs. Operators queued behind a notice window
    ///         report weight 0 until their registration commits.
    function getOperatorSet() external view returns (OperatorView[] memory set) {
        uint256 n = operatorList.length;
        set = new OperatorView[](n);
        for (uint256 i = 0; i < n; ++i) {
            address op = operatorList[i];
            uint256 weight = 0;
            if (address(registry) != address(0)) {
                (,, uint96 w, bool reg,) = registry.operators(op);
                weight = reg ? w : 0;
            }
            set[i] = OperatorView({operator: op, weight: weight, info: nodeInfo[op]});
        }
    }

    function getOperatorCount() external view returns (uint256) {
        return operatorList.length;
    }

    function getNodeInfo(address operator) external view returns (NodeInfo memory) {
        return nodeInfo[operator];
    }

    /// @notice Quantized live Commitments stake for `operator` (the weight `syncWeight`
    ///         would mirror).
    function quantizedStake(address operator) external view returns (uint256) {
        return _quantizedStake(operator);
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    function _quantizedStake(address operator) internal view returns (uint256) {
        return operatorRegistry.getOperatorStake(operator) / weightScale;
    }

    function _isRegistered(address operator) internal view returns (bool) {
        (,,, bool reg,) = registry.operators(operator);
        return reg;
    }

    /// @dev Forced removal: clear any queued change (the forced paths refuse to act on an
    ///      identity with one), deregister if currently in the set, and drop the sidecar.
    ///      Never reverts for an operator that is already gone.
    function _forceRemove(address operator) internal {
        if (registry.pendingChangeIndex(operator) != 0) {
            registry.cancelChange(operator);
        }
        if (_isRegistered(operator)) {
            registry.deregisterOperator(operator);
        }
        if (operatorIndex[operator] != 0) {
            _removeFromList(operator);
        }
    }

    function _removeFromList(address operator) internal {
        uint256 oneBased = operatorIndex[operator];
        uint256 last = operatorList.length;
        if (oneBased != last) {
            address moved = operatorList[last - 1];
            operatorList[oneBased - 1] = moved;
            operatorIndex[moved] = oneBased;
        }
        operatorList.pop();
        delete operatorIndex[operator];
        delete nodeInfo[operator];
    }
}
