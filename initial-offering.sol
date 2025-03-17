// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract LuxuryAssetOffering is ReentrancyGuard {
    using SafeMath for uint256;
    
    struct AssetOwner {
        address ownerAddress;
        uint256 shares;
        bool exists;
    }
    
    struct Asset {
        address originalOwner;     // Creator of the asset offering
        string name;
        uint256 totalShares;
        uint256 sharesRemaining;
        // uint256 minPricePerShare;
        uint256 minimumTotalPrice; // Minimum total price for the asset
        bool biddingClosed;
        uint256 biddingEndTime;
        address[] ownerAddresses;  // List of all owner addresses
        mapping(address => AssetOwner) owners; // Mapping to find owner details
    }
    
    struct Bid {
        address bidder;
        uint256 shareAmount;
        uint256 pricePerShare;
        bool allocated;
    }
    
    mapping(uint256 => Asset) public assets;
    mapping(uint256 => Bid[]) public assetBids;
    uint256 public assetCount;
    
    // Events with indexed parameters
    event AssetCreated(uint256 indexed assetId, address indexed originalOwner, string name, uint256 totalShares, uint256 minimumTotalPrice);
    event BidPlaced(uint256 indexed assetId, address indexed bidder, uint256 shares, uint256 price);
    event SharesAllocated(uint256 indexed assetId, address indexed bidder, uint256 shares, uint256 price);
    event RefundIssued(address indexed bidder, uint256 amount);
    event BiddingEnded(uint256 indexed assetId, bool successful, uint256 timestamp);
    event OwnerAdded(uint256 indexed assetId, address indexed owner, uint256 shares);
    event AssetCountUpdated(uint256 newCount);
    
    // Create new asset offering
    function createAssetOffering(
        string memory _name,
        uint256 _totalShares,
        uint256 _minPricePerShare,
        uint256 _minimumTotalPrice,
        uint256 _biddingDuration
    ) external {
        require(_totalShares > 0, "Invalid share count");
        require(_minPricePerShare > 0, "Invalid minimum price per share");
        require(_minimumTotalPrice > 0, "Invalid minimum total price");
        require(bytes(_name).length > 0, "Name cannot be empty");
        
        assetCount++;
        
        Asset storage newAsset = assets[assetCount];
        newAsset.originalOwner = msg.sender;
        newAsset.name = _name;
        newAsset.totalShares = _totalShares;
        newAsset.sharesRemaining = _totalShares;
        // newAsset.minPricePerShare = _minPricePerShare;
        newAsset.minimumTotalPrice = _minimumTotalPrice;
        newAsset.biddingClosed = false;
        newAsset.biddingEndTime = block.timestamp + _biddingDuration;
        
        // Add original owner as the sole owner with all shares initially
        newAsset.ownerAddresses.push(msg.sender);
        newAsset.owners[msg.sender] = AssetOwner({
            ownerAddress: msg.sender,
            shares: _totalShares,
            exists: true
        });
        
        emit AssetCreated(assetCount, msg.sender, _name, _totalShares, _minimumTotalPrice);
        emit OwnerAdded(assetCount, msg.sender, _totalShares);
        emit AssetCountUpdated(assetCount);
    }
    
    // Get latest asset count
    function getLatestAssetCount() external view returns (uint256) {
        return assetCount;
    }
    
    // Get asset basic details
    function getAssetBasicDetails(uint256 _assetId) external view returns (
        address originalOwner,
        string memory name,
        uint256 totalShares,
        uint256 sharesRemaining,
        // uint256 minPricePerShare,
        uint256 minimumTotalPrice,
        bool biddingClosed,
        uint256 biddingEndTime
    ) {
        require(_assetId > 0 && _assetId <= assetCount, "Invalid asset ID");
        Asset storage asset = assets[_assetId];
        
        return (
            asset.originalOwner,
            asset.name,
            asset.totalShares,
            asset.sharesRemaining,
            // asset.minPricePerShare,
            asset.minimumTotalPrice,
            asset.biddingClosed,
            asset.biddingEndTime
        );
    }
    
    // Get all owners of an asset
    function getAssetOwners(uint256 _assetId) external view returns (
        address[] memory ownerAddresses,
        uint256[] memory ownerShares
    ) {
        require(_assetId > 0 && _assetId <= assetCount, "Invalid asset ID");
        Asset storage asset = assets[_assetId];
        
        uint256 ownerCount = asset.ownerAddresses.length;
        ownerAddresses = new address[](ownerCount);
        ownerShares = new uint256[](ownerCount);
        
        for (uint256 i = 0; i < ownerCount; i++) {
            address ownerAddress = asset.ownerAddresses[i];
            ownerAddresses[i] = ownerAddress;
            ownerShares[i] = asset.owners[ownerAddress].shares;
        }
        
        return (ownerAddresses, ownerShares);
    }
    
    // Place bid for shares
    function placeBid(uint256 _assetId, uint256 _shareAmount) external payable nonReentrant {
        Asset storage asset = assets[_assetId];
        require(!asset.biddingClosed, "Bidding closed");
        require(block.timestamp < asset.biddingEndTime, "Bidding period ended");
        require(_shareAmount > 0, "Invalid share amount");
        // require(msg.value >= _shareAmount.mul(asset.minPricePerShare), "Bid below minimum price per share");
        
        // Store bid details
        assetBids[_assetId].push(Bid({
            bidder: msg.sender,
            shareAmount: _shareAmount,
            pricePerShare: msg.value.div(_shareAmount),
            allocated: false
        }));
        
        emit BidPlaced(_assetId, msg.sender, _shareAmount, msg.value.div(_shareAmount));
    }
    
    // Get all bids for an asset
    function getAssetBids(uint256 _assetId) external view returns (
        address[] memory bidders,
        uint256[] memory shareAmounts,
        uint256[] memory pricesPerShare,
        bool[] memory allocated
    ) {
        require(_assetId > 0 && _assetId <= assetCount, "Invalid asset ID");
        
        Bid[] storage bids = assetBids[_assetId];
        uint256 bidCount = bids.length;
        
        bidders = new address[](bidCount);
        shareAmounts = new uint256[](bidCount);
        pricesPerShare = new uint256[](bidCount);
        allocated = new bool[](bidCount);
        
        for (uint256 i = 0; i < bidCount; i++) {
            bidders[i] = bids[i].bidder;
            shareAmounts[i] = bids[i].shareAmount;
            pricesPerShare[i] = bids[i].pricePerShare;
            allocated[i] = bids[i].allocated;
        }
        
        return (bidders, shareAmounts, pricesPerShare, allocated);
    }
    
    // End bidding early
    function endBidding(uint256 _assetId) external nonReentrant {
        Asset storage asset = assets[_assetId];
        require(msg.sender == asset.originalOwner, "Unauthorized");
        require(!asset.biddingClosed, "Bidding already closed");
        
        // Mark bidding as closed
        asset.biddingClosed = true;
        
        // Process bids if any exist
        if(assetBids[_assetId].length > 0) {
            _processBids(_assetId);
        } else {
            emit BiddingEnded(_assetId, false, block.timestamp);
        }
    }
    
    // Execute bidding allocation
    function executeBidding(uint256 _assetId) external nonReentrant {
        Asset storage asset = assets[_assetId];
        require(msg.sender == asset.originalOwner, "Unauthorized");
        require(!asset.biddingClosed, "Bidding already closed");
        require(block.timestamp >= asset.biddingEndTime, "Bidding period ongoing");
        
        // Mark bidding as closed
        asset.biddingClosed = true;
        
        // Process bids if any exist
        if(assetBids[_assetId].length > 0) {
            _processBids(_assetId);
        } else {
            emit BiddingEnded(_assetId, false, block.timestamp);
        }
    }
    
    // Internal function to process bids
    function _processBids(uint256 _assetId) internal {
        Asset storage asset = assets[_assetId];
        
        // Sort bids in descending order of price
        _sortBids(_assetId);
        
        Bid[] storage bids = assetBids[_assetId];
        
        // First check: calculate total potential value to see if it meets minimum price
        uint256 totalBidValue = 0;
        uint256 sharesToAllocate = asset.sharesRemaining;
        
        for(uint256 i = 0; i < bids.length && sharesToAllocate > 0; i++) {
            Bid storage bid = bids[i];
            if(bid.allocated) continue;
            
            uint256 allocatableShares = (bid.shareAmount <= sharesToAllocate) 
                ? bid.shareAmount 
                : sharesToAllocate;
                
            totalBidValue = totalBidValue.add(allocatableShares.mul(bid.pricePerShare));
            sharesToAllocate = sharesToAllocate.sub(allocatableShares);
        }
        
        // Check if total bid value meets the minimum total price
        bool successful = totalBidValue >= asset.minimumTotalPrice;
        
        if (successful) {
            // Reset share allocation variables for actual allocation
            asset.sharesRemaining = asset.totalShares;
            
            // Remove all shares from previous owners
            for (uint256 i = 0; i < asset.ownerAddresses.length; i++) {
                address ownerAddress = asset.ownerAddresses[i];
                asset.owners[ownerAddress].shares = 0;
            }
            
            // Reset owner list
            delete asset.ownerAddresses;
            
            // Process the actual allocation
            for(uint256 i = 0; i < bids.length; i++) {
                if(asset.sharesRemaining == 0) break;
                
                Bid storage bid = bids[i];
                if(bid.allocated) continue;
                
                uint256 allocatableShares = (bid.shareAmount <= asset.sharesRemaining) 
                    ? bid.shareAmount 
                    : asset.sharesRemaining;
                
                // Calculate required payment and refund excess
                uint256 requiredPayment = allocatableShares.mul(bid.pricePerShare);
                uint256 refundAmount = bid.shareAmount.mul(bid.pricePerShare).sub(requiredPayment);
                
                if(allocatableShares > 0) {
                    // Transfer payment to original owner
                    payable(asset.originalOwner).transfer(requiredPayment);
                    
                    // Update shares remaining
                    asset.sharesRemaining = asset.sharesRemaining.sub(allocatableShares);
                    bid.allocated = true;
                    
                    // Add or update owner
                    if (!asset.owners[bid.bidder].exists) {
                        asset.ownerAddresses.push(bid.bidder);
                        asset.owners[bid.bidder] = AssetOwner({
                            ownerAddress: bid.bidder,
                            shares: allocatableShares,
                            exists: true
                        });
                    } else {
                        asset.owners[bid.bidder].shares = asset.owners[bid.bidder].shares.add(allocatableShares);
                    }
                    
                    emit SharesAllocated(_assetId, bid.bidder, allocatableShares, bid.pricePerShare);
                    emit OwnerAdded(_assetId, bid.bidder, allocatableShares);
                }
                
                // Refund unallocated portion
                if(refundAmount > 0) {
                    payable(bid.bidder).transfer(refundAmount);
                    emit RefundIssued(bid.bidder, refundAmount);
                }
            }
        } else {
            // Bidding failed, refund all bids
            _refundAllBids(_assetId);
        }
        
        emit BiddingEnded(_assetId, successful, block.timestamp);
    }
    
    // Internal function to sort bids
    function _sortBids(uint256 _assetId) internal {
        Bid[] storage bids = assetBids[_assetId];
        for(uint256 i = 0; i < bids.length; i++) {
            for(uint256 j = i+1; j < bids.length; j++) {
                if(bids[i].pricePerShare < bids[j].pricePerShare) {
                    Bid memory temp = bids[i];
                    bids[i] = bids[j];
                    bids[j] = temp;
                }
            }
        }
    }
    
    // Internal function to refund all bids (when bidding fails)
    function _refundAllBids(uint256 _assetId) internal {
        Bid[] storage bids = assetBids[_assetId];
        for(uint256 i = 0; i < bids.length; i++) {
            if(!bids[i].allocated) {
                uint256 refundAmount = bids[i].shareAmount.mul(bids[i].pricePerShare);
                payable(bids[i].bidder).transfer(refundAmount);
                emit RefundIssued(bids[i].bidder, refundAmount);
            }
        }
    }
}
