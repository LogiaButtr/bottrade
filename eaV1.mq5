//+------------------------------------------------------------------+
//|                                    TrendFollowingBreakoutEA.mq5  |
//|                                                                  |
//| STRATEGY ARCHITECTURE (matches the regime filter / entry signal /|
//| risk management structure used across the Pine Script suite):   |
//|                                                                  |
//|  1) REGIME FILTER : only allow trades in the direction of the    |
//|     long-term trend. The regime is defined as "uptrend" when     |
//|     price is above a long-term EMA AND the ADX confirms the      |
//|     market is actually trending (not choppy/ranging).            |
//|                                                                  |
//|  2) ENTRY SIGNAL   : a Donchian-channel style breakout. A long   |
//|     is triggered when the close breaks above the highest high of |
//|     the previous N bars (plus a small buffer to filter noise).   |
//|     A short is triggered symmetrically on a break below the      |
//|     lowest low.                                                  |
//|                                                                  |
//|  3) RISK MANAGEMENT: the stop loss distance is sized from the     |
//|     current ATR value, the take profit distance is a multiple of |
//|     the stop loss distance (reward:risk ratio), and the lot size |
//|     is calculated so that a stop-out loses a fixed percentage of |
//|     the account balance.                                          |
//+------------------------------------------------------------------+
#property copyright "Arthur rak torfan t sud nai lok"
#property link      ""
#property version   "1.02"
#property strict

#include <Trade\Trade.mqh>

//============================================================
// INPUT PARAMETERS - GROUPED BY PURPOSE
//============================================================

input group "===== Regime Filter Settings ====="
input int    InpRegimeEMAPeriod      = 200;   // EMA period used to define the long-term trend regime
input int    InpADXPeriod            = 14;    // ADX period used to confirm trend strength
input double InpADXThreshold         = 25.0;  // Minimum ADX value required to consider the market "trending"

input group "===== Breakout Entry Settings ====="
input int    InpBreakoutPeriod       = 20;    // Number of bars used to build the Donchian channel (highest high / lowest low)
input int    InpBreakoutBufferPoints = 20;    // Extra buffer in points added beyond the channel level, to filter out noise-driven false breakouts

input group "===== Risk Management Settings ====="
input double InpRiskPercent          = 1.0;   // Percentage of account balance risked on each single trade
input int    InpATRPeriod            = 14;    // ATR period used to size the stop loss distance
input double InpATRMultiplierSL      = 2.0;   // Stop loss distance = ATR value multiplied by this factor
input double InpRewardRiskRatio      = 2.0;   // Take profit distance = stop loss distance multiplied by this factor (2.0 = 2:1 reward:risk)

input group "===== General Settings ====="
input int    InpMagicNumber          = 20260905;          // Unique identifier attached to every order placed by this EA
input string InpTradeComment         = "TrendBreakoutEA"; // Comment attached to every order placed by this EA

//============================================================
// GLOBAL VARIABLES
//============================================================

CTrade ExtTrade;                    // Trade execution object, used to send buy/sell requests

int      ExtHandleRegimeEMA;        // Indicator handle: long-term EMA used in the regime filter
int      ExtHandleADX;              // Indicator handle: ADX used in the regime filter
int      ExtHandleATR;              // Indicator handle: ATR used in risk management

datetime ExtLastProcessedBarTime;   // Open time of the last bar already evaluated, so the EA only acts once per new bar

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Step 1: validate the input parameters before doing anything else
   if(InpRegimeEMAPeriod <= 0 || InpADXPeriod <= 0 || InpBreakoutPeriod <= 0 || InpATRPeriod <= 0)
     {
      Print("ERROR: One of the period inputs (EMA/ADX/Breakout/ATR) is not a positive integer.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpRiskPercent <= 0.0 || InpATRMultiplierSL <= 0.0 || InpRewardRiskRatio <= 0.0)
     {
      Print("ERROR: One of the risk management inputs (RiskPercent/ATRMultiplierSL/RewardRiskRatio) is not a positive number.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   //--- Step 2: configure the trade execution object
   ExtTrade.SetExpertMagicNumber(InpMagicNumber);
   ExtTrade.SetTypeFillingBySymbol(_Symbol);

   //--- Step 3: create the indicator handle for the long-term regime EMA
   ExtHandleRegimeEMA = iMA(_Symbol, PERIOD_CURRENT, InpRegimeEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(ExtHandleRegimeEMA == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create the Regime EMA indicator handle. Error code = ", GetLastError());
      return(INIT_FAILED);
     }

   //--- Step 4: create the indicator handle for the ADX used to confirm trend strength
   ExtHandleADX = iADX(_Symbol, PERIOD_CURRENT, InpADXPeriod);
   if(ExtHandleADX == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create the ADX indicator handle. Error code = ", GetLastError());
      return(INIT_FAILED);
     }

   //--- Step 5: create the indicator handle for the ATR used to size the stop loss / take profit
   ExtHandleATR = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(ExtHandleATR == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create the ATR indicator handle. Error code = ", GetLastError());
      return(INIT_FAILED);
     }

   //--- Step 6: initialize the "last processed bar" tracker to zero, so the very first tick is always evaluated
   ExtLastProcessedBarTime = 0;

   Print("rak tofran:");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   //--- release all indicator handles to free up resources
   if(ExtHandleRegimeEMA != INVALID_HANDLE)
      IndicatorRelease(ExtHandleRegimeEMA);

   if(ExtHandleADX != INVALID_HANDLE)
      IndicatorRelease(ExtHandleADX);

   if(ExtHandleATR != INVALID_HANDLE)
      IndicatorRelease(ExtHandleATR);
  }

//+------------------------------------------------------------------+
//| Expert tick function - main logic entry point                    |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Step 1: only evaluate trading logic once per new bar, not on every single tick
   if(!IsNewBar())
      return;

   //--- Step 2: do not look for a new entry if a position is already open on this symbol/magic
   if(HasOpenPosition())
      return;

   //--- Step 3: determine whether the market is currently in an uptrend regime or a downtrend regime
   bool isUptrendRegime   = IsUptrendRegime();
   bool isDowntrendRegime = IsDowntrendRegime();

   //--- Step 4: only look for a breakout entry in the direction allowed by the regime filter
   if(isUptrendRegime && CheckBullishBreakout())
     {
      OpenLongPosition();
      return;
     }

   if(isDowntrendRegime && CheckBearishBreakout())
     {
      OpenShortPosition();
      return;
     }
  }

//+------------------------------------------------------------------+
//| Returns true only the first time it is called on a given bar     |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

   if(currentBarTime == ExtLastProcessedBarTime)
      return(false);

   ExtLastProcessedBarTime = currentBarTime;
   return(true);
  }

//+------------------------------------------------------------------+
//| Returns true if this EA already has an open position here        |
//+------------------------------------------------------------------+
bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| Regime filter: price above the long-term EMA AND ADX trending    |
//+------------------------------------------------------------------+
bool IsUptrendRegime()
  {
   double emaValue[];
   double adxValue[];

   ArraySetAsSeries(emaValue, true);
   ArraySetAsSeries(adxValue, true);

   if(CopyBuffer(ExtHandleRegimeEMA, 0, 0, 1, emaValue) <= 0)
      return(false);

   if(CopyBuffer(ExtHandleADX, 0, 0, 1, adxValue) <= 0)
      return(false);

   double currentClose = iClose(_Symbol, PERIOD_CURRENT, 0);

   bool priceAboveEMA = (currentClose > emaValue[0]);
   bool adxIsTrending = (adxValue[0] >= InpADXThreshold);

   return(priceAboveEMA && adxIsTrending);
  }

//+------------------------------------------------------------------+
//| Regime filter: price below the long-term EMA AND ADX trending    |
//+------------------------------------------------------------------+
bool IsDowntrendRegime()
  {
   double emaValue[];
   double adxValue[];

   ArraySetAsSeries(emaValue, true);
   ArraySetAsSeries(adxValue, true);

   if(CopyBuffer(ExtHandleRegimeEMA, 0, 0, 1, emaValue) <= 0)
      return(false);

   if(CopyBuffer(ExtHandleADX, 0, 0, 1, adxValue) <= 0)
      return(false);

   double currentClose = iClose(_Symbol, PERIOD_CURRENT, 0);

   bool priceBelowEMA = (currentClose < emaValue[0]);
   bool adxIsTrending = (adxValue[0] >= InpADXThreshold);

   return(priceBelowEMA && adxIsTrending);
  }

//+------------------------------------------------------------------+
//| Entry signal: close breaks above the highest high of N bars      |
//+------------------------------------------------------------------+
bool CheckBullishBreakout()
  {
   //--- find the bar index of the highest high over the lookback period, starting from bar 1 (the last CLOSED bar, excluding the current forming bar)
   int highestBarIndex = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, InpBreakoutPeriod, 1);
   if(highestBarIndex < 0)
      return(false);

   double highestHigh = iHigh(_Symbol, PERIOD_CURRENT, highestBarIndex);

   double bufferInPrice = InpBreakoutBufferPoints * _Point;
   double breakoutLevel = highestHigh + bufferInPrice;

   double currentClose = iClose(_Symbol, PERIOD_CURRENT, 0);

   return(currentClose > breakoutLevel);
  }

//+------------------------------------------------------------------+
//| Entry signal: close breaks below the lowest low of N bars        |
//+------------------------------------------------------------------+
bool CheckBearishBreakout()
  {
   int lowestBarIndex = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, InpBreakoutPeriod, 1);
   if(lowestBarIndex < 0)
      return(false);

   double lowestLow = iLow(_Symbol, PERIOD_CURRENT, lowestBarIndex);

   double bufferInPrice = InpBreakoutBufferPoints * _Point;
   double breakoutLevel = lowestLow - bufferInPrice;

   double currentClose = iClose(_Symbol, PERIOD_CURRENT, 0);

   return(currentClose < breakoutLevel);
  }

//+------------------------------------------------------------------+
//| Returns the most recent ATR value, used to size the stop loss    |
//+------------------------------------------------------------------+
double GetCurrentATR()
  {
   double atrValue[];
   ArraySetAsSeries(atrValue, true);

   if(CopyBuffer(ExtHandleATR, 0, 0, 1, atrValue) <= 0)
      return(0.0);

   return(atrValue[0]);
  }

//+------------------------------------------------------------------+
//| Calculates a lot size so a stop-out loses InpRiskPercent of the  |
//| account balance                                                   |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossDistancePrice)
  {
   double accountBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmountMoney = accountBalance * (InpRiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0.0 || tickValue <= 0.0)
     {
      Print("ERROR: Invalid tick size or tick value for symbol ", _Symbol);
      return(0.0);
     }

   //--- money lost per 1.0 lot if price moves by stopLossDistancePrice
   double moneyLossPerLot = (stopLossDistancePrice / tickSize) * tickValue;
   if(moneyLossPerLot <= 0.0)
      return(0.0);

   double rawLotSize = riskAmountMoney / moneyLossPerLot;

   //--- round the raw lot size down to the nearest broker-allowed lot step, then clamp to the broker's min/max
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double normalizedLotSize = MathFloor(rawLotSize / lotStep) * lotStep;

   if(normalizedLotSize < minLot)
      normalizedLotSize = minLot;

   if(normalizedLotSize > maxLot)
      normalizedLotSize = maxLot;

   return(normalizedLotSize);
  }

//+------------------------------------------------------------------+
//| Opens a buy position with an ATR-based SL and reward:risk TP     |
//+------------------------------------------------------------------+
void OpenLongPosition()
  {
   double atrValue = GetCurrentATR();
   if(atrValue <= 0.0)
     {
      Print("WARNING: ATR value is invalid, skipping long entry.");
      return;
     }

   double stopLossDistance   = atrValue * InpATRMultiplierSL;
   double takeProfitDistance = stopLossDistance * InpRewardRiskRatio;

   double askPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double stopLossPrice   = NormalizeDouble(askPrice - stopLossDistance, _Digits);
   double takeProfitPrice = NormalizeDouble(askPrice + takeProfitDistance, _Digits);

   double lotSize = CalculateLotSize(stopLossDistance);
   if(lotSize <= 0.0)
     {
      Print("WARNING: Calculated lot size is invalid, skipping long entry.");
      return;
     }

   bool result = ExtTrade.Buy(lotSize, _Symbol, askPrice, stopLossPrice, takeProfitPrice, InpTradeComment);

   if(!result)
      Print("ERROR: Buy order failed. Return code = ", ExtTrade.ResultRetcode(), " - ", ExtTrade.ResultRetcodeDescription());
   else
      Print("Long position opened. Lot size = ", lotSize, " | SL = ", stopLossPrice, " | TP = ", takeProfitPrice);
  }

//+------------------------------------------------------------------+
//| Opens a sell position with an ATR-based SL and reward:risk TP    |
//+------------------------------------------------------------------+
void OpenShortPosition()
  {
   double atrValue = GetCurrentATR();
   if(atrValue <= 0.0)
     {
      Print("WARNING: ATR value is invalid, skipping short entry.");
      return;
     }

   double stopLossDistance   = atrValue * InpATRMultiplierSL;
   double takeProfitDistance = stopLossDistance * InpRewardRiskRatio;

   double bidPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double stopLossPrice   = NormalizeDouble(bidPrice + stopLossDistance, _Digits);
   double takeProfitPrice = NormalizeDouble(bidPrice - takeProfitDistance, _Digits);

   double lotSize = CalculateLotSize(stopLossDistance);
   if(lotSize <= 0.0)
     {
      Print("WARNING: Calculated lot size is invalid, skipping short entry.");
      return;
     }

   bool result = ExtTrade.Sell(lotSize, _Symbol, bidPrice, stopLossPrice, takeProfitPrice, InpTradeComment);

   if(!result)
      Print("ERROR: Sell order failed. Return code = ", ExtTrade.ResultRetcode(), " - ", ExtTrade.ResultRetcodeDescription());
   else
      Print("Short position opened. Lot size = ", lotSize, " | SL = ", stopLossPrice, " | TP = ", takeProfitPrice);
  }
//+------------------------------------------------------------------+