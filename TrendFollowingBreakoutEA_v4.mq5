//+------------------------------------------------------------------+
//|                                 TrendFollowingBreakoutEA_v4.mq5  |
//|                                                                  |
//| V4 CHANGELOG (on top of v3's drawdown/margin/retry/vol-sizing):  |
//|  + Volatility Squeeze Filter: only takes a breakout if price was |
//|    recently in an abnormally tight Bollinger Band Width squeeze, |
//|    to filter out breakouts that fire mid-noise instead of after  |
//|    genuine volatility contraction.                                |
//|                                                                  |
//| HONESTY NOTE: this is a signal-quality filter, not a profit      |
//| guarantee. It should reduce the number of low-quality breakout   |
//| entries taken, which historically correlates with better         |
//| expectancy in trend-following systems - but that must be         |
//| confirmed on YOUR instrument/timeframe via backtest before any   |
//| live use. No code change can guarantee higher profit.            |
//|                                                                  |
//| Scope kept intentionally narrow (one feature) per user request.  |
//+------------------------------------------------------------------+
#property copyright "Arthur"
#property link      ""
#property version   "4.00"
#property strict

#include <Trade\Trade.mqh>

//============================================================
// INPUT PARAMETERS - GROUPED BY PURPOSE
//============================================================

input group "===== Regime Filter Settings ====="
input int    InpRegimeEMAPeriod      = 200;
input int    InpADXPeriod            = 14;
input double InpADXThreshold         = 25.0;

input group "===== Higher-Timeframe Confirmation ====="
input bool             InpUseHTFConfirm  = false;
input ENUM_TIMEFRAMES  InpHTFTimeframe   = PERIOD_H4;
input int              InpHTFEMAPeriod   = 50;

input group "===== Breakout Entry Settings ====="
input int    InpBreakoutPeriod       = 20;
input int    InpBreakoutBufferPoints = 20;

input group "===== Volatility Squeeze Filter ====="
input bool   InpUseSqueezeFilter            = true; // only take a breakout if a recent volatility squeeze preceded it
input int    InpBBPeriod                    = 20;   // Bollinger Bands period used to measure band width
input double InpBBDeviation                 = 2.0;  // Bollinger Bands standard deviation multiplier
input int    InpSqueezeBaselineLookback     = 100;  // bars used to build the "normal" band-width distribution for this symbol
input double InpSqueezePercentileThreshold  = 25.0; // band width must have been at/below this percentile of the baseline to count as a squeeze
input int    InpSqueezeRecentBars           = 5;    // how many recent closed bars are checked for having been in a squeeze

input group "===== Risk Management Settings ====="
input double InpRiskPercent          = 1.0;
input int    InpATRPeriod            = 14;
input double InpATRMultiplierSL      = 2.0;
input double InpRewardRiskRatio      = 2.0;

input group "===== Volatility-Adaptive Sizing ====="
input bool   InpUseVolatilityAdaptiveSizing = true;
input int    InpATRAveragePeriod            = 50;
input double InpVolatilityShrinkThreshold   = 1.5;
input double InpMinSizeMultiplier           = 0.4;

input group "===== Trade Management (Break-even / Trailing / Partial) ====="
input bool   InpUseBreakEven         = true;
input double InpBreakEvenTriggerR    = 1.0;
input double InpBreakEvenLockPoints  = 20;
input bool   InpUseTrailingStop      = true;
input double InpTrailingStartR       = 1.5;
input double InpTrailingATRMultiplier= 1.5;
input bool   InpUsePartialClose      = true;
input double InpPartialCloseTriggerR = 1.0;
input double InpPartialClosePercent  = 50.0;

input group "===== Trade Filters ====="
input bool   InpUseSessionFilter     = false;
input int    InpSessionStartHour     = 7;
input int    InpSessionEndHour       = 21;
input bool   InpUseSpreadFilter      = true;
input int    InpMaxSpreadPoints      = 40;
input bool   InpUseNewsFilter        = true;
input int    InpNewsMinutesBefore    = 30;
input int    InpNewsMinutesAfter     = 30;

input group "===== Daily Protection ====="
input bool   InpUseDailyLossLimit    = true;
input double InpMaxDailyLossPercent  = 3.0;
input int    InpMaxTradesPerDay      = 3;

input group "===== Max Drawdown Protection (account-level circuit breaker) ====="
input bool   InpUseMaxDrawdownLimit  = true;
input double InpMaxDrawdownPercent   = 15.0;
input bool   InpCloseAllOnMaxDrawdown= true;

input group "===== Order Execution Robustness ====="
input bool   InpCheckMarginBeforeTrade = true;
input int    InpMaxOrderRetries        = 3;
input int    InpRetryDelayMs           = 500;

input group "===== Trade Journal ====="
input bool   InpUseTradeJournal      = true;
input string InpJournalFileName      = "TrendBreakoutEA_Journal.csv";

input group "===== General Settings ====="
input int    InpMagicNumber          = 20260905;
input string InpTradeComment         = "TrendBreakoutEA";
input int    InpSlippagePoints       = 20;

//============================================================
// GLOBAL VARIABLES
//============================================================

CTrade ExtTrade;

int      ExtHandleRegimeEMA;
int      ExtHandleADX;
int      ExtHandleATR;
int      ExtHandleHTFEMA;
int      ExtHandleBB;             // Indicator handle: Bollinger Bands used for the volatility squeeze filter

datetime ExtLastProcessedBarTime;

datetime ExtCurrentDayStart;
double   ExtDayStartBalance;
int      ExtTradesToday;
bool     ExtDailyLimitHit;

double   ExtEquityPeak;
bool     ExtMaxDrawdownHit;

ulong    ExtManagedTicket;
double   ExtManagedInitialRisk;
double   ExtManagedEntryPrice;
bool     ExtManagedIsLong;
bool     ExtManagedBEDone;
bool     ExtManagedPartialDone;

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpRegimeEMAPeriod <= 0 || InpADXPeriod <= 0 || InpBreakoutPeriod <= 0 || InpATRPeriod <= 0)
     {
      Print("ERROR: One of the period inputs (EMA/ADX/Breakout/ATR) is not a positive integer.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpRiskPercent <= 0.0 || InpATRMultiplierSL <= 0.0 || InpRewardRiskRatio <= 0.0)
     {
      Print("ERROR: One of the risk management inputs is not a positive number.");
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

   if(InpUseVolatilityAdaptiveSizing && (InpATRAveragePeriod <= 0 || InpVolatilityShrinkThreshold <= 0.0 || InpMinSizeMultiplier <= 0.0))
     {
      Print("ERROR: Volatility-adaptive sizing inputs must be positive numbers.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpUseMaxDrawdownLimit && InpMaxDrawdownPercent <= 0.0)
     {
      Print("ERROR: InpMaxDrawdownPercent must be a positive number when InpUseMaxDrawdownLimit is true.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpMaxOrderRetries <= 0)
     {
      Print("ERROR: InpMaxOrderRetries must be at least 1.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpUseSqueezeFilter && (InpBBPeriod <= 0 || InpBBDeviation <= 0.0 || InpSqueezeBaselineLookback <= 1 ||
                              InpSqueezePercentileThreshold <= 0.0 || InpSqueezePercentileThreshold > 100.0 ||
                              InpSqueezeRecentBars <= 0))
     {
      Print("ERROR: Volatility squeeze filter inputs are invalid (check periods/percentile/bars).");
      return(INIT_PARAMETERS_INCORRECT);
     }

   ExtTrade.SetExpertMagicNumber(InpMagicNumber);
   ExtTrade.SetTypeFillingBySymbol(_Symbol);
   ExtTrade.SetDeviationInPoints(InpSlippagePoints);

   ExtHandleRegimeEMA = iMA(_Symbol, PERIOD_CURRENT, InpRegimeEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(ExtHandleRegimeEMA == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create the Regime EMA indicator handle. Error code = ", GetLastError());
      return(INIT_FAILED);
     }

   ExtHandleADX = iADX(_Symbol, PERIOD_CURRENT, InpADXPeriod);
   if(ExtHandleADX == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create the ADX indicator handle. Error code = ", GetLastError());
      return(INIT_FAILED);
     }

   ExtHandleATR = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);
   if(ExtHandleATR == INVALID_HANDLE)
     {
      Print("ERROR: Failed to create the ATR indicator handle. Error code = ", GetLastError());
      return(INIT_FAILED);
     }

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

   if(InpUseSqueezeFilter)
     {
      ExtHandleBB = iBands(_Symbol, PERIOD_CURRENT, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
      if(ExtHandleBB == INVALID_HANDLE)
        {
         Print("ERROR: Failed to create the Bollinger Bands indicator handle. Error code = ", GetLastError());
         return(INIT_FAILED);
        }
     }
   else
     {
      ExtHandleBB = INVALID_HANDLE;
     }

   ExtLastProcessedBarTime = 0;

   ExtCurrentDayStart = 0;
   ExtDayStartBalance = 0.0;
   ExtTradesToday      = 0;
   ExtDailyLimitHit    = false;

   ExtEquityPeak     = AccountInfoDouble(ACCOUNT_EQUITY);
   ExtMaxDrawdownHit = false;

   ExtManagedTicket        = 0;
   ExtManagedInitialRisk   = 0.0;
   ExtManagedEntryPrice    = 0.0;
   ExtManagedIsLong        = false;
   ExtManagedBEDone        = false;
   ExtManagedPartialDone   = false;

   ResetDailyTrackingIfNeeded();

   Print("TrendFollowingBreakoutEA v3 initialized successfully on symbol ", _Symbol, ", timeframe ", EnumToString(PERIOD_CURRENT));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(ExtHandleRegimeEMA != INVALID_HANDLE)
      IndicatorRelease(ExtHandleRegimeEMA);

   if(ExtHandleADX != INVALID_HANDLE)
      IndicatorRelease(ExtHandleADX);

   if(ExtHandleATR != INVALID_HANDLE)
      IndicatorRelease(ExtHandleATR);

   if(ExtHandleHTFEMA != INVALID_HANDLE)
      IndicatorRelease(ExtHandleHTFEMA);

   if(ExtHandleBB != INVALID_HANDLE)
      IndicatorRelease(ExtHandleBB);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ResetDailyTrackingIfNeeded();
   UpdateMaxDrawdownProtection();

   ManageOpenPosition();

   if(!IsNewBar())
      return;

   if(HasOpenPosition())
      return;

   if(InpUseMaxDrawdownLimit && ExtMaxDrawdownHit)
      return;

   if(InpUseDailyLossLimit && ExtDailyLimitHit)
      return;

   if(InpUseDailyLossLimit && InpMaxTradesPerDay > 0 && ExtTradesToday >= InpMaxTradesPerDay)
      return;

   if(InpUseSessionFilter && !IsWithinSession())
      return;

   if(InpUseSpreadFilter && !IsSpreadAcceptable())
      return;

   if(InpUseNewsFilter && IsHighImpactNewsWindow())
      return;

   bool isUptrendRegime   = IsUptrendRegime();
   bool isDowntrendRegime = IsDowntrendRegime();

   if(isUptrendRegime && CheckBullishBreakout())
     {
      if((!InpUseHTFConfirm || IsHTFBullish()) && WasRecentSqueeze())
         OpenLongPosition();
      return;
     }

   if(isDowntrendRegime && CheckBearishBreakout())
     {
      if((!InpUseHTFConfirm || IsHTFBearish()) && WasRecentSqueeze())
         OpenShortPosition();
      return;
     }
  }

//+------------------------------------------------------------------+
//| Returns true if band width was at/below the configured percentile|
//| of its own recent distribution at some point in the last         |
//| InpSqueezeRecentBars closed bars - i.e. a genuine volatility      |
//| squeeze happened shortly before this breakout. Returns true       |
//| unconditionally if the filter is disabled.                        |
//+------------------------------------------------------------------+
bool WasRecentSqueeze()
  {
   if(!InpUseSqueezeFilter)
      return(true);

   int barsNeeded = InpSqueezeBaselineLookback + InpSqueezeRecentBars;

   double upperBuf[];
   double lowerBuf[];
   double middleBuf[];

   ArraySetAsSeries(upperBuf, true);
   ArraySetAsSeries(lowerBuf, true);
   ArraySetAsSeries(middleBuf, true);

   //--- start at shift 1 (last CLOSED bar) so the still-forming current bar never affects the reading
   if(CopyBuffer(ExtHandleBB, 1, 1, barsNeeded, upperBuf) < barsNeeded)
      return(false);

   if(CopyBuffer(ExtHandleBB, 2, 1, barsNeeded, lowerBuf) < barsNeeded)
      return(false);

   if(CopyBuffer(ExtHandleBB, 0, 1, barsNeeded, middleBuf) < barsNeeded)
      return(false);

   double allWidths[];
   ArrayResize(allWidths, barsNeeded);

   for(int i = 0; i < barsNeeded; i++)
      allWidths[i] = (middleBuf[i] > 0.0) ? (upperBuf[i] - lowerBuf[i]) / middleBuf[i] : 0.0;

   //--- build the baseline distribution from the OLDER bars only (excludes the recent window being tested)
   double baseline[];
   ArrayResize(baseline, InpSqueezeBaselineLookback);

   for(int i = 0; i < InpSqueezeBaselineLookback; i++)
      baseline[i] = allWidths[InpSqueezeRecentBars + i];

   ArraySort(baseline); // ascending order

   int percentileIndex = (int)MathFloor((InpSqueezePercentileThreshold / 100.0) * (InpSqueezeBaselineLookback - 1));
   percentileIndex = MathMax(0, MathMin(percentileIndex, InpSqueezeBaselineLookback - 1));

   double squeezeThreshold = baseline[percentileIndex];

   //--- true if ANY of the recent bars had a band width at or below that threshold
   for(int i = 0; i < InpSqueezeRecentBars; i++)
     {
      if(allWidths[i] <= squeezeThreshold)
         return(true);
     }

   return(false);
  }

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
  {
   if(!InpUseTradeJournal)
      return;

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong dealTicket = trans.deal;
   if(!HistoryDealSelect(dealTicket))
      return;

   if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagicNumber)
      return;

   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
      return;

   WriteJournalRow(dealTicket);
  }

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
void CloseAllOwnPositions()
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

      if(ExtTrade.PositionClose(ticket))
         Print("Position #", ticket, " closed due to max drawdown protection.");
      else
         Print("WARNING: Failed to close position #", ticket, " during max drawdown protection. Return code = ", ExtTrade.ResultRetcode());
     }

   ExtManagedTicket = 0;
  }

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
bool CheckBullishBreakout()
  {
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
double GetCurrentATR()
  {
   double atrValue[];
   ArraySetAsSeries(atrValue, true);

   if(CopyBuffer(ExtHandleATR, 0, 0, 1, atrValue) <= 0)
      return(0.0);

   return(atrValue[0]);
  }

//+------------------------------------------------------------------+
double GetVolatilityAdjustedRiskPercent()
  {
   if(!InpUseVolatilityAdaptiveSizing)
      return(InpRiskPercent);

   int barsNeeded = InpATRAveragePeriod + 1;
   double atrSeries[];
   ArraySetAsSeries(atrSeries, true);

   if(CopyBuffer(ExtHandleATR, 0, 0, barsNeeded, atrSeries) < barsNeeded)
      return(InpRiskPercent);

   double currentATR = atrSeries[0];

   double sumATR = 0.0;
   for(int i = 1; i < barsNeeded; i++)
      sumATR += atrSeries[i];

   double avgATR = sumATR / InpATRAveragePeriod;

   if(avgATR <= 0.0 || currentATR <= 0.0)
      return(InpRiskPercent);

   double ratio = currentATR / avgATR;

   if(ratio <= InpVolatilityShrinkThreshold)
      return(InpRiskPercent);

   double multiplier   = MathMax(InpVolatilityShrinkThreshold / ratio, InpMinSizeMultiplier);
   double adjustedRisk = InpRiskPercent * multiplier;

   Print("Volatility-adaptive sizing: ATR ", DoubleToString(currentATR, _Digits),
         " vs baseline ", DoubleToString(avgATR, _Digits),
         " -> risk shrunk from ", DoubleToString(InpRiskPercent, 2),
         "% to ", DoubleToString(adjustedRisk, 2), "%");

   return(adjustedRisk);
  }

//+------------------------------------------------------------------+
double CalculateLotSize(double stopLossDistancePrice, double riskPercent)
  {
   double accountBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmountMoney = accountBalance * (riskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0.0 || tickValue <= 0.0)
     {
      Print("ERROR: Invalid tick size or tick value for symbol ", _Symbol);
      return(0.0);
     }

   double moneyLossPerLot = (stopLossDistancePrice / tickSize) * tickValue;
   if(moneyLossPerLot <= 0.0)
      return(0.0);

   double rawLotSize = riskAmountMoney / moneyLossPerLot;

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
bool IsStopDistanceValid(double entryPrice, double stopLossPrice, double takeProfitPrice)
  {
   long stopLevelPoints   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLevelPoints = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long minLevelPoints    = MathMax(stopLevelPoints, freezeLevelPoints);

   if(minLevelPoints <= 0)
      return(true);

   double minDistance = minLevelPoints * _Point;

   double slDistance = MathAbs(entryPrice - stopLossPrice);
   double tpDistance = MathAbs(takeProfitPrice - entryPrice);

   if(slDistance < minDistance || tpDistance < minDistance)
     {
      Print("WARNING: SL/TP too close to price for this broker (min distance = ", minLevelPoints,
            " points). SL distance = ", DoubleToString(slDistance / _Point, 1),
            " pts, TP distance = ", DoubleToString(tpDistance / _Point, 1), " pts. Skipping entry.");
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
bool HasEnoughMargin(ENUM_ORDER_TYPE orderType, double lotSize, double price)
  {
   if(!InpCheckMarginBeforeTrade)
      return(true);

   double marginRequired = 0.0;
   if(!OrderCalcMargin(orderType, _Symbol, lotSize, price, marginRequired))
     {
      Print("WARNING: OrderCalcMargin failed. Error code = ", GetLastError(), ". Proceeding without a margin pre-check.");
      return(true);
     }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);

   if(marginRequired > freeMargin)
     {
      Print("WARNING: Not enough free margin for this trade. Required = ", DoubleToString(marginRequired, 2),
            ", Free margin = ", DoubleToString(freeMargin, 2), ". Skipping entry.");
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
bool IsRetryableRetcode(uint retcode)
  {
   return(retcode == TRADE_RETCODE_REQUOTE ||
          retcode == TRADE_RETCODE_PRICE_CHANGED ||
          retcode == TRADE_RETCODE_TIMEOUT ||
          retcode == TRADE_RETCODE_CONNECTION ||
          retcode == TRADE_RETCODE_PRICE_OFF);
  }

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

   double riskPercent = GetVolatilityAdjustedRiskPercent();
   double lotSize      = CalculateLotSize(stopLossDistance, riskPercent);
   if(lotSize <= 0.0)
     {
      Print("WARNING: Calculated lot size is invalid, skipping long entry.");
      return;
     }

   bool sent     = false;
   int  attempts = InpMaxOrderRetries;

   for(int attempt = 1; attempt <= attempts; attempt++)
     {
      double askPrice        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double stopLossPrice   = NormalizeDouble(askPrice - stopLossDistance, _Digits);
      double takeProfitPrice = NormalizeDouble(askPrice + takeProfitDistance, _Digits);

      if(!IsStopDistanceValid(askPrice, stopLossPrice, takeProfitPrice))
         return;

      if(!HasEnoughMargin(ORDER_TYPE_BUY, lotSize, askPrice))
         return;

      bool result = ExtTrade.Buy(lotSize, _Symbol, askPrice, stopLossPrice, takeProfitPrice, InpTradeComment);

      if(result)
        {
         Print("Long position opened (attempt ", attempt, "/", attempts, "). Lot size = ", lotSize,
               " | Risk% used = ", DoubleToString(riskPercent, 2),
               " | SL = ", stopLossPrice, " | TP = ", takeProfitPrice);

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
         sent = true;
         break;
        }

      uint retcode = ExtTrade.ResultRetcode();
      Print("WARNING: Buy attempt ", attempt, "/", attempts, " failed. Return code = ", retcode,
            " - ", ExtTrade.ResultRetcodeDescription());

      if(!IsRetryableRetcode(retcode) || attempt == attempts)
         break;

      Sleep(InpRetryDelayMs);
     }

   if(!sent)
      Print("ERROR: Long entry ultimately failed after ", attempts, " attempt(s).");
  }

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

   double riskPercent = GetVolatilityAdjustedRiskPercent();
   double lotSize      = CalculateLotSize(stopLossDistance, riskPercent);
   if(lotSize <= 0.0)
     {
      Print("WARNING: Calculated lot size is invalid, skipping short entry.");
      return;
     }

   bool sent     = false;
   int  attempts = InpMaxOrderRetries;

   for(int attempt = 1; attempt <= attempts; attempt++)
     {
      double bidPrice        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double stopLossPrice   = NormalizeDouble(bidPrice + stopLossDistance, _Digits);
      double takeProfitPrice = NormalizeDouble(bidPrice - takeProfitDistance, _Digits);

      if(!IsStopDistanceValid(bidPrice, stopLossPrice, takeProfitPrice))
         return;

      if(!HasEnoughMargin(ORDER_TYPE_SELL, lotSize, bidPrice))
         return;

      bool result = ExtTrade.Sell(lotSize, _Symbol, bidPrice, stopLossPrice, takeProfitPrice, InpTradeComment);

      if(result)
        {
         Print("Short position opened (attempt ", attempt, "/", attempts, "). Lot size = ", lotSize,
               " | Risk% used = ", DoubleToString(riskPercent, 2),
               " | SL = ", stopLossPrice, " | TP = ", takeProfitPrice);

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
         sent = true;
         break;
        }

      uint retcode = ExtTrade.ResultRetcode();
      Print("WARNING: Sell attempt ", attempt, "/", attempts, " failed. Return code = ", retcode,
            " - ", ExtTrade.ResultRetcodeDescription());

      if(!IsRetryableRetcode(retcode) || attempt == attempts)
         break;

      Sleep(InpRetryDelayMs);
     }

   if(!sent)
      Print("ERROR: Short entry ultimately failed after ", attempts, " attempt(s).");
  }

//+------------------------------------------------------------------+
bool SelectManagedPosition()
  {
   if(ExtManagedTicket == 0)
      return(false);

   if(!PositionSelectByTicket(ExtManagedTicket))
     {
      ExtManagedTicket = 0;
      return(false);
     }

   return(true);
  }

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

   if(!SelectManagedPosition())
      return;

   double currentSL = PositionGetDouble(POSITION_SL);
   double currentTP = PositionGetDouble(POSITION_TP);

   if(InpUseBreakEven && !ExtManagedBEDone && profitInR >= InpBreakEvenTriggerR)
     {
      double lockPoints  = InpBreakEvenLockPoints * _Point;
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
            currentSL        = candidateSL;
            Print("Break-even applied at ", DoubleToString(profitInR, 2), "R. New SL = ", candidateSL);
           }
         else
           {
            Print("WARNING: Break-even modify failed. Return code = ", ExtTrade.ResultRetcode(), " - ", ExtTrade.ResultRetcodeDescription());
           }
        }
     }

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
void UpdateMaxDrawdownProtection()
  {
   if(!InpUseMaxDrawdownLimit)
      return;

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(currentEquity > ExtEquityPeak)
      ExtEquityPeak = currentEquity;

   if(ExtMaxDrawdownHit || ExtEquityPeak <= 0.0)
      return;

   double drawdownPercent = (ExtEquityPeak - currentEquity) / ExtEquityPeak * 100.0;

   if(drawdownPercent >= InpMaxDrawdownPercent)
     {
      ExtMaxDrawdownHit = true;
      Print("MAX DRAWDOWN LIMIT REACHED (", DoubleToString(drawdownPercent, 2),
            "% from peak equity ", DoubleToString(ExtEquityPeak, 2),
            "). All new entries are now blocked. Restart the EA after reviewing performance to resume trading.");

      if(InpCloseAllOnMaxDrawdown)
         CloseAllOwnPositions();
     }
  }

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
bool IsWithinSession()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(InpSessionStartHour <= InpSessionEndHour)
      return(dt.hour >= InpSessionStartHour && dt.hour < InpSessionEndHour);

   return(dt.hour >= InpSessionStartHour || dt.hour < InpSessionEndHour);
  }

//+------------------------------------------------------------------+
bool IsSpreadAcceptable()
  {
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return(spreadPoints <= InpMaxSpreadPoints);
  }

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
void WriteJournalRow(ulong dealTicket)
  {
   bool fileExists = FileIsExist(InpJournalFileName);

   int handle = FileOpen(InpJournalFileName, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
     {
      Print("WARNING: Could not open trade journal file '", InpJournalFileName, "'. Error code = ", GetLastError());
      return;
     }

   if(!fileExists)
      FileWrite(handle, "Time", "DealTicket", "Type", "Volume", "Price", "Profit", "Comment");

   FileSeek(handle, 0, SEEK_END);

   datetime       dealTime   = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
   ENUM_DEAL_TYPE dealType   = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   double         dealVolume = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   double         dealPrice  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   double         dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   string         dealComment= HistoryDealGetString(dealTicket, DEAL_COMMENT);

   FileWrite(handle,
             TimeToString(dealTime, TIME_DATE | TIME_SECONDS),
             (long)dealTicket,
             EnumToString(dealType),
             DoubleToString(dealVolume, 2),
             DoubleToString(dealPrice, _Digits),
             DoubleToString(dealProfit, 2),
             dealComment);

   FileClose(handle);
  }
//+------------------------------------------------------------------+
