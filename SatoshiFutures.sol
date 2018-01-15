pragma solidity ^0.4.19;

import "./SafeMath.sol";
import "./oraclize.sol";
import "./strings.sol";

// start of satoshi futures contract

contract SatoshiFutures is usingOraclize {
    using strings for *;
    using SafeMath for *;

    
    address public owner;
    uint public allOpenTradesAmounts = 0;
    uint safeGas = 2300;
    uint constant ORACLIZE_GAS_LIMIT = 300000;
    bool public  isStopped = false;
    uint public ownerFee = 3;
    uint public currentProfitPct = 70;
    uint public minTrade = 10 finney;
    bool public emergencyWithdrawalActivated = false;
    uint public tradesCount = 0;
   
    

    struct Trade {
        address investor;
        uint amountInvested;
        uint initialPrice;
        uint finalPrice;
        string coinSymbol;
        string putOrCall;
    }

    struct TradeStats {
        uint initialTime;
        uint finalTime;
        bool resolved;
        uint tradePeriod;
        bool wonOrLost;
        string query;
    }

    struct Investor {
        address investorAddress;
        uint balanceToPayout;
        bool withdrew;
    }
    
    mapping(address => uint) public investorIDs;
    mapping(uint => Investor) public investors;
    uint public numInvestors = 0;


    mapping(bytes32 => Trade) public trades;
    mapping(bytes32 => TradeStats) public tradesStats;
    mapping(uint => bytes32) public tradesIds; 
    
    event LOG_MaxTradeAmountChanged(uint maxTradeAmount);
    event LOG_NewTradeCreated(bytes32 tradeId, address investor);
    event LOG_ContractStopped(string status);
    event LOG_OwnerAddressChanged(address oldAddr, address newOwnerAddress);
    event LOG_TradeWon (address investorAddress, uint amountInvested, bytes32 tradeId, uint _startTrade, uint _endTrade, uint _startPrice, uint _endPrice, string _coinSymbol, uint _pctToGain, string _queryUrl);
    event LOG_TradeLost(address investorAddress, uint amountInvested, bytes32 tradeId, uint _startTrade, uint _endTrade, uint _startPrice, uint _endPrice, string _coinSymbol, uint _pctToGain, string _queryUrl);
    event LOG_TradeDraw(address investorAddress, uint amountInvested, bytes32 tradeId, uint _startTrade, uint _endTrade, uint _startPrice, uint _endPrice, string _coinSymbol, uint _pctToGain, string _queryUrl);
    event LOG_GasLimitChanged(uint oldGasLimit, uint newGasLimit);


    //CONSTRUCTOR FUNCTION
    function SatoshiFutures()  {
        oraclize_setCustomGasPrice(40000000000 wei);
        oraclize_setProof(proofType_TLSNotary | proofStorage_IPFS);
        owner = msg.sender;
    }

    //SECTION I: MODIFIERS AND HELPER FUNCTIONS
    
    modifier onlyOwner {
            require(msg.sender == owner);
            _;
    }
    
    modifier onlyOraclize {
        require(msg.sender == oraclize_cbAddress());
        _;
    }
    
    modifier onlyIfValidGas(uint newGasLimit) {
        require(ORACLIZE_GAS_LIMIT + newGasLimit > ORACLIZE_GAS_LIMIT);
        require(newGasLimit > 2500);
        _;
    }
    
    modifier onlyIfNotStopped {
      require(!isStopped);
        _;
    }

    modifier onlyIfStopped {
      require(isStopped);
        _;
    }
    
    modifier onlyIfTradeExists(bytes32 myid) {
        require(trades[myid].investor != address(0x0));
        _;
    }

    modifier onlyIfTradeUnresolved(bytes32 myid) {
        require(tradesStats[myid].resolved != true);
        _;
    }

    modifier onlyIfEnoughBalanceToPayOut(uint _amountInvested) {
        require( _amountInvested < getMaxTradeAmount());
        _;
    }

    modifier onlyInvestors {
        require(investorIDs[msg.sender] != 0);
        _;
    }
    
    modifier onlyNotInvestors {
        require(investorIDs[msg.sender] == 0);
        _;
    }

    function addInvestorAtID(uint id)
    onlyNotInvestors
        private {
        investorIDs[msg.sender] = id;
        investors[id].investorAddress = msg.sender;
    }
    
    modifier onlyIfValidTradePeriod(uint tradePeriod) {
        require(tradePeriod <= 30);
        _;
    }

    modifier onlyIfTradeTimeEnded(uint _endTime) {
        require(block.timestamp > _endTime);
        _;
    }
    
    modifier onlyMoreThanMinTrade() {
        require(msg.value >= minTrade);
        _;
    }
    function getMaxTradeAmount() constant returns(uint) {
        LOG_MaxTradeAmountChanged((this.balance - allOpenTradesAmounts) * 100/currentProfitPct);
        require(this.balance >= allOpenTradesAmounts);
        return ((this.balance - allOpenTradesAmounts) * 100/currentProfitPct);
    }

    
    // SECTION II: TRADES & TRADE PROCESSING
     
     /*
     * @dev Add money to the contract in case balance goes to 0.
     */
    

    function addMoneyToContract() payable returns(uint) {
        //to add balance to the contract so trades are posible
        return msg.value;
        getMaxTradeAmount();
    }


     /*
     * @dev Initiate a trade by providing all the right params.
     */

    function startTrade(string _coinSymbol, uint _tradePeriod, bool _putOrCall) 
        payable 
        onlyIfNotStopped
        // onlyIfRightCoinChoosen(_coinSymbol)
        onlyMoreThanMinTrade 
        onlyIfValidTradePeriod(_tradePeriod)
        onlyIfEnoughBalanceToPayOut(msg.value) {
        string memory serializePutOrCall; 
        if(_putOrCall == true) {
            serializePutOrCall = "put";
        } else  {
            serializePutOrCall = "call";
        }
        var finalTime = block.timestamp + ((_tradePeriod + 1) * 60);
        string memory queryUrl = generateUrl(_coinSymbol, block.timestamp,  _tradePeriod );
        bytes32 queryId = oraclize_query(block.timestamp + ((_tradePeriod + 5) * 60), "URL", queryUrl,ORACLIZE_GAS_LIMIT + safeGas);
        var thisTrade = trades[queryId];
        var thisTradeStats = tradesStats[queryId];
        thisTrade.investor = msg.sender;
        thisTrade.amountInvested = msg.value - (msg.value * ownerFee / 100 ); 
        thisTrade.initialPrice = 0; 
        thisTrade.finalPrice = 0; 
        thisTrade.coinSymbol = _coinSymbol; 
        thisTradeStats.tradePeriod = _tradePeriod; 
        thisTrade.putOrCall = serializePutOrCall; 
        thisTradeStats.wonOrLost = false; 
        thisTradeStats.initialTime = block.timestamp; 
        thisTradeStats.finalTime = finalTime - 60; 
        thisTradeStats.resolved = false; 
        thisTradeStats.query = queryUrl; 
        allOpenTradesAmounts += thisTrade.amountInvested + ((thisTrade.amountInvested * currentProfitPct) / 100);
        tradesIds[tradesCount++] = queryId;
        owner.transfer(msg.value  * ownerFee / 100); 
        getMaxTradeAmount();
        if (investorIDs[msg.sender] == 0) {
           numInvestors++;
           addInvestorAtID(numInvestors); 
        } 
        
        LOG_NewTradeCreated(queryId, thisTrade.investor);

    }

    // function __callback(bytes32 myid, string result, bytes proof) public {
    //     __callback(myid, result);
    // }
    

     /*
     * @dev Callback function from oraclize after the trade period is over.
     * updates trade initial and final price and than calls the resolve trade function.
     */
    function __callback(bytes32 myid, string result, bytes proof)
        onlyOraclize 
        onlyIfTradeExists(myid)
        onlyIfTradeUnresolved(myid) {
        var s = result.toSlice();
        var d = s.beyond("[".toSlice()).until("]".toSlice());
        var delim = ",".toSlice();
        var parts = new string[](d.count(delim) + 1 );
        for(uint i = 0; i < parts.length; i++) {
          parts[i] = d.split(delim).toString();
        }
        
        trades[myid].initialPrice = parseInt(parts[0],4);
        trades[myid].finalPrice = parseInt(parts[tradesStats[myid].tradePeriod],4);
        resolveTrade(myid);         
    }
    

     /*
     * @dev Resolves the trade based on the initial and final amount,
     * depending if put or call were chosen, if its a draw the money goes back
     * to investor.
     */
    function resolveTrade(bytes32 _myId) internal
    onlyIfTradeExists(_myId)
    onlyIfTradeUnresolved(_myId)
    onlyIfTradeTimeEnded(tradesStats[_myId].finalTime)
        {
    tradesStats[_myId].resolved = true;    
    if(trades[_myId].initialPrice == trades[_myId].finalPrice) {
        trades[_myId].investor.transfer(trades[_myId].amountInvested);
        LOG_TradeDraw(trades[_myId].investor, trades[_myId].amountInvested,_myId, tradesStats[_myId].initialTime, tradesStats[_myId].finalTime, trades[_myId].initialPrice, trades[_myId].finalPrice, trades[_myId].coinSymbol, currentProfitPct, tradesStats[_myId].query);
        }
     if(trades[_myId].putOrCall.toSlice().equals("put".toSlice())) { 
         if(trades[_myId].initialPrice > trades[_myId].finalPrice) {
            tradesStats[_myId].wonOrLost = true;
            trades[_myId].investor.transfer(trades[_myId].amountInvested + ((trades[_myId].amountInvested * currentProfitPct) / 100)); 
            LOG_TradeWon(trades[_myId].investor, trades[_myId].amountInvested,_myId, tradesStats[_myId].initialTime, tradesStats[_myId].finalTime, trades[_myId].initialPrice, trades[_myId].finalPrice, trades[_myId].coinSymbol, currentProfitPct, tradesStats[_myId].query);
        }
        if(trades[_myId].initialPrice < trades[_myId].finalPrice) {
            tradesStats[_myId].wonOrLost = false;
            trades[_myId].investor.transfer(1); 
            LOG_TradeLost(trades[_myId].investor, trades[_myId].amountInvested,_myId, tradesStats[_myId].initialTime, tradesStats[_myId].finalTime, trades[_myId].initialPrice, trades[_myId].finalPrice, trades[_myId].coinSymbol, currentProfitPct, tradesStats[_myId].query);
        }    
     }

     if(trades[_myId].putOrCall.toSlice().equals("call".toSlice())) { 
         if(trades[_myId].initialPrice < trades[_myId].finalPrice) {
            tradesStats[_myId].wonOrLost = true;
            trades[_myId].investor.transfer(trades[_myId].amountInvested + ((trades[_myId].amountInvested * currentProfitPct) / 100)); 
            LOG_TradeWon(trades[_myId].investor, trades[_myId].amountInvested,_myId, tradesStats[_myId].initialTime, tradesStats[_myId].finalTime, trades[_myId].initialPrice, trades[_myId].finalPrice, trades[_myId].coinSymbol, currentProfitPct, tradesStats[_myId].query);
        }
        if(trades[_myId].initialPrice > trades[_myId].finalPrice) {
            tradesStats[_myId].wonOrLost = false;
            trades[_myId].investor.transfer(1); 
            LOG_TradeLost(trades[_myId].investor, trades[_myId].amountInvested,_myId, tradesStats[_myId].initialTime, tradesStats[_myId].finalTime, trades[_myId].initialPrice, trades[_myId].finalPrice, trades[_myId].coinSymbol, currentProfitPct, tradesStats[_myId].query);
        }
     }
    allOpenTradesAmounts -= trades[_myId].amountInvested + ((trades[_myId].amountInvested * currentProfitPct) / 100);
    getMaxTradeAmount();

    }
  
   

    /*
     * @dev Generate the url for the api call for oraclize.
     */
   function generateUrl(string _coinChosen, uint _timesStartTrade ,uint _tradePeriod) internal returns (string) {
        strings.slice[] memory parts = new strings.slice[](11);
        parts[0] = "json(https://api.cryptowat.ch/markets/bitfinex/".toSlice();
        parts[1] = _coinChosen.toSlice();
        parts[2] = "/ohlc?periods=60&after=".toSlice();
        parts[3] = uint2str(_timesStartTrade).toSlice();
        // parts[4] = "&before=".toSlice();
        // parts[5] = uint2str((_timesStartTrade + ( (_tradePeriod + 1 ) * 60))).toSlice();
        parts[4] = ").result.".toSlice();
        parts[5] = strConcat('"',uint2str(60),'"').toSlice();
        parts[6] = ".[0:".toSlice();
        parts[7] = uint2str(_tradePeriod + 1).toSlice();
        parts[8] = "].1".toSlice();
        return ''.toSlice().join(parts);
    }
 
   
    
    
    //SECTION IV: CONTRACT MANAGEMENT

    
    
    function stopContract()
    onlyOwner {
    isStopped = true;
    LOG_ContractStopped("the contract is stopped");
    }

    function resumeContract()
    onlyOwner {
    isStopped = false;
    LOG_ContractStopped("the contract is resumed");
    }
    
    function changeOwnerAddress(address newOwner)
    onlyOwner {
    require(newOwner != address(0x0)); //changed based on audit feedback
    owner = newOwner;
    LOG_OwnerAddressChanged(owner, newOwner);
    }

    function changeOwnerFee(uint _newFee) 
    onlyOwner {
        ownerFee = _newFee;
    }

    function setProfitPcnt(uint _newPct) onlyOwner {
        currentProfitPct = _newPct;
    }
 
    function changeOraclizeProofType(byte _proofType)
        onlyOwner {
        require(_proofType != 0x00);
        oraclize_setProof( _proofType |  proofStorage_IPFS );
    }

    function changeMinTrade(uint _newMinTrade) onlyOwner {
        minTrade = _newMinTrade;
    }
    
    function changeGasLimitOfSafeSend(uint newGasLimit)
        onlyOwner
        onlyIfValidGas(newGasLimit) {
        safeGas = newGasLimit;
        LOG_GasLimitChanged(safeGas, newGasLimit);

    }

     function changeOraclizeGasPrize(uint _newGasPrice) onlyOwner{
        oraclize_setCustomGasPrice(_newGasPrice);
    }

    function stopEmergencyWithdrawal() onlyOwner {
        emergencyWithdrawalActivated = false;
    }

    modifier onlyIfEmergencyWithdrawalActivated() {
        require(emergencyWithdrawalActivated);
        _;
    }

    modifier onlyIfnotWithdrew() {
        require(!investors[investorIDs[msg.sender]].withdrew);
        _;
    }



    /*
     * @dev In the case of emergency stop trades and
        divide balance equally to all investors and allow
        them to withdraw it.
     */ 
    function distributeBalanceToInvestors() 
    onlyOwner
     {  
        isStopped = true;
        emergencyWithdrawalActivated = true;
        uint dividendsForInvestors = SafeMath.div(this.balance, numInvestors);
        for(uint i = 1; i <=  numInvestors; i++) {
            investors[i].balanceToPayout = dividendsForInvestors;
        }
    }

    /*
     * @dev Withdraw your part from the total balance in case 
        of emergency.
     */ 
    function withdrawDividends() 
    onlyIfEmergencyWithdrawalActivated 
    onlyInvestors
    onlyIfnotWithdrew
    {   
       //send right balance to investor. 
       investors[investorIDs[msg.sender]].withdrew = true; 
       investors[investorIDs[msg.sender]].investorAddress.transfer(investors[investorIDs[msg.sender]].balanceToPayout); 
        investors[investorIDs[msg.sender]].balanceToPayout = 0;

    }

 
}