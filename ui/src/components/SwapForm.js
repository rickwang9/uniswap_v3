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
import {InputNumber, Select, Button, Space, Row, Col,Card,Form,Input,Dropdown,message , Table, Modal, Tooltip, Typography} from 'antd';
import { DownOutlined, UserOutlined,SettingOutlined,LoadingOutlined , PlusOutlined  } from '@ant-design/icons';
const { Option } = Select;

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
  console.log('Object.keys(tokens).map(k => tokens[k])',Object.keys(tokens).map(k => tokens[k]));
  return Object.keys(tokens).map(k => tokens[k]);
}

// 根据path，看swap路径的长度。
const countPathTokens = (path) => (path.length - 1) / 2 + 1;
const pathToTypes = (path) => {
  return ["address"].concat(new Array(countPathTokens(path) - 1).fill(["uint24", "address"]).flat());
}

const SwapInput = ({token, amount, setAmount, label, setShow, setIsZeroShow})=>{
  return (
      <>
        <Form.Item onChange={(ev) => setAmount(ev.target.value)} id={token + "_amount"} label={label} name={label}  labelCol={{ span: 2 }}  style={{marginBottom:'0px'}}>
          <Input size={"large"} style={{ width: '80%' }} id={token + "_amount"} value={amount} placeholder="0.0" />

          <a style={{marginLeft:"20px", width: '20%' }} onClick={(e) => {
            e.preventDefault()
            if(label == 'From'){
              setIsZeroShow(true);
            }else{
              setIsZeroShow(false);
            }
            setShow(true);
          }}>
            <Space>
              <Typography.Link href="#API">{token.symbol} <DownOutlined /></Typography.Link>
            </Space>
          </a>
        </Form.Item>
      </>

  )
};
//setPairs是个function
const SwapForm = ({ setPairs }) => {

  const metamaskContext = useContext(MetaMaskContext);
  const enabled = metamaskContext.status === 'connected';
  const account = metamaskContext.account;

  const [isShow, setIsShow] = useState(false); // 控制modal显示和隐藏
  const [isZeroShow, setIsZeroShow] = useState(true); // 控制modal显示和隐藏
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

  useEffect(()=>{
    // 创建manager合约对象， setManager是为了方便更新引用manager的地方
    const provider = new ethers.providers.Web3Provider(window.ethereum);
    provider.on("debug", console.log);
    setManager(new ethers.Contract(
        config.managerAddress,
        config.ABIs.Manager,
        provider.getSigner()
    ));
    // 创建Quoter合约对象， setQuoter是为了方便更新引用Quoter的地方
    setQuoter(new ethers.Contract(
        config.quoterAddress,
        config.ABIs.Quoter,
        provider.getSigner()
    ));
    // 设置 tokenIn == weth
    setTokenIn(new ethers.Contract(
        config.wethAddress,
        config.ABIs.ERC20,
        provider.getSigner()
    ));


    loadPairs().then((pairs) => {
      // pairs.filter()[0] 返回满足条件的第一个pair
      console.log('pairs',pairs);
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
      console.log('145              ',tokens);
    });

  },[setPairs]);

  const loadPairs = () => {
    // let wallet = new ethers.Wallet(account_from.privateKey, provider);
    // 创建 factory 合约对象
    const factory = new ethers.Contract(
        config.factoryAddress,
        config.ABIs.Factory,
        // wallet
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
          console.error('err', err)
        });
  }

  const updateAmountOut = debounce((amount) => {
    if (amount === 0 || amount === "0") {
      return;
    }

    setLoading(true);

    const packedPath = ethers.utils.solidityPack(pathToTypes(path), path);
    const amountIn = ethers.utils.parseEther(amount);
    console.log('packedPath',packedPath);
    console.log('amountIn',amountIn);
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


  const setAmountFn = (setAmountFn) => {
    return (amount) => {
      amount = amount || 0;
      setAmountFn(amount);
      updateAmountOut(amount)
    }
  }

  const selectToken = (symbol, index) => {
    let token0, token1;
    console.log('tokens',tokens);
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

  const toggleDirection = (e) => {
    e.preventDefault();

    setZeroForOne(!zeroForOne);
    console.log('toggleDirection',path);
    setPath(path.reverse());
  }

  const tokenByAddress = (address) => {
    return tokens.filter(t => t.address === address)[0];
  }

  let data = [];
  if(tokens) {
    tokens.forEach((token, index) => {
      data.push({
        key: index,
        name: token.symbol,
      });
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
          setLoading(true);
          console.log('swap',params);
          return manager.swap(params,{gasLimit: 5000000}).then(tx => tx.wait())
        })
        .then(() => {
          setLoading(false);
          alert('Swap succeeded!');
        }).catch((err) => {
          console.error(err);
          setLoading(false);
          alert('Failed!');
        });
  }





  return (
    <>
      <Row style={{margin:'100px 0px'}}>
        <Col md={{
          span:8,
          push:8,
        }}>
          <Card title='Swap'>
            <Form
                layout='horizontal'
                onFinish={(v) => {
                  // setQuery(v);
                }}
            >
              <SwapInput
                 amount={zeroForOne ? amount0 : amount1}
                 disabled={!enabled || loading}
                 selectToken={selectToken}
                 readOnly={false}
                 setAmount={setAmountFn(zeroForOne ? setAmount0 : setAmount1)}
                 token={path?tokenByAddress(path[0]):tokens?tokens[0]:''}
                 label={"From"}
                 setShow={setIsShow}
                 setIsZeroShow={setIsZeroShow}
              />
              <Form.Item   style={{marginBottom:'0px', textAlign:'center'}}>
                <DownOutlined onClick={toggleDirection}/>
              </Form.Item>
              <SwapInput
                  amount={zeroForOne ? amount1 : amount0}
                  disabled={!enabled || loading}
                  selectToken={selectToken}
                  readOnly={false}
                  setAmount={setAmountFn(zeroForOne ? setAmount1 : setAmount0)}
                  token={path?tokenByAddress(path[path.length - 1]):''}
                  label={"To"}
                  setShow={setIsShow}
                  setIsZeroShow={setIsZeroShow}
              />
              {loading ? <LoadingOutlined /> : <PlusOutlined />}
              <Form.Item md={{ offset: 4, span: 16 }}>
                <Button type="primary"  onClick={swap} style={{ width: '100%',marginTop:'30px',backgroundColor: '#4096ff' }} size="large">
                  Swap
                </Button>
              </Form.Item>
            </Form>
          </Card>
        </Col>
      </Row>

      <Modal
          title='Token List'
          open={isShow}
          maskClosable={false}
          destroyOnClose
          onCancel={()=>setIsShow(false)}
          footer={null}
      >
        <Table
            dataSource={data}
            rowKey='id'
            pagination={false}

            columns={[
              {
                title: '序号',
                width: 80,
                align: 'center',
                render(v, r, i) {
                  return <>{i + 1}</>;
                },
              },
              // {
              //   title: '主图',
              //   width: 120,
              //   align: 'center',
              //   render(v, r: any) {
              //     return (
              //         <img className='t-img' src={dalImg(r.image)} alt={r.name} />
              //     );
              //   },
              // },
              {
                title: '名字',
                dataIndex: 'name',
                width: 300,
              },
            ]}
          onRow={(record) => {
            return {
              onClick: (event) => {
                console.log('click',record);
                selectToken(record.name, isZeroShow?0:1);
                setIsShow(false);
              }, // 点击行
              onDoubleClick: (event) => {},
              onContextMenu: (event) => {},
              onMouseEnter: (event) => {}, // 鼠标移入行
              onMouseLeave: (event) => {},
            };
          }}
        />

      </Modal>
    </>
  )
}

export default SwapForm;