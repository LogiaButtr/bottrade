//+------------------------------------------------------------------+
//|                                    TrendFollowingBreakoutEA.mq5  |
//|                                                                  |
//| VERSION 2.00 = V1 + ADAPTIVE LAYERS (entry logic is unchanged)   |
//|                                                                  |
//| STRATEGY ARCHITECTURE:                                           |
//|                                                                  |
//|  1) TREND REGIME FILTER (unchanged from V1): only trade in the   |
//|     direction of the long-term trend (price vs long EMA) and     |
//|     only when ADX says the market is actually trending.          |
//|                                                                  |
//|  2) ENTRY SIGNAL (unchanged from V1): Donchian-style breakout of |
//|     the highest high / lowest low of the previous N bars, plus a |
//|     small buffer to filter noise.                                |
//|                                                                  |
//|  3) RISK MANAGEMENT (V1 + one new multiplier): the stop loss is  |
//|     sized from ATR, the take profit is a multiple of the stop    |
//|     distance, and the lot size is calculated so that a stop-out  |
//|     loses a fixed percentage of balance. NEW: that percentage is |
//|     scaled by the current VOLATILITY REGIME (see 4).             |
//|                                                                  |
//|  4) VOLATILITY REGIME (NEW, ported from the Storm Gauge Pine     |
//|     indicator): realized volatility measured on a higher         |
//|     timeframe (D1) is ranked against its own past year           |
//|     (percentile). This gives CALM / NORMAL / STORM. Because it   |
//|     is a RELATIVE rank, it calibrates itself when the overall    |
//|     level of market volatility changes. A hysteresis band stops  |
//|     the STORM state from flickering on and off.                  |
//|                                                                  |
//|  5) ACCOUNT GUARDRAILS (NEW): daily loss limit, drawdown kill    |
//|     switch, spread filter, and "skip the trade instead of        |
//|     forcing the minimum lot".                                    |
//|                                                                  |
//|  6) TRADE LOG (NEW): every entry and exit is appended to a CSV   |
//|     file together with the regime at entry time, so results can  |
//|     be analysed per regime afterwards.                           |
//|                                                                  |
//|  A/B TESTING: set InpReplicateV1Behavior = true to make the EA   |
//|  size and trade exactly like V1 (the regime is still measured    |
//|  and logged). Use it to verify parity with V1 and to get a       |
//|  baseline to compare every other setting against.                |
//+------------------------------------------------------------------+
#property copyright "Arthur rak torfan t sud nai lok"
#property link      ""
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//============================================================
// ENUMS
//============================================================

enum ENUM_VOL_REGIME
  {
   VOL_REGIME_UNKNOWN = 0,   // not enough data yet to measure the regime (treated like NORMAL for sizing)
   VOL_REGIME_CALM    = 1,   // volatility is low compared with its own past year
   VOL_REGIME_NORMAL  = 2,   // volatility is in the middle of its own past year
   VOL_REGIME_STORM   = 3    // volatility is high compared with its own past year
  };

//============================================================
// INPUT PARAMETERS - GROUPED BY PURPOSE
//============================================================

input group "===== A/B Testing Helper ====="
input bool   InpReplicateV1Behavior      = false; // true = size and trade exactly like V1: regime multipliers forced to 1.0, all guardrails off, min-lot forcing kept (regime is still measured and logged)

input group "===== Regime Filter Settings (trend, unchanged from V1) ====="
input int    InpRegimeEMAPeriod          = 200;   // EMA period used to define the long-term trend regime
input int    InpADXPeriod                = 14;    // ADX period used to confirm trend strength
input double InpADXThreshold             = 25.0;  // Minimum ADX value required to consider the market "trending"

input group "===== Breakout Entry Settings (unchanged from V1) ====="
input int    InpBreakoutPeriod           = 20;    // Number of bars used to build the Donchian channel (highest high / lowest low)
input int    InpBreakoutBufferPoints     = 20;    // Extra buffer in points added beyond the channel level, to filter out noise-driven false breakouts

input group "===== Risk Management Settings ====="
input double InpRiskPercent              = 1.0;   // Percentage of account balance risked on each single trade (before the regime multiplier)
input int    InpATRPeriod                = 14;    // ATR period used to size the stop loss distance
input double InpATRMultiplierSL          = 2.0;   // Stop loss distance = ATR value multiplied by this factor
input double InpRewardRiskRatio          = 2.0;   // Take profit distance = stop loss distance multiplied by this factor (2.0 = 2:1 reward:risk)

input group "===== Volatility Regime Settings (ported from Storm Gauge) ====="
input ENUM_TIMEFRAMES InpVolTimeframe    = PERIOD_D1; // Timeframe whose CLOSED bars are used to measure volatility
input int    InpVolWindowBars            = 20;    // Number of bars in each realized-volatility reading (standard deviation of log returns)
input int    InpVolPercentileLookback    = 252;   // How many past volatility readings the current reading is ranked against
input double InpCalmPercentile           = 33.0;  // Percentile BELOW which the regime is CALM
input double InpStormEnterPercentile     = 67.0;  // Percentile ABOVE which the regime becomes STORM
input double InpStormExitPercentile      = 60.0;  // Once in STORM, the regime only leaves STORM when the percentile falls BELOW this value (hysteresis)

input group "===== Regime Risk Multipliers (multiply InpRiskPercent, range 0.0 - 1.0) ====="
input double InpCalmRiskMultiplier       = 1.0;   // Risk multiplier while the regime is CALM
input double InpNormalRiskMultiplier     = 1.0;   // Risk multiplier while the regime is NORMAL (also used while UNKNOWN)
input double InpStormRiskMultiplier      = 0.5;   // Risk multiplier while the regime is STORM (0.0 = open no new trades during STORM)

input group "===== Account Guardrails ====="
input double InpMaxDailyLossPercent      = 3.0;   // Stop opening new trades for the rest of the day when equity is this % below the day-start equity (0 = disabled)
input double InpMaxDrawdownPercent       = 15.0;  // Stop opening new trades when equity is this % below its peak equity (0 = disabled)
input bool   InpResetPeakEquityOnStart   = false; // true = restart the peak-equity tracking from the current equity when the EA starts (set back to false afterwards)
input double InpMaxSpreadToStopRatio     = 0.10;  // Skip an entry when the spread is larger than this fraction of the stop loss distance (0 = disabled)
input bool   InpSkipTradeIfBelowMinLot   = true;  // true = skip the trade when the risk-based lot is below the broker minimum lot (V1 forced the minimum lot, which risks more than intended)

input group "===== Trade Log (CSV) ====="
input bool   InpEnableTradeLog           = true;                       // Write every entry and exit to a CSV file in the terminal Common\Files folder
input string InpTradeLogFileName         = "TrendBreakoutEA_log.csv";  // CSV file name (rows are appended, so one file can hold many runs)
input string InpTradeLogRunTag           = "run1";                     // Text written in the first column of every row; change it for each test run so runs can be told apart

input group "===== General Settings ====="
input int    InpMagicNumber              = 20260905;          // Unique identifier attached to every order placed by this EA
input string InpTradeComment             = "TrendBreakoutEA"; // Comment attached to every order placed by this EA

//============================================================
// GLOBAL VARIABLES
//============================================================

CTrade ExtTrade;                    // Trade execution object, used to send buy/sell requests

int      ExtHandleRegimeEMA;        // Indicator handle: long-term EMA used in the trend regime filter
int      ExtHandleADX;              // Indicator handle: ADX used in the trend regime filter
int      ExtHandleATR;              // Indicator handle: ATR used in risk management

datetime ExtLastProcessedBarTime;   // Open time of the last bar already evaluated, so the EA only acts once per new bar

//--- volatility regime state (recomputed only when a new bar of InpVolTimeframe has closed)
ENUM_VOL_REGIME ExtVolRegime;             // Current volatility regime; kept between calculations because the hysteresis needs the previous state
datetime        ExtLastVolBarTime;        // Open time of the volatility-timeframe bar the regime was last computed for
datetime        ExtLastVolWarningBarTime; // Open time of the volatility-timeframe bar we last printed a "not enough data" warning for
double          ExtVolPercentile;         // Current volatility reading ranked against its past year, 0 - 100
double          ExtCurrentVol;            // Current volatility reading (standard deviation of log returns, as a fraction)
double          ExtMedianVol;             // Median of the past volatility readings
double          ExtVolRatio;              // ExtCurrentVol / ExtMedianVol (1.0 = typical volatility)

//--- account guardrail state
double   ExtPeakEquity;             // Highest equity seen so far (high-water mark)
double   ExtDayStartEquity;         // Equity at the start of the current day (first tick seen on the day)
datetime ExtCurrentDayBarTime;      // Open time of the D1 bar that represents "today"
bool     ExtDrawdownHaltActive;     // true while the drawdown kill switch is blocking new trades (used only to print one message)
bool     ExtDailyLossHaltActive;    // true while the daily loss limit is blocking new trades (used only to print one message)
bool     ExtUseGlobalVariables;     // true = peak equity is saved in terminal global variables (live/demo); false in the Strategy Tester
string   ExtPeakEquityGlobalName;   // Name of the terminal global variable that stores the peak equity

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Step 1: validate the V1 input parameters before doing anything else
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

   //--- Step 1b: validate the NEW input parameters
   if(InpVolWindowBars < 5 || InpVolPercentileLookback < 60)
     {
      Print("ERROR: InpVolWindowBars must be at least 5 and InpVolPercentileLookback must be at least 60.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpCalmPercentile <= 0.0 ||
      InpCalmPercentile >= InpStormExitPercentile ||
      InpStormExitPercentile > InpStormEnterPercentile ||
      InpStormEnterPercentile >= 100.0)
     {
      Print("ERROR: Percentile inputs must satisfy: 0 < Calm < StormExit <= StormEnter < 100.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpCalmRiskMultiplier   < 0.0 || InpCalmRiskMultiplier   > 1.0 ||
      InpNormalRiskMultiplier < 0.0 || InpNormalRiskMultiplier > 1.0 ||
      InpStormRiskMultiplier  < 0.0 || InpStormRiskMultiplier  > 1.0)
     {
      Print("ERROR: Every regime risk multiplier must be between 0.0 and 1.0 (the regime layer may only reduce risk, never increase it).");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpMaxDailyLossPercent < 0.0 || InpMaxDrawdownPercent < 0.0 || InpMaxSpreadToStopRatio < 0.0)
     {
      Print("ERROR: Guardrail inputs (daily loss / drawdown / spread ratio) must not be negative. Use 0 to disable a guardrail.");
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

   //--- Step 7: initialize the volatility regime state
   ExtVolRegime             = VOL_REGIME_UNKNOWN;
   ExtLastVolBarTime        = 0;
   ExtLastVolWarningBarTime = 0;
   ExtVolPercentile         = 0.0;
   ExtCurrentVol            = 0.0;
   ExtMedianVol             = 0.0;
   ExtVolRatio              = 0.0;

   //--- Step 8: initialize the account guardrail state
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   ExtDayStartEquity      = currentEquity;
   ExtCurrentDayBarTime   = 0;
   ExtDrawdownHaltActive  = false;
   ExtDailyLossHaltActive = false;
   ExtPeakEquity          = currentEquity;

   //--- In the Strategy Tester we keep the peak equity in memory only, so one test run can never leak into the next one.
   //--- On a demo/live account we save it in a terminal global variable, so the drawdown kill switch survives an EA restart.
   ExtUseGlobalVariables   = !(bool)MQLInfoInteger(MQL_TESTER);
   ExtPeakEquityGlobalName = "TBEA_PEAK_" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + IntegerToString(InpMagicNumber);

   if(ExtUseGlobalVariables)
     {
      if(InpResetPeakEquityOnStart || !GlobalVariableCheck(ExtPeakEquityGlobalName))
        {
         //--- start (or restart) the high-water mark from the current equity
         ExtPeakEquity = currentEquity;
        }
      else
        {
         //--- continue from the saved high-water mark, unless the current equity is already higher
         double savedPeakEquity = GlobalVariableGet(ExtPeakEquityGlobalName);
         ExtPeakEquity = MathMax(savedPeakEquity, currentEquity);
        }

      GlobalVariableSet(ExtPeakEquityGlobalName, ExtPeakEquity);
     }

   //--- Step 9: prepare the CSV trade log (creates the file with a header row if it does not exist yet)
   if(InpEnableTradeLog)
      InitTradeLog();

   Print("rak tofran:");
   Print("EA V2 started. ReplicateV1 = ", (string)InpReplicateV1Behavior,
         " | StormRiskMultiplier = ", DoubleToString(InpStormRiskMultiplier, 2),
         " | MaxDailyLoss% = ", DoubleToString(InpMaxDailyLossPercent, 1),
         " | MaxDrawdown% = ", DoubleToString(InpMaxDrawdownPercent, 1),
         " | Peak equity = ", DoubleToString(ExtPeakEquity, 2));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   //--- save the peak equity one last time
   SaveEquityPeak();

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
   //--- Step 0: on EVERY tick keep the equity high-water mark and the day-start equity up to date (cheap)
   UpdateEquityTracking();

   //--- Step 1: only evaluate trading logic once per new bar, not on every single tick
   if(!IsNewBar())
      return;

   //--- Step 1b: once per bar, save the peak equity and refresh the volatility regime
   //---          (the regime itself is only recomputed when a new bar of InpVolTimeframe has closed)
   SaveEquityPeak();
   UpdateVolatilityRegime();

   //--- Step 2: do not look for a new entry if a position is already open on this symbol/magic
   if(HasOpenPosition())
      return;

   //--- Step 2b: do not look for a new entry if an account guardrail (daily loss / drawdown) is active
   if(!AreAccountGuardrailsSatisfied())
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
//| Trade transaction handler: logs every position exit to the CSV   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
  {
   if(!InpEnableTradeLog)
      return;

   //--- we are only interested in a new deal being added to the history
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong dealTicket = trans.deal;
   if(dealTicket == 0)
      return;

   if(!HistoryDealSelect(dealTicket))
      return;

   //--- only deals of this EA on this symbol
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)
      return;

   if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagicNumber)
      return;

   //--- only deals that CLOSE a position (an entry deal is logged by LogEntryToCsv)
   long dealEntryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(dealEntryType != DEAL_ENTRY_OUT && dealEntryType != DEAL_ENTRY_OUT_BY && dealEntryType != DEAL_ENTRY_INOUT)
      return;

   LogExitToCsv(dealTicket);
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
//| VOLATILITY REGIME: standard deviation of log returns             |
//|                                                                  |
//| closes[] must be a series array (index 0 = most recent bar).     |
//| The reading uses the returns ln(closes[k] / closes[k+1]) for     |
//| k = startIndex ... startIndex + windowBars - 1, so the array     |
//| must hold at least startIndex + windowBars + 1 values.           |
//| This is the same calculation as ta.stdev(ret, volLen) in the     |
//| Storm Gauge Pine script (population standard deviation).         |
//+------------------------------------------------------------------+
double ComputeReturnStdDev(const double &closes[], const int startIndex, const int windowBars)
  {
   //--- pass 1: mean of the log returns in the window
   double sumOfReturns = 0.0;
   for(int k = startIndex; k < startIndex + windowBars; k++)
     {
      if(closes[k] <= 0.0 || closes[k + 1] <= 0.0)
         return(0.0);

      sumOfReturns += MathLog(closes[k] / closes[k + 1]);
     }

   double meanReturn = sumOfReturns / windowBars;

   //--- pass 2: average squared distance from that mean, then the square root
   double sumOfSquaredDeviations = 0.0;
   for(int k = startIndex; k < startIndex + windowBars; k++)
     {
      double logReturn = MathLog(closes[k] / closes[k + 1]);
      double deviation = logReturn - meanReturn;
      sumOfSquaredDeviations += deviation * deviation;
     }

   return(MathSqrt(sumOfSquaredDeviations / windowBars));
  }

//+------------------------------------------------------------------+
//| VOLATILITY REGIME: text used in the Experts log and in the CSV   |
//+------------------------------------------------------------------+
string VolRegimeToString(const ENUM_VOL_REGIME regime)
  {
   if(regime == VOL_REGIME_CALM)
      return("CALM");

   if(regime == VOL_REGIME_NORMAL)
      return("NORMAL");

   if(regime == VOL_REGIME_STORM)
      return("STORM");

   return("UNKNOWN");
  }

//+------------------------------------------------------------------+
//| VOLATILITY REGIME: recompute CALM / NORMAL / STORM              |
//|                                                                  |
//| Only does real work when a new bar of InpVolTimeframe has        |
//| closed; on every other call it returns immediately.              |
//|                                                                  |
//| Reading numbering (j = 0 is the newest closed bar):              |
//|   readings[0]            = the CURRENT volatility reading        |
//|   readings[1..lookback]  = the PAST readings the current one is  |
//|                            ranked against                        |
//| Reading j is the standard deviation of the log returns of the    |
//| windowBars closed bars that end at closed bar number (j + 1).    |
//+------------------------------------------------------------------+
void UpdateVolatilityRegime()
  {
   //--- the regime can only change when a new bar of the volatility timeframe has appeared
   datetime volBarTime = iTime(_Symbol, InpVolTimeframe, 0);
   if(volBarTime <= 0)
      return;

   if(volBarTime == ExtLastVolBarTime)
      return;

   int windowBars   = InpVolWindowBars;
   int lookbackBars = InpVolPercentileLookback;

   //--- reading j needs closes j ... j + windowBars, and the oldest reading is j = lookbackBars
   int closesNeeded = lookbackBars + windowBars + 1;

   double closes[];
   ArraySetAsSeries(closes, true);

   //--- start position 1 = the last CLOSED bar; the still-forming bar 0 is never used
   int copiedCount = CopyClose(_Symbol, InpVolTimeframe, 1, closesNeeded, closes);
   if(copiedCount < closesNeeded)
     {
      ExtVolRegime = VOL_REGIME_UNKNOWN;

      //--- print the warning at most once per volatility bar; the calculation is retried on the next trading-timeframe bar
      if(volBarTime != ExtLastVolWarningBarTime)
        {
         ExtLastVolWarningBarTime = volBarTime;
         Print("WARNING: Not enough ", EnumToString(InpVolTimeframe), " history for the volatility regime. Needed ",
               closesNeeded, " closed bars, got ", copiedCount, ". Regime = UNKNOWN (sized like NORMAL).");
        }

      return;
     }

   //--- Step 1: compute every volatility reading
   double readings[];
   ArrayResize(readings, lookbackBars + 1);

   for(int j = 0; j <= lookbackBars; j++)
      readings[j] = ComputeReturnStdDev(closes, j, windowBars);

   double currentReading = readings[0];

   //--- Step 2: percentile = share of the past readings that are LOWER than the current reading
   int pastReadingsBelowCurrent = 0;
   for(int j = 1; j <= lookbackBars; j++)
     {
      if(readings[j] < currentReading)
         pastReadingsBelowCurrent++;
     }

   double percentile = 100.0 * pastReadingsBelowCurrent / lookbackBars;

   //--- Step 3: median of the past readings (used for the "vol ratio" that is written to the log)
   double pastReadings[];
   ArrayResize(pastReadings, lookbackBars);

   for(int j = 1; j <= lookbackBars; j++)
      pastReadings[j - 1] = readings[j];

   ArraySort(pastReadings);

   double medianReading = 0.0;
   if(lookbackBars % 2 == 0)
      medianReading = 0.5 * (pastReadings[lookbackBars / 2 - 1] + pastReadings[lookbackBars / 2]);
   else
      medianReading = pastReadings[lookbackBars / 2];

   double volRatio = 0.0;
   if(medianReading > 0.0)
      volRatio = currentReading / medianReading;

   //--- Step 4: turn the percentile into a regime, with hysteresis around STORM
   ENUM_VOL_REGIME previousRegime = ExtVolRegime;
   ENUM_VOL_REGIME newRegime      = VOL_REGIME_NORMAL;

   if(previousRegime == VOL_REGIME_STORM)
     {
      //--- already in STORM: stay in STORM until the percentile falls below the (lower) exit threshold
      if(percentile >= InpStormExitPercentile)
         newRegime = VOL_REGIME_STORM;
      else if(percentile < InpCalmPercentile)
         newRegime = VOL_REGIME_CALM;
      else
         newRegime = VOL_REGIME_NORMAL;
     }
   else
     {
      //--- not in STORM: enter STORM only when the percentile rises above the (higher) enter threshold
      //--- (CALM has no hysteresis band on purpose, to keep the number of parameters small)
      if(percentile > InpStormEnterPercentile)
         newRegime = VOL_REGIME_STORM;
      else if(percentile < InpCalmPercentile)
         newRegime = VOL_REGIME_CALM;
      else
         newRegime = VOL_REGIME_NORMAL;
     }

   //--- Step 5: store the result
   ExtVolRegime      = newRegime;
   ExtVolPercentile  = percentile;
   ExtCurrentVol     = currentReading;
   ExtMedianVol      = medianReading;
   ExtVolRatio       = volRatio;
   ExtLastVolBarTime = volBarTime;

   if(newRegime != previousRegime)
     {
      Print("Volatility regime: ", VolRegimeToString(previousRegime), " -> ", VolRegimeToString(newRegime),
            " | percentile = ", DoubleToString(percentile, 1),
            " | vol ratio vs median = ", DoubleToString(volRatio, 2));
     }
  }

//+------------------------------------------------------------------+
//| VOLATILITY REGIME: risk multiplier for the current regime        |
//+------------------------------------------------------------------+
double GetRegimeRiskMultiplier()
  {
   //--- V1 replication mode: the regime never changes the risk
   if(InpReplicateV1Behavior)
      return(1.0);

   double multiplier = 1.0;

   if(ExtVolRegime == VOL_REGIME_CALM)
      multiplier = InpCalmRiskMultiplier;
   else if(ExtVolRegime == VOL_REGIME_NORMAL)
      multiplier = InpNormalRiskMultiplier;
   else if(ExtVolRegime == VOL_REGIME_STORM)
      multiplier = InpStormRiskMultiplier;
   else
      multiplier = InpNormalRiskMultiplier;   // UNKNOWN is treated like NORMAL

   return(multiplier);
  }

//+------------------------------------------------------------------+
//| GUARDRAILS: keep the peak equity and the day-start equity fresh  |
//| (called on every tick, so it must stay cheap)                    |
//+------------------------------------------------------------------+
void UpdateEquityTracking()
  {
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   //--- high-water mark
   if(currentEquity > ExtPeakEquity)
      ExtPeakEquity = currentEquity;

   //--- day-start equity: the first tick we see on a new D1 bar defines "start of day"
   //--- (limitation: if the EA is started in the middle of a day, the day-start equity is the equity at start-up)
   datetime todayBarTime = iTime(_Symbol, PERIOD_D1, 0);
   if(todayBarTime > 0 && todayBarTime != ExtCurrentDayBarTime)
     {
      ExtCurrentDayBarTime   = todayBarTime;
      ExtDayStartEquity      = currentEquity;
      ExtDailyLossHaltActive = false;
     }
  }

//+------------------------------------------------------------------+
//| GUARDRAILS: save the peak equity so it survives an EA restart    |
//+------------------------------------------------------------------+
void SaveEquityPeak()
  {
   if(!ExtUseGlobalVariables)
      return;

   GlobalVariableSet(ExtPeakEquityGlobalName, ExtPeakEquity);
  }

//+------------------------------------------------------------------+
//| GUARDRAILS: returns false when a new trade must NOT be opened    |
//|                                                                  |
//| Note on the drawdown kill switch: once it triggers, no new trade |
//| is opened, so equity stops changing and the switch stays on until|
//| you raise InpMaxDrawdownPercent, set it to 0, or start the EA    |
//| with InpResetPeakEquityOnStart = true. That is intentional: it   |
//| forces a human decision before trading again.                    |
//| (Limitation: a deposit or withdrawal changes equity and can move |
//| the drawdown figure. Reset the peak after such an event.)        |
//+------------------------------------------------------------------+
bool AreAccountGuardrailsSatisfied()
  {
   //--- V1 replication mode: no guardrails
   if(InpReplicateV1Behavior)
      return(true);

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   //--- Guardrail 1: drawdown from the peak equity
   if(InpMaxDrawdownPercent > 0.0 && ExtPeakEquity > 0.0)
     {
      double drawdownPercent = (ExtPeakEquity - currentEquity) / ExtPeakEquity * 100.0;

      if(drawdownPercent >= InpMaxDrawdownPercent)
        {
         if(!ExtDrawdownHaltActive)
           {
            ExtDrawdownHaltActive = true;
            Print("GUARDRAIL: Drawdown kill switch ON. Drawdown = ", DoubleToString(drawdownPercent, 2),
                  "% (limit ", DoubleToString(InpMaxDrawdownPercent, 2), "%). No new trades.");
           }

         return(false);
        }

      if(ExtDrawdownHaltActive)
        {
         ExtDrawdownHaltActive = false;
         Print("GUARDRAIL: Drawdown is back below the limit. New trades allowed again.");
        }
     }

   //--- Guardrail 2: loss since the start of today
   if(InpMaxDailyLossPercent > 0.0 && ExtDayStartEquity > 0.0)
     {
      double dailyLossPercent = (ExtDayStartEquity - currentEquity) / ExtDayStartEquity * 100.0;

      if(dailyLossPercent >= InpMaxDailyLossPercent)
        {
         if(!ExtDailyLossHaltActive)
           {
            ExtDailyLossHaltActive = true;
            Print("GUARDRAIL: Daily loss limit reached. Loss today = ", DoubleToString(dailyLossPercent, 2),
                  "% (limit ", DoubleToString(InpMaxDailyLossPercent, 2), "%). No new trades until the next day.");
           }

         return(false);
        }
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Calculates a lot size so a stop-out loses riskPercent of the     |
//| account balance                                                   |
//| (riskPercent = InpRiskPercent x the regime risk multiplier)      |
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
     {
      //--- V2: skip the trade instead of forcing the minimum lot (forcing it would risk MORE than riskPercent)
      if(InpSkipTradeIfBelowMinLot && !InpReplicateV1Behavior)
        {
         Print("GUARDRAIL: Risk-based lot ", DoubleToString(rawLotSize, 4), " is below the broker minimum lot ",
               DoubleToString(minLot, 4), ". Trade skipped (risk used = ", DoubleToString(riskPercent, 2), "%).");
         return(0.0);
        }

      //--- V1 behavior: force the minimum lot
      normalizedLotSize = minLot;
     }

   if(normalizedLotSize > maxLot)
      normalizedLotSize = maxLot;

   return(normalizedLotSize);
  }

//+------------------------------------------------------------------+
//| Runs the pre-trade checks that depend on the stop distance and   |
//| calculates the final lot size.                                   |
//| Returns false when the trade must be skipped.                    |
//+------------------------------------------------------------------+
bool PrepareEntrySizing(const double stopLossDistance,
                        double       &lotSize,
                        double       &riskPercentUsed,
                        double       &regimeMultiplier)
  {
   //--- Check 1: the regime risk multiplier (0.0 means "no new trades in this regime")
   regimeMultiplier = GetRegimeRiskMultiplier();

   if(regimeMultiplier <= 0.0)
     {
      Print("Entry skipped: risk multiplier for regime ", VolRegimeToString(ExtVolRegime), " is 0.0.");
      return(false);
     }

   //--- Check 2: spread filter, relative to the stop distance so it adapts to the current volatility
   if(InpMaxSpreadToStopRatio > 0.0 && !InpReplicateV1Behavior)
     {
      double spreadPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(spreadPrice > stopLossDistance * InpMaxSpreadToStopRatio)
        {
         Print("GUARDRAIL: Entry skipped, spread ", DoubleToString(spreadPrice / _Point, 0),
               " points is larger than ", DoubleToString(InpMaxSpreadToStopRatio * 100.0, 0),
               "% of the stop distance (", DoubleToString(stopLossDistance / _Point, 0), " points).");
         return(false);
        }
     }

   //--- Check 3: risk percentage after the regime multiplier, then the lot size
   riskPercentUsed = InpRiskPercent * regimeMultiplier;

   lotSize = CalculateLotSize(stopLossDistance, riskPercentUsed);
   if(lotSize <= 0.0)
      return(false);

   return(true);
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

   double lotSize          = 0.0;
   double riskPercentUsed  = 0.0;
   double regimeMultiplier = 1.0;

   if(!PrepareEntrySizing(stopLossDistance, lotSize, riskPercentUsed, regimeMultiplier))
     {
      Print("Long entry skipped (see the message above).");
      return;
     }

   bool result = ExtTrade.Buy(lotSize, _Symbol, askPrice, stopLossPrice, takeProfitPrice, InpTradeComment);

   if(!result)
     {
      Print("ERROR: Buy order failed. Return code = ", ExtTrade.ResultRetcode(), " - ", ExtTrade.ResultRetcodeDescription());
     }
   else
     {
      Print("Long position opened. Lot size = ", lotSize, " | SL = ", stopLossPrice, " | TP = ", takeProfitPrice,
            " | Regime = ", VolRegimeToString(ExtVolRegime), " | Risk used = ", DoubleToString(riskPercentUsed, 2), "%");

      LogEntryToCsv("BUY", lotSize, riskPercentUsed, regimeMultiplier, atrValue, stopLossDistance);
     }
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

   double lotSize          = 0.0;
   double riskPercentUsed  = 0.0;
   double regimeMultiplier = 1.0;

   if(!PrepareEntrySizing(stopLossDistance, lotSize, riskPercentUsed, regimeMultiplier))
     {
      Print("Short entry skipped (see the message above).");
      return;
     }

   bool result = ExtTrade.Sell(lotSize, _Symbol, bidPrice, stopLossPrice, takeProfitPrice, InpTradeComment);

   if(!result)
     {
      Print("ERROR: Sell order failed. Return code = ", ExtTrade.ResultRetcode(), " - ", ExtTrade.ResultRetcodeDescription());
     }
   else
     {
      Print("Short position opened. Lot size = ", lotSize, " | SL = ", stopLossPrice, " | TP = ", takeProfitPrice,
            " | Regime = ", VolRegimeToString(ExtVolRegime), " | Risk used = ", DoubleToString(riskPercentUsed, 2), "%");

      LogEntryToCsv("SELL", lotSize, riskPercentUsed, regimeMultiplier, atrValue, stopLossDistance);
     }
  }

//+------------------------------------------------------------------+
//| TRADE LOG: create the CSV file with a header row if it is empty  |
//+------------------------------------------------------------------+
void InitTradeLog()
  {
   int fileHandle = OpenTradeLogForAppend();
   if(fileHandle == INVALID_HANDLE)
      return;

   //--- an empty file needs the header row
   if(FileSize(fileHandle) == 0)
     {
      FileWrite(fileHandle,
                "run_tag", "event", "time", "position_id", "direction", "lot",
                "risk_pct_used", "regime_multiplier", "vol_regime", "vol_percentile", "vol_ratio",
                "atr", "sl_distance", "spread_points",
                "exit_reason", "profit", "commission", "swap");
     }

   FileClose(fileHandle);

   Print("Trade log file: ", TerminalInfoString(TERMINAL_COMMONDATA_PATH), "\\Files\\", InpTradeLogFileName);
  }

//+------------------------------------------------------------------+
//| TRADE LOG: open the CSV file and move to the end (append mode)   |
//| Returns INVALID_HANDLE if the file cannot be opened.             |
//+------------------------------------------------------------------+
int OpenTradeLogForAppend()
  {
   int fileHandle = FileOpen(InpTradeLogFileName, FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');

   if(fileHandle == INVALID_HANDLE)
     {
      Print("WARNING: Could not open the trade log file ", InpTradeLogFileName, ". Error code = ", GetLastError());
      return(INVALID_HANDLE);
     }

   FileSeek(fileHandle, 0, SEEK_END);
   return(fileHandle);
  }

//+------------------------------------------------------------------+
//| TRADE LOG: one ENTRY row (regime, sizing and volatility context) |
//+------------------------------------------------------------------+
void LogEntryToCsv(const string direction,
                   const double lotSize,
                   const double riskPercentUsed,
                   const double regimeMultiplier,
                   const double atrValue,
                   const double stopLossDistance)
  {
   if(!InpEnableTradeLog)
      return;

   //--- the position id links this ENTRY row with the EXIT row written later
   ulong dealTicket = ExtTrade.ResultDeal();
   long  positionId = 0;

   if(dealTicket > 0 && HistoryDealSelect(dealTicket))
      positionId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   else
      positionId = (long)ExtTrade.ResultOrder();   // fallback: on hedging accounts the position id equals the opening order ticket

   double spreadPoints = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;

   int fileHandle = OpenTradeLogForAppend();
   if(fileHandle == INVALID_HANDLE)
      return;

   FileWrite(fileHandle,
             InpTradeLogRunTag,
             "ENTRY",
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             IntegerToString(positionId),
             direction,
             DoubleToString(lotSize, 3),
             DoubleToString(riskPercentUsed, 3),
             DoubleToString(regimeMultiplier, 2),
             VolRegimeToString(ExtVolRegime),
             DoubleToString(ExtVolPercentile, 1),
             DoubleToString(ExtVolRatio, 3),
             DoubleToString(atrValue, _Digits),
             DoubleToString(stopLossDistance, _Digits),
             DoubleToString(spreadPoints, 0),
             "", "", "", "");

   FileClose(fileHandle);
  }

//+------------------------------------------------------------------+
//| TRADE LOG: text for the reason a position was closed             |
//+------------------------------------------------------------------+
string DealReasonToString(const long dealReason)
  {
   if(dealReason == DEAL_REASON_SL)
      return("SL");

   if(dealReason == DEAL_REASON_TP)
      return("TP");

   if(dealReason == DEAL_REASON_SO)
      return("STOP_OUT");

   if(dealReason == DEAL_REASON_EXPERT)
      return("EXPERT");

   if(dealReason == DEAL_REASON_CLIENT)
      return("MANUAL");

   return("OTHER_" + IntegerToString(dealReason));
  }

//+------------------------------------------------------------------+
//| TRADE LOG: one EXIT row (result of the closed position)          |
//| Join it to the ENTRY row with the same run_tag + position_id.    |
//| Note: some brokers charge commission on the ENTRY deal, which is |
//| not included in the commission column of the EXIT row.           |
//+------------------------------------------------------------------+
void LogExitToCsv(const ulong dealTicket)
  {
   long     positionId   = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   datetime dealTime     = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
   double   dealVolume   = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
   double   dealProfit   = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   double   dealComm     = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
   double   dealSwap     = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
   long     dealReason   = HistoryDealGetInteger(dealTicket, DEAL_REASON);

   int fileHandle = OpenTradeLogForAppend();
   if(fileHandle == INVALID_HANDLE)
      return;

   FileWrite(fileHandle,
             InpTradeLogRunTag,
             "EXIT",
             TimeToString(dealTime, TIME_DATE | TIME_SECONDS),
             IntegerToString(positionId),
             "",
             DoubleToString(dealVolume, 3),
             "", "", "", "", "", "", "", "",
             DealReasonToString(dealReason),
             DoubleToString(dealProfit, 2),
             DoubleToString(dealComm, 2),
             DoubleToString(dealSwap, 2));

   FileClose(fileHandle);
  }
//+------------------------------------------------------------------+
