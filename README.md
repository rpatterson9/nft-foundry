This project implements a basic Opensea compatible NFT using the foundry framework to test and deploy your contract. Furthermore it offers an implementation using both [Solmate](https://github.com/Rari-Capital/solmate/blob/main/src/tokens/ERC721.sol)'s gas optimised ERC721 library as well as [OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC721/ERC721.sol)'s ERC721 library.

### Run tests:
```bash
forge test
```

### Compare gas costs between OpenZeppelin and Solmate library
```bash
forge test --gas-report
```
#### Deployment:
```bash
npm run deploy <constructor-args>
```
#### Send transaction:
```bash
npm run send <contractAddress> <functionSignature> <args>
```
