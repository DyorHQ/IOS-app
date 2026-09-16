// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MomentsBase} from "./MomentsBase.sol";
import {MomentTypes} from "../../src/moments/interfaces/IMoments.sol";
import {MomentsFactory} from "../../src/moments/MomentsFactory.sol";
import {MomentCoin} from "../../src/moments/MomentCoin.sol";
import {MomentNFT} from "../../src/moments/MomentNFT.sol";

/// Phase 4 (v1.1): the on-chain metadata is valid JSON whatever the creator typed, and round-trips exactly.
contract NFTMetadataTest is MomentsBase {
    function _publishNamed(string memory name_, string memory place) internal returns (uint256 id, MomentNFT nft) {
        MomentsFactory.PublishParams memory p = _params(PRICE, 0, 77);
        p.name = name_;
        p.symbol = "WEIRD";
        p.provenance = MomentTypes.Provenance({mediaURI: 'ipfs://bafy"quoted', mediaHash: keccak256("x"), place: place, date: 1_779_900_000});
        vm.prank(creator);
        (uint256 i,, address n) = factory.publish(p);
        return (i, MomentNFT(n));
    }

    function test_tokenURI_is_valid_json_with_quotes_backslashes_and_control_chars() public {
        string memory name_ = 'Sun"rise \\ over Labadi';
        string memory place = "Accra \"old town\"\n(beach)";
        (uint256 id, MomentNFT nft) = _publishNamed(name_, place);
        _collect(id, alice, 1);
        string memory uri = nft.tokenURI(1);
        bytes memory raw = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        assertEq(string(_slice(raw, 0, prefix.length)), string(prefix));
        string memory json = string(_b64decode(_slice(raw, prefix.length, raw.length - prefix.length)));
        // forge's JSON parser rejects malformed documents; the fields must round-trip exactly
        assertEq(vm.parseJsonString(json, ".name"), string.concat(name_, " #1"));
        assertEq(vm.parseJsonString(json, ".image"), 'ipfs://bafy"quoted');
        assertEq(vm.parseJsonString(json, ".attributes[1].value"), place);
        assertEq(vm.parseJsonUint(json, ".attributes[0].value"), 1);
    }

    function test_tokenURI_plain_strings_unchanged_and_edition_size_after_close() public {
        (uint256 id, MomentNFT nft) = _publishNamed("Plain name", "Accra");
        _collect(id, alice, 2);
        string memory json = string(_b64decode(_slice(bytes(nft.tokenURI(2)), 29, bytes(nft.tokenURI(2)).length - 29)));
        assertEq(vm.parseJsonString(json, ".name"), "Plain name #2");
        assertTrue(_contains(json, "(open edition)"));
        _completeWithSingles(id, bob);
        json = string(_b64decode(_slice(bytes(nft.tokenURI(2)), 29, bytes(nft.tokenURI(2)).length - 29)));
        assertTrue(_contains(json, string.concat("Edition #2 of ", vm.toString(nft.totalMinted()))));
        vm.expectRevert(); // ERC721NonexistentToken
        nft.tokenURI(999);
    }

    // ---- helpers ----
    function _slice(bytes memory b, uint256 start, uint256 len) internal pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) out[i] = b[start + i];
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length && ok; j++) ok = h[i + j] == n[j];
            if (ok) return true;
        }
        return false;
    }

    function _b64decode(bytes memory data) internal pure returns (bytes memory out) {
        uint256 len = data.length;
        uint256 pad;
        if (len > 0 && data[len - 1] == "=") pad++;
        if (len > 1 && data[len - 2] == "=") pad++;
        out = new bytes(len / 4 * 3 - pad);
        uint256 o;
        for (uint256 i = 0; i < len; i += 4) {
            uint256 n = (_v(data[i]) << 18) | (_v(data[i + 1]) << 12) | (_v(data[i + 2]) << 6) | _v(data[i + 3]);
            if (o < out.length) out[o++] = bytes1(uint8(n >> 16));
            if (o < out.length) out[o++] = bytes1(uint8(n >> 8));
            if (o < out.length) out[o++] = bytes1(uint8(n));
        }
    }

    function _v(bytes1 c) internal pure returns (uint256) {
        if (c >= "A" && c <= "Z") return uint8(c) - 65;
        if (c >= "a" && c <= "z") return uint8(c) - 97 + 26;
        if (c >= "0" && c <= "9") return uint8(c) - 48 + 52;
        if (c == "+") return 62;
        if (c == "/") return 63;
        return 0; // '='
    }
}
