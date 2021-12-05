pragma solidity ^0.6.2;

import "../node_modules/@openzeppelin/contracts/token/ERC777/ERC777.sol";
import "./internal/SponsorWhitelistControl.sol";

contract ArtCoin is ERC777 {

    address owner;

    address public minter;

    mapping(address=>bool) mainMinter;

    //---------- Minter Begin ---------//
    modifier onlyMinter() {
        require(mainMinter[msg.sender], "MinterRole: caller does not have the Minter role or above");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender==owner, "Owner Role: caller does not have the Minter role or above");
        _;
    }

    SponsorWhitelistControl public constant SPONSOR = SponsorWhitelistControl(
        address(0x0888000000000000000000000000000000000001)
    );

    constructor()
        ERC777("ART-Token", "ARTT", new address[](0))
        public
    {
        owner = msg.sender;
        
        // register all users as sponsees
        address[] memory users = new address[](1);
        users[0] = address(0);
        SPONSOR.addPrivilege(users);
    }

    function addMinter(address _minter) public onlyOwner(){
        mainMinter[_minter]=true;
    }

    function removeMinter(address _minter) public onlyOwner(){
        mainMinter[_minter]=false;
    }

    function addTokens(address _to, uint256 _value) external onlyMinter(){
        _mint(_to, _value, "", "");
    }
}
