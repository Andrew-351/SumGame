// SPDX-License-Identifier: MIT
pragma solidity >=0.7.0 <0.9.0;

/**
 * @title SumGame
 * A smart contract implementing a simple game between players A and B (who is A and who is B is decided fairly, irrespectively of who joins first.
 * Each player picks a number in the range [1, 100]. If the sum of the two numbers is even, A wins, otherwise B wins.
 * Each player must go through 4 phases to complete the game: 
 *      REGISTRATION, ENCRYPTED BIDDING, BID REVELATION, and REWARD WITHDRAWAL.
 * Each phase is timed (~ 5 minutes). If a player fails to make a move before certain phase ends ("times out"), they are unregistered,
 * and their opponent can claim the entire bank (consisting of 2 registration fees paid by both players at the beginning of the game).
 */
contract SumGame {
    enum Phase {Register, Bid, Reveal, Withdraw} // Phase should be interpreted as "player is ready to {...}"
    struct Player {
        address payable player; // player's address
        bytes32 encryptedBid;   // sha256 encryption of "<number>-<nonce>"
        uint8 bid;              // player's bid (in the range [1, 100])
        Phase phase;            // phase player is currently in (e.g. after player bids, their phase becomes Reveal as they are "ready to" reveal)
    }
    Player private player1;
    Player private player2;
    uint8 private bidSum;               // sum of the 2 bids submitted by the players
    uint16 private bank;                // amount of money (in Wei) consisting of players' registration fees
    uint256 private currentPhaseEnd;    // the end of current game phase (block number)

    address payable private owner;

    uint8 public minBid = 1;
    uint8 public maxBid = 100;
    uint8 public timeout = 25;              // 25 blocks ~= 5 minutes (12s per block)
    uint16 public registerFee = 2 * maxBid; // to join the game a player must pay twice the maximum bid (2 * 100 = 200 Wei)
    Phase public currentPhase;              // current game phase; switched to the next phase only when both players completed their previous phase
   
    event FundsReceived(address, uint256);
    event PlayerRegistered(address);
    event PlayerQuit(address);
    event PlayerBidPlaced(address);
    event PlayerBidRevealed(address);
    event RewardOrRefundWithdrawn(address, uint16);

    constructor() {
        owner = payable(msg.sender);
    }

    ///--------------------------------------------------------------------------------///
    ///-----------------------------       MODIFIERS      -----------------------------///
    ///--------------------------------------------------------------------------------///

    modifier eligibleToRegister() {
        require(
            player1.player == address(0x0) || player2.player == address(0x0),
            "You cannot play at the moment. Two players are already registered."
        );
        require(
            msg.sender != player1.player && msg.sender != player2.player,
            "You are already a registered player."
        );
        require(
            bank == 0 || bank == registerFee,
            "Previous players haven't finished their game yet."
        );
        require(
            msg.value == 2 * maxBid,
            "The registration fee is the doubled maximum bid amount."
        );
        _;
    }

    modifier isRegistered() {
        require(
            msg.sender == player1.player || msg.sender == player2.player,
            "You are not a registered player."
        );
        _;
    }

    modifier bothPlayersRegistered() {
        require(
            player1.player != address(0x0) && player2.player != address(0x0),
            "Both players are required to have registered to begin the game."
        );
        _;
    }

    modifier noBidAlreadyPlaced() {
        if (msg.sender == player1.player) {
            require(
                player1.encryptedBid == 0x0,
                "You've already placed your bid."
            );
        } else {
            require(
                player2.encryptedBid == 0x0,
                "You've already placed your bid."
            );
        }
        _;
    }

    modifier notTimedOut() {
        require(
            block.number <= currentPhaseEnd,
            "You've timed out."
        );
        _;
    }

    modifier bothEncrBidsPlaced() {
        require(
            player1.encryptedBid != 0x0 && player2.encryptedBid != 0x0,
            "Both players have to first place their bids."
        );
        _;
    }

    modifier validBid(uint8 bid) {
        require(
            minBid <= bid && bid <= maxBid,
            "Invalid bid amount. You must bid between MIN and MAX amounts."
        );
        _;
    }

    modifier bothBidsRevealed() {
        require(
            player1.bid != 0 && player2.bid != 0,
            "Both bids have to be revealed before the winner is decided."
        );
        _;
    }

    modifier opponentTimedOut() {
        require(
            currentPhaseEnd < block.number,
            "Current phase has not ended yet."
        );
        if (msg.sender == player1.player) {
            require(
                (player1.phase == Phase.Reveal && player2.phase == Phase.Bid) ||
                (player1.phase == Phase.Withdraw && player2.phase == Phase.Reveal),
                "You can't kick your opponent out now."
            );
        } else {
            require(
                (player2.phase == Phase.Reveal && player1.phase == Phase.Bid) ||
                (player2.phase == Phase.Withdraw && player1.phase == Phase.Reveal),
                "You can't kick your opponent out now."
            );
        }
        _;
    }

    modifier onlyOwner() {
        require(
            msg.sender == owner,
            "You're not the owner of the contract."
        );
        _;
    }


    ///--------------------------------------------------------------------------------///
    ///-------------------------      FALLBACK FUNCTIONS      -------------------------///
    ///--------------------------------------------------------------------------------///

    receive() external payable {
        emit FundsReceived(msg.sender, msg.value);
    }

    fallback() external payable {}


    //////////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////      REGISTRATION PHASE      ////////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////

    /**
     * Function to register for a game. 
     * It can be called by anyone (not yet registered) if they pay the registration fee, and another game is not in progress.
     */
    function register() external payable eligibleToRegister {
        if (player1.player == address(0x0)) {
            player1.player = payable(msg.sender);
            player1.encryptedBid = 0x0;
            player1.bid = 0;
            player1.phase = Phase.Bid;
        } else {
            player2.player = payable(msg.sender);
            player2.encryptedBid = 0x0;
            player2.bid = 0;
            player2.phase = Phase.Bid;
            currentPhase = Phase.Bid;
        }
        bank += registerFee;
        currentPhaseEnd = block.number + timeout;   // Set the end of Bid phase (only matters when 2nd player registers).
        emit PlayerRegistered(msg.sender);
    }

    /**
     * Function to quit from a game.
     * It can only be called by a registered player if they are waiting, but no opponent has joined so far.
     */
    function quit() external isRegistered {
        if (msg.sender == player1.player) {
            require(
                player1.phase == Phase.Bid && player2.phase == Phase.Register,
                "You can't quit at this point."
            );
            unregisterPlayer(1);
        } else {
            require(
                player2.phase == Phase.Bid && player1.phase == Phase.Register,
                "You can't quit at this point."
            );
            unregisterPlayer(2);
        }
        currentPhase = Phase.Register;
        bank = 0;
        (bool success, ) = msg.sender.call{value: registerFee}("");
        require(success, "Failed to refund the registration fee.");
        emit PlayerQuit(msg.sender);
    }


    //////////////////////////////////////////////////////////////////////////////////////
    //////////////////////////      ENCRYPTED BIDDING PHASE      /////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////  

    /**
     * Function to submit a number [1, 100] (i.e. "place a bid") in the following encrypted form: sha256(<number>-<nonce>).
     * (The parameter must be the SHA256 hash computed from a concatenation of the bid number and any nonce with "-" in between.)
     * @param encrBid - is the bid encrypted as explained above; it must begin with "0x".
     * E.g. to bid 10 with nonce "non", compute SHA256 of "10-non": 0xc13ab3a17d824163e938cecb813a22e6fecc58c5e6e3e65688d56c0a0d348c47.
     */
    function placeEncryptedBid(bytes32 encrBid) external isRegistered bothPlayersRegistered noBidAlreadyPlaced notTimedOut {
        if (msg.sender == player1.player) {
            player1.encryptedBid = encrBid;
            player1.phase = Phase.Reveal;
            if (player2.phase == Phase.Reveal) {
                currentPhase = Phase.Reveal;
                currentPhaseEnd = block.number + timeout;  // Set the end of Reveal phase (only if both players have placed bids).
            }
        }
        else {
            player2.encryptedBid = encrBid;
            player2.phase = Phase.Reveal;
            if (player1.phase == Phase.Reveal) {
                currentPhase = Phase.Reveal;
                currentPhaseEnd = block.number + timeout;   // Set the end of Reveal phase (only if both players have placed bids).
            }
        }
        emit PlayerBidPlaced(msg.sender);
    }


    //////////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////      BID REVELATION PHASE      ///////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////

    /**
     * Function to reveal the bid number submitted in the previous phase.
     * @param bid   - the bid number [1, 100] 
     * @param nonce - the nonce used to encrypt the bid in the previous phase
     */
    function revealBid(uint8 bid, string memory nonce) external isRegistered bothEncrBidsPlaced validBid(bid) notTimedOut {
        bytes32 hashOfBid = sha256(abi.encodePacked(uint8ToString(bid), "-", nonce));
        if (msg.sender == player1.player && hashOfBid == player1.encryptedBid) {
            require(player1.bid == 0, "You've already successfully revealed your bid.");
            player1.bid = bid;
            player1.phase = Phase.Withdraw;
            if (player2.phase == Phase.Withdraw) {
                currentPhase = Phase.Withdraw;
                currentPhaseEnd = block.number + timeout;   // Set the end of Withdraw phase (only if both players have revealed bids).
            }
        } else if (msg.sender == player2.player && hashOfBid == player2.encryptedBid) {
            require(player2.bid == 0, "You've already successfully revealed your bid.");
            player2.bid = bid;
            player2.phase = Phase.Withdraw;
            if (player1.phase == Phase.Withdraw) {
                currentPhase = Phase.Withdraw;
                currentPhaseEnd = block.number + timeout;   // Set the end of Withdraw phase (only if both players have revealed bids).
            }
        } else {
            revert("The revealed bid doesn't match the encrypted bid you placed.");
        }
        bidSum = player1.bid + player2.bid;
        
        emit PlayerBidRevealed(msg.sender);
    }


    //////////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////      REWARD OR REFUND PHASE      /////////////////////////
    //////////////////////////////////////////////////////////////////////////////////////

    /**
     * Function to withdraw a reward (winner) or a refund (loser).
     * A winner gets their registration fee back, plus the sum of the bids.
     * A loser gets their registration fee back, minus the sum of the bids.
     * A totally fair algorithm decides which of the two players is A, and which is B, based on the combination of their bids:
     *   player1 is A   if BOTH bids are [1,50] or BOTH bids are [51,100]
     *   player2 is A   otherwise
     */
    function withdrawReward() external isRegistered bothBidsRevealed notTimedOut {
        bool player1IsPlayerA; // true => player1 is A and player2 is B; false => player1 is B and player2 is A
        uint8 half = maxBid / 2;
        if ((player1.bid <= half && player2.bid <= half) || (half < player1.bid && half < player2.bid)) {
            player1IsPlayerA = true;
        }

        bool winnerIsA = bidSum % 2 == 0; // true => A wins; false => B wins
        uint16 rewardOrRefund;
        if (msg.sender == player1.player) {
            if ((player1IsPlayerA && winnerIsA) || (!player1IsPlayerA && !winnerIsA)) rewardOrRefund = registerFee + bidSum;
            else rewardOrRefund = registerFee - bidSum;
            bank -= rewardOrRefund;
            unregisterPlayer(1);
            if (player2.phase == Phase.Register) currentPhase = Phase.Register;
        } else {
            if ((player1IsPlayerA && !winnerIsA) || (!player1IsPlayerA && winnerIsA)) rewardOrRefund = registerFee + bidSum;
            else rewardOrRefund = registerFee - bidSum;
            bank -= rewardOrRefund;
            unregisterPlayer(2);
            if (player1.phase == Phase.Register) currentPhase = Phase.Register;
        }
        if (rewardOrRefund != 0) {
            (bool success, ) = msg.sender.call{value: rewardOrRefund}("");
            require(success, "Failed to send the reward/refund.");
        }
        emit RewardOrRefundWithdrawn(msg.sender, rewardOrRefund);
    }


    //////////////////////////////////////////////////////////////////////////////////////
    ///////////////////////        TIMEOUT CONTROL FUNCTIONS        //////////////////////
    //////////////////////////////////////////////////////////////////////////////////////

    /** 
     * Function to claim the entire bank.
     * It can be called by a player if the opponent timed out during BID or REVEAL phase.
     */
    function claimBankIfOpponentTimedOut() external isRegistered opponentTimedOut {
        unregisterPlayer(1);
        unregisterPlayer(2);
        currentPhase = Phase.Register;
        (bool success, ) = msg.sender.call{value: bank}("");
        require(success, "Failed to claim the bank.");
        bank = 0;   // No re-rentrancy can happen here since players are already unregistered.
    }

    /**
     * Function called by the owner to kickout one or both players who timed out.
     * If there is a player who didn't time out, the bank will be sent to them.
     * If both players timed out or if the transfer above failed, the owner will claim the bank.
     */
    function adminKickOut() external onlyOwner {
        require(
            currentPhaseEnd < block.number,
            "Current phase has not ended yet."
        );
        bool p1TimedOut;
        bool p2TimedOut;

        if (currentPhase == Phase.Bid) {
            if (player1.phase == Phase.Bid) p1TimedOut = true;
            if (player2.phase == Phase.Bid) p2TimedOut = true;
        } else if (currentPhase == Phase.Reveal) {
            if (player1.phase == Phase.Reveal) p1TimedOut = true;
            if (player2.phase == Phase.Reveal) p2TimedOut = true;
        } else if (currentPhase == Phase.Withdraw) {
            if (player1.phase == Phase.Withdraw) p1TimedOut = true;
            if (player2.phase == Phase.Withdraw) p2TimedOut = true;
        }
        
        require(p1TimedOut || p2TimedOut, "Nobody has timed out.");
        // If both timed out, owner claims the bank.
        if (p1TimedOut && p2TimedOut) {
            unregisterPlayer(1);
            unregisterPlayer(2);
            (bool success, ) = owner.call{value: bank}("");
            require(success, "Failed to claim the bank.");
        } else if (p1TimedOut) {
            // If player1 timed out, send the bank to player2. If failed, owner claims.
            unregisterPlayer(1);
            (bool success, ) = player2.player.call{value: bank}("");
            unregisterPlayer(2);
            if (!success) {
                (bool success1, ) = owner.call{value: bank}("");
                require(success1, "Failed to claim the bank.");
            }
        } else {
            // If player2 timed out, send the bank to player1. If failed, owner claims.
            unregisterPlayer(2);
            (bool success, ) = player1.player.call{value: bank}("");
            unregisterPlayer(1);
            if (!success) {
                (bool success1, ) = owner.call{value: bank}("");
                require(success1, "Failed to claim the bank.");
            }
        }
        bank = 0;
        currentPhase = Phase.Register;
    }


    ///--------------------------------------------------------------------------------///
    ///--------------------------      HELPER FUNCTIONS      --------------------------///
    ///--------------------------------------------------------------------------------///

    /**
     * Function to convert an 8-bit unsigned integer to a string.
     * @param number - a uint8 number to be converted to a string.
     */
    function uint8ToString(uint8 number) private pure returns(string memory){
        // The number will never be 0 because it would be an invalid bid, and so would be handled.
        uint8 temp = number;
        uint8 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (number != 0) {
            digits--;
            buffer[digits] = bytes1(uint8(48 + (number % 10))); // Convert to ASCII value.
            number /= 10;
        }
        return string(buffer);
    }

    /**
     * Function to unregister a player (if they quit, withdraw reward, kickout their opponent, or are kicked out).
     * @param player - an identifier, i.e. either 1 or 2 to unregister player1 or player2 respectively.
     */
    function unregisterPlayer(uint8 player) private {
        if (player == 1) {
            player1.player = payable(address(0x0));
            player1.phase = Phase.Register;
        } else {
            player2.player = payable(address(0x0));
            player2.phase = Phase.Register;
        }
    }
}
