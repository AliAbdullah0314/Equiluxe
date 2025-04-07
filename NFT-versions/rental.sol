// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract RentalDistribution is Ownable {
    IERC721Enumerable public nftContract;
    
    event ProfitDistributed(uint256 totalProfit, uint256 shareCount, uint256 amountPerShare);
    event AssetProfitDistributed(uint256 indexed assetId, uint256 totalProfit, uint256 shareCount);
    
    constructor(address initialOwner, address _nftContractAddress) Ownable(initialOwner) {
        nftContract = IERC721Enumerable(_nftContractAddress);
    }

    
    // Distribute profit equally among all NFT holders
    function distributeProfit() external payable onlyOwner {
        uint256 totalNFTs = nftContract.totalSupply();
        require(totalNFTs > 0, "No NFTs minted");
        require(msg.value > 0, "No profit to distribute");
        
        uint256 profitPerNFT = msg.value / totalNFTs;
        
        // Distribute to each NFT holder
        for (uint256 i = 1; i <= totalNFTs; i++) {
            address owner = nftContract.ownerOf(i);
            payable(owner).transfer(profitPerNFT);
        }
        
        // Return any remaining dust (due to division)
        uint256 remaining = msg.value - (profitPerNFT * totalNFTs);
        if (remaining > 0) {
            payable(owner()).transfer(remaining);
        }
        
        emit ProfitDistributed(msg.value, totalNFTs, profitPerNFT);
    }
    
    // Distribute profit for a specific asset (calling contract must track which tokens belong to which asset)
    function distributeAssetProfit(uint256[] calldata tokenIds) external payable onlyOwner {
        require(tokenIds.length > 0, "No tokens specified");
        require(msg.value > 0, "No profit to distribute");
        
        uint256 profitPerNFT = msg.value / tokenIds.length;
        
        // Distribute to each token owner
        for (uint256 i = 0; i < tokenIds.length; i++) {
            address owner = nftContract.ownerOf(tokenIds[i]);
            payable(owner).transfer(profitPerNFT);
        }
        
        // Return any remaining dust
        uint256 remaining = msg.value - (profitPerNFT * tokenIds.length);
        if (remaining > 0) {
            payable(owner()).transfer(remaining);
        }
        
        emit AssetProfitDistributed(0, msg.value, tokenIds.length);
    }
    
    // Function to receive Ether
    receive() external payable {}
}
