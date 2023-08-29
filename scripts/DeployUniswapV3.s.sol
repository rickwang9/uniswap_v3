// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "forge-std/console.sol";
import "forge-std/Script.sol";

import "../src/interfaces/IUniswapV3Manager.sol";
import "../src/lib/FixedPoint96.sol";
import "../src/lib/Math.sol";
import "../src/UniswapV3Factory.sol";
import "../src/UniswapV3Manager.sol";
import "../src/UniswapV3Pool.sol";
import "../src/UniswapV3Quoter.sol";
import "../test/ERC20Mintable.sol";
import "../test/TestUtils.sol";

contract DeployDevelopment is Script, TestUtils {
    struct TokenBalances {
        uint256 uni;
        uint256 usdc;
        uint256 usdt;
        uint256 wbtc;
        uint256 weth;
    }

    TokenBalances balances =
        TokenBalances({
            uni: 200 ether,
            usdc: 2_000_000 ether,
            usdt: 2_000_000 ether,
            wbtc: 20 ether,
            weth: 100 ether
        });

    function run() public {
        // DEPLOYING STARGED
        vm.startBroadcast();

        ERC20Mintable weth = new ERC20Mintable("Wrapped Ether", "WETH", 18);
        ERC20Mintable usdc = new ERC20Mintable("USD Coin", "USDC", 18);
        ERC20Mintable uni = new ERC20Mintable("Uniswap Coin", "UNI", 18);
        ERC20Mintable wbtc = new ERC20Mintable("Wrapped Bitcoin", "WBTC", 18);
        ERC20Mintable usdt = new ERC20Mintable("USD Token", "USDT", 18 );

        UniswapV3Factory factory = new UniswapV3Factory();
        UniswapV3Manager manager = new UniswapV3Manager(address(factory));
        UniswapV3Quoter quoter = new UniswapV3Quoter(address(factory));
        // fee 3000，当前价格5000
        UniswapV3Pool wethUsdc = deployPool(
            factory,
            address(weth),
            address(usdc),
            3000,
            5000
        );

        UniswapV3Pool wethUni = deployPool(
            factory,
            address(weth),
            address(uni),
            3000,
            10
        );

        UniswapV3Pool wbtcUSDT = deployPool(
            factory,
            address(wbtc),
            address(usdt),
            3000,
            20_000
        );

        UniswapV3Pool usdtUSDC = deployPool(
            factory,
            address(usdt),
            address(usdc),
            500,
            1
        );

        uni.mint(msg.sender, balances.uni);
        usdc.mint(msg.sender, balances.usdc);
        usdt.mint(msg.sender, balances.usdt);
        wbtc.mint(msg.sender, balances.wbtc);
        weth.mint(msg.sender, balances.weth);

        uni.approve(address(manager), 100 ether);
        usdc.approve(address(manager), 1_005_000 ether);
        usdt.approve(address(manager), 1_200_000 ether);
        wbtc.approve(address(manager), 10 ether);
        weth.approve(address(manager), 11 ether);

        manager.mint(
            mintParamsNotSort(
                address(weth),
                address(usdc),
                4545,
                5500,
                1 ether,
                5000 ether
            )
        );
        manager.mint(
            mintParamsNotSort(address(weth), address(uni), 7, 13, 10 ether, 100 ether)
        );
        // 当前的add比例必须是当前价格。v2也是，池子的比例就是当前价格，你必须按这个加。
        manager.mint(
            mintParamsNotSort(
                address(wbtc),
                address(usdt),
                19400,
                20500,
                10 ether,
                200_000 ether
            )
        );
        manager.mint(
            mintParamsNotSort(
                address(usdt),
                address(usdc),
                uint160(77222060634363714391462903808), //  0.95, int(math.sqrt(0.95) * 2**96)
                uint160(81286379615119694729911992320), // ~1.05, int(math.sqrt(1/0.95) * 2**96)
                1_000_000 ether,
                1_000_000 ether,
                500
            )
        );

        vm.stopBroadcast();
        // DEPLOYING DONE

        console.log("WETH address", address(weth));
        console.log("UNI address", address(uni));
        console.log("USDC address", address(usdc));
        console.log("USDT address", address(usdt));
        console.log("WBTC address", address(wbtc));

        console.log("Factory address", address(factory));
        console.log("Manager address", address(manager));
        console.log("Quoter address", address(quoter));

        console.log("USDT/USDC address", address(usdtUSDC));
        console.log("WBTC/USDT address", address(wbtcUSDT));
        console.log("WETH/UNI address", address(wethUni));
        console.log("WETH/USDC address", address(wethUsdc));
    }
    function mintParamsNotSort(
        address tokenA,
        address tokenB,
        uint256 lowerPrice,
        uint256 upperPrice,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (IUniswapV3Manager.MintParams memory params) {
        bool isSorted = tokenA < tokenB;
        (tokenA, tokenB) = isSorted ? (tokenA, tokenB) : (tokenB, tokenA);
        (amount0, amount1) = isSorted ? (amount0, amount1) : (amount1, amount0);

        params = IUniswapV3Manager.MintParams({
        tokenA: tokenA,
        tokenB: tokenB,
        fee: 3000,
        lowerTick: tick60(lowerPrice),
        upperTick: tick60(upperPrice),
        amount0Desired: amount0,
        amount1Desired: amount1,
        amount0Min: 0,
        amount1Min: 0
        });
    }
    function mintParamsNotSort(
        address tokenA,
        address tokenB,
        uint160 lowerSqrtP,
        uint160 upperSqrtP,
        uint256 amount0,
        uint256 amount1,
        uint24 fee
    ) internal view returns (IUniswapV3Manager.MintParams memory params) {
        bool isSorted = tokenA < tokenB;
        (tokenA, tokenB) = isSorted ? (tokenA, tokenB) : (tokenB, tokenA);
        (amount0, amount1) = isSorted ? (amount0, amount1) : (amount1, amount0);

        params = IUniswapV3Manager.MintParams({
        tokenA: tokenA,
        tokenB: tokenB,
        fee: fee,
        lowerTick: sqrtPToNearestTick(lowerSqrtP, tickSpacings[fee]),
        upperTick: sqrtPToNearestTick(upperSqrtP, tickSpacings[fee]),
        amount0Desired: amount0,
        amount1Desired: amount1,
        amount0Min: 0,
        amount1Min: 0
        });
    }

}