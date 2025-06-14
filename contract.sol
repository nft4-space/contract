// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Royalty.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title PlanetNFT
 * @author NFT4.Space
 * @notice Manages minting and management of Planet NFTs with predefined rarities, payable in ETH.
 * @dev Extends OpenZeppelin's ERC721 suite with custom features for rarity, batch minting, and royalties.
 * The rarity of each NFT is determined by a predefined, shuffled sequence set by the owner, ensuring even distribution.
 */
contract PlanetNFT is ERC721Royalty, Ownable, ReentrancyGuard, Pausable {
    using Strings for uint256;

    /// @notice Counter for the next token ID to be minted, starts at 1.
    uint256 private _tokenIdCounter;

    /// @notice Price in wei to mint one NFT.
    uint256 public mintPrice;

    /// @notice Maximum number of NFTs that can be minted initially.
    uint256 public maxSupply = 300;

    /// @notice Rarity levels for Planet NFTs.
    enum Rarity { Common, Uncommon, Rare, Epic, Legendary }

    /// @notice Mapping of token ID to its rarity.
    mapping(uint256 => Rarity) public rarity;

    /// @dev Base URI for NFT metadata.
    string private _baseURIextended;

    /// @dev Pre-set sequence of rarities for all NFTs, shuffled off-chain for randomness.
    Rarity[] private raritySequence;

    /// @dev Current index in the raritySequence.
    uint256 private rarityIndex;

    /// @notice Delay for royalty changes (48 hours).
    uint256 public royaltyChangeDelay = 2 days;

    /// @notice Struct for pending royalty changes.
    struct RoyaltyChange {
        address receiver;
        uint96 feeNumerator;
        uint256 executableAt;
    }

    /// @notice Pending royalty change proposal.
    RoyaltyChange public pendingRoyalty;

    /// @notice Flag indicating if the base URI is frozen.
    bool public baseURIFrozen = false;

    /// @notice Tracks the number of NFTs minted per user via mintPlanet.
    mapping(address => uint256) public mintedPerUser;

    /// @notice Maximum number of NFTs a user can mint via mintPlanet.
    uint256 public constant MAX_PER_USER = 10;

    /// @dev Mapping for specific URIs set by the owner for individual tokens.
    mapping(uint256 => string) private _specificURIs;

    /// @notice Maximum batch size for batchMint to manage gas usage.
    uint256 public maxBatchSize = 50;

    // Events
    event PlanetMinted(uint256 indexed tokenId, address indexed to, Rarity rarity);
    event BatchMinted(uint256[] tokenIds, address[] to, Rarity[] rarities);
    event RaritySequenceSet(uint256 length);
    event RaritySequenceExtended(uint256 additionalLength);
    event RoyaltyChangeProposed(address receiver, uint96 feeNumerator, uint256 executableAt);
    event RoyaltyChanged(address receiver, uint96 feeNumerator);
    event RoyaltyChangeCancelled();
    event MintPriceSet(uint256 newMintPrice);
    event MaxSupplySet(uint256 newMaxSupply);
    event BaseURISet(string newBaseURI);
    event BaseURIFrozen();
    event BaseURIVerification(string baseURI);

    /**
     * @notice Initializes the contract with token IDs starting at 1 and a 5% royalty.
     */
    constructor() ERC721("NFT4.Space Planets", "N4SP") Ownable(msg.sender) {
        _tokenIdCounter = 1;
        _setDefaultRoyalty(msg.sender, 500); // 5% royalty
        mintPrice = 140000000000000000; // 0.14 ETH
    }

    /*** Owner-Only Functions ***/

    /**
     * @notice Sets the mint price for NFTs in wei.
     * @param _mintPrice New mint price in wei.
     */
    function setMintPrice(uint256 _mintPrice) external onlyOwner {
        mintPrice = _mintPrice;
        emit MintPriceSet(_mintPrice);
    }

    /**
     * @notice Sets the base URI for metadata.
     * @param baseURI_ New base URI.
     */
    function setBaseURI(string memory baseURI_) external onlyOwner {
        require(!baseURIFrozen, "Base URI is frozen");
        require(bytes(baseURI_).length > 0, "Base URI cannot be empty");
        string memory normalized = bytes(baseURI_)[bytes(baseURI_).length - 1] == bytes1('/')
            ? baseURI_
            : string(abi.encodePacked(baseURI_, "/"));
        _baseURIextended = normalized;
        emit BaseURISet(normalized);
        emit BaseURIVerification(normalized);
    }

    /**
     * @notice Freezes the base URI.
     */
    function freezeBaseURI() external onlyOwner {
        require(!baseURIFrozen, "Base URI already frozen");
        baseURIFrozen = true;
        emit BaseURIFrozen();
    }

    /**
     * @notice Sets the maximum supply of NFTs.
     * @param _maxSupply New maximum supply.
     */
    function setMaxSupply(uint256 _maxSupply) external onlyOwner {
        require(_maxSupply >= _tokenIdCounter - 1, "Cannot set below current supply");
        if (raritySequence.length > 0) {
            require(_maxSupply <= raritySequence.length, "Cannot exceed rarity sequence length");
        }
        maxSupply = _maxSupply;
        emit MaxSupplySet(_maxSupply);
    }

    /**
     * @notice Sets the rarity sequence for NFTs.
     * @param _rarities Array of rarity values, shuffled off-chain.
     */
    function setRaritySequence(Rarity[] calldata _rarities) external onlyOwner {
        require(raritySequence.length == 0, "Rarity sequence already set");
        require(_rarities.length == maxSupply, "Rarity sequence length must match maxSupply");
        for (uint256 i = 0; i < _rarities.length; i++) {
            raritySequence.push(_rarities[i]);
        }
        rarityIndex = 0;
        emit RaritySequenceSet(_rarities.length);
    }

    /**
     * @notice Resets the rarity sequence before minting begins.
     * @param _rarities New array of rarity values.
     */
    function resetRaritySequence(Rarity[] calldata _rarities) external onlyOwner {
        require(_tokenIdCounter == 1, "Can only reset before minting begins");
        delete raritySequence;
        for (uint256 i = 0; i < _rarities.length; i++) {
            raritySequence.push(_rarities[i]);
        }
        rarityIndex = 0;
        maxSupply = _rarities.length;
        emit RaritySequenceSet(_rarities.length);
    }

    /**
     * @notice Extends the rarity sequence to allow minting more NFTs.
     * @param _additionalRarities Array of additional rarity values to append.
     */
    function extendRaritySequence(Rarity[] calldata _additionalRarities) external onlyOwner {
        require(_additionalRarities.length > 0, "Additional rarities cannot be empty");
        for (uint256 i = 0; i < _additionalRarities.length; i++) {
            raritySequence.push(_additionalRarities[i]);
        }
        maxSupply += _additionalRarities.length;
        emit RaritySequenceExtended(_additionalRarities.length);
    }

    /**
     * @notice Sets the URI for a specific token.
     * @param tokenId Token ID to update.
     * @param uri New URI for the token.
     */
    function setTokenURI(uint256 tokenId, string memory uri) external onlyOwner {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        _specificURIs[tokenId] = uri;
    }

    /**
     * @notice Proposes a royalty change with a timelock.
     * @param receiver New royalty recipient.
     * @param feeNumerator New royalty fee numerator (max 1000 for 10%).
     */
    function proposeRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        require(pendingRoyalty.executableAt == 0, "Royalty change already pending");
        require(feeNumerator <= 1000, "Royalty fee exceeds maximum (10%)");
        uint256 executableAt = block.timestamp + royaltyChangeDelay;
        pendingRoyalty = RoyaltyChange(receiver, feeNumerator, executableAt);
        emit RoyaltyChangeProposed(receiver, feeNumerator, executableAt);
    }

    /**
     * @notice Executes a pending royalty change.
     */
    function executeRoyalty() external onlyOwner {
        require(block.timestamp >= pendingRoyalty.executableAt, "Timelock not yet elapsed");
        require(pendingRoyalty.executableAt != 0, "No pending royalty change");
        _setDefaultRoyalty(pendingRoyalty.receiver, pendingRoyalty.feeNumerator);
        emit RoyaltyChanged(pendingRoyalty.receiver, pendingRoyalty.feeNumerator);
        delete pendingRoyalty;
    }

    /**
     * @notice Cancels a pending royalty change.
     */
    function cancelRoyaltyChange() external onlyOwner {
        require(pendingRoyalty.executableAt != 0, "No pending royalty change to cancel");
        delete pendingRoyalty;
        emit RoyaltyChangeCancelled();
    }

    /**
     * @notice Pauses the contract.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses the contract.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Withdraws ETH from the contract to the owner.
     */
    function withdraw() external onlyOwner {
        (bool success, ) = payable(owner()).call{value: address(this).balance}("");
        require(success, "ETH withdrawal failed");
    }

    /*** Minting Functions ***/

    /**
     * @notice Mints a single NFT to the caller, requiring payment in ETH.
     */
    function mintPlanet() external payable nonReentrant whenNotPaused {
        _checkMintConditions(1);
        require(mintedPerUser[msg.sender] < MAX_PER_USER, "User has exceeded mint limit");
        require(msg.value >= mintPrice, "Insufficient ETH sent");
        uint256 tokenId = _tokenIdCounter;
        Rarity _rarity = raritySequence[rarityIndex];
        _safeMint(msg.sender, tokenId);
        rarity[tokenId] = _rarity;
        _tokenIdCounter += 1;
        rarityIndex += 1;
        mintedPerUser[msg.sender] += 1;
        emit PlanetMinted(tokenId, msg.sender, _rarity);
    }

    /**
     * @notice Batch mints NFTs to specified addresses (owner only).
     * @param to Array of recipient addresses.
     */
    function batchMint(address[] calldata to) external onlyOwner nonReentrant whenNotPaused {
        require(to.length <= maxBatchSize, "Batch size exceeds maximum limit");
        _checkMintConditions(to.length);
        uint256 startTokenId = _tokenIdCounter;
        uint256[] memory tokenIds = new uint256[](to.length);
        Rarity[] memory rarities = new Rarity[](to.length);
        for (uint256 i = 0; i < to.length; i++) {
            require(to[i] != address(0), "Cannot mint to zero address");
            uint256 tokenId = startTokenId + i;
            Rarity _rarity = raritySequence[rarityIndex + i];
            _safeMint(to[i], tokenId);
            rarity[tokenId] = _rarity;
            tokenIds[i] = tokenId;
            rarities[i] = _rarity;
        }
        _tokenIdCounter = startTokenId + to.length;
        rarityIndex += to.length;
        emit BatchMinted(tokenIds, to, rarities);
    }

    /*** Internal Functions ***/

    /**
     * @dev Checks minting conditions.
     * @param count Number of NFTs to mint.
     */
    function _checkMintConditions(uint256 count) internal view {
        require(raritySequence.length Doctorate, "Rarity sequence not set");
        require(bytes(_baseURIextended).length > 0, "Base URI not set");
        require(_tokenIdCounter + count - 1 <= maxSupply, "Maximum supply reached");
        require(rarityIndex + count - 1 < raritySequence.length, "Rarity sequence exhausted");
    }

    /**
     * @dev Returns the base URI for token metadata.
     */
    function _baseURI() internal view virtual override returns (string memory) {
        return _baseURIextended;
    }

    /**
     * @dev Updates token ownership and handles burn logic.
     * @param to The address to transfer to (address(0) for burn).
     * @param tokenId The ID of the token.
     * @param auth The address authorized to perform the action.
     * @return The previous owner of the token.
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address previousOwner = super._update(to, tokenId, auth);
        if (to == address(0)) {
            delete rarity[tokenId];
            delete _specificURIs[tokenId];
        }
        return previousOwner;
    }

    /**
     * @dev Checks if the contract supports a given interface.
     * @param interfaceId The interface ID to check.
     * @return True if supported, false otherwise.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721Royalty) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /*** View Functions ***/

    /**
     * @notice Returns the URI for a given token ID.
     * @param tokenId Token ID to query.
     * @return Token URI string.
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        require(_ownerOf(tokenId) != address(0), "Token does not exist");
        string memory specificURI = _specificURIs[tokenId];
        if (bytes(specificURI).length > 0) {
            return specificURI;
        }
        return string(abi.encodePacked(_baseURIextended, Strings.toString(tokenId), ".json"));
    }

    /**
     * @notice Returns the current supply of minted NFTs.
     * @return Number of minted NFTs.
     */
    function currentSupply() external view returns (uint256) {
        return _tokenIdCounter - 1;
    }

    /**
     * @notice Returns the remaining supply of NFTs.
     * @return Number of remaining NFTs.
     */
    function remainingSupply() external view returns (uint256) {
        return maxSupply - (_tokenIdCounter - 1);
    }

    /**
     * @notice Returns the next token ID to be minted.
     * @return Next token ID.
     */
    function nextTokenId() external view returns (uint256) {
        return _tokenIdCounter;
    }

    /**
     * @notice Checks if a user can mint an NFT.
     * @param user Address to check.
     * @return True if user can mint, false otherwise.
     */
    function canMint(address user) external view returns (bool) {
        return !paused() &&
               raritySequence.length > 0 &&
               bytes(_baseURIextended).length > 0 &&
               _tokenIdCounter <= maxSupply &&
               rarityIndex < raritySequence.length &&
               mintedPerUser[user] < MAX_PER_USER;
    }

    // Receive function to accept ETH
    receive() external payable {}
}