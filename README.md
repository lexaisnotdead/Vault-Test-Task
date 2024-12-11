# Vault

The Vault is a smart contract designed for managing user deposits and interacting with DeFi protocols like Aave and Uniswap. Users can deposit and withdraw, receiving shares representing their stake. 

## Features
The Vault implements the following key features:
* Token deposits and withdrawals
* Token swaps utilizing Uniswap V3 with slippage protection and Oracle price validation
* Interfacing with Aave for lending and borrowing tokens

## Setup
1. Clone the repository and navigate to the project directory:

```shell
git clone https://github.com/lexaisnotdead/Vault-Test-Task.git
cd ./Vault-Test-Task
```

2. Install the project dependencies:
```shell
npm install
```

## Usage
To run the tests, simply execute the following command:
```shell
npx hardhat test
```