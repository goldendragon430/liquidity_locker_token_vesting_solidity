// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "./Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LiquidityLocker is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    struct UserInfo {
        EnumerableSet.AddressSet lockedTokens; // records all tokens the user has locked
        mapping(address => uint256[]) locksForToken; // map erc20 address to lock id for that token
    }

    struct TokenLock {
        uint256 lockDate; // the date the token was locked
        uint256 amount; // the amount of tokens still locked (initialAmount minus withdrawls)
        uint256 initialAmount; // the initial lock amount
        uint256 unlockDate; // the date the token can be withdrawn
        uint256 lockID; // lockID nonce per lp token
        address owner;
    }

    mapping(address => UserInfo) private users;

    EnumerableSet.AddressSet private lockedTokens;

    mapping(address => TokenLock[]) public tokenLocks; //map lp token to all its locks

    struct FeeStruct {
        uint256 ethFee; // Small eth fee to prevent spam on the platform
        uint256 ethEditFee; // Small eth fee
        IERC20 referralToken; // token the refferer must hold to qualify as a referrer
        uint256 referralHold; // balance the referrer must hold to qualify as a referrer
        uint256 referralDiscountEthFee; // discount on flatrate fees for using a valid referral address
    }

    FeeStruct public gFees;

    event onDeposit(
        address lpToken,
        address user,
        uint256 amount,
        uint256 lockDate,
        uint256 unlockDate
    );
    event onWithdraw(address lpToken, uint256 amount);

    constructor() {
        gFees.ethFee = 8e16; // 0.08 eth
        gFees.ethEditFee = 5e16; // 0.05 eth
        gFees.referralToken = IERC20(
            0xC98f38D074Cb3cf8da4AC30EB99632233465aE20
        );
        gFees.referralHold = 100e18; // 100 token
        gFees.referralDiscountEthFee = 6e16; // 0.06 eth
    }

    function setFees(
        uint256 ethFee,
        uint256 ethEditFee,
        uint256 referralDiscountEthFee
    ) public onlyOwner {
        gFees.ethFee = ethFee;
        gFees.ethEditFee = ethEditFee;
        gFees.referralDiscountEthFee = referralDiscountEthFee;
    }

    function setReferralTokenAndHold(
        address referralToken,
        uint256 referralHold
    ) public onlyOwner {
        gFees.referralToken = IERC20(referralToken);
        gFees.referralHold = referralHold;
    }

    /**
     * @notice Creates a new lock
     * @param _lpToken the lp token address
     * @param _amount amount of LP tokens to lock
     * @param _unlock_date the unix timestamp (in seconds) until unlock
     * @param _withdrawer the user who can withdraw liquidity once the lock expires.
     */
    function lockLpTokens(
        address _lpToken,
        uint256 _amount,
        uint256 _unlock_date,
        address payable _withdrawer
    ) external payable nonReentrant {
        require(_unlock_date < 10000000000, "TIMESTAMP INVALID"); // prevents errors when timestamp entered in milliseconds
        require(_amount > 0, "INSUFFICIENT AMOUNT");

        IERC20 LpToken = IERC20(address(_lpToken));

        // deposit lp token
        LpToken.transferFrom(address(msg.sender), address(this), _amount);

        uint256 validFee;
        uint256 referralAmount = gFees.referralToken.balanceOf(
            address(msg.sender)
        );
        if (referralAmount >= gFees.referralHold) {
            validFee = gFees.referralDiscountEthFee;
        } else {
            validFee = gFees.ethFee;
        }

        require(msg.value == validFee, "FEE NOT MET");

        TokenLock memory token_lock;
        token_lock.lockDate = block.timestamp;
        token_lock.amount = _amount;
        token_lock.initialAmount = _amount;
        token_lock.unlockDate = _unlock_date;
        token_lock.lockID = tokenLocks[_lpToken].length;
        token_lock.owner = _withdrawer;

        // record the lock for the lp token
        tokenLocks[_lpToken].push(token_lock);
        lockedTokens.add(_lpToken);

        //record the lock for the user
        UserInfo storage user = users[_withdrawer];
        user.lockedTokens.add(_lpToken);
        uint256[] storage user_locks = user.locksForToken[_lpToken];
        user_locks.push(token_lock.lockID);

        emit onDeposit(
            _lpToken,
            msg.sender,
            token_lock.amount,
            token_lock.lockDate,
            token_lock.unlockDate
        );
    }

    /**
     * @notice split a lock into two seperate locks, useful when a lock is about to expire and youd like to relock a portion
     * and withdraw a smaller portion
     * @param _lpToken the lp token address
     * @param _index users[msg.sender].locksForToken[_lpToken][_index]
     * @param _lockedId tokenLocks[_lpToken][lockID]
     * @param _amount amount to split

     */
    function splitLock(
        address _lpToken,
        uint256 _index,
        uint256 _lockedId,
        uint256 _amount
    ) external payable nonReentrant {
        require(_amount > 0, "ZERO AMOUNT");
        uint256 lockId = users[msg.sender].locksForToken[_lpToken][_index];
        TokenLock storage userLock = tokenLocks[_lpToken][lockId];
        require(
            lockId == _lockedId && userLock.owner == msg.sender,
            "LOCK MISMATCH"
        ); // ensures correct lock is affected

        require(msg.value == gFees.ethEditFee, "FEE NOT MET");

        userLock.amount = userLock.amount - (_amount);

        TokenLock memory token_lock;
        token_lock.lockDate = userLock.lockDate;
        token_lock.amount = _amount;
        token_lock.initialAmount = _amount;
        token_lock.unlockDate = userLock.unlockDate;
        token_lock.lockID = tokenLocks[_lpToken].length;
        token_lock.owner = msg.sender;

        // record the lock for the lp token
        tokenLocks[_lpToken].push(token_lock);

        //record the lock for the user
        UserInfo storage user = users[msg.sender];
        uint256[] storage user_locks = user.locksForToken[_lpToken];
        user_locks.push(token_lock.lockID);
    }

    /**
     * @notice increase the amount of tokens per a specific lock, this is preferable to creating a new lock, less fees, and faster loading on our live block explorer
     */
    function incrementLock(
        address _lpToken,
        uint256 _index,
        uint256 _lockId,
        uint256 _amount
    ) external payable nonReentrant {
        require(_amount > 0, "ZERO AMOUNT");
        uint256 lockId = users[msg.sender].locksForToken[_lpToken][_index];
        TokenLock storage userLock = tokenLocks[_lpToken][lockId];
        require(
            lockId == _lockId && userLock.owner == msg.sender,
            "LOCK MISMATCH"
        ); // ensures correct lock is affected

        require(msg.value == gFees.ethEditFee, "FEE NOT MET");

        IERC20 LpToken = IERC20(address(_lpToken));
        // deposit lp token
        LpToken.transferFrom(address(msg.sender), address(this), _amount);

        userLock.amount = userLock.amount + (_amount);

        emit onDeposit(
            _lpToken,
            msg.sender,
            _amount,
            userLock.lockDate,
            userLock.unlockDate
        );
    }

    /**
     * @notice transfer a lock to a new owner, e.g. presale project -> project owner
     */
    function transferLockOwnership(
        address _lpToken,
        uint256 _index,
        uint256 _lockID,
        address payable _newOwner
    ) external payable {
        require(msg.sender != _newOwner, "OWNER");
        uint256 lockID = users[msg.sender].locksForToken[_lpToken][_index];
        TokenLock storage transferredLock = tokenLocks[_lpToken][lockID];
        require(
            lockID == _lockID && transferredLock.owner == msg.sender,
            "LOCK MISMATCH"
        ); // ensures correct lock is affected

        // record the lock for the new Owner
        UserInfo storage user = users[_newOwner];
        user.lockedTokens.add(_lpToken);
        uint256[] storage user_locks = user.locksForToken[_lpToken];
        user_locks.push(transferredLock.lockID);

        // remove the lock from the old owner
        uint256[] storage userLocks = users[msg.sender].locksForToken[_lpToken];
        userLocks[_index] = userLocks[userLocks.length - 1];
        userLocks.pop();

        if (userLocks.length == 0) {
            users[msg.sender].lockedTokens.remove(_lpToken);
        }
        transferredLock.owner = _newOwner;
    }

    /**
     * @notice withdraw a specified amount from a lock. _index and _lockID ensure the correct lock is changed
     * this prevents errors when a user performs multiple tx per block possibly with varying gas prices
     */
    function withdraw(
        address _lpToken,
        uint256 _index,
        uint256 _lockID,
        uint256 _amount
    ) external nonReentrant {
        require(_amount > 0, "ZERO WITHDRAWL");
        uint256 lockID = users[msg.sender].locksForToken[_lpToken][_index];
        TokenLock storage userLock = tokenLocks[_lpToken][lockID];
        require(
            lockID == _lockID && userLock.owner == msg.sender,
            "LOCK MISMATCH"
        ); // ensures correct lock is affected

        require(userLock.unlockDate < block.timestamp, "NOT YET");
        userLock.amount = userLock.amount - (_amount);

        // clean user storage
        if (userLock.amount == 0) {
            uint256[] storage userLocks = users[msg.sender].locksForToken[
                _lpToken
            ];
            userLocks[_index] = userLocks[userLocks.length - 1];
            userLocks.pop();

            if (userLocks.length == 0) {
                users[msg.sender].lockedTokens.remove(_lpToken);
            }
        }

        IERC20 LpToken = IERC20(address(_lpToken));
        // withdraw lp token
        LpToken.transfer(address(msg.sender), _amount);
        emit onWithdraw(_lpToken, _amount);
    }

    // global functions
    function getNumLocksForToken(
        address _lpToken
    ) external view returns (uint256) {
        return tokenLocks[_lpToken].length;
    }

    function getNumLockedTokens() external view returns (uint256) {
        return lockedTokens.length();
    }

    function getLockedTokenAtIndex(
        uint256 _index
    ) external view returns (address) {
        return lockedTokens.at(_index);
    }

    // user functions
    function getUserNumLockedTokens(
        address _user
    ) external view returns (uint256) {
        UserInfo storage user = users[_user];
        return user.lockedTokens.length();
    }

    function getUserLockedTokenAtIndex(
        address _user,
        uint256 _index
    ) external view returns (address) {
        UserInfo storage user = users[_user];
        return user.lockedTokens.at(_index);
    }

    function getUserNumLocksForToken(
        address _user,
        address _lpToken
    ) external view returns (uint256) {
        UserInfo storage user = users[_user];
        return user.locksForToken[_lpToken].length;
    }

    function getUserLockForTokenAtIndex(
        address _user,
        address _lpToken,
        uint256 _index
    )
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, address)
    {
        uint256 lockID = users[_user].locksForToken[_lpToken][_index];
        TokenLock storage tokenLock = tokenLocks[_lpToken][lockID];
        return (
            tokenLock.lockDate,
            tokenLock.amount,
            tokenLock.initialAmount,
            tokenLock.unlockDate,
            tokenLock.lockID,
            tokenLock.owner
        );
    }
}
