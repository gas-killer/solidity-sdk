// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
import {GKVM_ADDRESS, GKVM_OK_TAG} from "../src/gkvm/GkVm.sol";
import {
    GkVmUnavailable,
    GkGuestTrap,
    GkGuestOutOfCycles,
    GkVmInputOverflow,
    GkVmOutputOverflow,
    GkVmStaticOnly
} from "../src/gkvm/GkVmErrors.sol";
import {GkVmExposed} from "./exposed/GkVmExposed.sol";

/// @dev Stand-in precompile: answers OK-tag || its own calldata, so tests observe the exact wire input
contract EchoGkVm {
    fallback() external {
        bytes memory out = abi.encodePacked(GKVM_OK_TAG, msg.data);
        assembly {
            return(add(out, 0x20), mload(out))
        }
    }
}

/// @dev Stand-in precompile: answers the fixed bytes it was constructed with
contract FixedGkVm {
    bytes internal answer;

    constructor(bytes memory _answer) {
        answer = _answer;
    }

    fallback() external {
        bytes memory out = answer;
        assembly {
            return(add(out, 0x20), mload(out))
        }
    }
}

/// @dev Stand-in precompile: reverts with the fixed bytes it was constructed with
contract RevertingGkVm {
    bytes internal reason;

    constructor(bytes memory _reason) {
        reason = _reason;
    }

    fallback() external {
        bytes memory out = reason;
        assembly {
            revert(add(out, 0x20), mload(out))
        }
    }
}

contract GkVmTest is Test {
    bytes32 internal constant PROGRAM_HASH = keccak256("guest.elf");
    bytes32 internal constant ARTIFACT_ROOT = keccak256("artifact");

    GkVmExposed internal gk;

    function setUp() public {
        gk = new GkVmExposed();
    }

    function testAddressDerivation() public pure {
        assertEq(GKVM_ADDRESS, address(uint160(uint256(keccak256("gaskiller.gkvm.addr.v1")))));
    }

    function testOkTag() public pure {
        assertEq(GKVM_OK_TAG, bytes1(0x01));
    }

    function testWireFormat() public {
        address echo = address(new EchoGkVm());
        bytes memory payload = abi.encode(uint256(7), "prompt");
        bytes memory out = gk.execExternal(echo, PROGRAM_HASH, ARTIFACT_ROOT, payload);
        assertEq(out, abi.encodePacked(PROGRAM_HASH, ARTIFACT_ROOT, payload));
    }

    function testWireFormatEmptyPayloadZeroRoot() public {
        address echo = address(new EchoGkVm());
        bytes memory out = gk.execExternal(echo, PROGRAM_HASH, bytes32(0), "");
        assertEq(out, abi.encodePacked(PROGRAM_HASH, bytes32(0)));
        assertEq(out.length, 64);
    }

    function testStripsTagAndDecodes() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 11;
        ids[1] = 22;
        ids[2] = 33;
        address fixedVm = address(new FixedGkVm(abi.encodePacked(GKVM_OK_TAG, abi.encode(ids, uint256(42)))));
        bytes memory out = gk.execExternal(fixedVm, PROGRAM_HASH, ARTIFACT_ROOT, "");
        (uint256[] memory gotIds, uint256 gotN) = abi.decode(out, (uint256[], uint256));
        assertEq(gotIds, ids);
        assertEq(gotN, 42);
    }

    function testTagOnlyAnswerIsEmptyOutput() public {
        address fixedVm = address(new FixedGkVm(abi.encodePacked(GKVM_OK_TAG)));
        bytes memory out = gk.execExternal(fixedVm, PROGRAM_HASH, ARTIFACT_ROOT, "");
        assertEq(out.length, 0);
    }

    function testFuzzRoundTrip(bytes32 programHash, bytes32 artifactRoot, bytes memory payload) public {
        address echo = address(new EchoGkVm());
        bytes memory out = gk.execExternal(echo, programHash, artifactRoot, payload);
        assertEq(out, abi.encodePacked(programHash, artifactRoot, payload));
    }

    function testUnavailableAtCanonicalAddress() public {
        assertEq(GKVM_ADDRESS.code.length, 0);
        vm.expectRevert(GkVmUnavailable.selector);
        gk.execExternal(GKVM_ADDRESS, PROGRAM_HASH, ARTIFACT_ROOT, abi.encode(uint256(1)));
    }

    function testUnavailableOnEmptyReturndata() public {
        address fixedVm = address(new FixedGkVm(""));
        vm.expectRevert(GkVmUnavailable.selector);
        gk.execExternal(fixedVm, PROGRAM_HASH, ARTIFACT_ROOT, "");
    }

    function testUnavailableOnWrongTag() public {
        address fixedVm = address(new FixedGkVm(abi.encodePacked(bytes1(0x00), abi.encode(uint256(42)))));
        vm.expectRevert(GkVmUnavailable.selector);
        gk.execExternal(fixedVm, PROGRAM_HASH, ARTIFACT_ROOT, "");
    }

    function testBubblesGuestTrap() public {
        bytes memory reason = abi.encodeWithSelector(GkGuestTrap.selector, uint32(0xE0000002), bytes("bad page"));
        address reverting = address(new RevertingGkVm(reason));
        vm.expectRevert(reason);
        gk.execExternal(reverting, PROGRAM_HASH, ARTIFACT_ROOT, "");
    }

    function testBubblesOutOfCycles() public {
        bytes memory reason =
            abi.encodeWithSelector(GkGuestOutOfCycles.selector, uint64(8_000_000_157), uint64(4_000_000));
        address reverting = address(new RevertingGkVm(reason));
        vm.expectRevert(reason);
        gk.execExternal(reverting, PROGRAM_HASH, ARTIFACT_ROOT, "");
    }

    function testBubblesParameterlessErrors() public {
        bytes4[3] memory selectors = [GkVmInputOverflow.selector, GkVmOutputOverflow.selector, GkVmStaticOnly.selector];
        for (uint256 i = 0; i < selectors.length; i++) {
            address reverting = address(new RevertingGkVm(abi.encodePacked(selectors[i])));
            vm.expectRevert(selectors[i]);
            gk.execExternal(reverting, PROGRAM_HASH, ARTIFACT_ROOT, "");
        }
    }

    function testBubblesEmptyRevert() public {
        address reverting = address(new RevertingGkVm(""));
        vm.expectRevert(bytes(""));
        gk.execExternal(reverting, PROGRAM_HASH, ARTIFACT_ROOT, "");
    }
}
