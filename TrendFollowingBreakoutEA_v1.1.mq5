//+------------------------------------------------------------------+
//|                                    TrendFollowingBreakoutEA.mq5  |
//|                                                                  |
//| STRATEGY ARCHITECTURE (unchanged from v1.00 - matches the regime |
//| filter / entry signal / risk management structure used across   |
//| the Pine Script suite):                                          |
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
//|                                                                  |
//+------------------------------------------------------------------+
//| v1.1 CHANGE LOG - all changes REFINE the three existing pillars  |
//| above. No new indicators, no new sub-strategies were added.      |
//|                                                                  |
//|  [FIX] Entry signal was evaluated against the CLOSE of the bar   |
//|        that had JUST OPENED (index 0), which at that instant is  |
//|        essentially equal to the open price -> the breakout       |
//|        condition could realistically only fire on a price gap.   |
//|        It now evaluates the CLOSE of the bar that just FINISHED  |
//|        (index 1) against the channel built from the bars before  |
//|        it. Same once-per-bar cadence, same Donchian logic, just  |
//|        pointed at the correct bar. This is the single biggest    |
//|        lever on trade frequency/quality in this file.            |
//|                                                                  |
//|  [IMPROVE] Breakout buffer can now scale with ATR instead of     |
//|        being a fixed number of points, so the same "filter out   |
//|        noise" purpose behaves consistently across symbols/       |
//|        timeframes with very different volatility. The fixed-     |
//|        points mode is kept as a fallback/legacy option.          |
//|                                                                  |
//|  [IMPROVE] Regime filter can optionally require ADX to be RISING |
//|        (not just above the threshold), using the SAME ADX handle |
//|        already created - avoids entering right as trend strength |
//|        is already fading.                                        |
//|                                                                  |
//|  [IMPROVE] Risk management now validates the broker's minimum    |
//|        stop distance before sending an order (prevents silent    |
//|        order rejections on some brokers/symbols) and clamps lot  |
//|        size to the symbol's maximum volume limit, in addition to |
//|        the existing min/max/step handling.                       |
//|                                                                  |
//|  [IMPROVE] An optional maximum-spread filter re-uses the bid/ask  |
//|        prices already read at entry time to avoid paying an      |
//|        abnormally wide spread, and execution slippage is now an  |
//|        explicit, tunable input instead of an implicit default.   |
//+------------------------------------------------------------------+
#property copyright "Arthur"
#property link      ""
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>

//============================================================
// INPUT PARAMETERS - GROUPED BY PURPOSE
//============================================================

input group "===== Regime Filter Settings ====="
input int    InpRegimeEMAPeriod      = 200;   // EMA period used to define the long-term trend regime
input int    InpADXPeriod            = 14;    // ADX period used to confirm trend strength
input double InpADXThreshold         = 25.0;  // Minimum ADX value required to consider the market "trending"
input bool   InpRequireADXRising     = true;  // Extra confirmation: require ADX to be rising vs the previous bar (uses the existing ADX handle)

input group "===== Breakout Entry Settings ====="
input int    InpBreakoutPeriod       = 20;    // Number of bars used to build the Donchian channel (highest high / lowest low)
input bool   InpUseATRBuffer         = true;  // If true, the noise buffer scales with ATR instead of being a fixed number of points
input double InpATRBufferMultiplier  = 0.10;  // Buffer = ATR * this factor (only used when InpUseATRBuffer = true)
input int    InpBreakoutBufferPoints = 20;    // Fallback/legacy buffer in points (used when InpUseATRBuffer = false, or if ATR is unavailable)

input group "===== Risk Management Settings ====="
input double InpRiskPercent          = 1.0;   // Percentage of account balance risked on each single trade
input int    InpATRPeriod            = 14;    // ATR period used to size the stop loss distance
input double InpATRMultiplierSL      = 2.0;   // Stop loss distance = ATR value multiplied by this factor
input double InpRewardRiskRatio      = 2.0;   // Take profit distance = stop loss distance multiplied by this factor (2.0 = 2:1 reward:risk)
input int    InpMaxSpreadPoints      = 30;    // Skip new entries if the current spread exceeds this many points (0 = disabled)
input int    InpSlippagePoints       = 10;    // Maximum allowed slippage (deviation) in points when sending market orders

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

   if(InpUseATRBuffer && InpATRBufferMultiplier <= 0.0)
     {
      Print("ERROR: InpATRBufferMultiplier must be a positive number when InpUseATRBuffer is true.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   //--- Step 2: configure the trade execution object
   ExtTrade.SetExpertMagicNumber(InpMagicNumber);
   ExtTrade.SetTypeFillingBySymbol(_Symbol);
   ExtTrade.SetDeviationInPoints(InpSlippagePoints);

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

   Print("TrendFollowingBreakoutEA v1.10 initialized successfully on symbol ", _Symbol, ", timeframe ", EnumToString(PERIOD_CURRENT));
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
//| [v1.1] Uses the last CLOSED bar's price for the EMA comparison,  |
//| and optionally requires ADX to be rising vs the previous bar.    |
//+------------------------------------------------------------------+
bool IsUptrendRegime()
  {
   double emaValue[];
   double adxValue[];

   ArraySetAsSeries(emaValue, true);
   ArraySetAsSeries(adxValue, true);

   int adxBarsNeeded = InpRequireADXRising ? 2 : 1;

   if(CopyBuffer(ExtHandleRegimeEMA, 0, 0, 1, emaValue) <= 0)
      return(false);

   if(CopyBuffer(ExtHandleADX, 0, 0, adxBarsNeeded, adxValue) <= 0)
      return(false);

   //--- use the last fully closed bar's close, consistent with the breakout signal below
   double referenceClose = iClose(_Symbol, PERIOD_CURRENT, 1);

   bool priceAboveEMA = (referenceClose > emaValue[0]);
   bool adxIsTrending = (adxValue[0] >= InpADXThreshold);
   bool adxIsRising   = true;

   if(InpRequireADXRising)
      adxIsRising = (adxValue[0] > adxValue[1]);

   return(priceAboveEMA && adxIsTrending && adxIsRising);
  }

//+------------------------------------------------------------------+
//| Regime filter: price below the long-term EMA AND ADX trending    |
//| [v1.1] Same refinements as IsUptrendRegime() above.               |
//+------------------------------------------------------------------+
bool IsDowntrendRegime()
  {
   double emaValue[];
   double adxValue[];

   ArraySetAsSeries(emaValue, true);
   ArraySetAsSeries(adxValue, true);

   int adxBarsNeeded = InpRequireADXRising ? 2 : 1;

   if(CopyBuffer(ExtHandleRegimeEMA, 0, 0, 1, emaValue) <= 0)
      return(false);

   if(CopyBuffer(ExtHandleADX, 0, 0, adxBarsNeeded, adxValue) <= 0)
      return(false);

   double referenceClose = iClose(_Symbol, PERIOD_CURRENT, 1);

   bool priceBelowEMA = (referenceClose < emaValue[0]);
   bool adxIsTrending = (adxValue[0] >= InpADXThreshold);
   bool adxIsRising   = true;

   if(InpRequireADXRising)
      adxIsRising = (adxValue[0] > adxValue[1]);

   return(priceBelowEMA && adxIsTrending && adxIsRising);
  }

//+------------------------------------------------------------------+
//| Returns the noise-filter buffer in price units, either as a     |
//| fraction of ATR (default) or as a fixed number of points.        |
//| [v1.1] New helper - consolidates buffer logic used by both       |
//| breakout checks so the ATR-based mode only has to be written     |
//| once.                                                              |
//+------------------------------------------------------------------+
double GetBreakoutBuffer()
  {
   if(InpUseATRBuffer)
     {
      double atrValue = GetCurrentATR();
      if(atrValue > 0.0)
         return(atrValue * InpATRBufferMultiplier);

      Print("WARNING: ATR unavailable for buffer calculation, falling back to fixed-point buffer.");
     }

   return(InpBreakoutBufferPoints * _Point);
  }

//+------------------------------------------------------------------+
//| Entry signal: the last CLOSED bar's close breaks above the      |
//| highest high of the N bars BEFORE it.                             |
//| [v1.1 FIX] Previously compared the currently-forming bar's close |
//| (essentially the open price of the new bar) against a channel    |
//| that included the most recent closed bar - this could only fire  |
//| on a price gap. It now compares the closed bar against the      |
//| channel built strictly from the bars preceding it.                |
//+------------------------------------------------------------------+
bool CheckBullishBreakout()
  {
   //--- lookback window is bars [2 .. InpBreakoutPeriod+1], i.e. strictly BEFORE the last closed bar (index 1)
   int highestBarIndex = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, InpBreakoutPeriod, 2);
   if(highestBarIndex < 0)
      return(false);

   double highestHigh = iHigh(_Symbol, PERIOD_CURRENT, highestBarIndex);
   double breakoutLevel = highestHigh + GetBreakoutBuffer();

   double lastClosedBarClose = iClose(_Symbol, PERIOD_CURRENT, 1);

   return(lastClosedBarClose > breakoutLevel);
  }

//+------------------------------------------------------------------+
//| Entry signal: the last CLOSED bar's close breaks below the      |
//| lowest low of the N bars BEFORE it. [v1.1 FIX - see above]       |
//+------------------------------------------------------------------+
bool CheckBearishBreakout()
  {
   int lowestBarIndex = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, InpBreakoutPeriod, 2);
   if(lowestBarIndex < 0)
      return(false);

   double lowestLow = iLow(_Symbol, PERIOD_CURRENT, lowestBarIndex);
   double breakoutLevel = lowestLow - GetBreakoutBuffer();

   double lastClosedBarClose = iClose(_Symbol, PERIOD_CURRENT, 1);

   return(lastClosedBarClose < breakoutLevel);
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
//| Returns true if the current spread is acceptable for a new entry |
//| [v1.1] New guard, reuses the bid/ask prices already read at      |
//| entry time - does not add any new market data subscription.      |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
  {
   if(InpMaxSpreadPoints <= 0)
      return(true); // filter disabled

   long currentSpreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return(currentSpreadPoints <= InpMaxSpreadPoints);
  }

//+------------------------------------------------------------------+
//| Returns true if stopLossDistancePrice respects the broker's      |
//| minimum stop / freeze distance for this symbol.                  |
//| [v1.1] New guard to prevent silent order rejections on brokers    |
//| that enforce a minimum stop distance (mainly relevant with very  |
//| small ATR values on low timeframes/exotic symbols).               |
//+------------------------------------------------------------------+
bool IsStopDistanceValid(double stopLossDistancePrice)
  {
   long stopsLevelPoints   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPoints  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long minRequiredPoints  = MathMax(stopsLevelPoints, freezeLevelPoints);

   if(minRequiredPoints <= 0)
      return(true); // broker does not enforce a minimum distance

   double minRequiredDistance = minRequiredPoints * _Point;
   return(stopLossDistancePrice >= minRequiredDistance);
  }

//+------------------------------------------------------------------+
//| Calculates a lot size so a stop-out loses InpRiskPercent of the  |
//| account balance                                                   |
//| [v1.1] Additionally clamps to the symbol's maximum tradeable      |
//| volume (SYMBOL_VOLUME_LIMIT), on top of the existing min/max/step |
//| handling.                                                          |
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
   double maxVolumeLimit = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT); // 0 = no broker-side cap on total volume

   double normalizedLotSize = MathFloor(rawLotSize / lotStep) * lotStep;

   if(normalizedLotSize < minLot)
      normalizedLotSize = minLot;

   if(normalizedLotSize > maxLot)
      normalizedLotSize = maxLot;

   if(maxVolumeLimit > 0.0 && normalizedLotSize > maxVolumeLimit)
      normalizedLotSize = MathFloor(maxVolumeLimit / lotStep) * lotStep;

   return(normalizedLotSize);
  }

//+------------------------------------------------------------------+
//| Opens a buy position with an ATR-based SL and reward:risk TP     |
//+------------------------------------------------------------------+
void OpenLongPosition()
  {
   if(!IsSpreadAcceptable())
     {
      Print("WARNING: Spread too wide, skipping long entry.");
      return;
     }

   double atrValue = GetCurrentATR();
   if(atrValue <= 0.0)
     {
      Print("WARNING: ATR value is invalid, skipping long entry.");
      return;
     }

   double stopLossDistance   = atrValue * InpATRMultiplierSL;
   double takeProfitDistance = stopLossDistance * InpRewardRiskRatio;

   if(!IsStopDistanceValid(stopLossDistance))
     {
      Print("WARNING: Stop loss distance is smaller than the broker's minimum stop level, skipping long entry.");
      return;
     }

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
   if(!IsSpreadAcceptable())
     {
      Print("WARNING: Spread too wide, skipping short entry.");
      return;
     }

   double atrValue = GetCurrentATR();
   if(atrValue <= 0.0)
     {
      Print("WARNING: ATR value is invalid, skipping short entry.");
      return;
     }

   double stopLossDistance   = atrValue * InpATRMultiplierSL;
   double takeProfitDistance = stopLossDistance * InpRewardRiskRatio;

   if(!IsStopDistanceValid(stopLossDistance))
     {
      Print("WARNING: Stop loss distance is smaller than the broker's minimum stop level, skipping short entry.");
      return;
     }

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
