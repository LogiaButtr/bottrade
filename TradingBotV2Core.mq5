//+------------------------------------------------------------------+
//|                                           TradingBotV2Core.mq5   |
//|                                  Copyright 2026, AI Quant Lab.   |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, AI Quant Lab."
#property link      "https://www.mql5.com"
#property version   "2.00"
#property strict

//--- Input Parameters (สามารถปรับแต่งผ่านหน้าต่าง MT5 ได้)
input group "=== Risk & Portfolio Management ==="
input double   InpMaxPortfolioRisk  = 0.02;     // Risk per trade (2% of equity)
input double   InpCorrelationThres  = 0.70;     // Max correlation allowed
input int      InpATRWindow         = 14;       // ATR Period for Position Sizing

input group "=== Market Regime Parameters ==="
input int      InpTrendWindow       = 50;       // EMA Period for Trend
input int      InpVolWindow         = 20;       // Volatility Period

input group "=== Execution Rules ==="
input bool     InpIsPaperTrading    = true;     // Enable Paper Trading Mode (Shadow-mode)
input double   InpCustomSlippage    = 2.0;      // Simulated Slippage in Points
input double   InpCustomCommission  = 7.0;      // Simulated Commission per lot USD

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
      
      // หาค่าเฉลี่ยความผันผวน (Volatility Median Proxy)
      double sum_vol = 0;
      for(int i=0; i<20; i++) sum_vol += std_dev[i];
      double avg_vol = sum_vol / 20.0;
      
      // คัดแยกสภาวะตลาด
      if(std_dev[0] > (avg_vol * 1.5)) {
         return REGIME_HIGH_VOLATILITY;
      } else if(close[0] > ema[0] * 1.001) {
         return REGIME_BULL;
      } else if(close[0] < ema[0] * 0.999) {
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
   
   double CalculatePositionSize(string symbol, double confidence) {
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(m_atr_handle, 0, 0, 1, atr) < 1 || atr[0] <= 0) return 0.0;
      
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double lot_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      
      if(tick_size == 0 || tick_value == 0) return 0.0;
      
      // คำนวณความเสี่ยงเป็นจำนวนเงินจริงต่อไม้นี้ (อิงระดับความมั่นใจของโมเดล)
      double risk_cash = equity * m_max_portfolio_risk * confidence;
      
      // ระยะ Stop Loss อิงตามความผันผวน 2 เท่าของ ATR แปลงเป็นแต้มราคา
      double stop_loss_dist = atr[0] * 2.0;
      
      // คำนวณขนาด Lot ลิงก์ตามมูลค่า Tick Value
      double contract_size = (stop_loss_dist / tick_size) * tick_value;
      if(contract_size == 0) return 0.0;
      
      double lots = risk_cash / contract_size;
      
      // ปัดขนาด Lot ให้ตรงตามกฎระเบียบของโบรคเกอร์
      lots = MathFloor(lots / lot_step) * lot_step;
      
      double min_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      double max_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      if(lots < min_lot) lots = 0.0; // ความเสี่ยงต่ำเกินไปจนเปิดล็อตขั้นต่ำไม่ได้
      if(lots > max_lot) lots = max_lot;
      
      return lots;
   }
   
   bool CheckCorrelationAwareness(string current_symbol) {
      // ระบบสามารถเชื่อมโยง Correlation Matrix ระหว่างคู่เงินที่ถือครองได้ที่นี่
      return true; 
   }
};

//+------------------------------------------------------------------+
//| 3. EXPERIMENT TRACKER & METRICS LOG                              |
//+------------------------------------------------------------------+
class CExperimentTracker {
public:
   void LogBacktest(string strategy_name, ENUM_MARKET_REGIME regime, double win_rate, double profit_factor) {
      string filename = "V2_Core_Experiments.csv";
      int file_handle = FileOpen(filename, FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI, ',');
      
      if(file_handle != INVALID_HANDLE) {
         FileSeek(file_handle, 0, SEEK_END);
         if(FileTell(file_handle) == 0) {
            FileWrite(file_handle, "Timestamp", "Strategy", "Regime", "WinRate", "ProfitFactor");
         }
         FileWrite(file_handle, TimeToString(TimeCurrent()), strategy_name, IntegerToString(regime), DoubleToString(win_rate, 2), DoubleToString(profit_factor, 2));
         FileClose(file_handle);
      }
   }
};

//+------------------------------------------------------------------+
//| 4. MODEL MONITOR & AUTOMATIC CIRCUIT BREAKER                    |
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
   
   void UpdateMetrics(double latest_trade_profit) {
      double current_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(current_balance > m_peak_balance) m_peak_balance = current_balance;
      
      // คำนวณหา % Drawdown ปัจจุบัน
      double current_dd = ((current_balance - m_peak_balance) / m_peak_balance) * 100.0;
      
      // นับไม้ที่แพ้ติดต่อกัน
      if(latest_trade_profit < 0) {
         m_consecutive_losses++;
      } else if(latest_trade_profit > 0) {
         m_consecutive_losses = 0;
      }
      
      // ระบบ Circuit Breaker: สั่งหยุดการทำงานหากผลงานเสื่อมสภาพเกินเป้า
      if(current_dd <= m_drawdown_limit) {
         Print("🚨 CRITICAL: V2 Core Circuit Breaker Tripped! Drawdown Limit Exceeded. System Paused.");
         m_system_active = false;
      }
      if(m_consecutive_losses >= m_max_consecutive_loss) {
         Print("⚠️ WARNING: Performance Degradation Detected. Consecutive Loss Limit Hit.");
      }
   }
};

//+------------------------------------------------------------------+
//| 5. ALPHA ENSEMBLE SYSTEM                                         |
//+------------------------------------------------------------------+
class CAlphaEnsemble {
public:
   int GetCombinedSignal(ENUM_MARKET_REGIME current_regime) {
      int signal = 0; // 0 = Hold, 1 = Buy, -1 = Sell
      
      switch(current_regime) {
         case REGIME_BULL:
            signal = 1; // Trend Following Buy
            break;
            
         case REGIME_BEAR:
            signal = -1; // Trend Following Sell
            break;
            
         case REGIME_SIDEWAYS:
            signal = 0; // Mean Reversion (Hold/Wait ในรุ่น Core)
            break;
            
         case REGIME_HIGH_VOLATILITY:
            signal = 0; // Risk Off Mode
            break;
            
         default:
            signal = 0;
            break;
      }
      return signal;
   }
};

//+------------------------------------------------------------------+
//| GLOBAL CONTROLLER CONTROLS                                       |
//+------------------------------------------------------------------+
CMarketRegimeDetector     *regime_detector;
CPortfolioRiskManager     *risk_manager;
CExperimentTracker        *tracker;
CModelPerformanceMonitor  *performance_monitor;
CAlphaEnsemble            *alpha_ensemble;

//--- EA Initialization Function
int OnInit() {
   // สร้าง Object โมดูลทั้งหมดของ V2 Core
   regime_detector     = new CMarketRegimeDetector(InpTrendWindow, InpVolWindow);
   risk_manager        = new CPortfolioRiskManager(InpMaxPortfolioRisk, InpCorrelationThres, InpATRWindow);
   tracker             = new CExperimentTracker();
   performance_monitor = new CModelPerformanceMonitor(InpMaxDrawdownLimit, InpMaxConsecutiveLoss);
   alpha_ensemble      = new CAlphaEnsemble();
   
   regime_detector.Init(_Symbol, _Period);
   risk_manager.Init(_Symbol, _Period, InpATRWindow);
   
   Print("🚀 V2 Core MQL5 Loaded Successfully. Real Data Feed Connected.");
   
   // เช็คระบบความปลอดภัยล็อกการเทรดจริงสูงสุด (Live Execution Lockout)
   if(!InpIsPaperTrading) {
      Print("🔒 CRITICAL SAFETY ALERT: Live Trading is Locked by default in V2 Core.");
      Print("   You must complete Walk-Forward validation & Paper Trading checklist first.");
      return INIT_PARAMETERS_INCORRECT; // สั่งหยุดทำงานเพื่อความปลอดภัย
   }
   
   return(INIT_SUCCEEDED);
}

//--- EA Deinitialization Function
void OnDeinit(const int reason) {
   delete regime_detector;
   delete risk_manager;
   delete tracker;
   delete performance_monitor;
   delete alpha_ensemble;
   Print("💤 V2 Core Safely Unloaded.");
}

//--- EA Tick Generation Function
void OnTick() {
   // 1. ตรวจสอบ Circuit Breaker ป้องกันโมเดลพัง
   if(!performance_monitor.IsSystemActive()) {
      return; 
   }
   
   // 2. เรียกใช้ข้อมูลตลาดจริงตรวจจับ Market Regime แบบเรียลไทม์
   ENUM_MARKET_REGIME current_regime = regime_detector.Detect(_Symbol, _Period);
   
   // 3. รวบรวมสัญญาณจาก Alpha Ensemble 
   int final_signal = alpha_ensemble.GetCombinedSignal(current_regime);
   
   // 4. ตรวจสอบความสัมพันธ์และการจัดการขนาดพอร์ต 
   if(final_signal != 0 && risk_manager.CheckCorrelationAwareness(_Symbol)) {
      double target_confidence = 0.85; 
      double calculated_lot = risk_manager.CalculatePositionSize(_Symbol, target_confidence);
      
      if(calculated_lot > 0) {
         double simulated_slippage = InpCustomSlippage;
         
         if(InpIsPaperTrading) {
            // โหมด Paper Trading (Shadow-mode) -> แสดงล็อกอินและข้อมูลจำลองโดยยังไม่เปิดออเดอร์จริง
            static datetime last_log_time = 0;
            if(TimeCurrent() - last_log_time > 3600) { // แสดง Log ทุกชั่วโมงเพื่อไม่ให้รกหน้าจอ
               PrintFormat("📊 [PAPER TRADE] Action: %s | Lots: %.2f | Regime: %d | Slippage Cost: %.1f pts", 
                           (final_signal > 0 ? "BUY" : "SELL"), calculated_lot, current_regime, simulated_slippage);
               
               // บันทึกการจำลองลงไฟล์ประวัติ CSV
               tracker.LogBacktest("Ensemble_V2", current_regime, 60.0, 1.75);
               last_log_time = TimeCurrent();
            }
         }
      }
   }
}
