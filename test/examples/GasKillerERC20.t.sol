// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {GasKillerERC20} from "../../src/examples/gaskiller-erc20/GasKillerERC20.sol";
import {StateUpdateType} from "../../src/StateChangeHandlerLib.sol";
import {IBLSSignatureCheckerTypes} from "@eigenlayer-middleware/interfaces/IBLSSignatureChecker.sol";

/// @dev Minimal BLS checker that always reports 100% signed stake, so `verifyAndUpdate`'s quorum
///      threshold is satisfied. Only the `checkSignatures` selector matters at the call site.
contract MockBLSSignatureChecker {
    function checkSignatures(
        bytes32,
        bytes calldata quorumNumbers,
        uint32,
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory
    ) external pure returns (IBLSSignatureCheckerTypes.QuorumStakeTotals memory totals, bytes32) {
        uint256 n = quorumNumbers.length;
        totals.signedStakeForQuorum = new uint96[](n);
        totals.totalStakeForQuorum = new uint96[](n);
        for (uint256 i = 0; i < n; i++) {
            totals.signedStakeForQuorum[i] = uint96(1e18);
            totals.totalStakeForQuorum[i] = uint96(1e18);
        }
        return (totals, bytes32(0));
    }
}

/// @title GasKillerERC20Test
/// @notice Exercises the single-slot commitment ERC20: ERC20 semantics via the witness path, the
///         canonical-commitment properties, the O(1) storage-write guarantee, and the end-to-end Gas
///         Killer `verifyAndUpdate` path.
/// @dev The test contract plays the role of the off-chain operator: it mirrors the full expanded state
///      in mappings, builds `TokenState` witnesses from that mirror, and after every on-chain mutation
///      cross-checks `token.stateRoot() == token.computeStateRoot(witness)`.
contract GasKillerERC20Test is Test {
    GasKillerERC20 internal token;
    MockBLSSignatureChecker internal bls;

    address internal avs = address(0xA75);
    // The test contract itself is the minter.
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);
    address internal dave = address(0xD00D);

    uint256 internal constant INITIAL = 1_000_000e18;

    // ---- off-chain mirror of the full token state ----
    address[] internal participants;
    mapping(address => bool) internal known;
    mapping(address => uint256) internal mBal;
    mapping(address => mapping(address => uint256)) internal mAllow;
    uint256 internal mSupply;

    // Slot written by StateTracker's trackState modifier (keccak256("gasKiller.stateTracker") - 1).
    bytes32 internal constant TRACKER_SLOT = 0xdebfdfd5a50ad117c10898d68b5ccf0893c6b40d4f443f902e2e7646601bdeaf;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        bls = new MockBLSSignatureChecker();
        token = new GasKillerERC20(avs, address(bls), "Gas Killer USD", "gkUSD", address(this), alice, INITIAL);

        _register(alice);
        _register(bob);
        _register(carol);
        _register(dave);

        // Seed the mirror to match the constructor's initial mint.
        mSupply = INITIAL;
        mBal[alice] = INITIAL;

        _assertInSync();
    }

    // =============================================================================================
    // Metadata & setup
    // =============================================================================================

    function testMetadata() public view {
        assertEq(token.name(), "Gas Killer USD");
        assertEq(token.symbol(), "gkUSD");
        assertEq(token.decimals(), 18);
        assertEq(token.minter(), address(this));
    }

    function testInitialCommitment() public view {
        assertEq(token.stateRoot(), token.computeStateRoot(_witness()));
        assertEq(token.balanceOf(_witness(), alice), INITIAL);
        assertEq(token.totalSupply(_witness()), INITIAL);
        assertEq(token.stateTransitionCount(), 0);
    }

    function testEmptyTokenHasWellDefinedRoot() public {
        GasKillerERC20 empty = new GasKillerERC20(avs, address(bls), "Empty", "MT", address(0), address(0), 0);
        GasKillerERC20.TokenState memory s; // totalSupply 0, no accounts
        assertEq(empty.stateRoot(), empty.computeStateRoot(s));
        assertEq(empty.balanceOf(s, alice), 0);
        assertEq(empty.totalSupply(s), 0);
    }

    function testConstructorRejectsSupplyToZeroAddress() public {
        vm.expectRevert(GasKillerERC20.TransferToZeroAddress.selector);
        new GasKillerERC20(avs, address(bls), "X", "X", address(0), address(0), 1);
    }

    function testMetadataTooLongReverts() public {
        vm.expectRevert(GasKillerERC20.MetadataTooLong.selector);
        new GasKillerERC20(
            avs, address(bls), "this name is definitely longer than thirty two bytes", "X", address(0), alice, 1
        );
    }

    // =============================================================================================
    // ERC20 semantics (standalone witness path)
    // =============================================================================================

    function testTransfer() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 100e18);

        vm.prank(alice);
        bool ok = token.transfer(_witness(), bob, 100e18);
        assertTrue(ok);
        _mTransfer(alice, bob, 100e18);

        _assertInSync();
        assertEq(token.balanceOf(_witness(), alice), INITIAL - 100e18);
        assertEq(token.balanceOf(_witness(), bob), 100e18);
        assertEq(token.stateTransitionCount(), 1);
    }

    function testTransferInsufficientBalanceReverts() public {
        vm.prank(bob); // bob has nothing
        vm.expectRevert(abi.encodeWithSelector(GasKillerERC20.InsufficientBalance.selector, bob, 0, 1));
        token.transfer(_witness(), alice, 1);
    }

    function testTransferToZeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(GasKillerERC20.TransferToZeroAddress.selector);
        token.transfer(_witness(), address(0), 1);
    }

    function testZeroTransferIsAllowed() public {
        vm.prank(bob); // zero balance, zero transfer is legal
        token.transfer(_witness(), carol, 0);
        _mTransfer(bob, carol, 0);
        _assertInSync();
        assertEq(token.stateTransitionCount(), 1);
    }

    function testSelfTransferIsNoOp() public {
        bytes32 before = token.stateRoot();
        vm.prank(alice);
        token.transfer(_witness(), alice, 123e18);
        _mTransfer(alice, alice, 123e18);
        _assertInSync();
        assertEq(token.balanceOf(_witness(), alice), INITIAL);
        assertEq(token.stateRoot(), before, "self-transfer must not change the commitment");
    }

    function testApproveAndTransferFrom() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, bob, 500e18);
        vm.prank(alice);
        token.approve(_witness(), bob, 500e18);
        _mApprove(alice, bob, 500e18);
        _assertInSync();
        assertEq(token.allowance(_witness(), alice, bob), 500e18);

        vm.prank(bob);
        token.transferFrom(_witness(), alice, carol, 200e18);
        _mTransferFrom(alice, carol, bob, 200e18);
        _assertInSync();

        assertEq(token.balanceOf(_witness(), carol), 200e18);
        assertEq(token.allowance(_witness(), alice, bob), 300e18);
    }

    function testTransferFromInsufficientAllowanceReverts() public {
        vm.prank(alice);
        token.approve(_witness(), bob, 10e18);
        _mApprove(alice, bob, 10e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GasKillerERC20.InsufficientAllowance.selector, alice, bob, 10e18, 11e18));
        token.transferFrom(_witness(), alice, carol, 11e18);
    }

    function testInfiniteAllowanceNotDecremented() public {
        vm.prank(alice);
        token.approve(_witness(), bob, type(uint256).max);
        _mApprove(alice, bob, type(uint256).max);
        _assertInSync();

        vm.prank(bob);
        token.transferFrom(_witness(), alice, carol, 250e18);
        _mTransferFrom(alice, carol, bob, 250e18);
        _assertInSync();

        assertEq(token.allowance(_witness(), alice, bob), type(uint256).max, "infinite allowance stays infinite");
        assertEq(token.balanceOf(_witness(), carol), 250e18);
    }

    function testApproveZeroRevokes() public {
        vm.prank(alice);
        token.approve(_witness(), bob, 42e18);
        _mApprove(alice, bob, 42e18);
        _assertInSync();

        vm.prank(alice);
        token.approve(_witness(), bob, 0);
        _mApprove(alice, bob, 0);
        _assertInSync();
        assertEq(token.allowance(_witness(), alice, bob), 0);
    }

    function testMint() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(0), bob, 777e18);
        token.mint(_witness(), bob, 777e18); // test contract is minter
        _mMint(bob, 777e18);
        _assertInSync();

        assertEq(token.balanceOf(_witness(), bob), 777e18);
        assertEq(token.totalSupply(_witness()), INITIAL + 777e18);
    }

    function testMintOnlyMinter() public {
        vm.prank(alice);
        vm.expectRevert(GasKillerERC20.NotMinter.selector);
        token.mint(_witness(), alice, 1);
    }

    function testBurn() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 300e18);
        vm.prank(alice);
        token.burn(_witness(), 300e18);
        _mBurn(alice, 300e18);
        _assertInSync();

        assertEq(token.balanceOf(_witness(), alice), INITIAL - 300e18);
        assertEq(token.totalSupply(_witness()), INITIAL - 300e18);
    }

    // =============================================================================================
    // Commitment / canonicalisation properties
    // =============================================================================================

    function testWrongWitnessReverts() public {
        GasKillerERC20.TokenState memory bad = _witness();
        bad.accounts[0].balance += 1; // tamper
        bytes32 provided = token.computeStateRoot(bad);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(GasKillerERC20.StateWitnessMismatch.selector, token.stateRoot(), provided)
        );
        token.transfer(bad, bob, 1);
    }

    function testWitnessOrderIndependent() public view {
        // Build a witness with a shuffled account order plus a padding zero-balance account; the
        // commitment must be identical because the contract canonicalises before hashing.
        GasKillerERC20.TokenState memory shuffled;
        shuffled.totalSupply = INITIAL;
        shuffled.accounts = new GasKillerERC20.Account[](2);
        // padding empty account first, real holder second (out of order, gets dropped/sorted)
        shuffled.accounts[0] = GasKillerERC20.Account(bob, 0, new GasKillerERC20.Allowance[](0));
        shuffled.accounts[1] = GasKillerERC20.Account(alice, INITIAL, new GasKillerERC20.Allowance[](0));

        assertEq(token.computeStateRoot(shuffled), token.stateRoot());
    }

    function testDuplicateOwnerWitnessReverts() public {
        GasKillerERC20.TokenState memory dup;
        dup.totalSupply = INITIAL;
        dup.accounts = new GasKillerERC20.Account[](2);
        dup.accounts[0] = GasKillerERC20.Account(alice, INITIAL, new GasKillerERC20.Allowance[](0));
        dup.accounts[1] = GasKillerERC20.Account(alice, 0, new GasKillerERC20.Allowance[](0));
        vm.expectRevert(GasKillerERC20.NonCanonicalWitness.selector);
        token.computeStateRoot(dup);
    }

    function testDuplicateSpenderWitnessReverts() public {
        GasKillerERC20.TokenState memory dup;
        dup.totalSupply = INITIAL;
        dup.accounts = new GasKillerERC20.Account[](1);
        GasKillerERC20.Allowance[] memory al = new GasKillerERC20.Allowance[](2);
        al[0] = GasKillerERC20.Allowance(bob, 1);
        al[1] = GasKillerERC20.Allowance(bob, 2); // duplicate spender
        dup.accounts[0] = GasKillerERC20.Account(alice, INITIAL, al);
        vm.expectRevert(GasKillerERC20.NonCanonicalWitness.selector);
        token.computeStateRoot(dup);
    }

    // =============================================================================================
    // The headline property: storage writes are O(1) regardless of holder count
    // =============================================================================================

    function testTransferWritesExactlyTwoSlots_fewHolders() public {
        uint256 uniqueWrites = _recordTransferWrites();
        assertEq(uniqueWrites, 2, "commitment slot + tracker slot only");
    }

    function testTransferWritesExactlyTwoSlots_manyHolders() public {
        // Spread the supply across 50 holders, then measure a transfer. The write count must not grow.
        for (uint256 i = 0; i < 50; i++) {
            address holder = vm.addr(i + 1);
            _register(holder);
            vm.prank(alice);
            token.transfer(_witness(), holder, 1e18);
            _mTransfer(alice, holder, 1e18);
        }
        _assertInSync();

        uint256 uniqueWrites = _recordTransferWrites();
        assertEq(uniqueWrites, 2, "O(1): still only commitment + tracker even with 50+ holders");
    }

    /// @dev Records the distinct storage slots written by a single `alice -> bob` transfer and asserts
    ///      they are exactly the commitment slot and the tracker slot.
    function _recordTransferWrites() internal returns (uint256 uniqueWrites) {
        GasKillerERC20.TokenState memory w = _witness();
        vm.record();
        vm.prank(alice);
        token.transfer(w, bob, 1e18);
        (, bytes32[] memory writes) = vm.accesses(address(token));
        _mTransfer(alice, bob, 1e18);

        bool sawRoot;
        bool sawTracker;
        bytes32 rootSlot = token.STATE_ROOT_SLOT();
        for (uint256 i = 0; i < writes.length; i++) {
            if (writes[i] == rootSlot) sawRoot = true;
            else if (writes[i] == TRACKER_SLOT) sawTracker = true;
            else revert("unexpected storage write");
        }
        assertTrue(sawRoot, "commitment slot not written");
        assertTrue(sawTracker, "tracker slot not written");
        uniqueWrites = (sawRoot ? 1 : 0) + (sawTracker ? 1 : 0);
    }

    // =============================================================================================
    // End-to-end Gas Killer path: an operator applies a transition as a single STORE op
    // =============================================================================================

    function testVerifyAndUpdateAppliesSingleStore() public {
        // The operator computes the post-state off-chain and its commitment.
        GasKillerERC20.TokenState memory pre = _witness();
        _mTransfer(alice, bob, 12345e18); // mirror = post-state
        GasKillerERC20.TokenState memory post = _witness();
        bytes32 newRoot = token.computeStateRoot(post);
        assertTrue(newRoot != token.stateRoot());

        // Build the single-STORE payload the operators would BLS-sign.
        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.STORE;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(token.STATE_ROOT_SLOT(), newRoot);
        bytes memory storageUpdates = abi.encode(types, args);

        vm.roll(100);
        uint32 refBlock = 99;
        uint256 transitionIndex = token.stateTransitionCount(); // == count before the call
        bytes4 targetFunction = token.transfer.selector;
        bytes32 msgHash = sha256(abi.encode(transitionIndex, address(token), targetFunction, storageUpdates));
        assertEq(msgHash, token.getMessageHash(transitionIndex, targetFunction, storageUpdates));

        bytes memory quorumNumbers = hex"00";
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory sig;

        // Record writes to prove the on-chain footprint is one STORE + the tracker counter.
        vm.record();
        token.verifyAndUpdate(msgHash, quorumNumbers, refBlock, storageUpdates, transitionIndex, targetFunction, sig);
        (, bytes32[] memory writes) = vm.accesses(address(token));

        bytes32 rootSlot = token.STATE_ROOT_SLOT();
        for (uint256 i = 0; i < writes.length; i++) {
            assertTrue(writes[i] == rootSlot || writes[i] == TRACKER_SLOT, "gas killer wrote an unexpected slot");
        }

        // State advanced to exactly the operator-computed commitment.
        assertEq(token.stateRoot(), newRoot);
        assertEq(token.stateTransitionCount(), transitionIndex + 1);
        _assertInSync();
        assertEq(token.balanceOf(_witness(), bob), 12345e18);
    }

    function testVerifyAndUpdateEmitsFaithfulEvent() public {
        // Production pattern: operators pair the single STORE with a LOG op so the ERC20 Transfer event
        // still fires even though on-chain state moved only one word.
        _mTransfer(alice, bob, 500e18);
        bytes32 newRoot = token.computeStateRoot(_witness());

        StateUpdateType[] memory types = new StateUpdateType[](2);
        types[0] = StateUpdateType.STORE;
        types[1] = StateUpdateType.LOG3;
        bytes[] memory args = new bytes[](2);
        args[0] = abi.encode(token.STATE_ROOT_SLOT(), newRoot);
        args[1] = abi.encode(
            abi.encode(uint256(500e18)), // data: the (non-indexed) value
            keccak256("Transfer(address,address,uint256)"),
            bytes32(uint256(uint160(alice))),
            bytes32(uint256(uint160(bob)))
        );
        bytes memory storageUpdates = abi.encode(types, args);

        vm.roll(100);
        uint256 transitionIndex = token.stateTransitionCount();
        bytes4 targetFunction = token.transfer.selector;
        bytes32 msgHash = sha256(abi.encode(transitionIndex, address(token), targetFunction, storageUpdates));
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory sig;

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 500e18);
        token.verifyAndUpdate(msgHash, hex"00", 99, storageUpdates, transitionIndex, targetFunction, sig);

        assertEq(token.stateRoot(), newRoot);
        _assertInSync();
    }

    function testConservationInvariantEnforced() public {
        // Forge a commitment whose balances do NOT sum to totalSupply, plant it directly in the slot,
        // and confirm reads/mutators fail closed rather than allowing phantom supply.
        GasKillerERC20.TokenState memory bad;
        bad.totalSupply = INITIAL; // claims INITIAL...
        bad.accounts = new GasKillerERC20.Account[](1);
        bad.accounts[0] = GasKillerERC20.Account(alice, INITIAL + 1, new GasKillerERC20.Allowance[](0)); // ...but holds more
        bytes32 badRoot = token.computeStateRoot(bad);
        vm.store(address(token), token.STATE_ROOT_SLOT(), badRoot);

        vm.expectRevert(abi.encodeWithSelector(GasKillerERC20.SupplyInvariantBroken.selector, INITIAL, INITIAL + 1));
        token.balanceOf(bad, alice);
    }

    function testStaleTransitionIndexRevertsAndReplayProtected() public {
        _mTransfer(alice, bob, 1e18);
        bytes32 newRoot = token.computeStateRoot(_witness());

        StateUpdateType[] memory types = new StateUpdateType[](1);
        types[0] = StateUpdateType.STORE;
        bytes[] memory args = new bytes[](1);
        args[0] = abi.encode(token.STATE_ROOT_SLOT(), newRoot);
        bytes memory storageUpdates = abi.encode(types, args);

        vm.roll(100);
        uint32 refBlock = 99;
        bytes4 targetFunction = token.transfer.selector;
        IBLSSignatureCheckerTypes.NonSignerStakesAndSignature memory sig;

        // A wrong transition index is rejected (ordering enforced).
        uint256 badIndex = token.stateTransitionCount() + 3;
        bytes32 badHash = sha256(abi.encode(badIndex, address(token), targetFunction, storageUpdates));
        vm.expectRevert(abi.encodeWithSignature("InvalidTransitionIndex()"));
        token.verifyAndUpdate(badHash, hex"00", refBlock, storageUpdates, badIndex, targetFunction, sig);

        // The correct index applies once.
        uint256 idx = token.stateTransitionCount();
        bytes32 goodHash = sha256(abi.encode(idx, address(token), targetFunction, storageUpdates));
        token.verifyAndUpdate(goodHash, hex"00", refBlock, storageUpdates, idx, targetFunction, sig);
        assertEq(token.stateRoot(), newRoot);
        _assertInSync();

        // Replaying the exact same payload now reverts — the counter has advanced (no double-apply).
        vm.expectRevert(abi.encodeWithSignature("InvalidTransitionIndex()"));
        token.verifyAndUpdate(goodHash, hex"00", refBlock, storageUpdates, idx, targetFunction, sig);
    }

    // =============================================================================================
    // Fuzz: the contract's applied result always equals the operator's independent computation
    // =============================================================================================

    function testFuzzTransferStaysInSync(uint256 amount) public {
        amount = bound(amount, 0, INITIAL);
        vm.prank(alice);
        token.transfer(_witness(), bob, amount);
        _mTransfer(alice, bob, amount);
        _assertInSync();
        assertEq(token.balanceOf(_witness(), bob), amount);
        assertEq(token.balanceOf(_witness(), alice), INITIAL - amount);
    }

    // =============================================================================================
    // Mirror helpers (the "operator")
    // =============================================================================================

    function _register(address a) internal {
        if (!known[a]) {
            known[a] = true;
            participants.push(a);
        }
    }

    function _mTransfer(address from, address to, uint256 amount) internal {
        mBal[from] -= amount;
        mBal[to] += amount;
    }

    function _mApprove(address owner, address spender, uint256 amount) internal {
        mAllow[owner][spender] = amount;
    }

    function _mTransferFrom(address from, address to, address spender, uint256 amount) internal {
        if (mAllow[from][spender] != type(uint256).max) {
            mAllow[from][spender] -= amount;
        }
        mBal[from] -= amount;
        mBal[to] += amount;
    }

    function _mMint(address to, uint256 amount) internal {
        mBal[to] += amount;
        mSupply += amount;
    }

    function _mBurn(address from, uint256 amount) internal {
        mBal[from] -= amount;
        mSupply -= amount;
    }

    /// @notice Build a `TokenState` witness from the off-chain mirror
    function _witness() internal view returns (GasKillerERC20.TokenState memory s) {
        s.totalSupply = mSupply;

        uint256 accountCount;
        for (uint256 i = 0; i < participants.length; i++) {
            if (_include(participants[i])) accountCount++;
        }

        s.accounts = new GasKillerERC20.Account[](accountCount);
        uint256 w;
        for (uint256 i = 0; i < participants.length; i++) {
            address owner = participants[i];
            if (!_include(owner)) continue;

            uint256 allowCount;
            for (uint256 j = 0; j < participants.length; j++) {
                if (mAllow[owner][participants[j]] > 0) allowCount++;
            }
            GasKillerERC20.Allowance[] memory al = new GasKillerERC20.Allowance[](allowCount);
            uint256 aw;
            for (uint256 j = 0; j < participants.length; j++) {
                address spender = participants[j];
                if (mAllow[owner][spender] > 0) {
                    al[aw++] = GasKillerERC20.Allowance(spender, mAllow[owner][spender]);
                }
            }
            s.accounts[w++] = GasKillerERC20.Account(owner, mBal[owner], al);
        }
    }

    function _include(address owner) internal view returns (bool) {
        if (mBal[owner] > 0) return true;
        for (uint256 j = 0; j < participants.length; j++) {
            if (mAllow[owner][participants[j]] > 0) return true;
        }
        return false;
    }

    function _assertInSync() internal view {
        assertEq(
            token.stateRoot(), token.computeStateRoot(_witness()), "contract commitment diverged from operator mirror"
        );
    }
}
