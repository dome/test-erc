// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0 <0.9.0;

/// @title LightWeight ERC20EXP Base abstract contract
/// @author Kiwari Labs

import {SlidingWindow} from "../../abstracts/LightWeightSlidingWindow.sol";
import {PU128SCDLL as SCDLL} from "../../utils/datastructure/PU128SCDLL.sol";
import {IERC7818} from "./extensions/IERC7818.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

abstract contract ERC20EXPBase is Context, IERC20, IERC20Metadata, IERC20Errors, IERC7818, SlidingWindow {
    using SCDLL for SCDLL.List;

    string private _name;
    string private _symbol;

    /// @notice Struct representing a slot containing balances mapped by blocks.
    struct Slot {
        uint256 slotBalance;
        mapping(uint256 => uint256) blockBalances;
        SCDLL.List list;
    }

    mapping(address => mapping(uint256 => mapping(uint8 => Slot))) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(uint256 blockNumber => uint256 balance) private _worldBlockBalances;

    /// @notice Constructor function to initialize the token contract with specified parameters.
    /// @param name_ The name of the token.
    /// @param symbol_ The symbol of the token.
    /// @param blockNumber_ The starting block number for the sliding window.
    /// @param blockTime_ The duration of each block in milliseconds.
    /// @param development_ The development mode flag.
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 blockNumber_,
        uint40 blockTime_,
        uint8 frameSize_,
        bool development_
    ) SlidingWindow(blockNumber_, blockTime_, frameSize_, development_) {
        _name = name_;
        _symbol = symbol_;
    }

    /// @notice Retrieves the total slot balance for the specified account and epoch,
    /// iterating through the range of slots from startSlot to endSlot inclusive.
    /// This function reads slot balances stored in a mapping `_balances`.
    /// @dev This function assumes that the provided `startSlot` is less than or equal to `endSlot`.
    /// It calculates the cumulative balance by summing the `slotBalance` of each slot within the specified range.
    /// @param account The address of the account for which the balance is being queried.
    /// @param epoch The epoch (time period) from which to retrieve balances.
    /// @param startSlot The starting slot index within the epoch to retrieve balances.
    /// @param endSlot The ending slot index within the epoch to retrieve balances.
    /// @return balance The total balance across the specified slots within the epoch.
    function _slotBalance(
        address account,
        uint256 epoch,
        uint8 startSlot,
        uint8 endSlot
    ) private view returns (uint256 balance) {
        unchecked {
            for (; startSlot <= endSlot; startSlot++) {
                balance += _balances[account][epoch][startSlot].slotBalance;
            }
        }
        return balance;
    }

    /// @notice Calculates the total buffered balance within a specific epoch and slot for the given account,
    /// considering all block balances that have not expired relative to the current block number.
    /// This function iterates through a sorted list of block indices and sums up corresponding balances.
    /// @dev This function is used to determine the total buffered balance for an account within a specific epoch and slot.
    /// It loops through a sorted list of block indices stored in `_spender.list` and sums up the balances from `_spender.blockBalances`.
    /// @param account The address of the account for which the balance is being calculated.
    /// @param epoch The epoch (time period) from which to retrieve balances.
    /// @param slot The specific slot within the epoch to retrieve balances.
    /// @param blockNumber The current block number for determining balance validity.
    /// @return balance The total buffered balance within the specified epoch and slot.
    /// @custom:gas-inefficiency This function can consume significant gas due to potentially
    /// iterating through a large array of block indices.
    function _bufferSlotBalance(
        address account,
        uint256 epoch,
        uint8 slot,
        uint256 blockNumber
    ) private view returns (uint256 balance) {
        Slot storage _spender = _balances[account][epoch][slot];
        uint256 key = _getFirstUnexpiredBlockBalance(_spender.list, blockNumber, _getFrameSizeInBlockLength());
        while (key > 0) {
            unchecked {
                balance += _spender.blockBalances[key];
            }
            key = _spender.list.next(key);
        }
    }

    /// @notice Finds the index of the first valid block balance in a sorted list of block numbers.
    /// A block balance index is considered valid if the difference between the current blockNumber
    /// and the block number at the index (key) is less than the expirationPeriodInBlockLength.
    /// @dev This function is used to determine the first valid block balance index within a sorted circular doubly linked list.
    /// It iterates through the list starting from the head and stops when it finds a valid index or reaches the end of the list.
    /// @param list The sorted circular doubly linked list of block numbers.
    /// @param blockNumber The current block number.
    /// @param expirationPeriodInBlockLength The maximum allowed difference between blockNumber and the key.
    /// @return key The index of the first valid block balance.
    function _getFirstUnexpiredBlockBalance(
        SCDLL.List storage list,
        uint256 blockNumber,
        uint256 expirationPeriodInBlockLength
    ) private view returns (uint256 key) {
        key = list.head();
        unchecked {
            while (blockNumber - key >= expirationPeriodInBlockLength) {
                if (key == 0) {
                    break;
                }
                key = list.next(key);
            }
        }
    }

    /// @notice Optimized to assume fromEpoch and fromSlot are already buffered, covering
    /// the gap between fromEpoch and toEpoch using slotBalance and summing to balance.
    /// @dev Returns the available balance from the given account, epochs, and slots.
    /// @param account The address of the account for which the balance is being queried.
    /// @param fromEpoch The starting epoch for the balance lookup.
    /// @param toEpoch The ending epoch for the balance lookup.
    /// @param fromSlot The starting slot within the starting epoch for the balance lookup.
    /// @param toSlot The ending slot within the ending epoch for the balance lookup.
    /// @param blockNumber The current block number.
    /// @return balance The available balance.
    function _lookBackBalance(
        address account,
        uint256 fromEpoch,
        uint256 toEpoch,
        uint8 fromSlot,
        uint8 toSlot,
        uint256 blockNumber
    ) private view returns (uint256 balance) {
        unchecked {
            balance = _bufferSlotBalance(account, fromEpoch, fromSlot, blockNumber);
            // Go to the next slot. Increase the epoch if the slot is over the limit.
            uint8 slotSizeCache = _getSlotsPerEpoch();
            fromSlot = (fromSlot + 1) % slotSizeCache;
            if (fromSlot == 0) {
                fromEpoch++;
            }

            // It is not possible if the fromEpoch is more than toEpoch.
            if (fromEpoch == toEpoch) {
                balance += _slotBalance(account, fromEpoch, fromSlot, toSlot);
            } else {
                // Keep it simple stupid first by spliting into 3 part then sum.
                // Part1: calulate balance at fromEpoch in naive in naive way O(n)
                uint8 maxSlotCache = slotSizeCache - 1;
                balance += _slotBalance(account, fromEpoch, fromSlot, maxSlotCache);
                // Part2: calulate balance betaween fromEpoch and toEpoch in naive way O(n)
                for (uint256 epoch = fromEpoch + 1; epoch < toEpoch; epoch++) {
                    balance += _slotBalance(account, epoch, 0, maxSlotCache);
                }
                // Part3:calulate balance at toEpoch in navie way O(n)
                balance += _slotBalance(account, toEpoch, 0, toSlot);
            }
        }
    }

    function _expired(uint256 id) internal view returns (bool) {
        unchecked {
            if (_blockNumberProvider() - id >= _getFrameSizeInBlockLength()) {
                return true;
            }
        }
    }

    /// @notice Internal function to update token balances during token transfers or operations.
    /// @dev Handles various scenarios including minting, burning, and transferring tokens with expiration logic.
    /// @param from The address from which tokens are being transferred (or minted/burned).
    /// @param to The address to which tokens are being transferred (or burned to if `to` is `zero address`).
    /// @param value The amount of tokens being transferred, minted, or burned.
    function _update(address from, address to, uint256 value) internal virtual {
        // Hook before transfer
        _beforeTokenTransfer(from, to, value);

        uint256 blockNumberCache = _blockNumberProvider();
        uint256 blockLengthCache = _getFrameSizeInBlockLength();
        uint8 slotSizeCache = _getSlotsPerEpoch();

        if (from == address(0)) {
            // Mint expirable token.
            (uint256 currentEpoch, uint8 currentSlot) = _calculateEpochAndSlot(blockNumberCache);
            Slot storage _recipient = _balances[to][currentEpoch][currentSlot];
            unchecked {
                _recipient.slotBalance += value;
                _recipient.blockBalances[blockNumberCache] += value;
                _worldBlockBalances[blockNumberCache] += value;
            }
            _recipient.list.insert(blockNumberCache);
        } else {
            (uint256 fromEpoch, uint256 toEpoch, uint8 fromSlot, uint8 toSlot) = _frame(blockNumberCache);
            uint256 balance = _lookBackBalance(from, fromEpoch, toEpoch, fromSlot, toSlot, blockNumberCache);
            if (balance < value) {
                revert ERC20InsufficientBalance(from, balance, value);
            }

            uint256 pendingValue = value;
            uint256 balanceCache = 0;

            if (to == address(0)) {
                // Burn expirable token.
                while ((fromEpoch < toEpoch || (fromEpoch == toEpoch && fromSlot <= toSlot)) && pendingValue > 0) {
                    Slot storage _spender = _balances[from][fromEpoch][fromSlot];

                    uint256 key = _getFirstUnexpiredBlockBalance(_spender.list, blockNumberCache, blockLengthCache);

                    while (key > 0 && pendingValue > 0) {
                        balanceCache = _spender.blockBalances[key];

                        if (balanceCache <= pendingValue) {
                            unchecked {
                                pendingValue -= balanceCache;
                                _spender.slotBalance -= balanceCache;
                                _spender.blockBalances[key] -= balanceCache;
                                _worldBlockBalances[key] -= balanceCache;
                            }
                            key = _spender.list.next(key);
                            _spender.list.remove(_spender.list.previous(key));
                        } else {
                            unchecked {
                                _spender.slotBalance -= pendingValue;
                                _spender.blockBalances[key] -= pendingValue;
                            }
                            pendingValue = 0;
                        }
                    }

                    // Go to the next slot. Increase the epoch if the slot is over the limit.
                    if (pendingValue > 0) {
                        unchecked {
                            fromSlot = (fromSlot + 1) % slotSizeCache;
                            if (fromSlot == 0) {
                                fromEpoch++;
                            }
                        }
                    }
                }
            } else {
                // Transfer expirable token.
                while ((fromEpoch < toEpoch || (fromEpoch == toEpoch && fromSlot <= toSlot)) && pendingValue > 0) {
                    Slot storage _spender = _balances[from][fromEpoch][fromSlot];
                    Slot storage _recipient = _balances[to][fromEpoch][fromSlot];

                    uint256 key = _getFirstUnexpiredBlockBalance(_spender.list, blockNumberCache, blockLengthCache);

                    while (key > 0 && pendingValue > 0) {
                        balanceCache = _spender.blockBalances[key];

                        if (balanceCache <= pendingValue) {
                            unchecked {
                                pendingValue -= balanceCache;
                                _spender.slotBalance -= balanceCache;
                                _spender.blockBalances[key] -= balanceCache;

                                _recipient.slotBalance += balanceCache;
                                _recipient.blockBalances[key] += balanceCache;
                                _recipient.list.insert(key);
                            }
                            key = _spender.list.next(key);
                            _spender.list.remove(_spender.list.previous(key));
                        } else {
                            unchecked {
                                _spender.slotBalance -= pendingValue;
                                _spender.blockBalances[key] -= pendingValue;

                                _recipient.slotBalance += pendingValue;
                                _recipient.blockBalances[key] += pendingValue;
                            }
                            _recipient.list.insert(key);
                            pendingValue = 0;
                        }
                    }

                    // Go to the next slot. Increase the epoch if the slot is over the limit.
                    if (pendingValue > 0) {
                        unchecked {
                            fromSlot = (fromSlot + 1) % slotSizeCache;
                            if (fromSlot == 0) {
                                fromEpoch++;
                            }
                        }
                    }
                }
            }
        }

        emit Transfer(from, to, value);

        // Hook after transfer
        _afterTokenTransfer(from, to, value);
    }

    function _updateSpecific(address from, address to, uint256 id, uint256 value) internal virtual {
        (uint256 epoch, uint8 slot) = _calculateEpochAndSlot(id);
        if (from == address(0)) {
            Slot storage _recipient = _balances[to][epoch][slot];
            unchecked {
                _recipient.slotBalance += value;
                _recipient.blockBalances[id] += value;
            }
            _worldBlockBalances[id] += value;
        } else {
            Slot storage _spender = _balances[from][epoch][slot];
            uint256 balanceCache = _spender.blockBalances[id];
            if (balanceCache < value) {
                revert ERC20InsufficientBalance(from, balanceCache, value);
            }
            if (to == address(0)) {
                _spender.slotBalance -= value;
                _spender.blockBalances[id] -= value;
                _worldBlockBalances[id] -= value;
            } else {
                Slot storage _recipient = _balances[from][epoch][slot];
                _spender.slotBalance -= value;
                _spender.blockBalances[id] -= value;
                _recipient.slotBalance += value;
                _recipient.blockBalances[id] += value;
            }
        }

        emit Transfer(from, to, value);
    }

    /// @notice Mints new tokens to a specified account.
    /// @dev This function updates the token balance by minting `value` amount of tokens to the `account`.
    /// Reverts if the `account` address is zero.
    /// @param account The address of the account to receive the minted tokens.
    /// @param value The amount of tokens to be minted.
    function _mint(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(address(0), account, value);
    }

    /// @notice Burns a specified amount of tokens from an account.
    /// @dev This function updates the token balance by burning `value` amount of tokens from the `account`.
    /// Reverts if the `account` address is zero.
    /// @param account The address of the account from which tokens will be burned.
    /// @param value The amount of tokens to be burned.
    function _burn(address account, uint256 value) internal {
        if (account == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        _update(account, address(0), value);
    }

    /// @notice Abstract hook called before every token transfer operation.
    /// @dev This function is called before every token transfer operation for additional checks or actions.
    /// @param from The address sending tokens.
    /// @param to The address receiving tokens.
    /// @param amount The amount of tokens being transferred.
    function _beforeTokenTransfer(address from, address to, uint amount) internal virtual {}

    /// @notice Abstract hook called after every token transfer operation.
    /// @dev This function is called after every token transfer operation for additional processing or logging.
    /// @param from The address sending tokens.
    /// @param to The address receiving tokens.
    /// @param amount The amount of tokens being transferred.
    function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual {}

    /// @notice Spends the specified allowance by reducing the allowance of the spender.
    /// @dev This function deducts the `value` amount from the current allowance of the `spender` by the `owner`.
    /// If the current allowance is less than `value`, the function reverts with an error.
    /// If the current allowance is the maximum `uint256`, the allowance is not reduced.
    /// @param owner The address of the token owner.
    /// @param spender The address of the spender.
    /// @param value The amount of tokens to spend from the allowance.
    function _spendAllowance(address owner, address spender, uint256 value) internal {
        uint256 currentAllowance = _allowances[owner][spender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) {
                revert ERC20InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _approve(owner, spender, currentAllowance - value, false);
            }
        }
    }

    /// @notice Approves the `spender` to spend `value` tokens on behalf of `owner`.
    /// @dev Calls an overloaded `_approve` function with an additional parameter to emit an event.
    /// @param owner The address of the token owner.
    /// @param spender The address allowed to spend the tokens.
    /// @param value The amount of tokens to be approved for spending.
    function _approve(address owner, address spender, uint256 value) internal {
        _approve(owner, spender, value, true);
    }

    /// @notice Approves the specified allowance for the spender on behalf of the owner.
    /// @dev Sets the allowance of the `spender` by the `owner` to `value`.
    /// If `emitEvent` is true, an `Approval` event is emitted.
    /// The function reverts if the `owner` or `spender` address is zero.
    /// @param owner The address of the token owner.
    /// @param spender The address of the spender.
    /// @param value The amount of tokens to allow.
    /// @param emitEvent Boolean flag indicating whether to emit the `Approval` event.
    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal {
        if (owner == address(0)) {
            revert ERC20InvalidApprover(address(0));
        }
        if (spender == address(0)) {
            revert ERC20InvalidSpender(address(0));
        }
        _allowances[owner][spender] = value;
        if (emitEvent) {
            emit Approval(owner, spender, value);
        }
    }

    /// @notice Transfers tokens from one address to another.
    /// @dev Moves `value` tokens from `from` to `to`.
    /// The function reverts if the `from` or `to` address is zero.
    /// @param from The address from which the tokens are transferred.
    /// @param to The address to which the tokens are transferred.
    /// @param value The amount of tokens to transfer.
    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _update(from, to, value);
    }

    function _transferSpecific(address from, address to, uint256 id, uint256 value) internal {
        if (from == address(0)) {
            revert ERC20InvalidSender(address(0));
        }
        if (to == address(0)) {
            revert ERC20InvalidReceiver(address(0));
        }
        _updateSpecific(from, to, id, value);
    }

    /// @notice Retrieves the total balance stored at a specific block.
    /// @dev This function returns the balance of the given block from the internal `_worldBlockBalances` mapping.
    /// @param blockNumber The block number for which the balance is being queried.
    /// @return balance The total balance stored at the given block number.
    function getBlockBalance(uint256 blockNumber) external view virtual returns (uint256) {
        return _worldBlockBalances[blockNumber];
    }

    /// @inheritdoc IERC20Metadata
    function name() external view virtual returns (string memory) {
        return _name;
    }

    /// @inheritdoc IERC20Metadata
    function symbol() external view virtual returns (string memory) {
        return _symbol;
    }

    /// @inheritdoc IERC20Metadata
    function decimals() external view virtual returns (uint8) {
        return 18;
    }

    /// @notice Returns 0 as there is no actual total supply due to token expiration.
    /// @dev This function returns the total supply of tokens, which is constant and set to 0.
    /// @inheritdoc IERC20
    function totalSupply() external pure virtual returns (uint256) {
        return 0;
    }

    /// @notice Returns the available balance of tokens for a given account.
    /// @dev Calculates and returns the available balance based on the frame.
    /// @inheritdoc IERC20
    function balanceOf(address account) external view virtual returns (uint256) {
        uint256 blockNumberCache = _blockNumberProvider();
        (uint256 fromEpoch, uint256 toEpoch, uint8 fromSlot, uint8 toSlot) = _frame(blockNumberCache);
        return _lookBackBalance(account, fromEpoch, toEpoch, fromSlot, toSlot, blockNumberCache);
    }

    /// @inheritdoc IERC20
    function allowance(address owner, address spender) external view virtual returns (uint256) {
        return _allowances[owner][spender];
    }

    /// @inheritdoc IERC20
    function transfer(address to, uint256 value) external virtual returns (bool) {
        address from = _msgSender();
        _transfer(from, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 value) external virtual returns (bool) {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    function approve(address spender, uint256 value) external virtual returns (bool) {
        address owner = _msgSender();
        _approve(owner, spender, value);
        return true;
    }

    /// @inheritdoc IERC7818
    function balanceOf(address account, uint256 id) external view returns (uint256) {
        if (_expired(id)) {
            return 0;
        }
        (uint256 epoch, uint8 slot) = _calculateEpochAndSlot(id);
        return _balances[account][epoch][slot].blockBalances[id];
    }

    /// @inheritdoc IERC7818
    function duration() public view virtual returns (uint256) {
        return _getFrameSizeInBlockLength();
    }

    /// @inheritdoc IERC7818
    function epoch() public view virtual returns (uint256) {
        (uint256 epoch, ) = _calculateEpochAndSlot(_blockNumberProvider());
        return epoch;
    }

    /// @inheritdoc IERC7818
    function expired(uint256 id) public view virtual returns (bool) {
        return _expired(id);
    }

    /// @inheritdoc IERC7818
    function transfer(address to, uint256 id, uint256 value) public virtual returns (bool) {
        if (_expired(id)) {
            revert ERC7818TransferExpired();
        }
        address owner = _msgSender();
        _transferSpecific(owner, to, id, value);
        return true;
    }

    /// @inheritdoc IERC7818
    function transferFrom(address from, address to, uint256 id, uint256 value) public virtual returns (bool) {
        if (_expired(id)) {
            revert ERC7818TransferExpired();
        }
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transferSpecific(from, to, id, value);
        return true;
    }

    /// @custom:gas-inefficiency if not limit the size of array
    function tokenList(
        address account,
        uint256 epoch,
        uint8 slot
    ) external view virtual returns (uint256[] memory list) {
        list = _balances[account][epoch][slot].list.ascending();
    }
}
