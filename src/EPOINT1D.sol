// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0 <0.9.0;

// import "./abstracts/ERC20Expirable.sol";
import "@kiwarilabs/tokens/ERC20/LightWeightERC20EXPBase.sol";
// blocktime 2 sec
// 4382901 1 hr
// 182620 1 day

contract EPOINT1D is ERC20EXPBase {
    uint256 public exp =  86400 ; // secound in 1 day
    constructor() ERC20EXPBase("Earth Point DEV", "EPOINT1D", 3621337, 182620, 1, true) {}

    function mint(address to, uint256 value) public {
        _mint(to, value);
        emit Mint(to, value, block.timestamp + exp);
    }

    function burn(address from, uint256 value) public {
        _burn(from, value);
        emit Burn(from, value);
    }
    event Mint(address to, uint256 value, uint256 exp);
    event Burn(address from, uint256 value);
}
