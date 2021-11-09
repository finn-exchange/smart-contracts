pragma solidity ^0.4.25;

import "./provableAPI_0.4.25.sol";

/* Interface for the FINN base contract */
contract FINN {

	function closeFuturesContract (bytes32 futuresContract, uint256 price) returns (bool);
	function getContractExpiration (bytes32 futuresContractHash) returns (uint256);
	function getContractClosed (bytes32 futuresContractHash) returns (bool);
	function getContractPriceUrl (bytes32 futuresContractHash) returns (string);
	function getContractPricePath (bytes32 futuresContractHash) returns (string);
    function getAssetDecimals (bytes32 futuresContractHash) returns (uint256);

    function recordLatestAssetPrice(bytes32 futuresContractHash, uint256 price);
    function setClosingPrice (bytes32 futuresContractHash, uint256 price) returns (bool);
}

// The FINN Futures Contract
contract FINN_Oracle is usingProvable {

	address public FINN_contract;
	address public owner; // holds the address of the contract owner

    mapping (bytes32 => bytes32)            public close_queries;       // mapping of pending oracle close contract queries (queryId => futuresContractHash)
	mapping (bytes32 => bytes32)            public price_queries;         // mapping of pending oracle price queries (queryId => futuresContractHash)
	mapping (address => bool) 				public admins;              // mapping of admin addresses


	event LogOracleRequest(bytes32 indexed queryId, bytes32 indexed futuresContractHash, uint8 route, string priceUrl, string pricePath);
    event LogOracleCallback(bytes32 indexed queryId, bytes32 indexed futuresContractHash, uint8 route,  string result);
    event FuturesContractClosed(bytes32 indexed futuresContract, uint256 closingPrice);
    event AssetPriceUpdated(bytes32 indexed futuresContract, uint256 price);
    event LogUint(uint8 id, uint256 value);

    // Event fired when the owner of the contract is changed
    event SetOwner(address indexed previousOwner, address indexed newOwner);

    function assert(bool assertion) pure {

        if (!assertion) {
            throw;
        }
    }

    // Safe Multiply Function - prevents integer overflow
    function safeMul(uint a, uint b) pure returns (uint) {
        uint c = a * b;
        assert(a == 0 || c / a == b);
        return c;
    }

    // Safe Subtraction Function - prevents integer overflow
    function safeSub(uint a, uint b) pure returns (uint) {
        assert(b <= a);
        return a - b;
    }

    // Safe Addition Function - prevents integer overflow
    function safeAdd(uint a, uint b) pure returns (uint) {
        uint c = a + b;
        assert(c>=a && c>=b);
        return c;
    }

    // Allows only the owner of the contract to execute the function
    modifier onlyOwner {
        assert(msg.sender == owner);
        _;
    }

    // Changes the owner of the contract
    function setOwner(address newOwner) onlyOwner {
        emit SetOwner(owner, newOwner);
        owner = newOwner;
    }

    // Adds or disables an admin account
    function setAdmin(address admin, bool isAdmin) onlyOwner {
        admins[admin] = isAdmin;
    }

    function setFinnContract(address FINN_contract_)
    {
    	FINN_contract = FINN_contract_;
    }

    // Allows for admins only to call the function
    modifier onlyAdmin {
        if (msg.sender != owner && !admins[msg.sender]) throw;
        _;
    }


	// Constructor function, initializes the contract and sets the core variables
    function FINN_Oracle() {
    	owner = msg.sender;
    }

    function deposit() payable {

    }

    function withdraw(uint256 amount) onlyOwner
    {
    	msg.sender.send(amount);
    }

	function closeFuturesContract (bytes32 futuresContractHash, uint256 gasPrice, uint256 gasLimit) onlyAdmin payable
    {
        if (FINN(FINN_contract).getContractExpiration(futuresContractHash) == 0) revert(); // contract not found
        if (FINN(FINN_contract).getContractClosed(futuresContractHash) == true) revert(); // contract already closed

        closeContractWithOraclePrice(futuresContractHash, gasPrice, gasLimit);
    }

    function closeContractWithOraclePrice(bytes32 futuresContractHash, uint256 gasPrice, uint256 gasLimit) private {
        string memory priceUrl = FINN(FINN_contract).getContractPriceUrl(futuresContractHash); // futuresAssets[FINN(FINN_contract).futuresContracts[futuresContractHash].asset].priceUrl;
        string memory path = FINN(FINN_contract).getContractPricePath(futuresContractHash); //  futuresAssets[FINN(FINN_contract).futuresContracts[futuresContractHash].asset].pricePath;

        provable_setCustomGasPrice(gasPrice);

        bytes32 queryId = provable_query("URL",strConcat("json(", priceUrl, ").",path), gasLimit);
        close_queries[queryId] = futuresContractHash;
        emit LogOracleRequest(queryId, futuresContractHash, 0, priceUrl, path);

    }

    function queryPrice (bytes32 futuresContractHash, uint256 gasPrice, uint256 gasLimit) onlyAdmin payable
    {
        if (FINN(FINN_contract).getContractExpiration(futuresContractHash) == 0) revert(); // contract not found
        if (FINN(FINN_contract).getContractClosed(futuresContractHash) == true) revert(); // contract already closed

        recordAssetPriceWithOracle(futuresContractHash, gasPrice, gasLimit);
    }

    function recordAssetPriceWithOracle(bytes32 futuresContractHash, uint256 gasPrice, uint256 gasLimit) private {
        string memory priceUrl = FINN(FINN_contract).getContractPriceUrl(futuresContractHash); // futuresAssets[FINN(FINN_contract).futuresContracts[futuresContractHash].asset].priceUrl;
        string memory path = FINN(FINN_contract).getContractPricePath(futuresContractHash); //  futuresAssets[FINN(FINN_contract).futuresContracts[futuresContractHash].asset].pricePath;

        provable_setCustomGasPrice(gasPrice);

        bytes32 queryId = provable_query("URL",strConcat("json(", priceUrl, ").",path), gasLimit);
        price_queries[queryId] = futuresContractHash;
        emit LogOracleRequest(queryId, futuresContractHash, 1, priceUrl, path);

    }

    // Receives price from the oracle
    function __callback(bytes32 myid, string result) {
        if (msg.sender != provable_cbAddress()) revert();
        if (close_queries[myid] == "" && price_queries[myid] == "") revert();

        uint8 route;
        bytes32 futuresContractHash;
        bytes32 empty;

        if (close_queries[myid] != "")
        {
            route = 0;
        }
        else if (price_queries[myid] != "")
        {
            route = 1;
        }
        else
        {
            revert();
        }

        if (route == 0)
        {
            futuresContractHash = close_queries[myid]; 
        }
        else
        {
            futuresContractHash = price_queries[myid];
        }
        

        emit LogOracleCallback(myid, futuresContractHash, route,  result);

        uint256 decimals = FINN(FINN_contract).getAssetDecimals(futuresContractHash);
        uint256 remainingDecimals = 8 - decimals;

        uint256 price = safeMul(parseInt(result, decimals), 10**remainingDecimals);

        if (route == 0)
        {
            closeFuturesContractInternal(futuresContractHash, price);
        }
        else
        {
            recordAssetPriceInternal(futuresContractHash, price);
        }
    }

    function recordAssetPriceInternal(bytes32 futuresContract, uint256 price) private returns (bool)
    {        
        FINN(FINN_contract).recordLatestAssetPrice(futuresContract, price); 

        emit AssetPriceUpdated(futuresContract, price);
    } 

    function closeFuturesContractInternal(bytes32 futuresContract, uint256 price) private returns (bool)
    {
        uint256 expirationBlock = FINN(FINN_contract).getContractExpiration(futuresContract);

        if (expirationBlock == 0 || expirationBlock > block.number)  return false; // contract not found
        if (FINN(FINN_contract).getContractClosed(futuresContract) == true)  return false; // contract already closed
        
        FINN(FINN_contract).setClosingPrice(futuresContract, price); 

        emit FuturesContractClosed(futuresContract, price);
    }  

}
