// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

/* Library Imports */
import { Lib_PredeployAddresses } from "../../libraries/constants/Lib_PredeployAddresses.sol";

/* Contract Imports */
import { L2StandardBridge } from "../messaging/L2StandardBridge.sol";
import { L2StandardERC20 } from "../../standards/L2StandardERC20.sol";
import { OVM_GasPriceOracle } from "../predeploys/OVM_GasPriceOracle.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/* Contract Imports */
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

/**
 * @title TON_FeeVault
 */
contract TON_FeeVault {
    // TODO: define value of the constants
    using SafeERC20 for IERC20;

    /*************
     * Constants *
     *************/

    // Minimum TON balance that can be withdrawn in a single withdrawal.
    // 150,000 TON
    uint256 public constant MIN_WITHDRAWAL_AMOUNT = 150000e18;

    /*************
     * Variables *
     *************/

    // Owner address
    address private _owner;

    // Address that will hold the fees once withdrawn. Dynamically initialized within l2geth.
    address public feeWallet;

    // L2 Ton token address
    address public l2TonAddress;

    // The maximum price ratio value of ETH and TON
    uint256 public maxPriceRatio = 5000;

    // The minimum price ratio value of ETH and TON
    uint256 public minPriceRatio = 500;

    // The price ratio of ETH and TON
    // This price ratio considers the saving percentage of using TON as the fee token
    uint256 public priceRatio;

    // Gas price oracle address (OVM_GasPriceOracle)
    address public gasPriceOracleAddress = 0x420000000000000000000000000000000000000F;

    // Record the wallet address that wants to use ton as fee token
    mapping(address => bool) public tonFeeTokenUsers;

    // Price ratio without discount
    uint256 public marketPriceRatio;

    /*************
     *  Events   *
     *************/

    event TransferOwnership(address, address);
    event UpdatePriceRatio(address, uint256, uint256);
    event UpdateMaxPriceRatio(address, uint256);
    event UpdateMinPriceRatio(address, uint256);
    event UpdateGasPriceOracleAddress(address, address);
    event WithdrawTON(address, address);

    /**********************
     * Function Modifiers *
     **********************/

    modifier onlyNotInitialized() {
        require(address(feeWallet) == address(0), "Contract has been initialized");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "caller is not the owner");
        _;
    }

    /********************
     * Fall back Functions *
     ********************/

    /**
     * Receive ETH
     */
    receive() external payable {}

    /********************
     * Public Functions *
     ********************/

    /**
     * transfer ownership
     * @param _newOwner new owner address
     */
    function transferOwnership(address _newOwner) public onlyOwner {
        require(_newOwner != address(0), "Ownable: new owner is the zero address");
        address oldOwner = _owner;
        _owner = _newOwner;
        emit TransferOwnership(oldOwner, _newOwner);
    }

    /**
     * Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return _owner;
    }

    /**
     * Initialize feeWallet and l2TonAddress.
     */
    function initialize(address payable _feeWallet, address _l2TonAddress)
        public
        onlyNotInitialized
    {
        require(_feeWallet != address(0) && _l2TonAddress != address(0));
        feeWallet = _feeWallet;
        l2TonAddress = _l2TonAddress;

        // Initialize the parameters
        _owner = msg.sender;
        gasPriceOracleAddress = 0x420000000000000000000000000000000000000F;
        maxPriceRatio = 5000;
        priceRatio = 2000;
        minPriceRatio = 500;
        marketPriceRatio = 2000;
    }

    /**
     * Update the price ratio of ETH and TON
     * @param _priceRatio the price ratio of ETH and TON
     * @param _marketPriceRatio tha market price ratio of ETH and TON
     */
    function updatePriceRatio(uint256 _priceRatio, uint256 _marketPriceRatio) public onlyOwner {
        require(_priceRatio <= maxPriceRatio && _priceRatio >= minPriceRatio);
        require(_marketPriceRatio <= maxPriceRatio && _marketPriceRatio >= minPriceRatio);
        priceRatio = _priceRatio;
        marketPriceRatio = _marketPriceRatio;
        emit UpdatePriceRatio(owner(), _priceRatio, _marketPriceRatio);
    }

    /**
     * Update the maximum price ratio of ETH and TON
     * @param _maxPriceRatio the maximum price ratio of ETH and TON
     */
    function updateMaxPriceRatio(uint256 _maxPriceRatio) public onlyOwner {
        require(_maxPriceRatio >= minPriceRatio && _maxPriceRatio > 0);
        maxPriceRatio = _maxPriceRatio;
        emit UpdateMaxPriceRatio(owner(), _maxPriceRatio);
    }

    /**
     * Update the minimum price ratio of ETH and TON
     * @param _minPriceRatio the minimum price ratio of ETH and TON
     */
    function updateMinPriceRatio(uint256 _minPriceRatio) public onlyOwner {
        require(_minPriceRatio <= maxPriceRatio && _minPriceRatio > 0);
        minPriceRatio = _minPriceRatio;
        emit UpdateMinPriceRatio(owner(), _minPriceRatio);
    }

    /**
     * Update the gas oracle address
     * @param _gasPriceOracleAddress gas oracle address
     */
    function updateGasPriceOracleAddress(address _gasPriceOracleAddress) public onlyOwner {
        require(Address.isContract(_gasPriceOracleAddress), "Account is EOA");
        require(_gasPriceOracleAddress != address(0));
        gasPriceOracleAddress = _gasPriceOracleAddress;
        emit UpdateGasPriceOracleAddress(owner(), _gasPriceOracleAddress);
    }

    /**
     * Get L1 Ton fee for fee estimation
     * @param _txData the data payload
     */
    function getL1TonFee(bytes memory _txData) public view returns (uint256) {
        OVM_GasPriceOracle gasPriceOracleContract = OVM_GasPriceOracle(gasPriceOracleAddress);
        return gasPriceOracleContract.getL1Fee(_txData) * priceRatio;
    }

    /**
     * withdraw TON tokens to l1 fee wallet
     */
    function withdrawTON() public {
        // check L2 balance whether it is possible to withdraw
        require(
            L2StandardERC20(l2TonAddress).balanceOf(address(this)) >= MIN_WITHDRAWAL_AMOUNT,
            // solhint-disable-next-line max-line-length
            "Ton_GasPriceOracle: withdrawal amount must be greater than minimum withdrawal amount"
        );
        // send amount of TON balance to L1
        L2StandardBridge(Lib_PredeployAddresses.L2_STANDARD_BRIDGE).withdrawTo(
            l2TonAddress,
            feeWallet,
            L2StandardERC20(l2TonAddress).balanceOf(address(this)),
            0,
            bytes("")
        );
        emit WithdrawTON(owner(), feeWallet);
    }
}
