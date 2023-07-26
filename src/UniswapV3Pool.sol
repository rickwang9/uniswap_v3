// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "forge-std/Test.sol";

import "prb-math/PRBMath.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV3FlashCallback.sol";
import "./interfaces/IUniswapV3MintCallback.sol";
import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3PoolDeployer.sol";
import "./interfaces/IUniswapV3SwapCallback.sol";

import "./lib/FixedPoint128.sol";
import "./lib/LiquidityMath.sol";
import "./lib/Math.sol";
import "./lib/Oracle.sol";
import "./lib/Position.sol";
import "./lib/SwapMath.sol";
import "./lib/Tick.sol";
import "./lib/TickBitmap.sol";
import "./lib/TickMath.sol";

contract UniswapV3Pool is IUniswapV3Pool, Test{
    using Oracle for Oracle.Observation[65535];
    using Position for Position.Info;
    using Position for mapping(bytes32 => Position.Info);
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);

    error AlreadyInitialized();
    error FlashLoanNotPaid();
    error InsufficientInputAmount();
    error InvalidPriceLimit();
    error InvalidTickRange();
    error NotEnoughLiquidity();
    error ZeroLiquidity();

    event Burn(
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    event Collect(
        address indexed owner,
        address recipient,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint256 amount0,
        uint256 amount1
    );

    event Flash(address indexed recipient, uint256 amount0, uint256 amount1);

    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld,
        uint16 observationCardinalityNextNew
    );

    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    // Pool parameters
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable tickSpacing;
    uint24 public immutable fee;

    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    // First slot will contain essential data
    struct Slot0 {
        // Current sqrt(P)
        uint160 sqrtPriceX96;
        // Current tick
        int24 tick;
        // Most recent observation index
        uint16 observationIndex;
        // Maximum number of observations
        uint16 observationCardinality;
        // Next maximum number of observations
        uint16 observationCardinalityNext;
    }

    struct SwapState {
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 feeGrowthGlobalX128;
        uint128 liquidity;
    }

    struct StepState {
        uint160 sqrtPriceStartX96;
        int24 nextTick;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    Slot0 public slot0;

    // Amount of liquidity, L.
    uint128 public liquidity;

    mapping(int24 => Tick.Info) public ticks;
    mapping(int16 => uint256) public tickBitmap;
    mapping(bytes32 => Position.Info) public positions;
    Oracle.Observation[65535] public observations;

    constructor() {
        (factory, token0, token1, tickSpacing, fee) = IUniswapV3PoolDeployer(
            msg.sender
        ).parameters();
    }

    function initialize(uint160 sqrtPriceX96) public {
        if (slot0.sqrtPriceX96 != 0) revert AlreadyInitialized();

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(
            _blockTimestamp()
        );

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext
        });
    }

    struct ModifyPositionParams {
        address owner;
        int24 lowerTick;
        int24 upperTick;
        int128 liquidityDelta;
    }

    function _modifyPosition(ModifyPositionParams memory params)
        internal
        returns (
            Position.Info storage position,
            int256 amount0,
            int256 amount1
        )
    {
        mylog('------------_modifyPosition.start-------------');
        mylog('input.params.lowerTick', params.lowerTick);
        mylog('input.params.upperTick', params.upperTick);
        mylog('input.params.liquidityDelta', params.liquidityDelta);


        // gas optimizations
        Slot0 memory slot0_ = slot0;
        uint256 feeGrowthGlobal0X128_ = feeGrowthGlobal0X128;
        uint256 feeGrowthGlobal1X128_ = feeGrowthGlobal1X128;

        mylog('currentTick', slot0_.tick);
        mylog(slot0_);
        mylog('feeGrowthGlobal0X128_', feeGrowthGlobal0X128_);
        mylog('feeGrowthGlobal1X128_', feeGrowthGlobal1X128_);

        position = positions.get(
            params.owner,
            params.lowerTick,
            params.upperTick
        );
        mylog(position);
        //更新tick的L，出来的是经过tick的L变化

        bool flippedLower = update(ticks,
            params.lowerTick, slot0_.tick, int128(params.liquidityDelta),
            feeGrowthGlobal0X128_, feeGrowthGlobal1X128_, false
        );

        bool flippedUpper = update(ticks,
            params.upperTick, slot0_.tick, int128(params.liquidityDelta),
            feeGrowthGlobal0X128_, feeGrowthGlobal1X128_, true
        );

        mylog('flippedLower', flippedLower);
        mylog('flippedUpper', flippedUpper);
        // 在位图上标记tick的激活状态，下次找tick从激活中的tick找。
        if (flippedLower) {
            tickBitmap.flipTick(params.lowerTick, int24(tickSpacing));
        }
        if (flippedUpper) {
            tickBitmap.flipTick(params.upperTick, int24(tickSpacing));
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            getFeeGrowthInside(
                ticks,
                params.lowerTick,
                params.upperTick,
                slot0_.tick,
                feeGrowthGlobal0X128_,
                feeGrowthGlobal1X128_
            );
        mylog('feeGrowthInside0X128', feeGrowthInside0X128);
        mylog('feeGrowthInside1X128', feeGrowthInside1X128);

        position.update(params.liquidityDelta,feeGrowthInside0X128,feeGrowthInside1X128);
        mylog(position);

        if (slot0_.tick < params.lowerTick) {
            amount0 = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
            mylog("< params.lowerTick amount0", amount0);
        } else if (slot0_.tick < params.upperTick) {
            amount0 = Math.calcAmount0Delta(
                slot0_.sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );

            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                slot0_.sqrtPriceX96,
                params.liquidityDelta
            );

            liquidity = LiquidityMath.addLiquidity(liquidity, params.liquidityDelta);
            mylog("params.lowerTick~params.upperTick amount0", amount0);
            mylog("params.lowerTick~params.upperTick amount1", amount1);
            mylog("params.lowerTick~params.upperTick liquidity", liquidity);
        } else {
            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
            mylog("> params.upperTick amount0", amount1);
        }
        mylog('------------_modifyPosition.end-------------');
    }

    function mint(
        address owner,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1) {
        mylog('------------mint.start-------------');
        mylog('input.lowerTick', lowerTick);
        mylog('input.upperTick', upperTick);
        mylog('input.amount', amount);
        if (
            lowerTick >= upperTick ||
            lowerTick < TickMath.MIN_TICK ||
            upperTick > TickMath.MAX_TICK
        ) revert InvalidTickRange();

        if (amount == 0) revert ZeroLiquidity();

        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: owner,
                lowerTick: lowerTick,
                upperTick: upperTick,
                liquidityDelta: int128(amount)
            })
        );
        mylog('_modifyPosition.result.amount0Int', amount0Int);
        mylog('_modifyPosition.result.amount1Int', amount1Int);
        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Before;
        uint256 balance1Before;

        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        mylog('balance0Before', balance0Before);
        mylog('balance1Before', balance1Before);

        //amount0 和 amount1 是计算出来的，通知前面transfer的
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(
            amount0,
            amount1,
            data
        );
        mylog('amount0 > 0', amount0 > 0);
        mylog('balance0()', balance0());
        mylog('balance1()', balance1());
        mylog('balance0Before + amount0 > balance0()', balance0Before + amount0 > balance0());
        if (amount0 > 0 && balance0Before + amount0 > balance0())
            revert InsufficientInputAmount();
        mylog('amount1 > 0', amount1 > 0);
        mylog('balance1Before + amount1 > balance1()', balance1Before + amount1 > balance1());
        if (amount1 > 0 && balance1Before + amount1 > balance1())
            revert InsufficientInputAmount();

        emit Mint(msg.sender,owner,lowerTick,upperTick,amount,amount0,amount1);
        mylog('------------mint.end-------------');
    }

    function burn(
        int24 lowerTick,
        int24 upperTick,
        uint128 amount
    ) public returns (uint256 amount0, uint256 amount1) {
        mylog('------------burn.start-------------');
        mylog('input.lowerTick', lowerTick);
        mylog('input.upperTick', upperTick);
        mylog('input.amount', amount);


        (
            Position.Info storage position,
            int256 amount0Int,
            int256 amount1Int
        ) = _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    lowerTick: lowerTick,
                    upperTick: upperTick,
                    liquidityDelta: -(int128(amount))
                })
            );
        mylog(position);
        mylog('_modifyPosition.result.amount0Int', amount0Int);
        mylog('_modifyPosition.result.amount1Int', amount1Int);
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }
        mylog(position);
        emit Burn(msg.sender, lowerTick, upperTick, amount, amount0, amount1);
        mylog('------------burn.end-------------');
    }

    function collect(
        address recipient,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) public returns (uint128 amount0, uint128 amount1) {
        Position.Info storage position = positions.get(
            msg.sender,
            lowerTick,
            upperTick
        );

        amount0 = amount0Requested > position.tokensOwed0
            ? position.tokensOwed0
            : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1
            ? position.tokensOwed1
            : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            IERC20(token0).transfer(recipient, amount0);
        }

        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            IERC20(token1).transfer(recipient, amount1);
        }

        emit Collect(
            msg.sender,
            recipient,
            lowerTick,
            upperTick,
            amount0,
            amount1
        );
    }


    function swap(
        address recipient,
        bool zeroForOne,
        uint256 amountSpecified,
        uint160 sqrtPriceLimitX96,// 交易的价格限制（超出即停止交易）滑点
        bytes calldata data
    ) public returns (int256 amount0, int256 amount1) {
        mylog('------------swap.start-------------');
        mylog('input.zeroForOne', zeroForOne);
        mylog('input.amountSpecified', amountSpecified);
        mylog('input.sqrtPriceLimitX96', sqrtPriceLimitX96);
        // Caching for gas saving
        Slot0 memory slot0_ = slot0;
        uint128 liquidity_ = liquidity;
        mylog(slot0);
        if (
            zeroForOne
                ? sqrtPriceLimitX96 > slot0_.sqrtPriceX96 ||  sqrtPriceLimitX96 < TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 < slot0_.sqrtPriceX96 ||  sqrtPriceLimitX96 > TickMath.MAX_SQRT_RATIO
        ) revert InvalidPriceLimit();

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            liquidity: liquidity_
        });
        mylog(state);
        uint i=0;
        mylog('while.start--------------');
        // state.amountSpecifiedRemaining > 0 =》还未swap完input state.sqrtPriceX96 != sqrtPriceLimitX96=》还未到滑点最大值
        while (state.amountSpecifiedRemaining > 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            mylog('index = ', i++);


            StepState memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.nextTick, ) = tickBitmap.nextInitializedTickWithinOneWord(state.tick, int24(tickSpacing), zeroForOne);

            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);

            (
                state.sqrtPriceX96,
                step.amountIn,
                step.amountOut,
                step.feeAmount
            ) = computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne? step.sqrtPriceNextX96 < sqrtPriceLimitX96: step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96: step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            state.amountSpecifiedRemaining -= step.amountIn + step.feeAmount;
            state.amountCalculated += step.amountOut;

            if (state.liquidity > 0) {
                state.feeGrowthGlobalX128 += PRBMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity );
            }
            mylog('state.sqrtPriceX96', state.sqrtPriceX96);
            mylog('step.sqrtPriceNextX96', step.sqrtPriceNextX96);

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                int128 liquidityDelta = cross(
//                    ticks,
                    step.nextTick,
                    (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128 ),
                    (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128 )
                );
                mylog('liquidityDelta', liquidityDelta);

                if (zeroForOne) liquidityDelta = -liquidityDelta;

                state.liquidity = LiquidityMath.addLiquidity(state.liquidity, liquidityDelta );

                if (state.liquidity == 0) revert NotEnoughLiquidity();

                state.tick = zeroForOne ? step.nextTick - 1 : step.nextTick;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
            mylog(step);
            mylog(state);
        }
        mylog('while end final ---------');

        mylog('state.tick', state.tick);
        mylog('slot0_.tick', slot0_.tick);

        if (state.tick != slot0_.tick) {//更新slot
            (uint16 observationIndex, uint16 observationCardinality) =
            observations.write(
                    slot0_.observationIndex,
                    _blockTimestamp(),
                    slot0_.tick,
                    slot0_.observationCardinality,
                    slot0_.observationCardinalityNext);

            (   slot0.sqrtPriceX96,
                slot0.tick,
                slot0.observationIndex,
                slot0.observationCardinality) =
            (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }
        mylog('liquidity_', liquidity_);
        mylog('state.liquidity', state.liquidity);
        if (liquidity_ != state.liquidity) liquidity = state.liquidity;//cross时会改变

        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }
        //部分成交？
        (amount0, amount1) = zeroForOne
            ? (int256(amountSpecified - state.amountSpecifiedRemaining),
                -int256(state.amountCalculated))
            : (-int256(state.amountCalculated),
                int256(amountSpecified - state.amountSpecifiedRemaining));

        mylog('amount0', amount0);
        mylog('amount1', amount1);

        if (zeroForOne) {
            IERC20(token1).transfer(recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback( amount0, amount1, data );
            if (balance0Before + uint256(amount0) > balance0())
                revert InsufficientInputAmount();
        } else {
            IERC20(token0).transfer(recipient, uint256(-amount0));//负数表示pool减少，event显示用的

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback( amount0, amount1, data );
            if (balance1Before + uint256(amount1) > balance1())
                revert InsufficientInputAmount();
        }

        emit Swap(msg.sender,recipient,amount0,amount1,slot0.sqrtPriceX96,state.liquidity,slot0.tick);
        mylog('------------swap.end-------------');
    }

    function computeSwapStep(
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96,
        uint128 liquidity,
        uint256 amountRemaining,
        uint24 fee
    ) internal  returns (uint160 sqrtPriceNextX96,uint256 amountIn,uint256 amountOut,uint256 feeAmount )
    {
        mylog('--------------computeSwapStep.start--------------');
        mylog('input.sqrtPriceCurrentX96', sqrtPriceCurrentX96);
        mylog('input.sqrtPriceTargetX96', sqrtPriceTargetX96);
        mylog('input.liquidity', liquidity);
        mylog('input.amountRemaining', amountRemaining);
        mylog('input.fee', fee);
        bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;//amount0进入，价格会降低
        uint256 amountRemainingLessFee = PRBMath.mulDiv(amountRemaining, 1e6 - fee, 1e6 );

        mylog('zeroForOne', zeroForOne);
        mylog('amountRemainingLessFee', amountRemainingLessFee);

        amountIn = zeroForOne ? Math.calcAmount0Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, true )
        : Math.calcAmount1Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity, true );

        mylog('amountIn', amountIn);

        if (amountRemainingLessFee >= amountIn){
            sqrtPriceNextX96 = sqrtPriceTargetX96;//target就是nextTick的价格。，超过了最远到这。
        } else{
            sqrtPriceNextX96 = Math.getNextSqrtPriceFromInput(sqrtPriceCurrentX96, liquidity, amountRemainingLessFee, zeroForOne );
        }
        mylog('sqrtPriceNextX96', sqrtPriceNextX96);

        bool max = sqrtPriceNextX96 == sqrtPriceTargetX96;

        mylog('max', max);

        if (zeroForOne) {
            amountIn = max ? amountIn
            : Math.calcAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, true );
            amountOut = Math.calcAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, false );
        } else {
            amountIn = max ? amountIn :
            Math.calcAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, true);
            amountOut = Math.calcAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity, false) ;
        }

        mylog('amountIn', amountIn);
        mylog('amountOut', amountOut);

        if (!max) {
            feeAmount = amountRemaining - amountIn;
        } else {
            feeAmount = Math.mulDivRoundingUp(amountIn, fee, 1e6 - fee);
        }
        mylog('--------------computeSwapStep.end--------------');
    }


    function flash(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) public {
        uint256 fee0 = Math.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = Math.mulDivRoundingUp(amount1, fee, 1e6);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        if (amount0 > 0) IERC20(token0).transfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(token1).transfer(msg.sender, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(
            fee0,
            fee1,
            data
        );

        if (IERC20(token0).balanceOf(address(this)) < balance0Before + fee0)
            revert FlashLoanNotPaid();
        if (IERC20(token1).balanceOf(address(this)) < balance1Before + fee1)
            revert FlashLoanNotPaid();

        emit Flash(msg.sender, amount0, amount1);
    }

    function observe(uint32[] calldata secondsAgos)
        public
        view
        returns (int56[] memory tickCumulatives)
    {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                slot0.observationCardinality
            );
    }

    function increaseObservationCardinalityNext(
        uint16 observationCardinalityNext
    ) public {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext;
        uint16 observationCardinalityNextNew = observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );

        if (observationCardinalityNextNew != observationCardinalityNextOld) {
            slot0.observationCardinalityNext = observationCardinalityNextNew;
            emit IncreaseObservationCardinalityNext(
                observationCardinalityNextOld,
                observationCardinalityNextNew
            );
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    //
    // INTERNAL
    //
    ////////////////////////////////////////////////////////////////////////////
    function balance0() internal returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function balance1() internal returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }

    function _blockTimestamp() internal view returns (uint32 timestamp) {
        timestamp = uint32(block.timestamp);
    }


    ///////////////////////////////////////////////////////////////

    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 currentTick,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        bool upper
    ) internal returns (bool flipped) {
        Tick.Info storage tickInfo = self[tick];
        mylog('tick.before update upper', upper);
        mylog(tickInfo, tick);
        uint128 liquidityBefore = tickInfo.liquidityGross;
        uint128 liquidityAfter = LiquidityMath.addLiquidity(
            liquidityBefore,
            liquidityDelta
        );
        //? 看不懂打印就懂了 liquidityDelta不是uint，burn时为负数。
        flipped = (liquidityAfter == 0) != (liquidityBefore == 0);

        if (liquidityBefore == 0) {
            // by convention, assume that all previous fees were collected below
            // the tick
            if (tick <= currentTick) {
                tickInfo.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                tickInfo.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }

            tickInfo.initialized = true;
        }

        tickInfo.liquidityGross = liquidityAfter;//Gross 一直累加
        tickInfo.liquidityNet = upper// Net 经过upper减，经过lower加。
        ? int128(int256(tickInfo.liquidityNet) - liquidityDelta)
        : int128(int256(tickInfo.liquidityNet) + liquidityDelta);
        mylog('tick.after update');
        mylog(tickInfo, tick);
    }

    function cross(
//        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal returns (int128 liquidityDelta) {
        Tick.Info storage info = ticks[tick];
        mylog('tick.before cross');
        mylog(info, tick);

        info.feeGrowthOutside0X128 =feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
        liquidityDelta = info.liquidityNet;

        mylog('tick.after cross');
        mylog('liquidityDelta', liquidityDelta);
        mylog(info, tick);

    }

    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        int24 lowerTick_,
        int24 upperTick_,
        int24 currentTick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        Tick.Info storage lowerTick = self[lowerTick_];
        Tick.Info storage upperTick = self[upperTick_];

        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;
        if (currentTick >= lowerTick_) {
            feeGrowthBelow0X128 = lowerTick.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lowerTick.feeGrowthOutside1X128;
        } else {
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lowerTick.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lowerTick.feeGrowthOutside1X128;
        }

        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;
        if (currentTick < upperTick_) {
            feeGrowthAbove0X128 = upperTick.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upperTick.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upperTick.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upperTick.feeGrowthOutside1X128;
        }

        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }


    // https://learnblockchain.cn/docs/foundry/i18n/zh/reference/ds-test.html
    function mylog (string memory key) public {
        emit log(key);
    }
    function mylog (string memory key, bool val) public {
        string memory key1 = string(abi.encodePacked(key, " ", val?"true":"false", " "));
        emit log(key1);
    }
    function mylog (string memory key, int val) public {
        emit log_named_decimal_int(key, val, 0);
    }
    function mylog (string memory key, uint val) public {
        emit log_named_decimal_uint(key, val, 0);
    }
    function mylog (string memory key, uint val, uint decimals) public {
        emit log_named_decimal_uint(key, val, decimals);
    }
    function mylog (Slot0 memory slot) public {
        mylog('Slot0----------------------');
        mylog("slot0.sqrtPriceX96", slot.sqrtPriceX96);
        mylog("slot0.tick", slot0.tick);
//        mylog("slot0.observationIndex", slot.observationIndex);
//        mylog("slot0.observationCardinality", slot.observationCardinality);
//        mylog("slot0.observationCardinalityNext", slot.observationCardinalityNext);
        mylog('----------------------------');
    }

    function mylog (SwapState memory state) public {
        mylog('SwapState----------------------');
        mylog("SwapState.amountSpecifiedRemaining", state.amountSpecifiedRemaining);
        mylog("SwapState.amountCalculated", state.amountCalculated);
        mylog("SwapState.sqrtPriceX96", state.sqrtPriceX96);
        mylog("SwapState.tick", state.tick);
        mylog("SwapState.feeGrowthGlobalX128", state.feeGrowthGlobalX128);
        mylog("SwapState.liquidity", state.liquidity);
        mylog('----------------------------');
    }

    function mylog (StepState memory state) public {
        mylog('StepState----------------------');
        mylog("StepState.sqrtPriceStartX96", state.sqrtPriceStartX96);
        mylog("StepState.nextTick", state.nextTick);
        mylog("StepState.initialized", state.initialized);//bool
        mylog("StepState.sqrtPriceNextX96", state.sqrtPriceNextX96);
        mylog("StepState.amountIn", state.amountIn);
        mylog("StepState.amountOut", state.amountOut);
        mylog("StepState.feeAmount", state.feeAmount);
        mylog('----------------------------');
    }
    function mylog (Position.Info memory position) public {
        mylog('Position.Info----------------------');
        mylog("position.liquidity", position.liquidity);
        mylog("position.feeGrowthInside0LastX128", position.feeGrowthInside0LastX128);
        mylog("position.feeGrowthInside1LastX128", position.feeGrowthInside1LastX128);
        mylog("position.tokensOwed0", position.tokensOwed0);
        mylog("position.tokensOwed1", position.tokensOwed1);
        mylog('----------------------------');
    }
    function mylog (Tick.Info memory tickInfo, int24 tick) public {
        mylog('tickInfo----------------------');
        mylog("tickInfo.index", tick);
        mylog("tickInfo.initialized", tickInfo.initialized);
        mylog("tickInfo.liquidityGross", tickInfo.liquidityGross);
        mylog("tickInfo.liquidityNet", tickInfo.liquidityNet);
        mylog("tickInfo.feeGrowthOutside0X128", tickInfo.feeGrowthOutside0X128);
        mylog("tickInfo.feeGrowthOutside1X128", tickInfo.feeGrowthOutside1X128);
        mylog('----------------------------');
    }
}
