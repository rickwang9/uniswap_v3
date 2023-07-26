// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "forge-std/Test.sol";
import "../TestUtils.sol";
/*
    forge test --contracts ./test/my/MyError.t.sol -vvv 这个会编译56个合约
forge script scripts/DeployDevelopment.s.sol --broadcast --fork-url="http://127.0.0.1:8545"
forge test --match-path ./test/my/MyError.t.sol --match-contract MyError --match-test "test*" -vvv
*/
interface IUniswapV3Quoter {
    function quote(bytes memory path, uint256 amountIn)
    external
    returns (
        uint256 amountOut,
        uint160[] memory sqrtPriceX96AfterList,
        int24[] memory tickAfterList
    );
}
//interface IERC20 {
//    event Approval(address indexed owner, address indexed spender, uint256 value);
//    event Transfer(address indexed from, address indexed to, uint256 value);
//
//    function name() external view returns (string memory);
//
//    function symbol() external view returns (string memory);
//
//    function decimals() external view returns (uint8);
//
//    function totalSupply() external view returns (uint256);
//
//    function balanceOf(address owner) external view returns (uint256);
//
//    function allowance(address owner, address spender)
//    external
//    view
//    returns (uint256);
//
//    function approve(address spender, uint256 value) external returns (bool);
//
//    function transfer(address to, uint256 value) external returns (bool);
//
//    function transferFrom(
//        address from,
//        address to,
//        uint256 value
//    ) external returns (bool);
//    function withdraw(uint256 wad) external;
//    function deposit(uint256 wad) external returns (bool);
//    function owner() external view virtual returns (address);
//}
contract MyError is Test, TestUtils   {
//    CheatCodes cheats = CheatCodes(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    IUniswapV3Quoter quoter = IUniswapV3Quoter(0xa513E6E4b8f2a923D98304ec87F64353C4D5C853);
    IERC20 weth = IERC20(0x5FbDB2315678afecb367f032d93F642f64180aa3);
    IERC20 usdc = IERC20(0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512);
    function setUp() public {
        vm.createSelectFork("http://127.0.0.1:8545");
    }
// forge test --match-path ./test/my/MyError.t.sol --match-contract MyError --match-test "testInfo*" -vv
    function testPriceSqrPTickInfo() public{
        console.log('testPriceSqrPTickInfo--------------------');
        uint[] memory arr = new uint[](15);
        arr[0] = 1;
        arr[1] = 2;
        arr[2] = 3;
        arr[3] = 4;
        arr[4] = 5;
        arr[5] = 6;
        arr[6] = 7;
        arr[7] = 8;
        arr[8] = 9;
        arr[9] = 10;
        arr[10] = 100;
        arr[11] = 200;
        arr[12] = 500;
        arr[13] = 1000;
        arr[14] = 5000;

        for(uint i=0;i<arr.length;i++){
            uint price = arr[i];
            uint160 sqrtPrice = sqrtP(price);
            int24 tick = tick60(price);
            console.log('price',price);
            console.log('sqrtPrice',sqrtPrice);
            console.logInt(tick);
        }
        console.log('testPriceSqrPTickInfo--------------------');
    }

    function encodeErrorLog(string memory error) internal view returns (bytes memory encoded)
    {
        encoded = abi.encodeWithSignature(error);
        console.log('encodeError',error);
        console.logBytes(encoded);
    }

    /**
     * UNI -> ETH -> USDC
     *    10/1   1/5000
     */
    function testQuoteUNIforUSDCviaETH() public {
        bytes memory path = bytes.concat(bytes20(address(weth)),bytes3(uint24(3000)),bytes20(address(usdc)));

        encodeErrorLog("InvalidPriceLimit()");
        encodeErrorLog("NotEnoughLiquidity()");
        encodeErrorLog("InsufficientInputAmount()");


//        vm.expectRevert(encodeError("NotEnoughLiquidity()"));
        (uint256 amountOut, uint160[] memory sqrtPriceX96AfterList, int24[] memory tickAfterList
        ) = quoter.quote(path, 3 ether);
        console.log('this is end!!!!!!!!!!!!!!!!!!!!!!');
//        assertEq(amountOut, 1463.863228593034635225 ether, "invalid amountOut");
//        assertEq(
//            sqrtPriceX96AfterList[0],
//            251771757807685223741030010328, // 10.098453187753986
//            "invalid sqrtPriceX96After"
//        );
//        assertEq(
//            sqrtPriceX96AfterList[1],
//            5527273314166940201896143730186, // 4867.015316523305
//            "invalid sqrtPriceX96After"
//        );
//        assertEq(tickAfterList[0], 23124, "invalid tickAFter");
//        assertEq(tickAfterList[1], 84906, "invalid tickAFter");
    }

}
