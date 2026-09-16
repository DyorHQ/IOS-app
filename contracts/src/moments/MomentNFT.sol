// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MomentTypes} from "./interfaces/IMoments.sol";

/// @notice The per-Moment collectible: a transferable ERC-721 whose token id IS the collector's edition rank
///         (#1, #2, ...). Minted only by the collect contract while the Moment is Collecting; the collection is
///         closed at graduation (by the executor) or at expiry (by the collect contract) and can never mint again. Provenance is written once
///         at construction and has no setter. Metadata is fully on-chain (no server dependency).
contract MomentNFT is ERC721Enumerable {
    using Strings for uint256;

    uint256 public constant MAX_BATCH = MomentTypes.MAX_BATCH;

    uint256 public immutable momentId;
    address public immutable creator;
    address public immutable collect; // the only minter; also closes on expiry
    address public immutable graduation; // closes at graduation

    MomentTypes.Provenance private _provenance;
    uint256 public totalMinted;
    bool public closed;

    event Closed(uint256 totalMinted);

    error NotCollect();
    error NotCloser();
    error CollectionClosed();
    error BadQuantity();
    error ZeroAddress();

    constructor(
        uint256 _momentId,
        string memory name_,
        string memory symbol_,
        address _creator,
        address _collect,
        address _graduation,
        MomentTypes.Provenance memory prov
    ) ERC721(name_, symbol_) {
        if (_creator == address(0) || _collect == address(0) || _graduation == address(0)) revert ZeroAddress();
        momentId = _momentId;
        creator = _creator;
        collect = _collect;
        graduation = _graduation;
        _provenance = prov;
    }

    /// @notice Mints `quantity` sequential editions to `to`; returns the first rank minted.
    function mint(address to, uint256 quantity) external returns (uint256 firstRank) {
        if (msg.sender != collect) revert NotCollect();
        if (closed) revert CollectionClosed();
        if (quantity == 0 || quantity > MAX_BATCH) revert BadQuantity();
        firstRank = totalMinted + 1;
        totalMinted += quantity;
        for (uint256 i = 0; i < quantity; i++) {
            _safeMint(to, firstRank + i);
        }
    }

    /// @notice Fixes the edition size forever: at graduation (executor) or at expiry (collect contract).
    function close() external {
        if (msg.sender != graduation && msg.sender != collect) revert NotCloser();
        if (closed) return;
        closed = true;
        emit Closed(totalMinted);
    }

    function provenance() external view returns (MomentTypes.Provenance memory) {
        return _provenance;
    }

    /// @notice A page of `owner`'s token ids (ranks), for wallets without an indexer.
    function tokensOfOwner(address owner, uint256 offset, uint256 limit) external view returns (uint256[] memory ids) {
        uint256 n = balanceOf(owner);
        if (offset >= n) return ids;
        uint256 end = offset + limit > n ? n : offset + limit;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = tokenOfOwnerByIndex(owner, i);
        }
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        MomentTypes.Provenance memory p = _provenance;
        bytes memory json = abi.encodePacked(
            '{"name":"',
            _json(name()),
            " #",
            tokenId.toString(),
            '","description":"A collected DyorHQ Moment. Edition #',
            tokenId.toString(),
            closed ? " of " : " (open edition)",
            closed ? totalMinted.toString() : "",
            '","image":"',
            _json(p.mediaURI),
            '","attributes":[{"trait_type":"Rank","value":',
            tokenId.toString(),
            '},{"trait_type":"Place","value":"',
            _json(p.place),
            '"},{"trait_type":"Date","display_type":"date","value":',
            uint256(p.date).toString(),
            '},{"trait_type":"Creator","value":"',
            Strings.toHexString(creator),
            '"},{"trait_type":"Media hash","value":"',
            Strings.toHexString(uint256(p.mediaHash), 32),
            '"}]}'
        );
        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(json)));
    }

    /// @dev Escapes a creator-supplied string for embedding in the metadata JSON: `"` and `\` are backslash-escaped
    ///      and control characters become `\u00XX`, so a quote in a name or place can never break the document.
    function _json(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 extra;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\") extra += 1;
            else if (c < 0x20) extra += 5;
        }
        if (extra == 0) return s;
        bytes memory out = new bytes(b.length + extra);
        bytes16 hexChars = "0123456789abcdef";
        uint256 j;
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == '"' || c == "\\") {
                out[j++] = "\\";
                out[j++] = c;
            } else if (c < 0x20) {
                out[j++] = "\\";
                out[j++] = "u";
                out[j++] = "0";
                out[j++] = "0";
                out[j++] = hexChars[uint8(c) >> 4];
                out[j++] = hexChars[uint8(c) & 0x0f];
            } else {
                out[j++] = c;
            }
        }
        return string(out);
    }

    // ---- OZ multiple-inheritance plumbing ----
    function _update(address to, uint256 tokenId, address auth) internal override(ERC721Enumerable) returns (address) {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value) internal override(ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
