// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Interface for the initial offering contract
interface ILuxuryAssetOffering {
    struct AssetOwner {
        address ownerAddress;
        uint256 shares;
        bool exists;
    }
    
    function getAssetBasicDetails(uint256 _assetId) external view returns (
        address originalOwner,
        string memory name,
        uint256 totalShares,
        uint256 sharesRemaining,
        uint256 minimumTotalPrice,
        bool biddingClosed,
        uint256 biddingEndTime
    );
    
    function getAssetOwners(uint256 _assetId) external view returns (
        address[] memory ownerAddresses,
        uint256[] memory ownerShares
    );
    
    function getLatestAssetCount() external view returns (uint256);
}

contract LuxuryAssetSecondaryMarket is ReentrancyGuard {
    using SafeMath for uint256;
    
    ILuxuryAssetOffering public initialOfferingContract;
    
    struct SecondaryListing {
        uint256 assetId;
        address seller;
        uint256 minPrice;
        bool isActive;
        bool isCompleted;
    }
    
    struct SecondaryBid {
        address bidder;
        uint256 bidAmount;
        bool isActive;
    }
    
    // Track ownership changes that occur in the secondary market
    struct OwnershipRecord {
        mapping(address => uint256) shares;
        address[] owners;
        bool initialized;
    }
    
    mapping(uint256 => SecondaryListing) public listings;
    mapping(uint256 => SecondaryBid[]) public listingBids;
    uint256 public listingCount;
    
    // Track current ownership state in this contract
    mapping(uint256 => OwnershipRecord) private assetOwnership;
    
    event ListingCreated(uint256 indexed listingId, uint256 indexed assetId, address indexed seller, uint256 minPrice, uint256 biddingEndTime);
    event BidPlaced(uint256 indexed listingId, address indexed bidder, uint256 bidAmount);
    event ListingCompleted(uint256 indexed listingId, bool successful, address winner, uint256 amount);
    event ListingCancelled(uint256 indexed listingId);
    event RefundIssued(address indexed bidder, uint256 amount);
    event OwnershipUpdated(uint256 indexed assetId, address indexed from, address indexed to);
    
    constructor(address _initialOfferingAddress) {
        initialOfferingContract = ILuxuryAssetOffering(_initialOfferingAddress);
    }
    
    // Initialize ownership data for a specific asset from the initial offering contract
    function initializeAssetOwnership(uint256 _assetId) public {
        require(!assetOwnership[_assetId].initialized, "Asset already initialized");
        
        (address[] memory ownerAddresses, uint256[] memory ownerShares) = initialOfferingContract.getAssetOwners(_assetId);
        
        for (uint256 i = 0; i < ownerAddresses.length; i++) {
            if (ownerShares[i] > 0) {
                assetOwnership[_assetId].shares[ownerAddresses[i]] = ownerShares[i];
                assetOwnership[_assetId].owners.push(ownerAddresses[i]);
            }
        }
        
        assetOwnership[_assetId].initialized = true;
    }
    
    // Create a secondary market listing for one share
    function createListing(
        uint256 _assetId,
        uint256 _minPrice,
        uint256 _biddingDuration
    ) external nonReentrant {
        require(_minPrice > 0, "Minimum price must be positive");
        
        // Initialize asset ownership if not already done
        if (!assetOwnership[_assetId].initialized) {
            initializeAssetOwnership(_assetId);
        }
        
        // Verify seller owns at least one share
        require(assetOwnership[_assetId].shares[msg.sender] >= 1, "Must own at least 1 share to sell");
        
        listingCount++;
        
        listings[listingCount] = SecondaryListing({
            assetId: _assetId,
            seller: msg.sender,
            minPrice: _minPrice,
            isActive: true,
            isCompleted: false
        });
        
        emit ListingCreated(listingCount, _assetId, msg.sender, _minPrice, block.timestamp + _biddingDuration);
    }
    
    // Place a bid on a secondary market listing
    function placeBid(uint256 _listingId) external payable nonReentrant {
        SecondaryListing storage listing = listings[_listingId];
        
        require(listing.isActive, "Listing not active");
        require(!listing.isCompleted, "Listing already completed");
        require(msg.sender != listing.seller, "Seller cannot bid on own listing");
        require(msg.value >= listing.minPrice, "Bid below minimum price");
        
        listingBids[_listingId].push(SecondaryBid({
            bidder: msg.sender,
            bidAmount: msg.value,
            isActive: true
        }));
        
        emit BidPlaced(_listingId, msg.sender, msg.value);
    }
    
    // Execute a secondary market listing (finalize bidding)
    function executeListing(uint256 _listingId) external nonReentrant {
        SecondaryListing storage listing = listings[_listingId];
        
        require(listing.isActive, "Listing not active");
        require(!listing.isCompleted, "Listing already completed");
        require(msg.sender == listing.seller, "You cannot execute");
        
        // Mark listing as completed
        listing.isActive = false;
        listing.isCompleted = true;
        
        // Find highest bid
        uint256 highestBidAmount = 0;
        address highestBidder = address(0);
        uint256 highestBidIndex = 0;
        bool foundBid = false;
        
        for (uint256 i = 0; i < listingBids[_listingId].length; i++) {
            SecondaryBid storage bid = listingBids[_listingId][i];
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
            
            // Update ownership records
            _transferShare(listing.assetId, listing.seller, highestBidder);
            
            emit ListingCompleted(_listingId, true, highestBidder, highestBidAmount);
            
            // Refund unsuccessful bids
            _refundUnsuccessfulBids(_listingId, highestBidIndex);
        } else {
            // No valid bid, refund all bids
            _refundAllBids(_listingId);
            emit ListingCompleted(_listingId, false, address(0), 0);
        }
    }
    
    // Cancel a listing before bidding ends
    function cancelListing(uint256 _listingId) external nonReentrant {
        SecondaryListing storage listing = listings[_listingId];
        
        require(msg.sender == listing.seller, "Only seller can cancel");
        require(listing.isActive, "Listing not active");
        require(!listing.isCompleted, "Listing already completed");
        
        listing.isActive = false;
        listing.isCompleted = true;
        
        // Refund all bids
        _refundAllBids(_listingId);
        
        emit ListingCancelled(_listingId);
    }
    
    // Internal function to transfer ownership of one share
    function _transferShare(uint256 _assetId, address _from, address _to) internal {
        // Ensure asset ownership is initialized
        if (!assetOwnership[_assetId].initialized) {
            initializeAssetOwnership(_assetId);
        }
        
        // Decrease seller's shares
        assetOwnership[_assetId].shares[_from] = assetOwnership[_assetId].shares[_from].sub(1);
        
        // If buyer is a new owner, add them to the owners list
        if (assetOwnership[_assetId].shares[_to] == 0) {
            assetOwnership[_assetId].owners.push(_to);
        }
        
        // Increase buyer's shares
        assetOwnership[_assetId].shares[_to] = assetOwnership[_assetId].shares[_to].add(1);
        
        // Remove seller from owners list if they have no more shares
        if (assetOwnership[_assetId].shares[_from] == 0) {
            for (uint256 i = 0; i < assetOwnership[_assetId].owners.length; i++) {
                if (assetOwnership[_assetId].owners[i] == _from) {
                    // Replace with last element and pop
                    assetOwnership[_assetId].owners[i] = assetOwnership[_assetId].owners[assetOwnership[_assetId].owners.length - 1];
                    assetOwnership[_assetId].owners.pop();
                    break;
                }
            }
        }
        
        emit OwnershipUpdated(_assetId, _from, _to);
    }
    
    // Internal function to refund all unsuccessful bids
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
    
    // Internal function to refund all bids
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
    
    // View function to get active listings
    function getActiveListings() external view returns (
        uint256[] memory listingIds,
        uint256[] memory assetIds,
        address[] memory sellers,
        uint256[] memory minPrices,
        uint256[] memory endTimes
    ) {
        // Count active listings
        uint256 activeCount = 0;
        for (uint256 i = 1; i <= listingCount; i++) {
            if (listings[i].isActive) {
                activeCount++;
            }
        }
        
        // Initialize arrays
        listingIds = new uint256[](activeCount);
        assetIds = new uint256[](activeCount);
        sellers = new address[](activeCount);
        minPrices = new uint256[](activeCount);
        
        // Populate arrays
        uint256 index = 0;
        for (uint256 i = 1; i <= listingCount; i++) {
            if (listings[i].isActive) {
                listingIds[index] = i;
                assetIds[index] = listings[i].assetId;
                sellers[index] = listings[i].seller;
                minPrices[index] = listings[i].minPrice;
                index++;
            }
        }
        
        return (listingIds, assetIds, sellers, minPrices, endTimes);
    }
    
    // View function to get listing details
    function getListingDetails(uint256 _listingId) external view returns (
        uint256 assetId,
        address seller,
        uint256 minPrice,
        bool isActive,
        bool isCompleted
    ) {
        SecondaryListing storage listing = listings[_listingId];
        return (
            listing.assetId,
            listing.seller,
            listing.minPrice,
            listing.isActive,
            listing.isCompleted
        );
    }
    
    // View function to get all bids for a listing
    function getListingBids(uint256 _listingId) external view returns (
        address[] memory bidders,
        uint256[] memory amounts
    ) {
        SecondaryBid[] storage bids = listingBids[_listingId];
        
        // Count active bids
        uint256 activeBidCount = 0;
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive) {
                activeBidCount++;
            }
        }
        
        // Initialize arrays
        bidders = new address[](activeBidCount);
        amounts = new uint256[](activeBidCount);
        
        // Populate arrays
        uint256 index = 0;
        for (uint256 i = 0; i < bids.length; i++) {
            if (bids[i].isActive) {
                bidders[index] = bids[i].bidder;
                amounts[index] = bids[i].bidAmount;
                index++;
            }
        }
        
        return (bidders, amounts);
    }
    
    // View function to get an asset's current owners in the secondary market
    function getAssetOwners(uint256 _assetId) external view returns (
        address[] memory owners,
        uint256[] memory shares
    ) {
        if (!assetOwnership[_assetId].initialized) {
            // Return empty arrays if not initialized
            owners = new address[](0);
            shares = new uint256[](0);
            return (owners, shares);
        }
        
        uint256 ownerCount = assetOwnership[_assetId].owners.length;
        owners = new address[](ownerCount);
        shares = new uint256[](ownerCount);
        
        for (uint256 i = 0; i < ownerCount; i++) {
            address owner = assetOwnership[_assetId].owners[i];
            owners[i] = owner;
            shares[i] = assetOwnership[_assetId].shares[owner];
        }
        
        return (owners, shares);
    }
    
    // View function to check shares owned by an address
    function getSharesOwned(uint256 _assetId, address _owner) external view returns (uint256) {
        if (!assetOwnership[_assetId].initialized) {
            // Get from initial contract if not initialized in secondary market
            (address[] memory ownerAddresses, uint256[] memory ownerShares) = initialOfferingContract.getAssetOwners(_assetId);
            
            for (uint256 i = 0; i < ownerAddresses.length; i++) {
                if (ownerAddresses[i] == _owner) {
                    return ownerShares[i];
                }
            }
            return 0;
        }
        
        return assetOwnership[_assetId].shares[_owner];
    }
}
