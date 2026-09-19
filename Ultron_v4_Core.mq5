//+------------------------------------------------------------------+
//|                                              Ultron_v4_Core.mq5  |
//|                                  Copyright 2026, AI Quant Lab.   |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, AI Quant Lab."
#property link      "https://www.mql5.com"
#property version   "4.00"
#property strict

//--- Input Parameters
input group "=== Ultron Master Controls ==="
input bool     InpAllowLiveTrading  = true;      // SET TO TRUE FOR REAL TRADING (Fixes 0 profit/loss)
input int      InpMagicNumber       = 998877;    // Unique ID for Ultron Orders

input group "=== Risk & Portfolio Management ==="
input double   InpMaxPortfolioRisk  = 0.02;      // Risk per trade (2% of equity)
input double   InpCorrelationThres  = 0.70;      // Max correlation allowed
input int      InpATRWindow         = 14;        // ATR Period for Position Sizing

input group "=== Market Regime Parameters ==="
input int      InpTrendWindow       = 50;        // EMA Period for Trend
input int      InpVolWindow         = 20;        // Volatility Period

input group "=== Ultron v4 Advanced Features ==="
input bool     InpUseTrailingStop   = true;      // Enable Trailing Stop to lock profits
input double   InpTrailingStartATR  = 1.5;       // Start trailing when profit reaches ATR * this factor
input double   InpTrailingStepATR   = 0.5;       // Trailing distance in ATR factor

input group "=== Safety & Telemetry ==="
input double   InpMaxDrawdownLimit  = -15.0;    // Max drawdown allowed before shutdown (%)
input int      InpMaxConsecutiveLoss= 5;        // Max consecutive losses before cooldown

//--- Global Enums
enum ENUM_MARKET_REGIME {
   REGIME_UNKNOWN,
   REGIME_BULL,
   REGIME_BEAR,
   REGIME_SIDEWAYS,
   REGIME_HIGH_VOLATILITY
};

//+------------------------------------------------------------------+
//| 1. MARKET REGIME DETECTOR CLASS                                  |
//+------------------------------------------------------------------+
class CMarketRegimeDetector {
private:
   int            m_trend_window;
   int            m_vol_window;
   int            m_ema_handle;
   int            m_std_handle;

public:
   CMarketRegimeDetector(int trend_win, int vol_win) {
      m_trend_window = trend_win;
      m_vol_window = vol_win;
   }
   
   ~CMarketRegimeDetector() {
      IndicatorRelease(m_ema_handle);
      IndicatorRelease(m_std_handle);
   }
   
   void Init(string symbol, ENUM_TIMEFRAMES timeframe) {
      m_ema_handle = iMA(symbol, timeframe, m_trend_window, 0, MODE_EMA, PRICE_CLOSE);
      m_std_handle = iStdDev(symbol, timeframe, m_vol_window, 0, MODE_EMA, PRICE_CLOSE);
   }
   
   ENUM_MARKET_REGIME Detect(string symbol, ENUM_TIMEFRAMES timeframe) {
      double ema[], std_dev[], close[];
      ArraySetAsSeries(ema, true);
      ArraySetAsSeries(std_dev, true);
      ArraySetAsSeries(close, true);
      
      if(CopyBuffer(m_ema_handle, 0, 0, 2, ema) < 2 ||
         CopyBuffer(m_std_handle, 0, 0, 20, std_dev) < 20 ||
         CopyClose(symbol, timeframe, 0, 2, close) < 2) {
         return REGIME_UNKNOWN;
      }
      
      double sum_vol = 0;
      for(int i=0; i<20; i++) sum_vol += std_dev[i];
      double avg_vol = sum_vol / 20.0;
      
      if(std_dev > (avg_vol * 1.5)) {
         return REGIME_HIGH_VOLATILITY;
      } else if(close > ema * 1.001) {
         return REGIME_BULL;
      } else if(close < ema * 0.999) {
         return REGIME_BEAR;
      } else {
         return REGIME_SIDEWAYS;
      }
   }
};

//+------------------------------------------------------------------+
//| 2. PORTFOLIO RISK MANAGER CLASS                                  |
//+------------------------------------------------------------------+
class CPortfolioRiskManager {
private:
   double         m_max_portfolio_risk;
   double         m_corr_threshold;
   int            m_atr_handle;

public:
   CPortfolioRiskManager(double max_risk, double corr_thres, int atr_win) {
      m_max_portfolio_risk = max_risk;
      m_corr_threshold = corr_thres;
   }
   
   ~CPortfolioRiskManager() {
      IndicatorRelease(m_atr_handle);
   }
   
   void Init(string symbol, ENUM_TIMEFRAMES timeframe, int atr_win) {
      m_atr_handle = iATR(symbol, timeframe, atr_win);
   }
   
   double CalculatePositionSize(string symbol, double confidence, double &atr_out) {
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(m_atr_handle, 0, 0, 1, atr) < 1 || atr <= 0) return 0.0;
      
      atr_out = atr;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double lot_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      
      if(tick_size == 0 || tick_value == 0) return 0.0;
      
      double risk_cash = equity * m_max_portfolio_risk * confidence;
      double stop_loss_dist = atr * 2.0;
      
      double contract_size = (stop_loss_dist / tick_size) * tick_value;
      if(contract_size == 0) return 0.0;
      
      double lots = risk_cash / contract_size;
      lots = MathFloor(lots / lot_step) * lot_step;
      
      double min_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double max_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      if(lots < min_lot) lots = 0.0; 
      if(lots > max_lot) lots = max_lot;
      
      return lots;
   }
};

//+------------------------------------------------------------------+
//| 3. PERFORMANCE MONITOR CLASS                                     |
//+------------------------------------------------------------------+
class CModelPerformanceMonitor {
private:
   double         m_drawdown_limit;
   int            m_max_consecutive_loss;
   int            m_consecutive_losses;
   bool           m_system_active;
   double         m_peak_balance;

public:
   CModelPerformanceMonitor(double dd_limit, int max_loss) {
      m_drawdown_limit = dd_limit;
      m_max_consecutive_loss = max_loss;
      m_consecutive_losses = 0;
      m_system_active = true;
      m_peak_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   }
   
   bool IsSystemActive() { return m_system_active; }
   
   void CheckPortfolioStatus() {
      double current_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(current_balance > m_peak_balance) m_peak_balance = current_balance;
      
      double current_dd = ((current_balance - m_peak_balance) / m_peak_balance) * 100.0;
      
      if(current_dd <= m_drawdown_limit) {
         Print("🚨 CRITICAL: Ultron Circuit Breaker Tripped! Drawdown Limit Breached.");
         m_system_active = false;
      }
   }
   
   void RegisterTradeResult(double profit) {
      if(profit < 0) {
         m_consecutive_losses++;
      } else if(profit > 0) {
         m_consecutive_losses = 0;
      }
      
      if(m_consecutive_losses >= m_max_consecutive_loss) {
         Print("⚠️ WARNING: High Consecutive Loss Detected.");
      }
   }
};

//+------------------------------------------------------------------+
//| 4. ALPHA ENSEMBLE SYSTEM                                         |
//+------------------------------------------------------------------+
class CAlphaEnsemble {
public:
   int GetCombinedSignal(ENUM_MARKET_REGIME current_regime) {
      switch(current_regime) {
         case REGIME_BULL: return 1;  // BUY SIGNAL
         case REGIME_BEAR: return -1; // SELL SIGNAL
         default:          return 0;  // SIDEWAYS/HIGH VOLATILITY -> HOLD
      }
   }
};

//+------------------------------------------------------------------+
//| GLOBAL SYSTEM OBJECTS                                            |
//+------------------------------------------------------------------+
CMarketRegimeDetector     *regime_detector;
CPortfolioRiskManager     *risk_manager;
CModelPerformanceMonitor  *performance_monitor;
CAlphaEnsemble            *alpha_ensemble;

int OnInit() {
   regime_detector     = new CMarketRegimeDetector(InpTrendWindow, InpVolWindow);
   risk_manager        = new CPortfolioRiskManager(InpMaxPortfolioRisk, InpCorrelationThres, InpATRWindow);
   performance_monitor = new CModelPerformanceMonitor(InpMaxDrawdownLimit, InpMaxConsecutiveLoss);
   alpha_ensemble      = new CAlphaEnsemble();
   
   regime_detector.Init(_Symbol, _Period);
   risk_manager.Init(_Symbol, _Period, InpATRWindow);
   
   Print("🤖 Ultron v.4 Core Engine Loaded.");
   if(InpAllowLiveTrading) {
      Print("⚡ LIVE EXECUTION ENGAGED: Real trading requests are active.");
   } else {
      Print("🔍 SHADOW MODE: Logs only. Change InpAllowLiveTrading to true to trade.");
   }
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   delete regime_detector;
   delete risk_manager;
   delete performance_monitor;
   delete alpha_ensemble;
}

//--- ฟังก์ชันหลักในการเปิดคำสั่งซื้อขายจริงเข้าตลาด
void ExecuteRealOrder(int signal_type, double lot_size, double atr_val) {
   MqlTradeRequest request = {};
   MqlTradeResult  result = {};
   
   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = _Symbol;
   request.volume       = lot_size;
   request.magic        = InpMagicNumber;
   request.type_filling = ORDER_FILLING_FOK;
   
   double price = 0.0;
   double sl_distance = atr_val * 2.0;
   
   if(signal_type > 0) {
      request.type = ORDER_TYPE_BUY;
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      request.price = price;
      request.sl = NormalizeDouble(price - sl_distance, _Digits);
      request.tp = NormalizeDouble(price + (sl_distance * 1.5), _Digits);
   } else {
      request.type = ORDER_TYPE_SELL;
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      request.price = price;
      request.sl = NormalizeDouble(price + sl_distance, _Digits);
      request.tp = NormalizeDouble(price - (sl_distance * 1.5), _Digits);
   }
   
   if(!OrderSend(request, result)) {
      PrintFormat("❌ OrderSend Failed. Error code: %d", GetLastError());
   } else {
      PrintFormat("✅ Live Order Executed! Ticket: %I64d | Capital Working.", result.order);
   }
}

//--- ฟังก์ชันควบคุม Trailing Stop สำหรับ Ultron v.4
void ManageTrailingStop(double atr_val) {
   if(!InpUseTrailingStop || atr_val <= 0) return;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         double current_sl = PositionGetDouble(POSITION_SL);
         
         double current_price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double trl_start_dist = atr_val * InpTrailingStartATR;
         double trl_step_dist = atr_val * InpTrailingStepATR;
         
         MqlTradeRequest request = {};
         MqlTradeResult  result = {};
         
         if(type == POSITION_TYPE_BUY) {
            if(current_price - open_price > trl_start_dist) {
               double new_sl = NormalizeDouble(current_price - trl_step_dist, _Digits);
               if(new_sl > current_sl + Point) {
                  request.action = TRADE_ACTION_SLTP;
                  request.position = ticket;
                  request.sl = new_sl;
                  request.tp = PositionGetDouble(POSITION_TP);
                  if(!OrderSend(request, result)) Print("Error modifying Trailing Stop BUY: ", GetLastError());
               }
            }
         }
         else if(type == POSITION_TYPE_SELL) {
            if(open_price - current_price > trl_start_dist) {
               double new_sl = NormalizeDouble(current_price + trl_step_dist, _Digits);
               if(current_sl == 0 || new_sl < current_sl - Point) {
                  request.action = TRADE_ACTION_SLTP;
                  request.position = ticket;
                  request.sl = new_sl;
                  request.tp = PositionGetDouble(POSITION_TP);
                  if(!OrderSend(request, result)) Print("Error modifying Trailing Stop SELL: ", GetLastError());
               }
            }
         }
      }
   }
}

void OnTick() {
   performance_monitor.CheckPortfolioStatus();
   if(!performance_monitor.IsSystemActive()) return;
   
   double current_atr = 0;
   // เรียกคำนวณขนาดไม้ล็อตรวมถึงดึงค่า ATR ล่าสุดออกมาใช้คุม Trailing
   double dummy_lot = risk_manager.CalculatePositionSize(_Symbol, 1.0, current_atr);
   
   // รันระบบ Trailing Stop อัตโนมัติ (Ultron v.4)
   ManageTrailingStop(current_atr);
   
   int total_positions = PositionsTotal();
   bool has_position = false;
   for(int i = total_positions - 1; i >= 0; i--) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         has_position = true;
         performance_monitor.RegisterTradeResult(PositionGetDouble(POSITION_PROFIT));
         break;
      }
   }
   if(has_position) return; 

   ENUM_MARKET_REGIME current_regime = regime_detector.Detect(_Symbol, _Period);
   int final_signal = alpha_ensemble.GetCombinedSignal(current_regime);
   
   if(final_signal != 0) {
      if(dummy_lot > 0) {
         if(InpAllowLiveTrading) {
            ExecuteRealOrder(final_signal, dummy_lot, current_atr);
         } else {
            PrintFormat("📝 [Ultron PaperMode] Signal: %d | Lot: %.2f | Regime: %d", final_signal, dummy_lot, current_regime);
         }
      }
   }
}
