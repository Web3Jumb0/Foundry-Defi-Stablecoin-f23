//SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";

/**
 * @title DSCEngine
 * @author Junbo Li
 *
 * The system is desigend to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmic Stable
 *
 * It is similar to DAI if DAI had no governance and was backed by WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral be less than the $ backed value of all DSC tokens.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO Dss(DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    //////////////////
    // Error        //
    //////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotSupported();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor();
    error DSCEngine__MintFailed();

    //////////////////////
    // State Variables  //
    //////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THREADSHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_pricefeed; //tokenToPricefeed
    mapping(address user => mapping(address token => uint256)) private s_collateralDeposited; //userToTokenToCollateral
    mapping(address user => uint256) private s_dscMinted; //userToDscMinted
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    //////////////////
    // Events       //
    //////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);

    //////////////////
    // Modifiers    //
    //////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_pricefeed[token] == address(0)) {
            revert DSCEngine__TokenNotSupported();
        }
        _;
    }

    //////////////////
    // Functions    //
    //////////////////

    constructor(address[] memory tokenAddress, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddress.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        for (uint256 i = 0; i < tokenAddress.length; i++) {
            s_pricefeed[tokenAddress[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddress[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////////
    // External Functions    //
    ///////////////////////////

    /*
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stable coin to mint
     * @notice this function will deposit collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @notice follows CEI
     * @param tokenCollateralAddress The address of the collateral token
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /*
    *
    * @param tokenCollateralAddress The address of the collateral token
    * @param amountCollateral The amount of collateral to redeem
    * @param amountDscToBurn The amount of decentralized stable coin to burn
    * This function will redeem collateral and mint DSC in one transaction
    */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks the health factor
    }

    // in order to redeem collatgeral:
    // 1. health factor must be over 1 AFTER collateral pulled
    // DRY: Don't repeat yourself
    // CEI: Check-Effect-Interact
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);
        // _calculateHealthFactorAfter()
        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        _reverIfHealthFactorIsBroken(msg.sender);
    }

    /*
    * @notice follows CEI
    * @param amountDscToMint The amount of decentralized stable coin to mint
    * @notice they must have more collateral than the minimum threadhold
    */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        _reverIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        s_dscMinted[msg.sender] -= amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amount);
        _reverIfHealthFactorIsBroken(msg.sender); // This might never be hitted
    }

    // $75 backing $50 DSC
    // Liquidator take $75 backing and burns off the $50 DSC

    // If someone is almost undercollateralized, we will pay you to liquidate them!
    /*
    * @param collateral The erc20 collateral address to liquidate from the user
    * @param user the user who broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
    * @param debtToCover the amount of DSC you want to burn to imporve the users health factor
    * @notice You can partially liquidate a user.
    * @notice You will get a luquidation bonuse for take the users funds
    * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
    * @notice A know bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentive the liquidators.
    * For example, if the price of the collateral plummeted before anyone could be liquidated.
    * 
    * Following CEI: Check-Effect-Interact
    */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //need to check health factor of user
        uint256 startingUserHealthFactor = _healthFactor(user);
    }

    function getHealthFactor() external view {}

    //////////////////////////////////
    // Private & Internal View Functions //
    //////////////////////////////////
    /*
    * Returns how close the liquidation a user is
    * If a user goes below 1, then they can get liquidated
    */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinited, uint256 totalCollateralValue)
    {
        totalDscMinited = s_dscMinted[user];
        totalCollateralValue = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) internal view returns (uint256) {
        (uint256 totalDscMinited, uint256 totalCollateralValue) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreadhold = totalCollateralValue * LIQUIDATION_THREADSHOLD / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreadhold * PRECISION) / totalDscMinited;
        // return totalCollateralValue / totalDscMinited;
    }

    function _reverIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor();
        }
    }
    // 1. Check health factor (do they have enough collateral?)
    // 2. Rever if they don't

    //////////////////////////////////
    // Public & External View Functions //
    //////////////////////////////////
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // Loop through all the collateral tokens and get the value of the collateral
        uint256 totalCollateralValue = 0;
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValue += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_pricefeed[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH =  $1000
        // The returned value from CL will be 1000 * 1e18;
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
