// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "openzeppelin-contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBase.sol";
import "openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import "openzeppelin-contracts/contracts/access/Ownable.sol";
contract Daffle is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 private _raffleIdCounter = 1; // Start from 1
    uint256 private constant CLAIM_PERIOD = 1 weeks;

    bytes32 internal keyHash;
    uint256 internal fee;

    struct NFTItem {
        uint256 id;
        string imageUrl;
        string name;
        string qty;
        string floor;
        string lastSale;
    }

    struct Raffle {
        uint256 id;
        address payable creator;
        uint256 endTime;
        uint256 maxTickets;
        uint256 ticketPrice;
        uint256 minTickets;
        string description;
        NFTItem nftItem;
        EnumerableSet.AddressSet ticketHolders; // Unique ticket holders set
        bool isDrawn;
        uint256 drawTime;
    }

    constructor(
        address vrfCoordinator,
        address linkToken,
        bytes32 vrfKeyHash,
        uint256 vrfFee
    ) VRFConsumerBase(vrfCoordinator, linkToken) Ownable(msg.sender) {
        keyHash = vrfKeyHash;
        fee = vrfFee;
    }

    mapping(bytes32 => uint256) private requestIdToRaffleId;
    mapping(uint256 => address) public drawWinner;
    mapping(uint256 => Raffle) public raffles;
    mapping(uint256 => mapping(address => uint256)) public ticketsBought;

    // Events
    event RaffleCreated(uint256 indexed raffleId, address indexed creator);
    event TicketPurchased(
        uint256 indexed raffleId,
        address indexed buyer,
        uint256 quantity
    );
    event WinnerDrawn(uint256 indexed raffleId, address indexed winner);
    event RaffleCancelled(uint256 indexed raffleId);
    event RefundIssued(
        uint256 indexed raffleId,
        address indexed recipient,
        uint256 amount
    );

    // Create a new Raffle
    function createRaffle(
        // uint256 _nftId,
        uint256 _endTime,
        uint256 _maxTickets,
        uint256 _ticketPriceInWei,
        uint256 _minTickets,
        string memory _description,
        NFTItem memory _nftItem
    ) public {
        uint256 raffleId = _raffleIdCounter; // Use the manual counter
        _raffleIdCounter++; // Increment for next use

        Raffle memory newRaffle = Raffle({
            id: raffleId,
            creator: payable(msg.sender),
            endTime: _endTime,
            maxTickets: _maxTickets,
            ticketPrice: _ticketPriceInWei,
            minTickets: _minTickets,
            description: _description,
            nftItem: _nftItem,
            ticketHolders: new address[](0),
            isDrawn: false
        });

        raffles[raffleId] = newRaffle;
        emit RaffleCreated(raffleId, msg.sender);
    }

    // Buy tickets for a Raffle
    function buyTicket(
        uint256 _raffleId,
        uint256 _quantity
    ) public payable nonReentrant {
        Raffle storage raffle = raffles[_raffleId];

        // Check if the raffle exists and has not ended...
        require(raffle.id != 0, "Raffle does not exist");
        require(block.timestamp < raffle.endTime, "Raffle has ended");
        require(_quantity > 0, "Quantity must be greater than 0");
        require(
            raffle.ticketHolders.length + _quantity <= raffle.maxTickets,
            "Exceeds max tickets"
        );

        uint256 totalCost = _quantity * raffle.ticketPrice;
        require(msg.value >= totalCost, "Insufficient ETH sent");

        // Add tickets to the buyer...
        for (uint256 i = 0; i < _quantity; i++) {
            raffle.ticketHolders.push(msg.sender);
        }
        ticketsBought[_raffleId][msg.sender] += _quantity;

        emit TicketPurchased(_raffleId, msg.sender, _quantity);
    }

    // Draw a Winner
    function drawWinner(uint256 _raffleId) public nonReentrant {
        Raffle storage raffle = raffles[_raffleId];

        // Security checks...
        require(raffle.id != 0, "Raffle does not exist");
        require(block.timestamp >= raffle.endTime, "Raffle not yet ended");
        require(
            raffle.ticketHolders.length() >= raffle.minTickets,
            "Minimum tickets not sold"
        );
        require(!raffle.isDrawn, "Winner already drawn");
        require(
            LINK.balanceOf(address(this)) >= fee,
            "Not enough LINK - fill contract with faucet"
        );

        // Request randomness
        bytes32 requestId = requestRandomness(keyHash, fee);
        requestIdToRaffleId[requestId] = _raffleId;

        // Note: Random number will be returned to the fulfillRandomness function
    }

    // Callback function used by VRF Coordinator
    function fulfillRandomness(
        bytes32 requestId,
        uint256 randomness
    ) internal override {
        uint256 raffleId = requestIdToRaffleId[requestId];
        Raffle storage raffle = raffles[raffleId];

        uint256 totalTicketCount = raffle.ticketHolders.length();
        require(
            totalTicketCount > 0,
            "No ticket holders available for the draw."
        );

        uint256 randomIndex = randomness % totalTicketCount;
        address winner = raffle.ticketHolders.at(randomIndex);

        drawWinner[raffleId] = winner; // Store the winner's address for the raffle
        raffle.isDrawn = true;
        raffle.drawTime = block.timestamp; // Set the time the draw occurred

        // TODO: Transfer NFT to winner (logic depends on NFT contract implementation)...
        // ...

        emit WinnerDrawn(raffleId, winner);
    }

    function processRefunds(uint256 _raffleId) public nonReentrant {
        Raffle storage raffle = raffles[_raffleId];
        require(raffle.id != 0, "Raffle does not exist");
        require(raffle.isDrawn, "Winner has not been drawn yet");
        require(
            block.timestamp >= raffle.drawTime + CLAIM_PERIOD,
            "Claim period has not expired"
        );

        // Loop over all ticket holders and issue refunds
        for (uint256 i = 0; i < raffle.ticketHolders.length; i++) {
            address ticketHolder = raffle.ticketHolders[i];
            uint256 tickets = ticketsBought[_raffleId][ticketHolder];

            if (tickets > 0) {
                uint256 refundAmount = tickets * raffle.ticketPrice;
                ticketsBought[_raffleId][ticketHolder] = 0; // Prevent re-entrancy

                (bool success, ) = ticketHolder.call{value: refundAmount}("");
                require(success, "Refund failed");

                emit RefundIssued(_raffleId, ticketHolder, refundAmount);
            }
        }

        delete raffles[_raffleId]; // Optionally remove the raffle data to clean up state
    }

    function claimNFT(uint256 _raffleId) public nonReentrant {
        Raffle storage raffle = raffles[_raffleId];

        // Additional checks to ensure only the winner can claim...
        require(
            msg.sender == raffle.winner,
            "Only the winner can claim the NFT"
        );
        require(!raffle.prizeClaimed, "Prize has already been claimed");

        uint256 prizeValue = raffle.ticketHolders.length * raffle.ticketPrice;

        // Transfer prizeValue to the creator of the Daffle
        address creator = raffle.creator;
        (bool sent, ) = creator.call{value: prizeValue}("");
        require(sent, "Failed to send Ether to the Daffle creator");

        // Logic to transfer the NFT to the winner...
        // ...

        raffle.prizeClaimed = true;
        emit NFTClaimed(_raffleId, msg.sender);
    }

    function processRefunds(uint256 _raffleId) public nonReentrant {
        Raffle storage raffle = raffles[_raffleId];
        require(raffle.id != 0, "Raffle does not exist");
        require(raffle.isDrawn, "Winner has not been drawn yet");
        require(
            block.timestamp >= raffle.drawTime + CLAIM_PERIOD,
            "Claim period has not expired"
        );

        // Loop over all ticket holders and issue refunds
        for (uint256 i = 0; i < raffle.ticketHolders.length; i++) {
            address ticketHolder = raffle.ticketHolders[i];
            uint256 tickets = ticketsBought[_raffleId][ticketHolder];

            if (tickets > 0) {
                uint256 refundAmount = tickets * raffle.ticketPrice;
                ticketsBought[_raffleId][ticketHolder] = 0; // Prevent re-entrancy

                (bool success, ) = ticketHolder.call{value: refundAmount}("");
                require(success, "Refund failed");

                emit RefundIssued(_raffleId, ticketHolder, refundAmount);
            }
        }

        delete raffles[_raffleId]; // Optionally remove the raffle data to clean up state
    }

    // Cancel a Raffle
    function cancelRaffle(uint256 _raffleId) public nonReentrant {
        Raffle storage raffle = raffles[_raffleId];

        require(raffle.id != 0, "Raffle does not exist");
        require(msg.sender == raffle.creator, "Only creator can cancel");
        require(!raffle.isDrawn, "Winner already drawn");

        // Refund logic
        for (uint256 i = 0; i < raffle.ticketHolders.length; i++) {
            address ticketHolder = raffle.ticketHolders[i];
            uint256 tickets = ticketsBought[_raffleId][ticketHolder];
            if (tickets > 0) {
                uint256 refundAmount = tickets * raffle.ticketPrice;
                payable(ticketHolder).transfer(refundAmount);
                ticketsBought[_raffleId][ticketHolder] = 0;
            }
        }

        delete raffles[_raffleId];
        emit RaffleCancelled(_raffleId);
    }

    // Ensure there's a way to withdraw LINK
    function withdrawLink() external onlyOwner {
        require(
            LINK.transfer(msg.sender, LINK.balanceOf(address(this))),
            "Unable to transfer"
        );
    }

    // TODO: Additional helper methods like getRaffleInfo, refundTickets, etc...
    // ...
}
