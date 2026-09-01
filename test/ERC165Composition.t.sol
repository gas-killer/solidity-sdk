// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

import {GasKillerSDK} from "../src/GasKillerSDK.sol";
import {IGasKillerSDK} from "../src/interface/IGasKillerSDK.sol";
import {SchnorrGasKillerSDK} from "../src/schnorr/SchnorrGasKillerSDK.sol";
import {ISchnorrGasKillerSDK} from "../src/schnorr/interface/ISchnorrGasKillerSDK.sol";
import {ISchnorrGasKillerSDKBatch} from "../src/schnorr/interface/ISchnorrGasKillerSDKBatch.sol";

/// A target that inherits the SDK and an OpenZeppelin module, resolving the clash the way
/// every OpenZeppelin module documents: one override that defers entirely to `super`.
/// Both inheritance orders appear below because C3 walks them in opposite directions, and
/// an integrator picks the order for unrelated reasons.
contract SdkFirstNft is GasKillerSDK, ERC721 {
    constructor() ERC721("SdkFirst", "SF") {}

    function supportsInterface(bytes4 interfaceId) public view override(GasKillerSDK, ERC721) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

contract Erc721FirstNft is ERC721, GasKillerSDK {
    constructor() ERC721("Erc721First", "EF") {}

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, GasKillerSDK) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

contract SchnorrSdkFirstNft is SchnorrGasKillerSDK, ERC721 {
    constructor() ERC721("SchnorrSdkFirst", "SSF") {}

    function supportsInterface(bytes4 interfaceId) public view override(SchnorrGasKillerSDK, ERC721) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

/// The router gates every submission on an ERC-165 probe, so an SDK interface ID that a
/// target fails to report is indistinguishable from a target that does not implement the
/// SDK at all: the round is rejected before any signature is checked. A target composing
/// the SDK with another ERC-165 module must therefore report the union of both ID sets.
contract ERC165CompositionTest is Test {
    function test_sdkFirst_reportsUnionOfInterfaceIds() public {
        SdkFirstNft target = new SdkFirstNft();

        assertTrue(target.supportsInterface(type(IGasKillerSDK).interfaceId), "gas killer id");
        assertTrue(target.supportsInterface(type(IERC721).interfaceId), "erc721 id");
        assertTrue(target.supportsInterface(type(IERC721Metadata).interfaceId), "erc721 metadata id");
        assertTrue(target.supportsInterface(type(IERC165).interfaceId), "erc165 id");
        assertFalse(target.supportsInterface(0xffffffff), "invalid id");
    }

    function test_erc721First_reportsUnionOfInterfaceIds() public {
        Erc721FirstNft target = new Erc721FirstNft();

        assertTrue(target.supportsInterface(type(IGasKillerSDK).interfaceId), "gas killer id");
        assertTrue(target.supportsInterface(type(IERC721).interfaceId), "erc721 id");
        assertTrue(target.supportsInterface(type(IERC721Metadata).interfaceId), "erc721 metadata id");
        assertTrue(target.supportsInterface(type(IERC165).interfaceId), "erc165 id");
        assertFalse(target.supportsInterface(0xffffffff), "invalid id");
    }

    function test_schnorrSdkFirst_reportsUnionOfInterfaceIds() public {
        SchnorrSdkFirstNft target = new SchnorrSdkFirstNft();

        assertTrue(target.supportsInterface(type(ISchnorrGasKillerSDK).interfaceId), "schnorr gas killer id");
        assertTrue(target.supportsInterface(type(ISchnorrGasKillerSDKBatch).interfaceId), "schnorr batch id");
        assertTrue(target.supportsInterface(type(IERC721).interfaceId), "erc721 id");
        assertTrue(target.supportsInterface(type(IERC721Metadata).interfaceId), "erc721 metadata id");
        assertTrue(target.supportsInterface(type(IERC165).interfaceId), "erc165 id");
        assertFalse(target.supportsInterface(0xffffffff), "invalid id");
    }
}
