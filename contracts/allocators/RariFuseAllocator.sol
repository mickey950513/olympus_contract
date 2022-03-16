// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

// interfaces
import "./interfaces/RariInterfaces.sol";

// types
import {BaseAllocator, AllocatorInitData} from "../types/BaseAllocator.sol";

/// @dev stored in storage
struct fData {
    uint96 idTroller;
    fToken token;
}

/// @dev function argument
struct fDataExpanded {
    fData f;
    IERC20 base;
    IERC20 rT;
}

struct ProtocolSpecificData {
    address treasury;
    address rewards;
}

struct FuseAllocatorInitData {
    AllocatorInitData base;
    ProtocolSpecificData spec;
}

contract RariFuseAllocator is BaseAllocator {
    address public treasury;

    RewardsDistributorDelegate internal _rewards;

    fData[] internal _fData;
    IERC20[] internal _rewardTokens;

    RariTroller[] internal _trollers;

    constructor(FuseAllocatorInitData memory fuseData) BaseAllocator(fuseData.base) {
        _rewards = RewardsDistributorDelegate(fuseData.spec.rewards);
        treasury = fuseData.spec.treasury;
    }

    function _update(uint256 id) internal override returns (uint128 gain, uint128 loss) {
        // reads
        uint256 index = tokenIds[id];
        fToken f = _fData[index].token;
        IERC20Metadata b = IERC20Metadata(address(_tokens[index]));
        RewardsDistributorDelegate rewards = _rewards;
        uint256 balance = b.balanceOf(address(this));

        // interactions
        if (rewards.compAccrued(address(this)) > 0) rewards.claimRewards(address(this));

        if (balance > 0) {
            b.approve(address(f), balance);
            f.mint(balance);
        }

        // effects
        uint256 former = extender.getAllocatorAllocated(id) + extender.getAllocatorPerformance(id).gain;
        uint256 current = _worth(f, b);

        if (current >= former) gain = uint128(current - former);
        else loss = uint128(former - current);
    }

    function deallocate(uint256[] memory amounts) public override onlyGuardian {
        uint256 length = amounts.length;

        for (uint256 i; i < length; i++) {
            fToken f = _fData[i].token;

            if (amounts[i] == type(uint256).max) f.redeem(f.balanceOf(address(this)));
            else f.redeemUnderlying(amounts[i]);
        }
    }

    function _deactivate(bool panic) internal override {
        _deallocateAll();

        if (panic) {
            uint256 length = _fData.length;

            for (uint256 i; i < length; i++) {
                fToken f = _fData[i].token;
                IERC20 u = _tokens[i];

                f.redeem(f.balanceOf(address(this)));
                u.transfer(treasury, u.balanceOf(address(this)));
            }

            length = _rewardTokens.length;

            for (uint256 i; i < length; i++) {
                IERC20 rT = _rewardTokens[i];
                rT.transfer(treasury, rT.balanceOf(address(this)));
            }
        }
    }

    function _prepareMigration() internal override {
        RewardsDistributorDelegate rewards = _rewards;
        if (rewards.compAccrued(address(this)) > 0) rewards.claimRewards(address(this));
    }

    function amountAllocated(uint256 id) public view override returns (uint256) {
        uint256 index = tokenIds[id];
        IERC20Metadata b = IERC20Metadata(address(_tokens[index]));
        return _worth(_fData[index].token, b) + b.balanceOf(address(this));
    }

    function rewardTokens() public view override returns (IERC20[] memory) {
        return _rewardTokens;
    }

    function utilityTokens() public view override returns (IERC20[] memory) {
        IERC20[] memory uTokens = new IERC20[](_fData.length);
        for (uint256 i; i < 0; i++) uTokens[i] = _fData[i].token;
        return uTokens;
    }

    function name() external pure override returns (string memory) {
        return "RariFuseAllocator";
    }

    //// start of functions specific for allocator

    function setTreasury(address newTreasury) external onlyGuardian {
        treasury = newTreasury;
    }

    function setRewards(address newRewards) external onlyGuardian {
        _rewards = RewardsDistributorDelegate(newRewards);
    }

    /// @notice Add a fuse pool by adding the troller.
    /// @dev The troller is a comptroller, which is a contract that has all the data and allows entering markets in regards to a fuse pool.
    /// @param troller the trollers' address
    function fusePoolAdd(address troller) external onlyGuardian {
        _trollers.push(RariTroller(troller));
    }

    /// @notice Add data for depositing an underlying token in a fuse pool.
    /// @dev The data fields are described above in the struct `fDataExpanded` specific for this contract.
    /// @param data the data necessary for another token to be allocated, check the struct in code
    function fDataAdd(fDataExpanded calldata data) external onlyGuardian {
        // reads
        address[] memory fInput = new address[](1);
        fInput[0] = address(data.f.token);

        // interaction
        _trollers[data.f.idTroller].enterMarkets(fInput);

        data.base.approve(address(extender), type(uint256).max);
        data.f.token.approve(address(extender), type(uint256).max);

        // effect
        _fData.push(data.f);
        _tokens.push(data.base);

        if (data.rT != IERC20(address(0))) {
            _rewardTokens.push(data.rT);
            data.rT.approve(address(extender), type(uint256).max);
        }
    }

    /// @dev logic is directly from fuse docs
    function _worth(fToken f, IERC20Metadata b) internal view returns (uint256) {
        return (f.exchangeRate() * f.balanceOf(address(this))) / (10**(18 + uint256(b.decimals() - f.decimals())));
    }

    function _deallocateAll() internal {
        uint256[] memory input = new uint256[](_fData.length);
        for (uint256 i; i < input.length; i++) input[i] = type(uint256).max;
        deallocate(input);
    }
}
