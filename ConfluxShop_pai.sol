pragma solidity ^0.6.2;

import "@openzeppelin/contracts/math/SafeMath.sol";

import "@openzeppelin/contracts/introspection/IERC1820Registry.sol";

import "./internal/AdminControl.sol";
import "./internal/SponsorWhitelistControl.sol";
import "./internal/Staking.sol";
//import "./interfaces/ITokenWrapper.sol";


interface TicketNft{
    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId,
        uint256 amount,
        bytes calldata data
    ) external;
}

contract ConfluxShop_pai{

    event BuyTicket(address buyer, uint256 tokenId);
    event CancelShell(address seller, uint256 tokenId, uint256 price);
    event AddTicketCount(uint256 count);
    event BuySellerTicket(address seller,address buyer,uint256 tokenId,uint256 price);
    event SellTicker(address seller,uint256 tokenId,uint256 price);

    using SafeMath for uint256;

    address ticketShopOwner;

    TicketNft ticketNft;
    
    uint256 public totalBalance;

    uint256[] public shopIds;
    // tokenId 对应的买卖信息
    mapping(uint256 => Shop) public shopMap;
    mapping(uint256 => uint256) public _allTokensIndex;

    mapping(address => mapping(uint256 => uint256)) public sellerIndex;
    mapping(address => uint256[]) public sellerShops;

    //price  tokenId 对应的价格
    mapping(uint256 => uint256) public prices;

    address public platform;
    //2.5  -> 25/1000
    uint256 rate = 25;

    struct Shop{
        address seller;//卖家
        uint256 price;//价格
        address buyer;//xxx买家 无用
        uint256 min_add_price;//最小加价额度
        uint256 have_buyer;//0没人买、1有人出价
        uint256 end_time;//拍卖结束unix时间戳
    }

    modifier onlyOwner(){
        require(msg.sender == ticketShopOwner,"Not owner");
        _;
    }

    SponsorWhitelistControl public constant SPONSOR = SponsorWhitelistControl(
        address(0x0888000000000000000000000000000000000001)
    );
    Staking public constant STAKING =
        Staking(address(0x0888000000000000000000000000000000000002));
    AdminControl public constant adminControl =
        AdminControl(address(0x0888000000000000000000000000000000000000));

    //ITokenWrapper iTokenWrapper;

    constructor(address _ticketNft) public{
        ticketShopOwner = msg.sender;
        ticketNft = TicketNft(_ticketNft);
        platform = msg.sender;
        //iTokenWrapper = _iTokenWrapper;
        // register all users as sponsees
        address[] memory users = new address[](1);
        users[0] = address(0);
        SPONSOR.addPrivilege(users);
    }

    //获取自己售卖的 nft
    function getSellerShop(address _seller) view public returns(uint256[] memory _ids){
        return sellerShops[_seller];
    }

    //获取所有的正在售卖的nft
    function getShopItems() view public returns(uint256[] memory _shopIds){
        return shopIds;
    }

    function setTokenParam(TicketNft _ticketNft) public onlyOwner(){
        ticketNft = TicketNft(_ticketNft);
    }
    //设置平台收款地址
    function setPlatForm(address _platform) public onlyOwner(){
        platform = _platform;
    }

    //设置平台收取手续费低至
    function setPlatFormRate(uint256 _rate) public onlyOwner(){
        rate = _rate;
    }

    //上架 cfx
    function sellTicker(uint256 _tokenId,uint256 _price,uint256 _min_add_price, uint256 _time_continue) public{
        require(_price>0,"init-minPrice > 0");
        require(_min_add_price>0,"init-_min_add_price > 0");
        require(_time_continue>0,"_time_continue > 0 hour");
        require(_time_continue<=8760,"_time_continue <= 1 year");
        Shop storage shop = shopMap[_tokenId];
        shop.seller = msg.sender;
        shop.buyer = address(0);
        shop.price = _price;//*1e18;
        shop.min_add_price= _min_add_price;//*1e18;
        shop.have_buyer = 0;//0没人买、1及以后表示出价人数
        shop.end_time = now + _time_continue*3600;//拍卖结束unix时间戳
        _allTokensIndex[_tokenId] = shopIds.length;
        shopIds.push(_tokenId);
        transfer1155(msg.sender,address(this),_tokenId);
        
        //add to seller
        sellerIndex[msg.sender][_tokenId] = sellerShops[msg.sender].length;
        sellerShops[msg.sender].push(_tokenId);
        emit SellTicker(msg.sender, _tokenId, _price);
    }

    //出价及收取 payable value
    function buySellerTicket(uint256 _tokenId) payable public{
        Shop storage shop=shopMap[_tokenId];
        uint256 _price = msg.value;
        if (now <  shop.end_time)
        {
            require(shop.seller!=msg.sender,"Can not buy self");
            if (shop.have_buyer == 0)
            {
                require(_price>=shop.price,"Price wrong");
                require(_price>=1e18,"minPrice >=1cfx");
                //竞价cfx转给平台，平台把cfx进行质押
                totalBalance = totalBalance.add(_price);
                _depositStaking(_price);
                shop.have_buyer += 1;
                shop.price = _price;
            }
            else
            {
                require(_price>=shop.price+shop.min_add_price,"Price wrong");
                //新竞价钱转给平台，平台把钱退给上一个竞拍者后多余的cfx马上进行质押
                totalBalance = totalBalance.add(_price-shop.price);
                _depositStaking(_price-shop.price);
                transferMainCoin(shop.buyer, shop.price);
                shop.have_buyer += 1;
                shop.price = _price;
            }
        }
        else
        {
            require(shop.seller!=msg.sender,"Can not buy self");
            require(shop.buyer==msg.sender,"not pai");
            STAKING.withdraw(shop.price);
            totalBalance = totalBalance.sub(shop.price);
            address(uint160(platform)).transfer(shop.price.mul(rate).div(1000));
            address(uint160(shop.seller)).transfer(shop.price.mul(1000-rate).div(1000));
            //1155
            transfer1155(address(this),msg.sender,_tokenId);
            _removeTokenFromShop(_tokenId);
            //remove seller
            _removeTokenFromSellerShop(shop.seller,_tokenId);
        }
        
        //address(uint160(platform)).transfer(_price.mul(rate).div(1000));
        //address(uint160(shop.seller)).transfer(_price.mul(1000-rate).div(1000));
        //1155
        //transfer1155(address(this),msg.sender,_tokenId);
        
        emit BuySellerTicket(shop.seller, msg.sender, _tokenId, _price);
        shop.buyer = msg.sender;
        prices[_tokenId] = _price;
        //_removeTokenFromShop(_tokenId);
        //remove seller
        //_removeTokenFromSellerShop(shop.seller,_tokenId);
    }
    
    //合约质押cfx
    function _depositStaking(uint256 _amount) internal {
        STAKING.deposit(_amount);
    }
    //转CFX，main代表链主币
    function transferMainCoin(address _address, uint256 _value) internal {
        (bool res, ) = address(uint160(_address)).call{value: _value}("");
        require(res, "TRANSFER MAIN ERROR");
    }

    //卖家取消
    function cancelShell(uint256 _tokenId) public{
        Shop storage shop=shopMap[_tokenId];
        require(shop.seller == msg.sender,"Only seller");
        require(shop.have_buyer == 0,"have been pai");
        transfer1155(address(this),msg.sender,_tokenId);
        emit CancelShell(shop.seller,_tokenId,shop.price);
        _removeTokenFromShop(_tokenId);
        _removeTokenFromSellerShop(shop.seller,_tokenId);
    }
    //拿取利息
    function withdrawMain() public onlyOwner() {
        uint256 deposit = STAKING.getStakingBalance(address(this));
        STAKING.withdraw(deposit);
        STAKING.deposit(deposit);
        transferMainCoin(msg.sender, address(this).balance);
    }

    function _removeTokenFromSellerShop(address _seller, uint256 _tokenId) private {
        uint256 lastTokenIndex = sellerShops[_seller].length.sub(1);
        uint256 tokenIndex = sellerIndex[_seller][_tokenId];

        uint256 lastTokenId = sellerShops[_seller][lastTokenIndex];

        sellerShops[_seller][tokenIndex] = lastTokenId;
        sellerIndex[_seller][lastTokenId] = tokenIndex;

        sellerShops[_seller].pop();
        sellerIndex[_seller][_tokenId] = 0;
    }

    function _removeTokenFromShop(uint256 _tokenId) private {
        uint256 lastTokenIndex = shopIds.length.sub(1);
        uint256 tokenIndex = _allTokensIndex[_tokenId];

        uint256 lastTokenId = shopIds[lastTokenIndex];

        shopIds[tokenIndex] = lastTokenId;
        _allTokensIndex[lastTokenId] = tokenIndex;

        shopIds.pop();
        _allTokensIndex[_tokenId] = 0;
    }

    function transferEth(address _address, uint256 _value) internal{
        (bool res, ) = address(uint160(_address)).call{value:_value}("");
        require(res,"TRANSFER ETH ERROR");
    }

    function transfer1155(address _from,address _to,uint256 _tokenId) internal{
        ticketNft.safeTransferFrom(_from,_to,_tokenId,1,"");
    }

     //-----------
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    )external returns(bytes4){
       return bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    )external returns(bytes4){
        return bytes4(keccak256("onERC1155BatchReceived(address,address,uint256[],uint256[],bytes)"));
    }
}
