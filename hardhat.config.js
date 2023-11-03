require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.20",
    settings: {
      viaIR: true,
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {
    sepolia: {
      url: "https://ethereum-sepolia.publicnode.com",
      accounts: [process.env.DEPLOYER],
      chainId: 11155111,
    },
    bscTest: {
      url: "https://bsc-testnet.publicnode.com",
      accounts: [process.env.DEPLOYER],
      chainId: 97,
    }
  },
  etherscan: {
    apiKey: "U6Y6XR19NT3314IKJJUKJZ8689JEHM13MZ",
  }
};
