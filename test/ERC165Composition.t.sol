// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {SchnorrStakeRegistry} from "../src/SchnorrStakeRegistry.sol";
import {GasKillerNestedSDK} from "../src/GasKillerNestedSDK.sol";
import {IGasKillerSDK} from "../src/interface/IGasKillerSDK.sol";
import {IGasKillerNested} from "../src/interface/IGasKillerNested.sol";
import {IGasKillerSDKBatch} from "../src/interface/IGasKillerSDKBatch.sol";
import {IGasKillerValueBound} from "../src/interface/IGasKillerValueBound.sol";

/// A target that inherits the SDK and an OpenZeppelin module, resolving the clash the way
/// every OpenZeppelin module documents: one override that defers entirely to `super`.
/// Both inheritance orders appear below because C3 walks them in opposite directions, and
/// an integrator picks the order for unrelated reasons.
contract SdkFirstNft is GasKillerSDK, ERC721 {
    constructor(address registry) ERC721("SdkFirst", "SF") {
        _setSchnorrRegistry(registry);
    }

    function supportsInterface(bytes4 interfaceId) public view override(GasKillerSDK, ERC721) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

contract Erc721FirstNft is ERC721, GasKillerSDK {
    constructor(address registry) ERC721("Erc721First", "EF") {
        _setSchnorrRegistry(registry);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, GasKillerSDK) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

contract NestedNft is GasKillerNestedSDK, ERC721 {
    constructor(address registry) ERC721("Nested", "NS") {
        _setSchnorrRegistry(registry);
    }

    function supportsInterface(bytes4 interfaceId) public view override(GasKillerNestedSDK, ERC721) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

/// The router gates every submission on an ERC-165 probe, so an SDK interface ID that a
/// target fails to report is indistinguishable from a target that does not implement the
/// SDK at all: the round is rejected before any signature is checked. A target composing
/// the SDK with another ERC-165 module must therefore report the union of both ID sets.
contract ERC165CompositionTest is Test {
    address registry = address(new SchnorrStakeRegistry(2, 3, address(this), 0));

    function test_sdkFirst_reportsUnionOfInterfaceIds() public {
        SdkFirstNft target = new SdkFirstNft(registry);

        assertTrue(target.supportsInterface(type(IGasKillerSDK).interfaceId), "gas killer id");
        assertTrue(target.supportsInterface(type(IGasKillerSDKBatch).interfaceId), "batch id");
        assertTrue(target.supportsInterface(type(IGasKillerValueBound).interfaceId), "value-bound id");
        assertFalse(target.supportsInterface(type(IGasKillerNested).interfaceId), "nested is opt-in");
        assertTrue(target.supportsInterface(type(IERC721).interfaceId), "erc721 id");
        assertTrue(target.supportsInterface(type(IERC721Metadata).interfaceId), "erc721 metadata id");
        assertTrue(target.supportsInterface(type(IERC165).interfaceId), "erc165 id");
        assertFalse(target.supportsInterface(0xffffffff), "invalid id");
    }

    function test_erc721First_reportsUnionOfInterfaceIds() public {
        Erc721FirstNft target = new Erc721FirstNft(registry);

        assertTrue(target.supportsInterface(type(IGasKillerSDK).interfaceId), "gas killer id");
        assertTrue(target.supportsInterface(type(IGasKillerSDKBatch).interfaceId), "batch id");
        assertTrue(target.supportsInterface(type(IGasKillerValueBound).interfaceId), "value-bound id");
        assertFalse(target.supportsInterface(type(IGasKillerNested).interfaceId), "nested is opt-in");
        assertTrue(target.supportsInterface(type(IERC721).interfaceId), "erc721 id");
        assertTrue(target.supportsInterface(type(IERC721Metadata).interfaceId), "erc721 metadata id");
        assertTrue(target.supportsInterface(type(IERC165).interfaceId), "erc165 id");
        assertFalse(target.supportsInterface(0xffffffff), "invalid id");
    }

    function test_nested_reportsUnionOfInterfaceIds() public {
        NestedNft target = new NestedNft(registry);

        assertTrue(target.supportsInterface(type(IGasKillerSDK).interfaceId), "gas killer id");
        assertTrue(target.supportsInterface(type(IGasKillerSDKBatch).interfaceId), "batch id");
        assertTrue(target.supportsInterface(type(IGasKillerValueBound).interfaceId), "value-bound id");
        assertTrue(target.supportsInterface(type(IGasKillerNested).interfaceId), "nested id");
        assertTrue(target.supportsInterface(type(IERC721).interfaceId), "erc721 id");
        assertTrue(target.supportsInterface(type(IERC165).interfaceId), "erc165 id");
        assertFalse(target.supportsInterface(0xffffffff), "invalid id");
    }
}
