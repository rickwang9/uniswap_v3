import './SwapForm.css';
import { ethers } from 'ethers';
import { useContext, useEffect, useState } from 'react';
import { uint256Max } from '../lib/constants';
import { MetaMaskContext } from '../contexts/MetaMask';
import config from "../config.js";
import debounce from '../lib/debounce';
import AddLiquidityForm from './AddLiquidityForm';
import RemoveLiquidityForm from './RemoveLiquidityForm';
import PathFinder from '../lib/pathFinder';
/*
* pairs 交易对目前4个
* reduce，循环，acc上次返回值，pair当前pair
* 对象： {token1:tokenObj, token2:token2Obj....}
* 4个pairs，最终不是8个token，因为token有重复，共5个token。
* */
const pairsToTokens = (pairs) => {
  console.log('pairs ', pairs);
  const tokens = pairs.reduce((acc, pair) => {
    acc[pair.token0.address] = {
      symbol: pair.token0.symbol,
      address: pair.token0.address,
      selected: false
    };
    acc[pair.token1.address] = {
      symbol: pair.token1.symbol,
      address: pair.token1.address,
      selected: false
    };
    console.log('acc', acc);
    // console.log('acc', acc.length);
    return acc;
  }, {});

  return Object.keys(tokens).map(k => tokens[k]);
}
// 根据path，看swap路径的长度。
const countPathTokens = (path) => (path.length - 1) / 2 + 1;

const pathToTypes = (path) => {
  return ["address"].concat(new Array(countPathTokens(path) - 1).fill(["uint24", "address"]).flat());
}
// swap的输入框= 输入+ 下拉
const SwapInput = ({ token, tokens, onChange, amount, setAmount, disabled, readOnly }) => {
  return (
    <fieldset className="SwapInput" disabled={disabled}>
      <input type="text" id={token + "_amount"} placeholder="0.0" value={amount} onChange={(ev) => setAmount(ev.target.value)} readOnly={readOnly} />
      <select name="token" value={token} onChange={onChange}>
        {tokens.map(t => <option key={`${token}_${t.symbol}`}>{t.symbol}</option>)}
      </select>
    </fieldset>
  );
}
// 交换 TokenIn 和 TokenOut
const ChangeDirectionButton = ({ onClick, disabled }) => {
  return (
    <button className='ChangeDirectionBtn' onClick={onClick} disabled={disabled}>🔄</button>
  )
}
// 设置滑点
const SlippageControl = ({ setSlippage, slippage }) => {
  return (
    <fieldset className="SlippageControl">
      <label htmlFor="slippage">Slippage tolerance, %</label>
      <input type="text" value={slippage} onChange={(ev) => setSlippage(ev.target.value)} />
    </fieldset>
  );
}

const SwapForm = ({ setPairs }) => {
  const metamaskContext = useContext(MetaMaskContext);
  const enabled = metamaskContext.status === 'connected';
  const account = metamaskContext.account;

  const [zeroForOne, setZeroForOne] = useState(true);// token0 还是 token1
  const [amount0, setAmount0] = useState(0);
  const [amount1, setAmount1] = useState(0);
  const [tokenIn, setTokenIn] = useState();
  const [manager, setManager] = useState();
  const [quoter, setQuoter] = useState();//报价
  const [loading, setLoading] = useState(false);
  const [addingLiquidity, setAddingLiquidity] = useState(false);
  const [removingLiquidity, setRemovingLiquidity] = useState(false);
  const [slippage, setSlippage] = useState(0.1);
  const [tokens, setTokens] = useState();
  const [path, setPath] = useState();
  const [pathFinder, setPathFinder] = useState();

  useEffect(() => {
    // 创建manager合约对象， setManager是为了方便更新引用manager的地方
    setManager(new ethers.Contract(
      config.managerAddress,
      config.ABIs.Manager,
      new ethers.providers.Web3Provider(window.ethereum).getSigner()
    ));
    // 创建Quoter合约对象， setQuoter是为了方便更新引用Quoter的地方
    setQuoter(new ethers.Contract(
      config.quoterAddress,
      config.ABIs.Quoter,
      new ethers.providers.Web3Provider(window.ethereum).getSigner()
    ));
    // 设置 tokenIn == weth
    setTokenIn(new ethers.Contract(
      config.wethAddress,
      config.ABIs.ERC20,
      new ethers.providers.Web3Provider(window.ethereum).getSigner()
    ));

    loadPairs().then((pairs) => {
      // pairs.filter()[0] 返回满足条件的第一个pair
      const pair_ = pairs.filter((pair) => {
        return pair.token0.address === config.wethAddress || pair.token1.address === config.wethAddress;
      })[0];
      const path_ = [
        config.wethAddress,
        pair_.fee,
        pair_.token0.address === config.wethAddress ? pair_.token1.address : pair_.token0.address
      ];
      // 更新 4个 state, pairs是入参
      setPairs(pairs);
      setPath(path_);
      setPathFinder(new PathFinder(pairs));
      setTokens(pairsToTokens(pairs));
    });
  }, [setPairs]);

  /**
   * Load pairs from a Factory address by scanning for 'PoolCreated' events.
   * 
   * @returns array of 'pair' objects.
   */
  const loadPairs = () => {
    // 创建 factory 合约对象
    const factory = new ethers.Contract(
      config.factoryAddress,
      config.ABIs.Factory,
      new ethers.providers.Web3Provider(window.ethereum).getSigner()
    );
    // 查询从最早到现在的 PoolCreated 的事件
    return factory.queryFilter("PoolCreated", "earliest", "latest")
      .then((events) => {
        const pairs = events.map((event) => {
          return {
            token0: {
              address: event.args.token0,
              symbol: config.tokens[event.args.token0].symbol
            },
            token1: {
              address: event.args.token1,
              symbol: config.tokens[event.args.token1].symbol
            },
            fee: event.args.fee,
            address: event.args.pool
          }
        });
        console.log('PoolCreated ', pairs);
        return Promise.resolve(pairs);
      }).catch((err) => {
        console.error(err)
      });
  }


  /**
   * Swaps tokens by calling Manager contract. Before swapping, asks users to approve spending of tokens.
   * 交换按钮事件
   */
  const swap = (e) => {
    e.preventDefault();

    const amountIn = ethers.utils.parseEther(zeroForOne ? amount0 : amount1);
    const amountOut = ethers.utils.parseEther(zeroForOne ? amount1 : amount0);
    const minAmountOut = amountOut.mul((100 - parseFloat(slippage)) * 100).div(10000);
    /*
    * ['0x5FbDB2315678afecb367f032d93F642f64180aa3', 3000, '0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512']
    * ['address', 'uint24', 'address']
    * packedPath 0x5fbdb2315678afecb367f032d93f642f64180aa3000bb8e7f1725e7734ce288f8367e1bb143e90bb3f0512
    * 000bb8=3000
    * */
    const packedPath = ethers.utils.solidityPack(pathToTypes(path), path);
    console.log('path',path);
    console.log('pathToTypes(path)',pathToTypes(path));
    console.log('packedPath',packedPath);
    const params = {
      path: packedPath,
      recipient: account,
      amountIn: amountIn,
      minAmountOut: minAmountOut
    };
    const token = tokenIn.attach(path[0]);
    console.log('tokenIn',tokenIn);
    console.log('token',token);
    // 查询授权余额，不够就调用授权，然后swap，有结果提示成功
    token.allowance(account, config.managerAddress)
      .then((allowance) => {
        if (allowance.lt(amountIn)) {
          console.log('approve',{gasLimit: 5000000});
          return token.approve(config.managerAddress, uint256Max, {gasLimit: 5000000}).then(tx => tx.wait())
        }
      })
      .then(() => {
        console.log('swap',params);
        return manager.swap(params,{gasLimit: 5000000}).then(tx => tx.wait())
      })
      .then(() => {
        alert('Swap succeeded!');
      }).catch((err) => {
        console.error(err);
        alert('Failed!');
      });
  }

  /**
   * Calculates output amount by querying Quoter contract. Sets 'priceAfter' and 'amountOut'.
   *
   */
  const updateAmountOut = debounce((amount) => {
    if (amount === 0 || amount === "0") {
      return;
    }

    setLoading(true);

    const packedPath = ethers.utils.solidityPack(pathToTypes(path), path);
    const amountIn = ethers.utils.parseEther(amount);
    //调用合约查询价格，
    quoter.callStatic
      .quote(packedPath, amountIn)
      .then(({ amountOut }) => {
        // 根据In计算Out的值
        zeroForOne ? setAmount1(ethers.utils.formatEther(amountOut)) : setAmount0(ethers.utils.formatEther(amountOut));
        setLoading(false);
      })
      .catch((err) => {
        zeroForOne ? setAmount1(0) : setAmount0(0);
        setLoading(false);
        console.error(err);
      })
  })

  /**
   *  Wraps 'setAmount', ensures amount is correct, and calls 'updateAmountOut'.
   *  输入金额
   *
   */
  const setAmountFn = (setAmountFn) => {
    return (amount) => {
      amount = amount || 0;
      setAmountFn(amount);
      updateAmountOut(amount)
    }
  }

  const toggleAddLiquidityForm = () => {
    if (!addingLiquidity) {
      if (path.length > 3) {
        const token0 = tokens.filter(t => t.address === path[0])[0];
        const token1 = tokens.filter(t => t.address === path[path.length - 1])[0];
        alert(`Cannot add liquidity: ${token0.symbol}/${token1.symbol} pair doesn't exist!`);
        return false;
      }
    }

    setAddingLiquidity(!addingLiquidity);
  }

  const toggleRemoveLiquidityForm = () => {
    if (!removingLiquidity) {
      if (path.length > 3) {
        const token0 = tokens.filter(t => t.address === path[0])[0];
        const token1 = tokens.filter(t => t.address === path[path.length - 1])[0];
        alert(`Cannot add liquidity: ${token0.symbol}/${token1.symbol} pair doesn't exist!`);
        return false;
      }
    }

    setRemovingLiquidity(!removingLiquidity);
  }

  /**
   * Set currently selected pair based on selected tokens.
   * 
   * @param {symbol} selected token symbol
   * @param {index} token index
   */
  const selectToken = (symbol, index) => {
    let token0, token1;

    if (index === 0) {
      token0 = tokens.filter(t => t.symbol === symbol)[0].address;
      token1 = path[path.length - 1];
    }

    if (index === 1) {
      token0 = path[0];
      token1 = tokens.filter(t => t.symbol === symbol)[0].address;
    }

    if (token0 === token1) {
      return false;
    }

    try {
      setPath(pathFinder.findPath(token0, token1));
      setAmount0(0);
      setAmount1(0);
    } catch {
      alert(`${token0.symbol}/${token1.symbol} pair doesn't exist!`);
    }
  }

  /**
   * Toggles swap direction.
   */
  const toggleDirection = (e) => {
    e.preventDefault();

    setZeroForOne(!zeroForOne);
    setPath(path.reverse());
  }

  const tokenByAddress = (address) => {
    return tokens.filter(t => t.address === address)[0];
  }

  return (
    <section className="SwapContainer">
      {addingLiquidity &&
        <AddLiquidityForm
          toggle={toggleAddLiquidityForm}
          token0Info={tokens.filter(t => t.address === path[0])[0]}
          token1Info={tokens.filter(t => t.address === path[2])[0]}
          fee={path[1]}
        />
      }
      {removingLiquidity &&
        <RemoveLiquidityForm
          toggle={toggleRemoveLiquidityForm}
          token0Info={tokens.filter(t => t.address === path[0])[0]}
          token1Info={tokens.filter(t => t.address === path[2])[0]}
          fee={path[1]}
        />
      }
      <header>
        <h1>Swap tokens</h1>
        <button disabled={!enabled || loading} onClick={toggleAddLiquidityForm}>Add liquidity</button>
        <button disabled={!enabled || loading} onClick={toggleRemoveLiquidityForm}>Remove liquidity</button>
      </header>
      {path ?
        <form className="SwapForm">
          <SwapInput
            amount={zeroForOne ? amount0 : amount1}
            disabled={!enabled || loading}
            onChange={(ev) => selectToken(ev.target.value, 0)}
            readOnly={false}
            setAmount={setAmountFn(zeroForOne ? setAmount0 : setAmount1)}
            token={tokenByAddress(path[0]).symbol}
            tokens={tokens} />

          <ChangeDirectionButton zeroForOne={zeroForOne} onClick={toggleDirection} disabled={!enabled || loading} />

          <SwapInput
            amount={zeroForOne ? amount1 : amount0}
            disabled={!enabled || loading}
            onChange={(ev) => selectToken(ev.target.value, 1)}
            readOnly={true}
            token={tokenByAddress(path[path.length - 1]).symbol}
            tokens={tokens.filter(t => t.address !== path[0])} />

          <SlippageControl
            setSlippage={setSlippage}
            slippage={slippage} />

          <button className='swap' disabled={!enabled || loading} onClick={swap}>Swap</button>
        </form>
        :
        <span>Loading pairs...</span>}
    </section>
  )
}

export default SwapForm;