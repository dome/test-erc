// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0 <0.9.0;

// import "./abstracts/ERC20Expirable.sol";
import "@kiwarilabs/tokens/ERC20/LightWeightERC20EXPBase.sol";
// blocktime 2 sec
// 4382901 1 hr
// 182620 1 day
contract EPOINT1HR is ERC20EXPBase {
    constructor() ERC20EXPBase("Earth Point DEV", "EPOINT1HR", 3081088, 4382901, 1, true) {}

    function mint(address to, uint256 value) public {
        _mint(to, value);
        emit Mint(to, value);
    }

    function burn(address from, uint256 value) public {
        _burn(from, value);
        emit Burn(from, value);
    }
    event Mint(address to, uint256 value);
    event Burn(address from, uint256 value);
}
