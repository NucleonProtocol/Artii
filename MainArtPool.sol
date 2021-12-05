pragma solidity ^0.6.0;
import "@openzeppelin/contracts/math/Math.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@openzeppelin/contracts/utils/Address.sol";

import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IRewardDistributionRecipient.sol";

import "./token/TokenWrapper.sol";
import "./internal/SponsorWhitelistControl.sol";

import "@openzeppelin/contracts/token/ERC777/IERC777.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts/introspection/IERC1820Registry.sol";

contract MainArtPool is
    TokenWrapper,
    IRewardDistributionRecipient,
    IERC777Recipient
{
    IERC777 public artCoin;
    uint256 public constant DURATION = 30 days;

    uint256 public initreward = 200000 * 10**18; // total：500w

    uint256 public starttime;
    uint256 public periodFinish = 0;
    uint256 public rewardRate = 0;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    mapping(address => bool) public miners;

    modifier onlyMiner() {
        require(miners[msg.sender], "Not miner");
        _;
    }

    IERC1820Registry private _erc1820 =
        IERC1820Registry(0x88887eD889e776bCBe2f0f9932EcFaBcDfCd1820);

    // keccak256("ERC777TokensRecipient")
    bytes32 private constant TOKENS_RECIPIENT_INTERFACE_HASH =
        0xb281fc8c12954d22544db45de3159a39272895b169a852b314f9cc762e44c53b;

    SponsorWhitelistControl public constant SPONSOR =
        SponsorWhitelistControl(
            address(0x0888000000000000000000000000000000000001)
        );

    constructor(address artCoin_, uint256 starttime_) public {
        _erc1820.setInterfaceImplementer(
            address(this),
            TOKENS_RECIPIENT_INTERFACE_HASH,
            address(this)
        );
        artCoin = IERC777(artCoin_);
        starttime = starttime_;

        // register all users as sponsees
        address[] memory users = new address[](1);
        users[0] = address(0);
        SPONSOR.addPrivilege(users);
    }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function addMiner(address _miner) public onlyOwner() {
        miners[_miner] = true;
    }

    function removeMiner(address _miner) public onlyOwner() {
        miners[_miner] = false;
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(lastUpdateTime)
                    .mul(rewardRate)
                    .mul(1e18)
                    .div(totalSupply())
            );
    }

    //获取收益结果
    function earned(address account) public view returns (uint256) {
        return
            balanceOf(account)
                .mul(rewardPerToken().sub(userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(rewards[account]);
    }

    //抵押
    function stake()
        public
        payable
        override
        updateReward(msg.sender)
        checkhalve()
        checkStart()
    {
        uint256 amount = msg.value;
        require(amount > 0, "stake amount error,must > 0");
        super.stake();
        emit Staked(msg.sender, amount);
    }

    //铸造用的方法，增加铸造的balance2
    function stake2(address _sender, uint256 _amount)
        public
        override
        updateReward(_sender)
        checkhalve()
        checkStart()
        onlyMiner()
    {
        uint256 amount = _amount;
        require(amount > 0, "stake amount error,must > 0");
        super.stake2(_sender, _amount);
        emit Staked(_sender, amount);
    }

    //扣除一定量的铸造时的抵押币，不需要转移，直接扣除就行
    function withdraw2(address _sender, uint256 amount)
        public
        override
        updateReward(_sender)
        checkhalve()
        checkStart()
        onlyMiner()
    {
        require(amount > 0, "Cannot withdraw 0");
        super.withdraw2(_sender, amount);
        emit Withdrawn(_sender, amount);
    }

    //取出一定量的抵押币
    function withdraw(uint256 amount)
        public
        override
        updateReward(msg.sender)
        checkhalve
        checkStart
    {
        require(amount > 0, "Cannot withdraw 0");
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
    }

    //取出收益+抵押的所有币,只能取出balance1的币！！
    function exit() external {
        withdraw(balance1Of(msg.sender));
        getReward();
    }

    //领取收益
    function getReward() public updateReward(msg.sender) checkhalve checkStart {
        uint256 reward = earned(msg.sender);
        if (reward > 0) {
            rewards[msg.sender] = 0;
            artCoin.send(msg.sender, reward, "");
            emit RewardPaid(msg.sender, reward);
        }
    }

    modifier checkhalve() {
        if (block.timestamp >= periodFinish) {
            initreward = initreward.mul(96).div(100);

            rewardRate = initreward.div(DURATION);
            periodFinish = block.timestamp.add(DURATION);
            emit RewardAdded(initreward);
        }
        _;
    }

    modifier checkStart() {
        require(block.timestamp >= starttime, "not start");
        _;
    }

    function notifyRewardAmount(uint256 reward)
        external
        override
        onlyRewardDistribution
        updateReward(address(0))
    {
        if (block.timestamp > starttime) {
            if (block.timestamp >= periodFinish) {
                rewardRate = reward.div(DURATION);
            } else {
                uint256 remaining = periodFinish.sub(block.timestamp);
                uint256 leftover = remaining.mul(rewardRate);
                rewardRate = reward.add(leftover).div(DURATION);
            }
            lastUpdateTime = block.timestamp;
            periodFinish = block.timestamp.add(DURATION);
            emit RewardAdded(reward);
        } else {
            rewardRate = initreward.div(DURATION);
            lastUpdateTime = starttime;
            periodFinish = starttime.add(DURATION);
            emit RewardAdded(reward);
        }
    }

    function tokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata userData,
        bytes calldata operatorData
    ) external override {
        //require(operator == address(artCoin), "Not artCoin");
    }
}
