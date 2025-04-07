// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract SecondaryMarket is ReentrancyGuard {
    using SafeMath for uint256;
    
    IERC721 public nftContract;
    
    struct Listing {
        uint256 tokenId;
        address seller;
        uint256 minPrice;
        bool isActive;
        bool isCompleted;
    }
    
    struct Bid {
        address bidder;
        uint256 bidAmount;
        bool isActive;
    }
    
    mapping(uint256 => Listing) public listings;
    mapping(uint256 => Bid[]) public listingBids;
    uint256 public listingCount;
    
    event ListingCreated(uint256 indexed listingId, uint256 indexed tokenId, address indexed seller, uint256 minPrice);
    event BidPlaced(uint256 indexed listingId, address indexed bidder, uint256 amount);
    event ListingCompleted(uint256 indexed listingId, bool successful, address winner, uint256 amount);
    event ListingCancelled(uint256 indexed listingId);
    event RefundIssued(address indexed bidder, uint256 amount);
    
    constructor(address _nftContractAddress) {
        nftContract = IERC721(_nftContractAddress);
    }
    
    function createListing(uint256 _tokenId, uint256 _minPrice) external nonReentrant {
        require(nftContract.ownerOf(_tokenId) == msg.sender, "Not the owner of this token");
        require(nftContract.isApprovedForAll(msg.sender, address(this)) || 
                nftContract.getApproved(_tokenId) == address(this), 
                "Contract not approved to transfer token");
        require(_minPrice > 0, "Minimum price must be positive");
        
        listingCount++;
        
        listings[listingCount] = Listing({
            tokenId: _tokenId,
            seller: msg.sender,
            minPrice: _minPrice,
            isActive: true,
            isCompleted: false
        });
        
        emit ListingCreated(listingCount, _tokenId, msg.sender, _minPrice);
    }
    
    function placeBid(uint256 _listingId) external payable nonReentrant {
        Listing storage listing = listings[_listingId];
        
        require(listing.isActive, "Listing not active");
        require(!listing.isCompleted, "Listing already completed");
        require(msg.sender != listing.seller, "Seller cannot bid on own listing");
        require(msg.value >= listing.minPrice, "Bid below minimum price");
        
        listingBids[_listingId].push(Bid({
            bidder: msg.sender,
            bidAmount: msg.value,
            isActive: true
        }));
        
        emit BidPlaced(_listingId, msg.sender, msg.value);
    }
    
    function executeListing(uint256 _listingId) external nonReentrant {
        Listing storage listing = listings[_listingId];
        
        require(listing.isActive, "Listing not active");
        require(!listing.isCompleted, "Listing already completed");
        require( msg.sender == listing.seller, "Unauthorized to execute");
        
        // Mark listing as completed
        listing.isActive = false;
        listing.isCompleted = true;
        
        // Find highest bid
        uint256 highestBidAmount = 0;
        address highestBidder = address(0);
        uint256 highestBidIndex = 0;
        bool foundBid = false;
        
        for (uint256 i = 0; i < listingBids[_listingId].length; i++) {
            Bid storage bid = listingBids[_listingId][i];
            if (bid.isActive && bid.bidAmount > highestBidAmount) {
                highestBidAmount = bid.bidAmount;
                highestBidder = bid.bidder;
                highestBidIndex = i;
                foundBid = true;
            }
        }
        
        // If valid bid found and meets minimum price
        if (foundBid && highestBidAmount >= listing.minPrice) {
            // Mark winning bid as inactive
            listingBids[_listingId][highestBidIndex].isActive = false;
            
            // Transfer payment to seller
            payable(listing.seller).transfer(highestBidAmount);
            
            // Transfer NFT to buyer
            nftContract.safeTransferFrom(listing.seller, highestBidder, listing.tokenId);
            
            emit ListingCompleted(_listingId, true, highestBidder, highestBidAmount);
            
            // Refund unsuccessful bids
            _refundUnsuccessfulBids(_listingId, highestBidIndex);
        } else {
            // No valid bid, refund all bids
            _refundAllBids(_listingId);
            emit ListingCompleted(_listingId, false, address(0), 0);
        }
    }
    
    function cancelListing(uint256 _listingId) external nonReentrant {
        Listing storage listing = listings[_listingId];
        
        require(msg.sender == listing.seller, "Only seller can cancel");
        require(listing.isActive, "Listing not active");
        require(!listing.isCompleted, "Listing already completed");
        
        listing.isActive = false;
        listing.isCompleted = true;
        
        // Refund all bids
        _refundAllBids(_listingId);
        
        emit ListingCancelled(_listingId);
    }
    
    function _refundUnsuccessfulBids(uint256 _listingId, uint256 _winningBidIndex) internal {
        for (uint256 i = 0; i < listingBids[_listingId].length; i++) {
            if (i != _winningBidIndex && listingBids[_listingId][i].isActive) {
                address bidder = listingBids[_listingId][i].bidder;
                uint256 amount = listingBids[_listingId][i].bidAmount;
                listingBids[_listingId][i].isActive = false;
                payable(bidder).transfer(amount);
                emit RefundIssued(bidder, amount);
            }
        }
    }
    
    function _refundAllBids(uint256 _listingId) internal {
        for (uint256 i = 0; i < listingBids[_listingId].length; i++) {
            if (listingBids[_listingId][i].isActive) {
                address bidder = listingBids[_listingId][i].bidder;
                uint256 amount = listingBids[_listingId][i].bidAmount;
                listingBids[_listingId][i].isActive = false;
                payable(bidder).transfer(amount);
                emit RefundIssued(bidder, amount);
            }
        }
    }
}
