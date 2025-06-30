# SumGame
Smart Contract Programming Assignment for Blockchains &amp; Distributed Ledgers 2023, The University of Edinburgh

The project was awarded the mark of 85/100 (A2).

## The Game
The smart contract should emulate the following game between two players, A and B. Each player
picks a number in the range [1, 100]. If the sum of the two numbers is even, then A wins, otherwise
B wins. The winner is rewarded the sum of the two numbers in wei.

## Example
Two players, A and B, each with 1,000,000,000 wei in their wallets, start a game. A picks
40 and B picks 34. The sum is 74, so A wins. After the game ends, A’s balance is 1,000,000,074
wei (possibly minus some gas fees, if necessary).
After a game ends, any two players should be able to start a new game on the same contract.

## Note
Solidity implementation can be found in the `SumGame.sol` file, whereas `report.pdf` contains the description with design rationale, and security and fairness analysis.
