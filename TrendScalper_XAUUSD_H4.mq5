//+------------------------------------------------------------------+
//|                                    TrendScalper_XAUUSD_H4.mq5      |
//|          Trend-Following EA: EMA Cross + ATR Risk Management       |
//|          Designed for: XAUUSD, Timeframe H4                        |
//|          Written from scratch - 100% original, no third-party code |
//+------------------------------------------------------------------+
#property copyright "Custom EA - built for user specification"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Trade object
CTrade trade;

//====================== INPUT PARAMETERS =============================
input group "=== Strategy - EMA Trend Filter ==="
input int      InpFastEMA        = 20;     // Fast EMA period
input int      InpSlowEMA        = 50;     // Slow EMA period
input int      InpTrendEMA       = 200;    // Long-term trend filter EMA
input bool     InpUseTrendFilter = true;   // Only trade in direction of TrendEMA

input group "=== Risk Management ==="
input double   InpRiskPercent    = 2.0;    // Risk per trade (% of balance)
input int      InpATRPeriod      = 14;     // ATR period (for volatility-based SL)
input double   InpATR_SL_Mult    = 2.0;    // SL distance = ATR * this multiplier
input double   InpRewardRatio    = 2.0;    // TP distance = SL distance * this ratio
input double   InpMaxSpreadPts   = 500;    // Max allowed spread (points) - skip trade if wider

input group "=== Trade Management ==="
input bool     InpUseTrailing    = true;   // Enable ATR-based trailing stop
input double   InpTrailATRMult   = 1.5;    // Trailing distance = ATR * this multiplier
input int      InpMagicNumber    = 20260917; // Unique magic number for this EA
input int      InpSlippagePts    = 30;     // Max slippage in points

//====================== GLOBALS =======================================
int    handleFastEMA, handleSlowEMA, handleTrendEMA, handleATR;
double bufFast[], bufSlow[], bufTrend[], bufATR[];
datetime lastBarTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   // Sanity check: this EA is tuned for H4. Warn if attached elsewhere.
   if(PeriodSeconds(PERIOD_CURRENT) != PeriodSeconds(PERIOD_H4))
      Print("Warning: This EA was designed for H4. Current chart period differs - review inputs before trading live.");

   handleFastEMA  = iMA(_Symbol, PERIOD_CURRENT, InpFastEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA  = iMA(_Symbol, PERIOD_CURRENT, InpSlowEMA,  0, MODE_EMA, PRICE_CLOSE);
   handleTrendEMA = iMA(_Symbol, PERIOD_CURRENT, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleATR      = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);

   if(handleFastEMA==INVALID_HANDLE || handleSlowEMA==INVALID_HANDLE ||
      handleTrendEMA==INVALID_HANDLE || handleATR==INVALID_HANDLE)
   {
      Print("Error creating indicator handles");
      return(INIT_FAILED);
   }

   ArraySetAsSeries(bufFast, true);
   ArraySetAsSeries(bufSlow, true);
   ArraySetAsSeries(bufTrend, true);
   ArraySetAsSeries(bufATR, true);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleFastEMA);
   IndicatorRelease(handleSlowEMA);
   IndicatorRelease(handleTrendEMA);
   IndicatorRelease(handleATR);
}

//+------------------------------------------------------------------+
//| Copy latest indicator values. Returns false if not enough data.   |
//+------------------------------------------------------------------+
bool RefreshIndicators()
{
   if(CopyBuffer(handleFastEMA, 0, 0, 3, bufFast)   < 3) return false;
   if(CopyBuffer(handleSlowEMA, 0, 0, 3, bufSlow)   < 3) return false;
   if(CopyBuffer(handleTrendEMA,0, 0, 3, bufTrend)  < 3) return false;
   if(CopyBuffer(handleATR,     0, 0, 3, bufATR)    < 3) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Check whether a new bar has opened                                 |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t != lastBarTime)
   {
      lastBarTime = t;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Count open positions for this EA/symbol                            |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Calculate lot size from risk % and SL distance (in price units)    |
//+------------------------------------------------------------------+
double CalcLotSize(double slDistancePrice)
{
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount  = balance * (InpRiskPercent / 100.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(tickSize <= 0 || point <= 0) return 0.0;

   // Money value of one point move, per 1.0 lot
   double moneyPerPoint = (tickValue / tickSize) * point;
   double slPoints      = slDistancePrice / point;

   if(slPoints <= 0 || moneyPerPoint <= 0) return 0.0;

   double rawLots = riskAmount / (slPoints * moneyPerPoint);

   // Normalize to broker's volume step / min / max
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double volMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lots = MathFloor(rawLots / volStep) * volStep;
   lots = MathMax(volMin, MathMin(volMax, lots));

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Spread filter                                                      |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   double spreadPts = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spreadPts <= InpMaxSpreadPts);
}

//+------------------------------------------------------------------+
//| Open a new trade in given direction                                |
//+------------------------------------------------------------------+
void OpenTrade(bool isBuy)
{
   double atr = bufATR[1]; // last closed bar's ATR
   double slDistance = atr * InpATR_SL_Mult;
   double tpDistance = slDistance * InpRewardRatio;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double lots = CalcLotSize(slDistance);
   if(lots <= 0)
   {
      Print("Lot size calculated as 0 - trade skipped. Check risk settings / account balance.");
      return;
   }

   if(isBuy)
   {
      double sl = ask - slDistance;
      double tp = ask + tpDistance;
      trade.Buy(lots, _Symbol, ask, sl, tp, "TrendScalper Buy");
   }
   else
   {
      double sl = bid + slDistance;
      double tp = bid - tpDistance;
      trade.Sell(lots, _Symbol, bid, sl, tp, "TrendScalper Sell");
   }
}

//+------------------------------------------------------------------+
//| ATR-based trailing stop management                                 |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(!InpUseTrailing) return;

   double atr = bufATR[1];
   double trailDist = atr * InpTrailATRMult;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      long   type       = PositionGetInteger(POSITION_TYPE);
      double curSL       = PositionGetDouble(POSITION_SL);
      double curTP       = PositionGetDouble(POSITION_TP);
      double openPrice   = PositionGetDouble(POSITION_PRICE_OPEN);

      if(type == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double newSL = bid - trailDist;
         // Only move SL up, and only once price has moved favorably past open
         if(newSL > openPrice && newSL > curSL)
            trade.PositionModify(ticket, newSL, curTP);
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double newSL = ask + trailDist;
         if((newSL < openPrice) && (curSL == 0 || newSL < curSL))
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!RefreshIndicators()) return;

   // Manage trailing stops every tick (not just on new bar)
   ManageTrailingStop();

   // Only evaluate new entries once per closed H4 bar
   if(!IsNewBar()) return;

   if(!SpreadOK()) return;

   // Use index 1 = last fully closed bar (avoid repainting on the forming bar)
   double fastPrev = bufFast[2],  fastLast = bufFast[1];
   double slowPrev = bufSlow[2],  slowLast = bufSlow[1];
   double trendLast = bufTrend[1];
   double closeLast = iClose(_Symbol, PERIOD_CURRENT, 1);

   bool crossUp   = (fastPrev <= slowPrev) && (fastLast > slowLast);
   bool crossDown = (fastPrev >= slowPrev) && (fastLast < slowLast);

   bool trendUp   = closeLast > trendLast;
   bool trendDown = closeLast < trendLast;

   // Don't stack multiple positions
   if(CountOpenPositions() > 0) return;

   if(crossUp && (!InpUseTrendFilter || trendUp))
   {
      OpenTrade(true);
   }
   else if(crossDown && (!InpUseTrendFilter || trendDown))
   {
      OpenTrade(false);
   }
}
//+------------------------------------------------------------------+
