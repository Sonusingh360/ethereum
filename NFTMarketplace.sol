// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title NFTMarketplace - Refactored with shared internal buy logic
 * Supports ERC-721 & ERC-1155, single + batch buy
 */
contract NFTMarketplace is Ownable, ReentrancyGuard {
    // ... (keep the same Listing struct, mappings, platformFee, feeRecipient, events)

    struct Listing {
        address seller;
        address tokenContract;
        uint256 tokenId;
        uint256 amount;
        uint256 price;
        bool isERC1155;
        bool active;
    }

    mapping(uint256 => Listing) public listings;
    uint256 public nextListingId;

    uint256 public platformFee = 250; // 2.5%
    address public feeRecipient;

    event Listed(uint256 indexed listingId, address indexed seller, address tokenContract, uint256 tokenId, uint256 amount, uint256 price, bool isERC1155);
    event Bought(uint256 indexed listingId, address indexed buyer, uint256 amountPaid);
    event BatchBought(address indexed buyer, uint256[] listingIds, uint256 totalPaid);
    event Cancelled(uint256 indexed listingId);
    event FeeUpdated(uint256 newFee);
    event FeeRecipientUpdated(address newRecipient);

    constructor(address _feeRecipient) Ownable(msg.sender) {
        feeRecipient = _feeRecipient;
    }

    // ────────────────────────────────────────────────
    // Listing & Cancel (unchanged)
    // ────────────────────────────────────────────────

    function list(address tokenContract, uint256 tokenId, uint256 amount, uint256 price, bool isERC1155) external nonReentrant {
        require(price > 0, "Price must be greater than zero");
        require(amount > 0, "Amount must be greater than zero");

        if (isERC1155) {
            IERC1155(tokenContract).safeTransferFrom(msg.sender, address(this), tokenId, amount, "");
        } else {
            require(amount == 1, "ERC-721 amount must be 1");
            IERC721(tokenContract).safeTransferFrom(msg.sender, address(this), tokenId);
        }

        uint256 listingId = nextListingId++;
        listings[listingId] = Listing({
            seller: msg.sender,
            tokenContract: tokenContract,
            tokenId: tokenId,
            amount: amount,
            price: price,
            isERC1155: isERC1155,
            active: true
        });

        emit Listed(listingId, msg.sender, tokenContract, tokenId, amount, price, isERC1155);
    }

    function cancel(uint256 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.seller == msg.sender, "Not the seller");
        require(listing.active, "Listing not active");

        if (listing.isERC1155) {
            IERC1155(listing.tokenContract).safeTransferFrom(address(this), msg.sender, listing.tokenId, listing.amount, "");
        } else {
            IERC721(listing.tokenContract).safeTransferFrom(address(this), msg.sender, listing.tokenId);
        }

        listing.active = false;
        emit Cancelled(listingId);
    }

    // ────────────────────────────────────────────────
    // Core Buy Logic (Internal - reusable)
    // ────────────────────────────────────────────────

    function _executeBuy(uint256 listingId, address buyer) internal {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing not active");

        uint256 fee = (listing.price * platformFee) / 10000;
        uint256 sellerAmount = listing.price - fee;

        // Transfer funds
        (bool sentFee,) = feeRecipient.call{value: fee}("");
        require(sentFee, "Fee transfer failed");

        (bool sentSeller,) = listing.seller.call{value: sellerAmount}("");
        require(sentSeller, "Seller transfer failed");

        // Transfer NFT
        if (listing.isERC1155) {
            IERC1155(listing.tokenContract).safeTransferFrom(address(this), buyer, listing.tokenId, listing.amount, "");
        } else {
            IERC721(listing.tokenContract).safeTransferFrom(address(this), buyer, listing.tokenId);
        }

        listing.active = false;
        emit Bought(listingId, buyer, listing.price);
    }

    // ────────────────────────────────────────────────
    // External Buy Functions
    // ────────────────────────────────────────────────

    /**
     * @dev Buy a single listing
     */
    function buy(uint256 listingId) external payable nonReentrant {
        Listing storage listing = listings[listingId];
        require(listing.active, "Listing not active");
        require(msg.value == listing.price, "Incorrect ETH amount");

        _executeBuy(listingId, msg.sender);
    }

    /**
     * @dev Batch buy multiple listings
     */
    function batchBuy(uint256[] calldata listingIds) external payable nonReentrant {
        uint256 totalPrice = 0;

        // First pass: calculate total and validate
        for (uint256 i = 0; i < listingIds.length; i++) {
            uint256 id = listingIds[i];
            Listing storage listing = listings[id];
            require(listing.active, "One or more listings inactive");
            totalPrice += listing.price;
        }

        require(msg.value == totalPrice, "Incorrect total ETH sent");

        // Second pass: execute buys
        for (uint256 i = 0; i < listingIds.length; i++) {
            _executeBuy(listingIds[i], msg.sender);
        }

        emit BatchBought(msg.sender, listingIds, totalPrice);
    }

    // Admin functions (unchanged)
    function setPlatformFee(uint256 newFee) external onlyOwner {
        require(newFee <= 1000, "Fee too high"); // max 10%
        platformFee = newFee;
        emit FeeUpdated(newFee);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Invalid address");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    receive() external payable {}
}
