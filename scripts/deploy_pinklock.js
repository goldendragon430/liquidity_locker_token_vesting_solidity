// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// You can also run a script with `npx hardhat run <script>`. If you do that, Hardhat
// will compile your contracts, add the Hardhat Runtime Environment's members to the
// global scope, and execute the script.
const hre = require("hardhat");

async function main() {

  const [deployer] = await hre.ethers.getSigners();


  // const lock = await hre.ethers.deployContract("LiquidityLocker");

  // await lock.waitForDeployment();

  // console.log(
  //   `Deployed to ${lock.target}`
  // );


  const pinklock = await hre.ethers.deployContract("MyPinkLock02");

  await pinklock.waitForDeployment();

  console.log(
    `Deployed to ${pinklock.target}`
  );

  // const USDT  = await hre.ethers.getContractFactory("ERC20USDT");
  // const usdtContract = await USDT.deploy();

  // await usdtContract.mint("100000000000000000000000000");


  // console.log(
  //   `Deployed to ${await usdtContract.getAddress()}`
  // );
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
