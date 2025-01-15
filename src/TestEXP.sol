// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0 <0.9.0;

// import "./abstracts/ERC20Expirable.sol";
import "@kiwarilabs/tokens/ERC20/LightWeightERC20EXPBase.sol";

contract EPOINTDEV is ERC20EXPBase {
    constructor() ERC20EXPBase("Earth Point", "EPOINTDEV", 3071509, 8765802, 1, true) {}

    function mint(address to, uint256 value) public {
        _mint(to, value);
    }

    function burn(address from, uint256 value) public {
        _burn(from, value);
    }
}
