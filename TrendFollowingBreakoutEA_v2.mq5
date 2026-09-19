//+------------------------------------------------------------------+
//|                                 TrendFollowingBreakoutEA_v2.mq5  |
//|                                                                  |
//| V2 CHANGELOG (on top of the original trend/breakout/ATR core):   |
//|  + Higher-timeframe trend confirmation                          |
//|  + Break-even move once trade reaches a set R-multiple           |
//|  + ATR-based trailing stop once trade reaches a set R-multiple   |
//|  + Partial close (take some profit off, let the rest run)        |
//|  + Session (time-of-day) filter                                 |
//|  + Max spread filter                                             |
//|  + High-impact news filter (built-in MT5 economic calendar)      |
//|  + Daily loss limit / max trades-per-day kill switch             |
//|  + Explicit slippage (deviation) control                         |
//|                                                                  |
//| The original regime/entry/base-risk logic is unchanged.          |
//+------------------------------------------------------------------+
#property copyright "Arthur"
#property link      ""
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//============================================================
// INPUT PARAMETERS - GROUPED BY PURPOSE
//============================================================

input group "===== Regime Filter Settings ====="
input int    InpRegimeEMAPeriod      = 200;   // EMA period used to define the long-term trend regime
input int    InpADXPeriod            = 14;    // ADX period used to confirm trend strength
input double InpADXThreshold         = 25.0;  // Minimum ADX value required to consider the market "trending"

input group "===== Higher-Timeframe Confirmation ====="
input bool             InpUseHTFConfirm  = true;        // require alignment with a higher-timeframe trend before entering
input ENUM_TIMEFRAMES  InpHTFTimeframe   = PERIOD_H4;    // higher timeframe used for confirmation
input int              InpHTFEMAPeriod   = 50;           // EMA period on the higher timeframe

input group "===== Breakout Entry Settings ====="
input int    InpBreakoutPeriod       = 20;    // Number of bars used to build the Donchian channel (highest high / lowest low)
input int    InpBreakoutBufferPoints = 20;    // Extra buffer in points added beyond the channel level, to filter out noise-driven false breakouts

input group "===== Risk Management Settings ====="
input double InpRiskPercent          = 1.0;   // Percentage of account balance risked on each single trade
input int    InpATRPeriod            = 14;    // ATR period used to size the stop loss distance
input double InpATRMultiplierSL      = 2.0;   // Stop loss distance = ATR value multiplied by this factor
input double InpRewardRiskRatio      = 2.0;   // Take profit distance = stop loss distance multiplied by this factor (2.0 = 2:1 reward:risk)

input group "===== Trade Management (Break-even / Trailing / Partial) ====="
input bool   InpUseBreakEven         = true;  // move stop loss to break-even once in profit
input double InpBreakEvenTriggerR    = 1.0;   // trigger break-even once profit reaches this multiple of the initial risk (R)
input double InpBreakEvenLockPoints  = 20;    // points of profit locked in above/below entry when break-even triggers
input bool   InpUseTrailingStop      = true;  // trail the stop loss once sufficiently in profit
input double InpTrailingStartR       = 1.5;   // start trailing once profit reaches this multiple of R
input double InpTrailingATRMultiplier= 1.5;   // trailing distance = current ATR multiplied by this factor
input bool   InpUsePartialClose      = true;  // take partial profit at a set R-multiple
input double InpPartialCloseTriggerR = 1.0;   // take partial profit once price reaches this multiple of R
input double InpPartialClosePercent  = 50.0;  // percent of the position volume to close at the partial trigger

input group "===== Trade Filters ====="
input bool   InpUseSessionFilter     = false; // only trade within a specific hour window (broker/server time)
input int    InpSessionStartHour     = 7;     // session start hour, 0-23, broker server time
input int    InpSessionEndHour       = 21;    // session end hour, 0-23, broker server time
input bool   InpUseSpreadFilter      = true;  // skip new entries if the spread is too wide
input int    InpMaxSpreadPoints      = 40;    // maximum allowed spread, in points, to allow a new entry
input bool   InpUseNewsFilter        = true;  // skip new entries around high-impact news for this symbol's currencies
input int    InpNewsMinutesBefore    = 30;    // block new entries this many minutes BEFORE a high-impact event
input int    InpNewsMinutesAfter     = 30;    // block new entries this many minutes AFTER a high-impact event

input group "===== Daily Protection ====="
input bool   InpUseDailyLossLimit    = true;  // stop opening new trades for the day after a loss limit is hit
input double InpMaxDailyLossPercent  = 3.0;   // max percent of the day's starting balance allowed to be lost
input int    InpMaxTradesPerDay      = 3;     // max number of new entries allowed per calendar day

input group "===== General Settings ====="
input int    InpMagicNumber          = 20260905;          // Unique identifier attached to every order placed by this EA
input string InpTradeComment         = "TrendBreakoutEA"; // Comment attached to every order placed by this EA
input int    InpSlippagePoints       = 20;                // Max allowed slippage (deviation), in points, on market orders

//============================================================
// GLOBAL VARIABLES
//============================================================

CTrade ExtTrade;                    // Trade execution object, used to send buy/sell requests

int      ExtHandleRegimeEMA;        // Indicator handle: long-term EMA used in the regime filter
int      ExtHandleADX;              // Indicator handle: ADX used in the regime filter
int      ExtHandleATR;              // Indicator handle: ATR used in risk management
int      ExtHandleHTFEMA;           // Indicator handle: higher-timeframe EMA used for confirmation

datetime ExtLastProcessedBarTime;   // Open time of the last bar already evaluated, so the EA only acts once per new bar

//--- daily protection tracking
datetime ExtCurrentDayStart;        // midnight timestamp of the day currently being tracked
double   ExtDayStartBalance;        // account balance recorded at the start of the tracked day
int      ExtTradesToday;            // number of new entries opened so far today
bool     ExtDailyLimitHit;          // true once the daily loss limit has been breached today

//--- per-position management state (this EA only ever holds one position at a time)
ulong    ExtManagedTicket;          // ticket of the position currently being managed
double   ExtManagedInitialRisk;     // initial SL distance in price terms for that position (the "R" unit)
double   ExtManagedEntryPrice;      // entry price of that position
bool     ExtManagedIsLong;          // true if that position is a buy
bool     ExtManagedBEDone;          // true once break-even has already been applied to that position
bool     ExtManagedPartialDone;     // true once the partial close has already been taken on that position

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

   if(InpUseHTFConfirm && InpHTFEMAPeriod <= 0)
     {
      Print("ERROR: InpHTFEMAPeriod must be a positive integer when InpUseHTFConfirm is true.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpSessionStartHour < 0 || InpSessionStartHour > 23 || InpSessionEndHour < 0 || InpSessionEndHour > 23)
     {
      Print("ERROR: Session hours must be between 0 and 23.");
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

   //--- Step 5: create the indicator handle for the ATR used to size the stop loss / take profit / trailing
   ExtHandleATR = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(ExtHandleATR == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create the ATR indicator handle. Error code = ", GetLastError());
      return(INIT_FAILED);
     }

   //--- Step 6: create the higher-timeframe EMA handle, only if that confirmation is enabled
   if(InpUseHTFConfirm)
     {
      ExtHandleHTFEMA = iMA(_Symbol, InpHTFTimeframe, InpHTFEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
      if(ExtHandleHTFEMA == INVALID_HANDLE)
        {
         Print("ERROR: Failed to create the HTF EMA indicator handle. Error code = ", GetLastError());
         return(INIT_FAILED);
        }
     }
   else
     {
      ExtHandleHTFEMA = INVALID_HANDLE;
     }

   //--- Step 7: initialize state trackers
   ExtLastProcessedBarTime = 0;

   ExtCurrentDayStart = 0;
   ExtDayStartBalance = 0.0;
   ExtTradesToday      = 0;
   ExtDailyLimitHit    = false;

   ExtManagedTicket        = 0;
   ExtManagedInitialRisk   = 0.0;
   ExtManagedEntryPrice    = 0.0;
   ExtManagedIsLong        = false;
   ExtManagedBEDone        = false;
   ExtManagedPartialDone   = false;

   ResetDailyTrackingIfNeeded();

   Print("TrendFollowingBreakoutEA v2 initialized successfully on symbol ", _Symbol, ", timeframe ", EnumToString(PERIOD_CURRENT));
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

   if(ExtHandleHTFEMA != INVALID_HANDLE)
      IndicatorRelease(ExtHandleHTFEMA);
  }

//+------------------------------------------------------------------+
//| Expert tick function - main logic entry point                    |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- Step 0: keep the daily loss/trade tracker up to date every tick
   ResetDailyTrackingIfNeeded();

   //--- Step 1: manage any already-open position every tick (break-even / trailing / partial close)
   ManageOpenPosition();

   //--- Step 2: only evaluate NEW entries once per new bar, not on every single tick
   if(!IsNewBar())
      return;

   //--- Step 3: do not look for a new entry if a position is already open on this symbol/magic
   if(HasOpenPosition())
      return;

   //--- Step 4: daily protection gates
   if(InpUseDailyLossLimit && ExtDailyLimitHit)
      return;

   if(InpUseDailyLossLimit && InpMaxTradesPerDay > 0 && ExtTradesToday >= InpMaxTradesPerDay)
      return;

   //--- Step 5: environment filters (session / spread / news)
   if(InpUseSessionFilter && !IsWithinSession())
      return;

   if(InpUseSpreadFilter && !IsSpreadAcceptable())
      return;

   if(InpUseNewsFilter && IsHighImpactNewsWindow())
      return;

   //--- Step 6: determine whether the market is currently in an uptrend regime or a downtrend regime
   bool isUptrendRegime   = IsUptrendRegime();
   bool isDowntrendRegime = IsDowntrendRegime();

   //--- Step 7: only look for a breakout entry in the direction allowed by the regime filter,
   //---         and, if enabled, only if the higher timeframe agrees with that direction
   if(isUptrendRegime && CheckBullishBreakout())
     {
      if(!InpUseHTFConfirm || IsHTFBullish())
         OpenLongPosition();
      return;
     }

   if(isDowntrendRegime && CheckBearishBreakout())
     {
      if(!InpUseHTFConfirm || IsHTFBearish())
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
//| Returns the ticket of this EA's open position, or 0 if none      |
//+------------------------------------------------------------------+
ulong GetOpenPositionTicket()
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

      return(ticket);
     }

   return(0);
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
//| Higher-timeframe confirmation: close above the HTF EMA           |
//+------------------------------------------------------------------+
bool IsHTFBullish()
  {
   double htfEma[];
   ArraySetAsSeries(htfEma, true);

   if(CopyBuffer(ExtHandleHTFEMA, 0, 0, 1, htfEma) <= 0)
      return(false);

   double htfClose = iClose(_Symbol, InpHTFTimeframe, 0);
   return(htfClose > htfEma[0]);
  }

//+------------------------------------------------------------------+
//| Higher-timeframe confirmation: close below the HTF EMA           |
//+------------------------------------------------------------------+
bool IsHTFBearish()
  {
   double htfEma[];
   ArraySetAsSeries(htfEma, true);

   if(CopyBuffer(ExtHandleHTFEMA, 0, 0, 1, htfEma) <= 0)
      return(false);

   double htfClose = iClose(_Symbol, InpHTFTimeframe, 0);
   return(htfClose < htfEma[0]);
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
//| and, later, the trailing distance                                |
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
//| Rounds a volume down to a valid lot step; returns 0 if too small |
//+------------------------------------------------------------------+
double NormalizeVolumeForPartialClose(double volume)
  {
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double normalized = MathFloor(volume / lotStep) * lotStep;

   if(normalized < minLot)
      return(0.0);

   return(normalized);
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
     {
      Print("ERROR: Buy order failed. Return code = ", ExtTrade.ResultRetcode(), " - ", ExtTrade.ResultRetcodeDescription());
      return;
     }

   Print("Long position opened. Lot size = ", lotSize, " | SL = ", stopLossPrice, " | TP = ", takeProfitPrice);

   //--- record management state for this new position (break-even / trailing / partial close use this)
   ulong newTicket = GetOpenPositionTicket();
   if(newTicket > 0)
     {
      ExtManagedTicket      = newTicket;
      ExtManagedInitialRisk = stopLossDistance;
      ExtManagedEntryPrice  = askPrice;
      ExtManagedIsLong      = true;
      ExtManagedBEDone      = false;
      ExtManagedPartialDone = false;
     }

   ExtTradesToday++;
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
     {
      Print("ERROR: Sell order failed. Return code = ", ExtTrade.ResultRetcode(), " - ", ExtTrade.ResultRetcodeDescription());
      return;
     }

   Print("Short position opened. Lot size = ", lotSize, " | SL = ", stopLossPrice, " | TP = ", takeProfitPrice);

   //--- record management state for this new position (break-even / trailing / partial close use this)
   ulong newTicket = GetOpenPositionTicket();
   if(newTicket > 0)
     {
      ExtManagedTicket      = newTicket;
      ExtManagedInitialRisk = stopLossDistance;
      ExtManagedEntryPrice  = bidPrice;
      ExtManagedIsLong      = false;
      ExtManagedBEDone      = false;
      ExtManagedPartialDone = false;
     }

   ExtTradesToday++;
  }

//+------------------------------------------------------------------+
//| Selects the currently managed position, if it still exists       |
//+------------------------------------------------------------------+
bool SelectManagedPosition()
  {
   if(ExtManagedTicket == 0)
      return(false);

   if(!PositionSelectByTicket(ExtManagedTicket))
     {
      //--- position no longer exists (hit SL/TP, or was closed manually) -> clear management state
      ExtManagedTicket = 0;
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Runs on every tick: partial close, break-even, trailing stop     |
//| for whichever position this EA currently has open                |
//+------------------------------------------------------------------+
void ManageOpenPosition()
  {
   if(!SelectManagedPosition())
      return;

   if(ExtManagedInitialRisk <= 0.0)
      return;

   double currentPrice = ExtManagedIsLong ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                           : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double profitDistance = ExtManagedIsLong ? (currentPrice - ExtManagedEntryPrice)
                                             : (ExtManagedEntryPrice - currentPrice);

   double profitInR = profitDistance / ExtManagedInitialRisk;

   //--- 1) Partial close: bank some profit once the trade reaches the trigger R-multiple
   if(InpUsePartialClose && !ExtManagedPartialDone && profitInR >= InpPartialCloseTriggerR)
     {
      double currentVolume = PositionGetDouble(POSITION_VOLUME);
      double closeVolume   = NormalizeVolumeForPartialClose(currentVolume * (InpPartialClosePercent / 100.0));

      if(closeVolume > 0.0 && closeVolume < currentVolume)
        {
         if(ExtTrade.PositionClosePartial(ExtManagedTicket, closeVolume))
           {
            ExtManagedPartialDone = true;
            Print("Partial close done at ", DoubleToString(profitInR, 2), "R. Closed volume = ", closeVolume);
           }
         else
           {
            Print("WARNING: Partial close failed. Return code = ", ExtTrade.ResultRetcode(), " - ", ExtTrade.ResultRetcodeDescription());
           }
        }
     }

   //--- re-select, since a partial close changes the position's remaining volume/ticket state
   if(!SelectManagedPosition())
      return;

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);

   //--- 2) Break-even: once far enough in profit, move the SL to lock in a small gain
   if(InpUseBreakEven && !ExtManagedBEDone && profitInR >= InpBreakEvenTriggerR)
     {
      double lockPoints = InpBreakEvenLockPoints * _Point;
      double candidateSL = ExtManagedIsLong ? (ExtManagedEntryPrice + lockPoints)
                                             : (ExtManagedEntryPrice - lockPoints);
      candidateSL = NormalizeDouble(candidateSL, _Digits);

      bool improvesSL = ExtManagedIsLong ? (currentSL == 0.0 || candidateSL > currentSL)
                                          : (currentSL == 0.0 || candidateSL < currentSL);

      if(improvesSL)
        {
         if(ExtTrade.PositionModify(ExtManagedTicket, candidateSL, currentTP))
           {
            ExtManagedBEDone = true;
            currentSL = candidateSL;
            Print("Break-even applied at ", DoubleToString(profitInR, 2), "R. New SL = ", candidateSL);
           }
         else
           {
            Print("WARNING: Break-even modify failed. Return code = ", ExtTrade.ResultRetcode(), " - ", ExtTrade.ResultRetcodeDescription());
           }
        }
     }

   //--- 3) Trailing stop: once far enough in profit, trail the SL behind price using current ATR
   if(InpUseTrailingStop && profitInR >= InpTrailingStartR)
     {
      double atrValue = GetCurrentATR();
      if(atrValue > 0.0)
        {
         double trailDistance = atrValue * InpTrailingATRMultiplier;

         if(ExtManagedIsLong)
           {
            double candidateSL = NormalizeDouble(currentPrice - trailDistance, _Digits);
            if(currentSL == 0.0 || candidateSL > currentSL)
              {
               if(!ExtTrade.PositionModify(ExtManagedTicket, candidateSL, currentTP))
                  Print("WARNING: Trailing stop modify failed. Return code = ", ExtTrade.ResultRetcode(), " - ", ExtTrade.ResultRetcodeDescription());
              }
           }
         else
           {
            double candidateSL = NormalizeDouble(currentPrice + trailDistance, _Digits);
            if(currentSL == 0.0 || candidateSL < currentSL)
              {
               if(!ExtTrade.PositionModify(ExtManagedTicket, candidateSL, currentTP))
                  Print("WARNING: Trailing stop modify failed. Return code = ", ExtTrade.ResultRetcode(), " - ", ExtTrade.ResultRetcodeDescription());
              }
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Resets the daily balance/trade tracker at the start of each new  |
//| calendar day, and flags the daily loss limit if it is breached   |
//+------------------------------------------------------------------+
void ResetDailyTrackingIfNeeded()
  {
   datetime now = TimeCurrent();
   MqlDateTime dtNow;
   TimeToStruct(now, dtNow);

   bool needsReset = false;

   if(ExtCurrentDayStart == 0)
     {
      needsReset = true;
     }
   else
     {
      MqlDateTime dtDayStart;
      TimeToStruct(ExtCurrentDayStart, dtDayStart);
      if(dtNow.day != dtDayStart.day || dtNow.mon != dtDayStart.mon || dtNow.year != dtDayStart.year)
         needsReset = true;
     }

   if(needsReset)
     {
      MqlDateTime dtMidnight = dtNow;
      dtMidnight.hour = 0;
      dtMidnight.min  = 0;
      dtMidnight.sec  = 0;

      ExtCurrentDayStart = StructToTime(dtMidnight);
      ExtDayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      ExtTradesToday      = 0;
      ExtDailyLimitHit    = false;
      return;
     }

   //--- check current equity drawdown against the balance recorded at the start of the day
   if(InpUseDailyLossLimit && !ExtDailyLimitHit && ExtDayStartBalance > 0.0)
     {
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      double lossPercent   = (ExtDayStartBalance - currentEquity) / ExtDayStartBalance * 100.0;

      if(lossPercent >= InpMaxDailyLossPercent)
        {
         ExtDailyLimitHit = true;
         Print("DAILY LOSS LIMIT REACHED (", DoubleToString(lossPercent, 2), "%). No new entries until the next calendar day.");
        }
     }
  }

//+------------------------------------------------------------------+
//| Session filter: only allow new entries within the configured     |
//| hour window (broker/server time); supports overnight windows     |
//+------------------------------------------------------------------+
bool IsWithinSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(InpSessionStartHour <= InpSessionEndHour)
      return(dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);

   //--- window wraps past midnight, e.g. start=22, end=6
   return(dt.hour >= InpSessionStartHour || dt.hour < InpSessionEndHour);
  }

//+------------------------------------------------------------------+
//| Spread filter: only allow new entries when the spread is tight   |
//| enough to trade reasonably                                       |
//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
  {
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return(spreadPoints <= InpMaxSpreadPoints);
  }

//+------------------------------------------------------------------+
//| News filter: blocks new entries around high-impact calendar      |
//| events for this symbol's base and profit currencies              |
//+------------------------------------------------------------------+
bool IsHighImpactNewsWindow()
  {
   datetime windowFrom = TimeTradeServer() - InpNewsMinutesAfter  * 60;
   datetime windowTo   = TimeTradeServer() + InpNewsMinutesBefore * 60;

   string currencies[2];
   currencies[0] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   currencies[1] = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   for(int c = 0; c < 2; c++)
     {
      if(currencies[c] == "")
         continue;

      MqlCalendarValue values[];
      CalendarValueHistory(values, windowFrom, windowTo, NULL, currencies[c]);

      int count = ArraySize(values);
      for(int i = 0; i < count; i++)
        {
         MqlCalendarEvent event;
         if(!CalendarEventById(values[i].event_id, event))
            continue;

         if(event.importance == CALENDAR_IMPORTANCE_HIGH)
            return(true);
        }
     }

   return(false);
  }
//+------------------------------------------------------------------+
