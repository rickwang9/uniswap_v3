// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "./ERC20Mintable.sol";
import "./UniswapV3Pool.Utils.t.sol";

import "../src/interfaces/IUniswapV3Pool.sol";
import "../src/lib/LiquidityMath.sol";
import "../src/lib/TickMath.sol";
import "../src/UniswapV3Factory.sol";
import "../src/UniswapV3Pool.sol";
// forge test --match-path ./test/UniswapV3Pool.all.t.sol --match-contract UniswapV3PoolAllTest --match-test "test*" -vv
/*
    共8个test方法， 5个mint 3个swap
    testPool_MintInRange()  当前价格 5000， 在一个区间[4545,5500]添加流动性
    testPool_MintRangeBelow() 当前价格 5000， 在一个区间[4000,4996]添加流动性
    testPool_MintRangeAbove() 当前价格 5000， 在一个区间[5001,6250]添加流动性
    testPool_MintOverlappingRanges() 当前价格 5000， 在两个区间[4545,5500]，[4000,6250]添加流动性
    testPool_MintTwoEqualPriceRanges() 当前价格 5000， 在一个区间[4545,5500]添加两次流动性
    testSwap_BuyETHOnePriceRange() 当前价格 5000， 在一个区间[4545,5500]添加流动性。然后用42U交易
    testSwap_BuyETHTwoEqualPriceRanges() 当前价格 5000， 在一个区间[4545,5500]添加两次流动性。然后用42U交易
    testSwap_BuyETHConsecutivePriceRanges() 当前价格 5000， 在两个区间[4545,5500]，[5500,6250]添加流动性。然后用10000U交易

*/
contract UniswapV3PoolAllTest is Test, UniswapV3PoolUtils {
    ERC20Mintable weth;
    ERC20Mintable usdc;
    UniswapV3Factory factory;
    UniswapV3Pool pool;

    bool transferInMintCallback = true;
    bool flashCallbackCalled = false;
    bool transferInSwapCallback = true;
    bytes extra;
    /*
        通过代码读懂swap
    */
    function setUp() public {
        usdc = new ERC20Mintable("USDC", "USDC", 18);
        weth = new ERC20Mintable("Ether", "ETH", 18);
        factory = new UniswapV3Factory();

        extra = encodeExtra(address(weth), address(usdc), address(this));
    }

    //          5000
    //  4545 -----|----- 5500
    function testPool_MintInRange() public {
        logFunction("testPool_MintInRange", true);

        pool_mintInRange();

        logFunction("testPool_MintInRange", false);
    }

     //                      5000
    //  4000 --------- 4996 --|
    function testPool_MintRangeBelow() public {
        logFunction("testPool_MintRangeBelow", true);

        pool_mintRangeBelow();

        logFunction("testPool_MintRangeBelow", false);
    }

    
    // 5000
    //  |--5001 --------- 6250
    function testPool_MintRangeAbove() public {
        logFunction("testPool_MintRangeAbove", true);
        
        pool_mintRangeAbove();

        logFunction("testPool_MintRangeAbove", false);
    }


    //
    //          5000
    //   4545 ----|---- 5500
    // 4000 ------|------ 6250
    function testPool_MintOverlappingRanges() public {
        logFunction("testPool_MintOverlappingRanges", true);
        
        pool_mintOverlappingRanges();

        logFunction("testPool_MintOverlappingRanges", false);
    }

    
    //          5000
    //  4545 -----|----- 5500
    //  4545 -----|----- 5500
    function testPool_MintTwoEqualPriceRanges() public {
        logFunction("testPool_MintTwoEqualPriceRanges", true);
        
        pool_twoEqualPriceRanges();

        logFunction("testPool_MintTwoEqualPriceRanges", false);
    }


    function pool_mintInRange() public {
        (
            LiquidityRange[] memory liquidity,
            uint256 poolBalance0,
            uint256 poolBalance1
        ) = setupPool(
                PoolParams({
                    balances: [uint256(1 ether), 5000 ether],
                    currentPrice: 5000,
                    liquidity: liquidityRanges(
                        liquidityRange(4545, 5500, 1 ether, 5000 ether, 5000)
                    ),
                    transferInMintCallback: true,
                    transferInSwapCallback: true,
                    mintLiqudity: true
                })
            );

        (uint256 expectedAmount0, uint256 expectedAmount1) = (
            0.987078348444137445 ether,
            5000 ether
        );
        
        assertEq(
            poolBalance0,
            expectedAmount0,
            "incorrect weth deposited amount"
        );
        assertEq(
            poolBalance1,
            expectedAmount1,
            "incorrect usdc deposited amount"
        );

    }


    function pool_mintRangeBelow() public {
        (
            LiquidityRange[] memory liquidity,
            uint256 poolBalance0,
            uint256 poolBalance1
        ) = setupPool(
                PoolParams({
                    balances: [uint256(1 ether), 5000 ether],
                    currentPrice: 5000,
                    liquidity: liquidityRanges(
                        liquidityRange(4000, 4996, 1 ether, 5000 ether, 5000)
                    ),
                    transferInMintCallback: true,
                    transferInSwapCallback: true,
                    mintLiqudity: true
                })
            );

        (uint256 expectedAmount0, uint256 expectedAmount1) = (
            0 ether,
            4999.999999999999999994 ether
        );
        
        assertEq(
            poolBalance0,
            expectedAmount0,
            "incorrect weth deposited amount"
        );
        assertEq(
            poolBalance1,
            expectedAmount1,
            "incorrect usdc deposited amount"
        );
    }



    function pool_mintRangeAbove() public {
        (
            LiquidityRange[] memory liquidity,
            uint256 poolBalance0,
            uint256 poolBalance1
        ) = setupPool(
                PoolParams({
                    balances: [uint256(1 ether), 5000 ether],
                    currentPrice: 5000,
                    liquidity: liquidityRanges(
                        liquidityRange(5001, 6250, 1 ether, 5000 ether, 5000)
                    ),
                    transferInMintCallback: true,
                    transferInSwapCallback: true,
                    mintLiqudity: true
                })
            );

        (uint256 expectedAmount0, uint256 expectedAmount1) = (1 ether, 0);
        
        assertEq(
            poolBalance0,
            expectedAmount0,
            "incorrect weth deposited amount"
        );
        assertEq(
            poolBalance1,
            expectedAmount1,
            "incorrect usdc deposited amount"
        );
        
    }



    function pool_mintOverlappingRanges() public {
        (LiquidityRange[] memory liquidity, , ) = setupPool(
            PoolParams({
                balances: [uint256(3 ether), 15000 ether],
                currentPrice: 5000,
                liquidity: liquidityRanges(
                    liquidityRange(4545, 5500, 1 ether, 5000 ether, 5000),
                    liquidityRange(4000, 6250, 0.8 ether, 4000 ether, 5000)
                ),
                transferInMintCallback: true,
                transferInSwapCallback: true,
                mintLiqudity: true
            })
        );

    }


    function pool_twoEqualPriceRanges() public {
        (LiquidityRange[] memory liquidity, , ) = setupPool(
            PoolParams({
                balances: [uint256(3 ether), 15000 ether],
                currentPrice: 5000,
                liquidity: liquidityRanges(
                    liquidityRange(4545, 5500, 1 ether, 5000 ether, 5000),
                    liquidityRange(4545, 5500, 1 ether, 5000 ether, 5000)
                ),
                transferInMintCallback: true,
                transferInSwapCallback: true,
                mintLiqudity: true
            })
        );

    }


    function testSwap_BuyETHOnePriceRange() public {
        logFunction("testSwap_BuyETHOnePriceRange", true);
        
        // 1 初始化池子 currentPrice=5000， [4545, 5500]
        pool_mintInRange();

        uint256 swapAmount = 42 ether; // 42 USDC
        usdc.mint(address(this), swapAmount);
        usdc.approve(address(this), swapAmount);

        (int256 userBalance0Before, int256 userBalance1Before) = (
            int256(weth.balanceOf(address(this))),
            int256(usdc.balanceOf(address(this)))
        );

        (int256 amount0Delta, int256 amount1Delta) = pool.swap(
            address(this),
            false,
            swapAmount,
            sqrtP(5004),
            extra
        );

        assertEq(amount0Delta, -0.008371593947078467 ether, "invalid ETH out");//Delta表示变化量， pool增加了-0.008371593947078467 ether 个 token0
        assertEq(amount1Delta, 42 ether, "invalid USDC in");//Delta表示变化量， pool增加了42 ether 个 token1

        logFunction("testSwap_BuyETHOnePriceRange", false);
    }

    //  Two equal price ranges
    //
    //          5000
    //  4545 -----|----- 5500
    //  4545 -----|----- 5500
    //
    // forge test --match-path ./test/UniswapV3Pool.Swaps.t.sol --match-contract UniswapV3PoolSwapsTest --match-test "testBuyETHTwoEqualPriceRanges*" -vvv
    function testSwap_BuyETHTwoEqualPriceRanges() public {
        logFunction("testSwap_BuyETHTwoEqualPriceRanges", true);
        
        pool_twoEqualPriceRanges();

        uint256 swapAmount = 42 ether; // 42 USDC
        usdc.mint(address(this), swapAmount);
        usdc.approve(address(this), swapAmount);

        (int256 userBalance0Before, int256 userBalance1Before) = (
            int256(weth.balanceOf(address(this))),
            int256(usdc.balanceOf(address(this)))
        );
        // swapAmount=42 usdc ,价格=5002，
        (int256 amount0Delta, int256 amount1Delta) = pool.swap(
            address(this),
            false,
            swapAmount,
            sqrtP(5002),
            extra
        );

        assertEq(amount0Delta, -0.008373196666644048 ether, "invalid ETH out");
        assertEq(amount1Delta, 42 ether, "invalid USDC in");

        logFunction("testSwap_BuyETHTwoEqualPriceRanges", false);
    }


        //
    //          5000
    //  4545 -----|----- 5500
    //                   5500 ----------- 6250
    //
    function testSwap_BuyETHConsecutivePriceRanges() public {
        logFunction("testSwap_BuyETHConsecutivePriceRanges", true);
        (
            LiquidityRange[] memory liquidity,
            uint256 poolBalance0,
            uint256 poolBalance1
        ) = setupPool(
                PoolParams({
                    balances: [uint256(2 ether), 10000 ether],
                    currentPrice: 5000,
                    liquidity: liquidityRanges(
                        liquidityRange(4545, 5500, 1 ether, 5000 ether, 5000),
                        liquidityRange(5500, 6250, 1 ether, 5000 ether, 5000)
                    ),
                    transferInMintCallback: true,
                    transferInSwapCallback: true,
                    mintLiqudity: true
                })
            );

        uint256 swapAmount = 10000 ether; // 10000 USDC
        usdc.mint(address(this), swapAmount);
        usdc.approve(address(this), swapAmount);

        (int256 userBalance0Before, int256 userBalance1Before) = (
            int256(weth.balanceOf(address(this))),
            int256(usdc.balanceOf(address(this)))
        );

        (int256 amount0Delta, int256 amount1Delta) = pool.swap(
            address(this),
            false,
            swapAmount,
            sqrtP(6206),
            extra
        );

        assertEq(amount0Delta, -1.806151062659754714 ether, "invalid ETH out");
        assertEq(
            amount1Delta,
            9938.146841864722991247 ether,
            "invalid USDC in"
        );

        logFunction("testSwap_BuyETHConsecutivePriceRanges", false);
    }


    ////////////////////////////////////////////////////////////////////////////
    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) public {
        if (transferInMintCallback) {
            IUniswapV3Pool.CallbackData memory extra = abi.decode(
                data,
                (IUniswapV3Pool.CallbackData)
            );

            IERC20(extra.token0).transferFrom(extra.payer, msg.sender, amount0);
            IERC20(extra.token1).transferFrom(extra.payer, msg.sender, amount1);
        }
    }

    function uniswapV3SwapCallback(
        int256 amount0,
        int256 amount1,
        bytes calldata data
    ) public {
        if (transferInSwapCallback) {
            IUniswapV3Pool.CallbackData memory cbData = abi.decode(
                data,
                (IUniswapV3Pool.CallbackData)
            );

            if (amount0 > 0) {
                IERC20(cbData.token0).transferFrom(
                    cbData.payer,
                    msg.sender,
                    uint256(amount0)
                );
            }

            if (amount1 > 0) {
                IERC20(cbData.token1).transferFrom(
                    cbData.payer,
                    msg.sender,
                    uint256(amount1)
                );
            }
        }
    }

    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) public {
        (uint256 amount0, uint256 amount1) = abi.decode(
            data,
            (uint256, uint256)
        );

        if (amount0 > 0) weth.transfer(msg.sender, amount0 + fee0);
        if (amount1 > 0) usdc.transfer(msg.sender, amount1 + fee1);

        flashCallbackCalled = true;
    }

    function setupPool(PoolParams memory params)
        internal
        returns (
            LiquidityRange[] memory liquidity,
            uint256 poolBalance0,
            uint256 poolBalance1
        )
    {
        weth.mint(address(this), params.balances[0]);
        usdc.mint(address(this), params.balances[1]);

        pool = deployPool(
            factory,
            address(weth),
            address(usdc),
            3000,
            params.currentPrice
        );

        if (params.mintLiqudity) {
            weth.approve(address(this), params.balances[0]);
            usdc.approve(address(this), params.balances[1]);

            bytes memory extra = encodeExtra(
                address(weth),
                address(usdc),
                address(this)
            );

            uint256 poolBalance0Tmp;
            uint256 poolBalance1Tmp;
            for (uint256 i = 0; i < params.liquidity.length; i++) {
                (poolBalance0Tmp, poolBalance1Tmp) = pool.mint(
                    address(this),
                    params.liquidity[i].lowerTick,
                    params.liquidity[i].upperTick,
                    params.liquidity[i].amount,
                    extra
                );
                poolBalance0 += poolBalance0Tmp;
                poolBalance1 += poolBalance1Tmp;
            }
        }

        transferInMintCallback = params.transferInMintCallback;
        liquidity = params.liquidity;
    }

    function logFunction(string memory str, bool val) public{
        string memory key1 = string(abi.encodePacked("--------------------------",str, ".", val?"start":"end", "-----------------"));
        emit log(key1);
    }
}
