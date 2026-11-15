// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IPriceSource} from "../src/PriceSources.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// A source whose reading the test sets.
contract MockSource is IPriceSource {
    uint256 public price;
    uint64 public at;

    function set(uint256 price_, uint64 at_) external {
        price = price_;
        at = at_;
    }

    function read(bytes32) external view returns (uint256, uint64) {
        require(price != 0, "no price");
        return (price, at);
    }
}
