// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract LuxuryAssetShares is ERC721Enumerable, Ownable, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeMath for uint256;
    
    Counters.Counter private _tokenIdCounter;
    
    struct Asset {
        string name;
        uint256 totalShares;
        uint256 sharesRemaining;
        uint256 minimumTotalPrice;
        bool biddingClosed;
        uint256 currentTokenId; // First token ID for this asset
    }
    
    struct Bid {
        address bidder;
        uint256 shareAmount;
        uint256 pricePerShare;
        bool allocated;
    }
    
    mapping(uint256 => Asset) public assets;
    mapping(uint256 => Bid[]) public assetBids;
    mapping(uint256 => uint256) public tokenToAsset; // Maps token ID to asset ID
    uint256 public assetCount;
    
    event AssetCreated(uint256 indexed assetId, string name, uint256 totalShares, uint256 minimumTotalPrice);
    event BidPlaced(uint256 indexed assetId, address indexed bidder, uint256 shares, uint256 price);
    event SharesAllocated(uint256 indexed assetId, address indexed bidder, uint256 shares, uint256 price);
    event RefundIssued(address indexed bidder, uint256 amount);
    event BiddingEnded(uint256 indexed assetId, bool successful);
    
   constructor(address initialOwner) ERC721("LuxuryAssetShare", "LAS") Ownable(initialOwner) ReentrancyGuard() {}
    
    function createAsset(
        string memory _name,
        uint256 _totalShares,
        uint256 _minimumTotalPrice
    ) external onlyOwner {
        require(_totalShares > 0, "Invalid share count");
        require(_minimumTotalPrice > 0, "Invalid minimum price");
        
        assetCount++;
        
        assets[assetCount] = Asset({
            name: _name,
            totalShares: _totalShares,
            sharesRemaining: _totalShares,
            minimumTotalPrice: _minimumTotalPrice,
            biddingClosed: false,
            currentTokenId: _tokenIdCounter.current() + 1
        });
        
        emit AssetCreated(assetCount, _name, _totalShares, _minimumTotalPrice);
    }
    
    function placeBid(uint256 _assetId, uint256 _shareAmount) external payable nonReentrant {
        Asset storage asset = assets[_assetId];
        require(!asset.biddingClosed, "Bidding closed");
        require(_shareAmount > 0, "Invalid share amount");
        
        // Store bid details
        assetBids[_assetId].push(Bid({
            bidder: msg.sender,
            shareAmount: _shareAmount,
            pricePerShare: msg.value.div(_shareAmount),
            allocated: false
        }));
        
        emit BidPlaced(_assetId, msg.sender, _shareAmount, msg.value.div(_shareAmount));
    }
    
    function executeBidding(uint256 _assetId) external nonReentrant onlyOwner {
        Asset storage asset = assets[_assetId];
        require(!asset.biddingClosed, "Bidding already closed");        
        // Mark bidding as closed
        asset.biddingClosed = true;
        
        // Sort bids in descending order of price
        _sortBids(_assetId);
        
        // Calculate total bid value to ensure it meets minimum total price
        uint256 totalBidValue = 0;
        Bid[] storage bids = assetBids[_assetId];
        uint256 sharesAllocated = 0;
        
        for(uint256 i = 0; i < bids.length; i++) {
            if(asset.sharesRemaining == 0) break;
            
            Bid storage bid = bids[i];
            if(bid.allocated) continue;
            
            uint256 allocatableShares = (bid.shareAmount <= asset.sharesRemaining) 
                ? bid.shareAmount 
                : asset.sharesRemaining;
            
            totalBidValue = totalBidValue.add(allocatableShares.mul(bid.pricePerShare));
            sharesAllocated = sharesAllocated.add(allocatableShares);
            
            if(sharesAllocated == asset.totalShares) break;
        }
        
        // Check if total bid value meets minimum price
        bool successful = totalBidValue >= asset.minimumTotalPrice;
        
        if(successful) {
            // Process bids and mint NFTs
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
                    // Mark shares as allocated
                    asset.sharesRemaining = asset.sharesRemaining.sub(allocatableShares);
                    bid.allocated = true;
                    
                    // Mint NFTs to the bidder
                    for(uint256 j = 0; j < allocatableShares; j++) {
                        _tokenIdCounter.increment();
                        uint256 tokenId = _tokenIdCounter.current();
                        _mint(bid.bidder, tokenId);
                        tokenToAsset[tokenId] = _assetId;
                    }
                    
                    payable(msg.sender).transfer(requiredPayment);
                    emit SharesAllocated(_assetId, bid.bidder, allocatableShares, bid.pricePerShare);
                }
                
                // Refund unallocated portion
                if(refundAmount > 0) {
                    payable(bid.bidder).transfer(refundAmount);
                    emit RefundIssued(bid.bidder, refundAmount);
                }
            }
        } else {
            // Refund all bids if minimum price not met
            for(uint256 i = 0; i < bids.length; i++) {
                if(!bids[i].allocated) {
                    uint256 refundAmount = bids[i].shareAmount.mul(bids[i].pricePerShare);
                    payable(bids[i].bidder).transfer(refundAmount);
                    emit RefundIssued(bids[i].bidder, refundAmount);
                }
            }
        }
        
        emit BiddingEnded(_assetId, successful);
    }
    
    // Helper function to sort bids in descending order of price
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

    
    
    // Function to get asset ID for a token
    function getAssetIdForToken(uint256 _tokenId) external view returns (uint256) {
        require(_ownerOf(_tokenId) != address(0), "Token does not exist");
        return tokenToAsset[_tokenId];
    }

    // Add this variable to store the secondary market address
    address public secondaryMarketAddress;

    // Function to set the secondary market address
    function setSecondaryMarketAddress(address _marketAddress) external onlyOwner {
        secondaryMarketAddress = _marketAddress;
    }

    // Convenience function for token holders to approve all their tokens
    function approveAllForSecondaryMarket() external {
        require(secondaryMarketAddress != address(0), "Secondary market not set");
        setApprovalForAll(secondaryMarketAddress, true);
    }
}


