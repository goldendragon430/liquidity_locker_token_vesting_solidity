// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "./Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./VestingMathLibrary.sol";
import "./FullMath.sol";

contract TokenVesting is Ownable, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    struct UserInfo {
        EnumerableSet.AddressSet lockedTokens; // records all token addresses the user has locked
        mapping(address => uint256[]) locksForToken; // map erc20 address to lockId for that token
    }

    struct TokenLock {
        address tokenAddress; // The token address
        uint256 sharesDeposited; // the total amount of shares deposited
        uint256 sharesWithdrawn; // amount of shares withdrawn
        uint256 startEmission; // date token emission begins
        uint256 endEmission; // the date the tokens can be withdrawn
        uint256 lockID; // lock id per token lock
        address owner; // the owner who can edit or withdraw the lock
    }

    struct LockParams {
        address payable owner; // the user who can withdraw tokens once the lock expires.
        uint256 amount; // amount of tokens to lock
        uint256 endEmission; // the unlock date as a unix timestamp (in seconds)
    }

    EnumerableSet.AddressSet private TOKENS; // list of all unique tokens that have a lock
    mapping(uint256 => TokenLock) public LOCKS; // map lockID nonce to the lock
    uint256 public NONCE = 0; // incremental lock nonce counter, this is the unique ID for the next lock
    uint256 public MINIMUM_DEPOSIT = 100; // minimum divisibility per lock at time of locking

    mapping(address => uint256[]) private TOKEN_LOCKS; // map token address to array of lockIDs for that token
    mapping(address => UserInfo) private USERS;

    mapping(address => uint) public SHARES; // map token to number of shares per token, shares allow rebasing and deflationary tokens to compute correctly

    struct FeeStruct {
        uint256 ethFee; // Small eth fee to prevent spam on the platform
        uint256 ethEditFee; // Small eth fee
        address referralToken; // token the refferer must hold to qualify as a referrer
        uint256 referralHold; // balance the referrer must hold to qualify as a referrer
        uint256 referralDiscountEthFee; // discount on flatrate fees for using a valid referral address
    }

    FeeStruct public gFees;

    event onLock(
        uint256 lockID,
        address token,
        address owner,
        uint256 amountInTokens,
        uint256 startEmission,
        uint256 endEmission
    );
    event onWithdraw(address lpToken, uint256 amountInTokens);
    event onRelock(uint256 lockID, uint256 unlockDate);
    event onTransferLock(
        uint256 lockIDFrom,
        uint256 lockIDto,
        address oldOwner,
        address newOwner
    );
    event onSplitLock(
        uint256 fromLockID,
        uint256 toLockID,
        uint256 amountInTokens
    );

    constructor() {
        gFees.ethFee = 8e16; // 0.08 eth
        gFees.ethEditFee = 5e16; // 0.05 eth
        gFees.referralToken = address(
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
        gFees.referralToken = address(referralToken);
        gFees.referralHold = referralHold;
    }

    /**
     * @notice Creates one or multiple locks for the specified token
     * @param _token the erc20 token address
     * @param _isVesting is vesting
     * @param _lock_params an array of locks with format: [LockParams[owner, amount, endEmission]]
     * owner: user or contract who can withdraw the tokens
     * amount: must be >= 100 units
     * startEmission = 0 : LockType 1
     * startEmission != 0 : LockType 2 (linear scaling lock)
     * use address(0) for no premature unlocking condition
     * Fails if startEmission is not less than EndEmission
     * Fails is amount < 100
     */
    function lock(
        address _token,
        bool _isVesting,
        LockParams[] calldata _lock_params
    ) external payable nonReentrant {
        require(_lock_params.length > 0, "NO PARAMS");

        uint256 validFee;
        if (hasRefferalTokenHold(msg.sender)) {
            validFee = gFees.ethFee;
        } else {
            validFee = gFees.referralDiscountEthFee;
        }

        require(msg.value == validFee, "SERVICE FEE");

        uint256 totalAmount = 0;
        for (uint256 i = 0; i < _lock_params.length; i++) {
            totalAmount += _lock_params[i].amount;
        }

        // deposit vesting token
        IERC20 VestingToken = IERC20(address(_token));
        uint256 balanceBefore = VestingToken.balanceOf(address(this));
        VestingToken.transferFrom(
            address(msg.sender),
            address(this),
            totalAmount
        );
        uint256 amountIn = VestingToken.balanceOf(address(this)) -
            balanceBefore;

        uint256 shares = 0;
        LockParams memory lock_param;
        for (uint256 i = 0; i < _lock_params.length; i++) {
            lock_param = _lock_params[i];
            require(block.timestamp < lock_param.endEmission, "PERIOD");

            require(lock_param.endEmission < 1e10, "TIMESTAMP INVALID"); // prevents errors when timestamp entered in milliseconds
            require(lock_param.amount >= MINIMUM_DEPOSIT, "MIN DEPOSIT");
            uint256 amountInTokens = FullMath.mulDiv(
                lock_param.amount,
                amountIn,
                totalAmount
            );

            if (SHARES[_token] == 0) {
                shares = amountInTokens;
            } else {
                shares = FullMath.mulDiv(
                    amountInTokens,
                    SHARES[_token],
                    balanceBefore == 0 ? 1 : balanceBefore
                );
            }

            require(shares > 0, "SHARES");
            SHARES[_token] += shares;

            balanceBefore += amountInTokens;

            TokenLock memory token_lock;
            token_lock.tokenAddress = _token;
            token_lock.sharesDeposited = shares;
            token_lock.startEmission = _isVesting ? block.timestamp : 0;
            token_lock.endEmission = lock_param.endEmission;
            token_lock.lockID = NONCE;
            token_lock.owner = lock_param.owner;

            // record the lock globally
            LOCKS[NONCE] = token_lock;
            TOKENS.add(_token);
            TOKEN_LOCKS[_token].push(NONCE);

            // record the lock for the user
            UserInfo storage user = USERS[lock_param.owner];
            user.lockedTokens.add(_token);
            user.locksForToken[_token].push(NONCE);

            NONCE++;
            emit onLock(
                token_lock.lockID,
                _token,
                token_lock.owner,
                amountInTokens,
                token_lock.startEmission,
                token_lock.endEmission
            );
        }
    }

    /**
     * @notice withdraw a specified amount from a lock. _amount is the ideal amount to be withdrawn.
     * however, this amount might be slightly different in rebasing tokens due to the conversion to shares,
     * then back into an amount
     * @param _lockID the lockID of the lock to be withdrawn
     * @param _amount amount of tokens to withdraw
     */
    function withdraw(uint256 _lockID, uint256 _amount) external nonReentrant {
        TokenLock storage userLock = LOCKS[_lockID];
        require(userLock.owner == msg.sender, "OWNER");
        // convert _amount to its representation in shares
        uint256 balance = IERC20(userLock.tokenAddress).balanceOf(
            address(this)
        );
        uint256 shareDebit = FullMath.mulDiv(
            SHARES[userLock.tokenAddress],
            _amount,
            balance
        );

        // round _amount up to the nearest whole share if the amount of tokens specified does not translate to
        // at least 1 share.
        if (shareDebit == 0 && _amount > 0) {
            shareDebit++;
        }
        require(shareDebit > 0, "ZERO WITHDRAWL");
        uint256 withdrawableShares = getWithdrawableShares(userLock.lockID);
        // dust clearance block, as mulDiv rounds down leaving one share stuck, clear all shares for dust amounts
        if (shareDebit + 1 == withdrawableShares) {
            if (
                FullMath.mulDiv(
                    SHARES[userLock.tokenAddress],
                    balance / SHARES[userLock.tokenAddress],
                    balance
                ) == 0
            ) {
                shareDebit++;
            }
        }
        require(withdrawableShares >= shareDebit, "AMOUNT");
        userLock.sharesWithdrawn += shareDebit;

        // now convert shares to the actual _amount it represents, this may differ slightly from the
        // _amount supplied in this methods arguments.
        uint256 amountInTokens = FullMath.mulDiv(
            shareDebit,
            balance,
            SHARES[userLock.tokenAddress]
        );
        SHARES[userLock.tokenAddress] -= shareDebit;

        IERC20 VestingToken = IERC20(userLock.tokenAddress);
        VestingToken.transfer(address(msg.sender), amountInTokens);

        emit onWithdraw(userLock.tokenAddress, amountInTokens);
    }

    /**
     * @notice extend a lock with a new unlock date, if lock is Type 2 it extends the emission end date
     */
    function relock(
        uint256 _lockID,
        uint256 _unlock_date
    ) external payable nonReentrant {
        require(_unlock_date < 1e10, "TIME"); // prevents errors when timestamp entered in milliseconds

        TokenLock storage userLock = LOCKS[_lockID];
        require(userLock.owner == msg.sender, "OWNER");
        require(userLock.endEmission < _unlock_date, "END");

        require(msg.value == gFees.ethEditFee, "FEE NOT MET");

        userLock.endEmission = _unlock_date;
        emit onRelock(_lockID, _unlock_date);
    }

    /**
     * @notice increase the amount of tokens per a specific lock, this is preferable to creating a new lock
     * Its possible to increase someone elses lock here it does not need to be your own, useful for contracts
     */
    function incrementLock(
        uint256 _lockID,
        uint256 _amount
    ) external payable nonReentrant {
        TokenLock storage userLock = LOCKS[_lockID];
        require(_amount >= MINIMUM_DEPOSIT, "MIN DEPOSIT");

        require(msg.value == gFees.ethEditFee, "FEE NOT MET");

        IERC20 VestingToken = IERC20(userLock.tokenAddress);
        uint256 balanceBefore = VestingToken.balanceOf(address(this));
        VestingToken.transferFrom(address(msg.sender), address(this), _amount);

        uint256 amountInTokens = IERC20(userLock.tokenAddress).balanceOf(
            address(this)
        ) - balanceBefore;

        uint256 shares;
        if (SHARES[userLock.tokenAddress] == 0) {
            shares = amountInTokens;
        } else {
            shares = FullMath.mulDiv(
                amountInTokens,
                SHARES[userLock.tokenAddress],
                balanceBefore
            );
        }

        require(shares > 0, "SHARES");
        SHARES[userLock.tokenAddress] += shares;
        userLock.sharesDeposited += shares;
        emit onLock(
            userLock.lockID,
            userLock.tokenAddress,
            userLock.owner,
            amountInTokens,
            userLock.startEmission,
            userLock.endEmission
        );
    }

    /**
     * @notice transfer a lock to a new owner, e.g. presale project -> project owner
     * Please be aware this generates a new lock, and nulls the old lock, so a new ID is assigned to the new lock.
     */
    function transferLockOwnership(
        uint256 _lockID,
        address payable _newOwner
    ) external nonReentrant {
        require(msg.sender != _newOwner, "SELF");
        TokenLock storage transferredLock = LOCKS[_lockID];
        require(transferredLock.owner == msg.sender, "OWNER");

        TokenLock memory token_lock;
        token_lock.tokenAddress = transferredLock.tokenAddress;
        token_lock.sharesDeposited = transferredLock.sharesDeposited;
        token_lock.sharesWithdrawn = transferredLock.sharesWithdrawn;
        token_lock.startEmission = transferredLock.startEmission;
        token_lock.endEmission = transferredLock.endEmission;
        token_lock.lockID = NONCE;
        token_lock.owner = _newOwner;

        // record the lock globally
        LOCKS[NONCE] = token_lock;
        TOKEN_LOCKS[transferredLock.tokenAddress].push(NONCE);

        // record the lock for the new owner
        UserInfo storage newOwner = USERS[_newOwner];
        newOwner.lockedTokens.add(transferredLock.tokenAddress);
        newOwner.locksForToken[transferredLock.tokenAddress].push(
            token_lock.lockID
        );
        NONCE++;

        // zero the lock from the old owner
        transferredLock.sharesWithdrawn = transferredLock.sharesDeposited;
        emit onTransferLock(_lockID, token_lock.lockID, msg.sender, _newOwner);
    }

    /**
     * @notice split a lock into two seperate locks, useful when a lock is about to expire and youd like to relock a portion
     * and withdraw a smaller portion
     * Only works on lock type 1, this feature does not work with lock type 2
     * @param _amount the amount in tokens
     */
    function splitLock(
        uint256 _lockID,
        uint256 _amount
    ) external payable nonReentrant {
        require(_amount > 0, "ZERO AMOUNT");
        TokenLock storage userLock = LOCKS[_lockID];
        require(userLock.owner == msg.sender, "OWNER");
        require(userLock.startEmission == 0, "LOCK TYPE 2");

        require(msg.value == gFees.ethEditFee, "FEE NOT MET");

        // convert _amount to its representation in shares
        uint256 balance = IERC20(userLock.tokenAddress).balanceOf(
            address(this)
        );
        uint256 amountInShares = FullMath.mulDiv(
            SHARES[userLock.tokenAddress],
            _amount,
            balance
        );

        require(
            userLock.sharesWithdrawn + amountInShares <=
                userLock.sharesDeposited
        );

        TokenLock memory token_lock;
        token_lock.tokenAddress = userLock.tokenAddress;
        token_lock.sharesDeposited = amountInShares;
        token_lock.endEmission = userLock.endEmission;
        token_lock.lockID = NONCE;
        token_lock.owner = msg.sender;

        // debit previous lock
        userLock.sharesWithdrawn += amountInShares;

        // record the new lock globally
        LOCKS[NONCE] = token_lock;
        TOKEN_LOCKS[userLock.tokenAddress].push(NONCE);

        // record the new lock for the owner
        USERS[msg.sender].locksForToken[userLock.tokenAddress].push(
            token_lock.lockID
        );
        NONCE++;
        emit onSplitLock(_lockID, token_lock.lockID, _amount);
    }

    // returns withdrawable share amount from the lock, taking into consideration start and end emission
    function getWithdrawableShares(
        uint256 _lockID
    ) public view returns (uint256) {
        TokenLock storage userLock = LOCKS[_lockID];
        uint8 lockType = userLock.startEmission == 0 ? 1 : 2;
        uint256 amount = lockType == 1
            ? userLock.sharesDeposited - userLock.sharesWithdrawn
            : userLock.sharesDeposited;
        uint256 withdrawable;
        withdrawable = VestingMathLibrary.getWithdrawableAmount(
            userLock.startEmission,
            userLock.endEmission,
            amount,
            block.timestamp
        );
        if (lockType == 2) {
            withdrawable -= userLock.sharesWithdrawn;
        }
        return withdrawable;
    }

    // convenience function for UI, converts shares to the current amount in tokens
    function getWithdrawableTokens(
        uint256 _lockID
    ) external view returns (uint256) {
        TokenLock storage userLock = LOCKS[_lockID];
        uint256 withdrawableShares = getWithdrawableShares(userLock.lockID);
        uint256 balance = IERC20(userLock.tokenAddress).balanceOf(
            address(this)
        );
        uint256 amountTokens = FullMath.mulDiv(
            withdrawableShares,
            balance,
            SHARES[userLock.tokenAddress] == 0
                ? 1
                : SHARES[userLock.tokenAddress]
        );
        return amountTokens;
    }

    // For UI use
    function convertSharesToTokens(
        address _token,
        uint256 _shares
    ) external view returns (uint256) {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        return FullMath.mulDiv(_shares, balance, SHARES[_token]);
    }

    function convertTokensToShares(
        address _token,
        uint256 _tokens
    ) external view returns (uint256) {
        uint256 balance = IERC20(_token).balanceOf(address(this));
        return FullMath.mulDiv(SHARES[_token], _tokens, balance);
    }

    // For use in UI, returns more useful lock Data than just querying LOCKS,
    // such as the real-time token amount representation of a locks shares
    function getLock(
        uint256 _lockID
    )
        external
        view
        returns (
            uint256,
            address,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            address
        )
    {
        TokenLock memory tokenLock = LOCKS[_lockID];

        uint256 balance = IERC20(tokenLock.tokenAddress).balanceOf(
            address(this)
        );
        uint256 totalSharesOr1 = SHARES[tokenLock.tokenAddress] == 0
            ? 1
            : SHARES[tokenLock.tokenAddress];
        // tokens deposited and tokens withdrawn is provided for convenience in UI, with rebasing these amounts will change
        uint256 tokensDeposited = FullMath.mulDiv(
            tokenLock.sharesDeposited,
            balance,
            totalSharesOr1
        );
        uint256 tokensWithdrawn = FullMath.mulDiv(
            tokenLock.sharesWithdrawn,
            balance,
            totalSharesOr1
        );
        return (
            tokenLock.lockID,
            tokenLock.tokenAddress,
            tokensDeposited,
            tokensWithdrawn,
            tokenLock.sharesDeposited,
            tokenLock.sharesWithdrawn,
            tokenLock.startEmission,
            tokenLock.endEmission,
            tokenLock.owner
        );
    }

    function getNumLockedTokens() external view returns (uint256) {
        return TOKENS.length();
    }

    function getTokenAtIndex(uint256 _index) external view returns (address) {
        return TOKENS.at(_index);
    }

    function getTokenLocksLength(
        address _token
    ) external view returns (uint256) {
        return TOKEN_LOCKS[_token].length;
    }

    function getTokenLockIDAtIndex(
        address _token,
        uint256 _index
    ) external view returns (uint256) {
        return TOKEN_LOCKS[_token][_index];
    }

    // user functions
    function getUserLockedTokensLength(
        address _user
    ) external view returns (uint256) {
        return USERS[_user].lockedTokens.length();
    }

    function getUserLockedTokenAtIndex(
        address _user,
        uint256 _index
    ) external view returns (address) {
        return USERS[_user].lockedTokens.at(_index);
    }

    function getUserLocksForTokenLength(
        address _user,
        address _token
    ) external view returns (uint256) {
        return USERS[_user].locksForToken[_token].length;
    }

    function getUserLockIDForTokenAtIndex(
        address _user,
        address _token,
        uint256 _index
    ) external view returns (uint256) {
        return USERS[_user].locksForToken[_token][_index];
    }

    // consider service fee
    function hasRefferalTokenHold(address _user) internal view returns (bool) {
        return
            IERC20(gFees.referralToken).balanceOf(_user) >= gFees.referralHold;
    }
}
