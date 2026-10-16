//+------------------------------------------------------------------+
//|                                              DidinskaGridV2.mq5   |
//|   Expert Advisor Grid Trading XAUUSD + 10 AI Analis + AI Penyimpul |
//|                  Didinska Grid V2  -  versi 2.00                   |
//+------------------------------------------------------------------+
// RINGKASAN PERUBAHAN v2.00 (bahasa sederhana):
//   RISIKO
//     - Risiko BASKET: total risiko 1 grid dibatasi (InpMaxBasketRiskPct),
//       bukan cuma per-order. Jumlah layer per sisi dibatasi.
//     - Cooldown setelah N basket rugi beruntun.
//     - Peak equity & balance awal hari DISIMPAN (GlobalVariable), jadi
//       restart EA tidak menghapus ingatan drawdown.
//     - Saat halt, EA terus berusaha menutup sisa posisi sampai bersih.
//   BERITA & WAKTU
//     - Filter berita pakai Kalender Ekonomi MT5 (tanpa WebRequest).
//       BLACKOUT = hapus pending + larang grid baru di sekitar berita HIGH.
//     - Filter rollover, penundaan buka Senin, dan proteksi Jumat.
//   EKSEKUSI
//     - Hasil BuyStop/SellStop dicek, stops level dipatuhi, harga
//       dinormalisasi, pending punya masa kedaluwarsa.
//     - Jarak grid berbasis ATR (bukan poin tetap).
//     - Trailing tidak spam PositionModify; trailing/BE SELALU jalan
//       walau spread melebar.
//     - Siklus AI tidak dijalankan saat ada posisi live (EA tidak
//       "membeku" menunggu WebRequest saat posisi perlu dikelola).
//   AI
//     - Mode PROXY (Cloudflare Worker): 10 analis dipanggil paralel.
//     - Native Engine sebagai gerbang (veto) dan pembanding akurasi.
//     - Jurnal keputusan + evaluasi akurasi (file CSV) + laporan harian.
//+------------------------------------------------------------------+
#property copyright "Didinska Grid V2"
#property link      ""
#property version   "2.03"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include "Include\GroqClient.mqh"
#include "Include\MarketData.mqh"
#include "Include\Analysts.mqh"
#include "Include\AISummarizer.mqh"
#include "Include\NativeDecisionEngine.mqh"
#include "Include\NewsFilter.mqh"
#include "Include\DecisionJournal.mqh"
#include "Include\TelegramNotify.mqh"

//+------------------------------------------------------------------+
//| Mode Analisa: AI (Groq) atau Native (tanpa API, untuk backtest)     |
//+------------------------------------------------------------------+
enum ENUM_EA_MODE
{
   MODE_AI_ON  = 0,   // Pakai 10 AI analis + AI Penyimpul (butuh internet/WebRequest)
   MODE_AI_OFF = 1    // Analisa native 9 domain teknikal, TANPA API - cocok untuk backtest
};

//+------------------------------------------------------------------+
//| Gerbang Native untuk keputusan AI (hanya berlaku di AI ON)          |
//+------------------------------------------------------------------+
enum ENUM_NATIVE_GATE
{
   NGATE_OFF            = 0,   // Nonaktif - AI bebas menentukan
   NGATE_BLOCK_OPPOSITE = 1,   // Veto kalau Native berlawanan arah dengan AI
   NGATE_REQUIRE_AGREE  = 2    // Wajib searah (Native WAIT/lawan -> AI di-veto)
};

//+------------------------------------------------------------------+
//| EA Inputs                                                          |
//+------------------------------------------------------------------+
input group "--- Mode Analisa ---"
input ENUM_EA_MODE     InpMode        = MODE_AI_ON;          // AI ON = pakai Groq; AI OFF = native, tanpa API (wajib untuk backtest)
input ENUM_NATIVE_GATE InpNativeGate  = NGATE_BLOCK_OPPOSITE; // Gerbang Native untuk keputusan AI

input group "--- Native Mode - Kalibrasi Sinyal (berlaku saat MODE_AI_OFF / gerbang) ---"
input double   InpADXTrendThreshold    = 20.0;  // ADX minimum dianggap trending (di bawah ini = ranging, WAIT paksa)
input double   InpHighConfidenceThreshold = 0.75; // Di atas ini, grid cuma pasang 1 sisi (+1 hedge lot minimum)

input group "--- Ambang Keyakinan (berlaku AI ON maupun AI OFF) ---"
input double   InpMinProbability       = 0.65;  // Probabilitas minimum sebelum grid boleh dibuka

input group "--- Target Ekspansi Volatilitas (sesuai cara grid untung) ---"
input bool     InpUseExpansionGate   = true;   // AI ON: grid hanya dibuka kalau peluang ekspansi cukup
input double   InpExpansionATRMult   = 1.5;    // Definisi ekspansi: harga menjauh >= N x ATR (ke arah mana pun)
input double   InpMinExpansionProb   = 0.50;   // Peluang ekspansi minimum agar grid boleh dibuka
input bool     InpAllowSymmetricGrid = false;  // Izinkan grid 2 sisi saat arah WAIT tapi ekspansi tinggi (UJI dulu di demo)
input double   InpSymmetricExpansionProb = 0.65; // Ambang ekspansi untuk grid simetris

input group "--- AI - PROXY Cloudflare Worker (DISARANKAN) ---"
input string   InpProxyUrl             = "";    // URL Worker, contoh https://ea-proxy.namamu.workers.dev (kosong = pakai key langsung di bawah)
input string   InpProxyToken           = "";    // Token rahasia (sama dengan secret EA_TOKEN di Worker)

input group "--- AI - POOL BANYAK API KEY Groq LANGSUNG (cadangan Proxy / tanpa Worker) ---"
input string   InpApiKeyPool         = "";               // key1,key2,key3,... (dipisah koma). Dirotasi otomatis, key mati/saldo habis dilewati
input string   InpApiKeyFile         = "groq_keys.txt";  // File di MQL5\Files berisi key (koma/baris baru). Untuk puluhan-ratusan key. Kosongkan kalau tidak dipakai

input group "--- AI - 12 Slot API Key Groq LANGSUNG (cara lama; kosongkan kalau pakai Proxy/Pool) ---"
input string   InpApiKey_Analyst1    = "";  // Slot 1: AI Analis #1 - Trend
input string   InpApiKey_Analyst2    = "";  // Slot 2: AI Analis #2 - Momentum
input string   InpApiKey_Analyst3    = "";  // Slot 3: AI Analis #3 - Volatilitas
input string   InpApiKey_Analyst4    = "";  // Slot 4: AI Analis #4 - Volume
input string   InpApiKey_Analyst5    = "";  // Slot 5: AI Analis #5 - Support/Resistance
input string   InpApiKey_Analyst6    = "";  // Slot 6: AI Analis #6 - Smart Money Concepts
input string   InpApiKey_Analyst7    = "";  // Slot 7: AI Analis #7 - Price Action + Sesi
input string   InpApiKey_Analyst8    = "";  // Slot 8: AI Analis #8 - Multi-Timeframe
input string   InpApiKey_Analyst9    = "";  // Slot 9: AI Analis #9 - Makro XAUUSD
input string   InpApiKey_Analyst10   = "";  // Slot 10: AI Analis #10 - Risk Management
input string   InpApiKey_Summarizer  = "";  // Slot 11: AI Penyimpul (keputusan final)
input string   InpApiKey_Reserve     = "";  // Slot 12: CADANGAN UNIVERSAL

input group "--- AI - Provider & Model (BISA CUSTOM) ---"
input ENUM_AI_PROVIDER InpAIProvider = AIP_GROQ;   // Provider: Groq / OpenRouter / OpenAI / Anthropic / Custom (FastRouter dll)
input string   InpAIModel            = "openai/gpt-oss-120b"; // Nama model SESUAI provider (mis. claude-haiku-5-5, gpt-4o-mini, openai/gpt-oss-120b)
input string   InpAIBaseUrl          = "";         // Alamat API (kosong = bawaan provider). WAJIB untuk Custom, contoh https://api.contoh.com/v1. Hanya untuk jalur key langsung; di mode Worker alamat diatur di Worker
input double   InpAITemperature      = 0.3;        // Temperature. Isi NEGATIF (mis. -1) kalau model menolak parameter ini (mis. gpt-5 / o-series)
input string   InpAIExtraJson        = "auto";     // Field tambahan request. auto=bawaan provider, kosong=tanpa tambahan, atau potongan JSON tanpa kurung kurawal
input string   InpAITokenParam       = "auto";     // Nama field batas token. auto = max_tokens (OpenAI: max_completion_tokens)

input group "--- AI - Konfigurasi Umum ---"
input int      InpAIAnalysisInterval = 600;    // Interval Siklus Analisa AI Penuh (detik) - default 10 menit
input int      InpAIMaxTokens        = 1500;   // Max token per panggilan AI (JANGAN di bawah 1000 - gpt-oss-120b butuh token utk reasoning+JSON)
input int      InpAITimeoutMs        = 30000;  // Timeout tiap panggilan API (ms)

input group "--- Market Data - Simbol Referensi & Sesi ---"
input ENUM_TIMEFRAMES InpWorkingTF   = PERIOD_M15; // Timeframe kerja utama
input ENUM_TIMEFRAMES InpHigherTF    = PERIOD_H4;  // Timeframe lebih tinggi (MTF alignment)
input string   InpMacroProxySymbol   = "EURUSD";   // Symbol proksi korelasi dolar (kalau DXY tidak tersedia)
input string   InpDxySymbol          = "";         // Symbol Dollar Index broker (kosongkan kalau tidak ada)
input string   InpYieldSymbol        = "";         // Symbol yield obligasi AS di broker, mis. US10Y (kosongkan kalau tidak ada)
input int      InpBrokerGmtOffset    = 2;          // Offset GMT waktu server broker (jam), untuk deteksi sesi

input group "--- Filter Berita (Kalender Ekonomi MT5) ---"
input bool     InpUseNewsFilter      = true;   // Aktifkan Filter Berita (tidak aktif di Strategy Tester)
input string   InpNewsCurrencies     = "USD";  // Mata uang yang dipantau, pisah koma (emas peka terhadap USD)
input int      InpNewsBlackoutBefore = 20;     // BLACKOUT: menit SEBELUM berita HIGH (hapus pending, larang grid baru)
input int      InpNewsBlackoutAfter  = 15;     // BLACKOUT: menit SESUDAH berita HIGH
input int      InpNewsWarnMinutes    = 60;     // WASPADA: menit sebelum berita (lot x0.5, syarat probabilitas naik)

input group "--- Filter Waktu (jam = JAM SERVER BROKER) ---"
input bool     InpAvoidRollover      = true;   // Jangan buka grid sekitar rollover (tengah malam server)
input int      InpRolloverMinutes    = 15;     // Lebar jendela rollover (menit sebelum & sesudah 00:00 server)
input bool     InpBlockSunday        = true;   // Jangan buka grid di hari Minggu (server)
input int      InpMondayDelayMin     = 30;     // Tunda grid N menit pertama Senin (0 = nonaktif)
input bool     InpFridayProtection   = true;   // Aktifkan proteksi akhir pekan
input int      InpFridayStopNewHour  = 20;     // Jumat: setelah jam ini (server) tidak buka grid baru
input int      InpFridayCloseHour    = 22;     // Jumat: setelah jam ini (server) tutup SEMUA posisi & pending

input group "--- Telegram Notifikasi (Satu Arah) ---"
input bool     InpUseTelegramNotify  = true;   // Aktifkan Notifikasi Telegram
input string   InpTelegramBotToken   = "";     // Bot Token Telegram
input string   InpTelegramChatId     = "";     // Chat ID Telegram
input bool     InpDailyReport        = true;   // Kirim laporan harian ke Telegram

input group "--- Grid Mechanics ---"
input bool     InpUseATRGridDistance = true;   // Jarak grid berbasis ATR (disarankan; lintas-broker)
input double   InpGridDistanceATR    = 0.5;    // Jarak dasar grid (x ATR) - dikalikan grid_distance_multiplier dari AI
input int      InpGridDistance       = 300;    // Jarak dasar grid (Poin) - dipakai HANYA kalau ATR grid dimatikan
input int      InpGridOrders         = 2;      // Jumlah dasar pending order per sisi
input int      InpMaxLayersPerSide   = 4;      // BATAS jumlah layer per sisi (membatasi risiko basket)
input int      InpTakeProfit         = 200;    // Take Profit (Poin) - FALLBACK sebelum ada siklus AI
input int      InpStopLoss           = 150;    // Stop Loss (Poin) - FALLBACK sebelum ada siklus AI
input bool     InpDeleteOpposite     = true;   // Batalkan grid sisi lawan saat salah satu ke-trigger
input int      InpPendingExpiryMin   = 60;     // Pending order kedaluwarsa otomatis setelah N menit (0 = tanpa batas)

input group "--- Protection & Trailing (berbasis ATR, bukan poin fixed) ---"
input double   InpBreakEvenTriggerATR = 1.0;   // Pindah ke BE saat profit >= (x ATR)
input double   InpBreakEvenOffsetATR  = 0.2;   // Profit yang dikunci di BE (x ATR)
input double   InpTrailingStartATR    = 2.0;   // Mulai trailing SL saat profit >= (x ATR)
input double   InpTrailingStepATR     = 0.5;   // Ukuran langkah Trailing (x ATR)

input group "--- Risk Management ---"
input double   InpMaxRiskPerTrade    = 1.0;    // Risiko per layer/order (%) - batas ATAS (dipotong otomatis oleh basket)
input double   InpMaxBasketRiskPct   = 2.0;    // BATAS risiko TOTAL 1 grid (%) kalau semua layer 1 sisi kena SL (0 = nonaktif)
input double   InpMaxDailyLossPct    = 10.0;   // Kerugian Harian Maksimum (%)
input double   InpMaxDrawdownPct     = 15.0;   // Floating Drawdown Maksimum (%)
input double   InpMaxDrawdownFromPeakPct = 20.0; // Drawdown Maksimum dari PUNCAK Equity (%) - halt PERMANEN
input bool     InpResetPeakOnInit    = false;  // Set TRUE sekali untuk melanjutkan setelah halt peak drawdown, lalu kembalikan FALSE
input int      InpMaxConsecLosses    = 3;      // Setelah N basket rugi beruntun -> cooldown (0 = nonaktif)
input int      InpLossCooldownMin    = 60;     // Lama cooldown (menit)
input int      InpMaxSpread          = 35;     // Spread Maksimum untuk membuka grid baru (Poin)
input bool     InpDynamicPositionSizing = true; // Gunakan Position Sizing dari AI
input int      InpSlippagePoints     = 30;     // Deviasi/slippage maksimum (Poin)
input ulong    InpMagicNumber        = 990022; // Magic Number EA

input group "--- Jurnal Keputusan AI ---"
input bool     InpEnableJournal      = true;   // Catat keputusan & ukur akurasi (file CSV di MQL5\Files)
input int      InpJournalEvalMin     = 60;     // Evaluasi hasil keputusan setelah N menit

//+------------------------------------------------------------------+
//| Global Engine Variables                                            |
//+------------------------------------------------------------------+
CTrade            m_trade;
CPositionInfo     m_position;
COrderInfo        m_order;
CAccountInfo      m_account;
CNewsFilter       m_news_filter;

CGroqClient       m_groq_client;
CMarketDataEngine m_market_engine;
CAnalystEngine    *m_analyst_engine;
CAISummarizer     *m_ai_summarizer;
CNativeDecisionEngine m_native_engine;
CTelegramNotify   m_telegram;
CDecisionJournal  m_journal;

// State risiko
double            m_start_day_balance = 0.0;
double            m_peak_equity = 0.0;
bool              m_peak_drawdown_halted = false; // TIDAK di-reset harian
int               m_current_day_key = -1;         // tahun*1000 + hari-ke-n
datetime          m_day_start_time = 0;
bool              m_system_halted = false;
datetime          m_last_peak_save = 0;

// Cooldown akibat loss beruntun
int               m_consec_losses = 0;
datetime          m_loss_cooldown_until = 0;
bool              m_basket_active = false;
datetime          m_basket_start = 0;

// Berita & waktu
ENUM_NEWS_FILTER_STATE m_news_state = NFS_CLEAR;
ENUM_NEWS_FILTER_STATE m_prev_news_state = NFS_CLEAR;
string            m_news_title = "";
int               m_news_minutes = 0;
bool              m_news_caution = false;   // true kalau CAUTION atau BLACKOUT (dipakai lot & probabilitas)
bool              m_time_blocked = false;
string            m_time_block_reason = "";

// AI
datetime          m_last_ai_analysis = 0;
bool              m_grid_needs_refresh = false;
datetime          m_next_grid_attempt = 0;
datetime          m_last_journal_eval = 0;
int               m_atr_handle = INVALID_HANDLE;

SMarketSnapshot   m_last_snapshot;
SAnalystOpinion   m_last_opinions[];
SFinalDecision    m_last_decision;
bool              m_has_decision = false;
bool              m_vetoed = false;          // keputusan siklus ini di-veto Native

// Statistik harian (untuk laporan)
int               m_day_cycles = 0;
int               m_day_failed_sum = 0;
int               m_day_fallbacks = 0;
int               m_day_vetos = 0;
int               m_day_blackouts = 0;

string            m_dashboard_status = "INITIALIZING";

//+------------------------------------------------------------------+
//| Utilitas dasar                                                      |
//+------------------------------------------------------------------+
int TodayKey()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   return dt.year * 1000 + dt.day_of_year;
}

string StateKey(const string name)
{
   return "DGV2_" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) + "_" +
          IntegerToString((long)InpMagicNumber) + "_" + name;
}

bool IsTester()
{
   return (bool)MQLInfoInteger(MQL_TESTER);
}

double NormalizePrice(const double price)
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(tick > 0.0)
      return NormalizeDouble(MathRound(price / tick) * tick, digits);
   return NormalizeDouble(price, digits);
}

// Jarak minimum (dalam HARGA) yang diizinkan broker untuk SL/TP/pending
double MinStopDistance()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stops   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(stops, freeze) * point;
}

double FloorToStep(const double value, const double step)
{
   if(step <= 0.0) return value;
   return MathFloor(value / step + 1e-9) * step;
}

int LotDigits(const double lot_step)
{
   int dg = 0;
   for(double s = lot_step; s < 0.9999 && dg < 8; s *= 10.0) dg++;
   return dg;
}

int CountManagedPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber &&
         m_position.Symbol() == _Symbol)
         n++;
   }
   return n;
}

int CountManagedOrders()
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(m_order.SelectByIndex(i) && m_order.Magic() == InpMagicNumber &&
         m_order.Symbol() == _Symbol)
         n++;
   }
   return n;
}

//+------------------------------------------------------------------+
//| Simpan/muat state (GlobalVariable) supaya restart EA tidak amnesia  |
//+------------------------------------------------------------------+
void SavePeak()
{
   if(IsTester()) return;
   GlobalVariableSet(StateKey("PEAK"), m_peak_equity);
   m_last_peak_save = TimeCurrent();
}

void SaveDayState()
{
   if(IsTester()) return;
   GlobalVariableSet(StateKey("DAYKEY"), (double)m_current_day_key);
   GlobalVariableSet(StateKey("DAYBAL"), m_start_day_balance);
   GlobalVariableSet(StateKey("DAYSTART"), (double)m_day_start_time);
}

void SaveRiskState()
{
   if(IsTester()) return;
   GlobalVariableSet(StateKey("CONSEC"), (double)m_consec_losses);
   GlobalVariableSet(StateKey("COOLDOWN"), (double)m_loss_cooldown_until);
}

void LoadState()
{
   double balance = m_account.Balance();
   m_start_day_balance   = balance;
   m_peak_equity         = MathMax(m_account.Equity(), balance);
   m_current_day_key     = -1;
   m_day_start_time      = TimeCurrent();
   m_consec_losses       = 0;
   m_loss_cooldown_until = 0;

   if(IsTester()) return;

   if(InpResetPeakOnInit)
   {
      GlobalVariableDel(StateKey("PEAK"));
      Print("State: InpResetPeakOnInit=TRUE -> peak equity di-reset ke equity sekarang. ",
            "JANGAN LUPA kembalikan input ini ke FALSE.");
   }
   else if(GlobalVariableCheck(StateKey("PEAK")))
   {
      double stored_peak = GlobalVariableGet(StateKey("PEAK"));
      if(stored_peak > m_peak_equity) m_peak_equity = stored_peak;
   }

   if(GlobalVariableCheck(StateKey("DAYKEY")))
   {
      m_current_day_key = (int)GlobalVariableGet(StateKey("DAYKEY"));
      if(GlobalVariableCheck(StateKey("DAYBAL")))
         m_start_day_balance = GlobalVariableGet(StateKey("DAYBAL"));
      if(GlobalVariableCheck(StateKey("DAYSTART")))
         m_day_start_time = (datetime)GlobalVariableGet(StateKey("DAYSTART"));
   }

   if(GlobalVariableCheck(StateKey("CONSEC")))
      m_consec_losses = (int)GlobalVariableGet(StateKey("CONSEC"));
   if(GlobalVariableCheck(StateKey("COOLDOWN")))
      m_loss_cooldown_until = (datetime)GlobalVariableGet(StateKey("COOLDOWN"));

   Print("State dimuat: PeakEquity=", DoubleToString(m_peak_equity, 2),
         " | BalanceAwalHari=", DoubleToString(m_start_day_balance, 2),
         " | LossBeruntun=", m_consec_losses);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      Print("PERINGATAN: Algo Trading belum diizinkan (tombol Algo Trading / izin EA). Order tidak akan bisa dikirim.");

   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpSlippagePoints);
   m_trade.SetTypeFillingBySymbol(_Symbol);

   // --- Mode proxy dulu, baru key langsung (dipakai sebagai cadangan) ---
   m_groq_client.SetProxy(InpProxyUrl, InpProxyToken);

   // --- Pool banyak key (input koma + file) ---
   int pool_input = m_groq_client.AddKeysFromText(InpApiKeyPool);
   int pool_file  = (StringLen(InpApiKeyFile) > 0) ? m_groq_client.LoadKeysFromFile(InpApiKeyFile) : 0;
   if(m_groq_client.PoolSize() > 0)
      Print("Pool API key: ", m_groq_client.PoolSize(), " key aktif dimuat (dari input: ", pool_input,
            ", dari file: ", pool_file, "). Rotasi otomatis, key mati dilewati.");

   string api_keys[12];
   api_keys[0] = InpApiKey_Analyst1;
   api_keys[1] = InpApiKey_Analyst2;
   api_keys[2] = InpApiKey_Analyst3;
   api_keys[3] = InpApiKey_Analyst4;
   api_keys[4] = InpApiKey_Analyst5;
   api_keys[5] = InpApiKey_Analyst6;
   api_keys[6] = InpApiKey_Analyst7;
   api_keys[7] = InpApiKey_Analyst8;
   api_keys[8] = InpApiKey_Analyst9;
   api_keys[9] = InpApiKey_Analyst10;
   api_keys[10] = InpApiKey_Summarizer;
   api_keys[11] = InpApiKey_Reserve;

   m_groq_client.SetProvider((int)InpAIProvider, InpAIBaseUrl, InpAIExtraJson, InpAITokenParam);
   m_groq_client.Initialize(api_keys, InpAIModel, InpAIMaxTokens, InpAITemperature, InpAITimeoutMs);

   m_analyst_engine = new CAnalystEngine(GetPointer(m_groq_client));
   m_ai_summarizer  = new CAISummarizer(GetPointer(m_groq_client));
   m_analyst_engine.SetExpansionSpec(InpExpansionATRMult, InpJournalEvalMin);

   m_market_engine.Configure(_Symbol, InpWorkingTF, InpHigherTF,
                              InpMacroProxySymbol, InpDxySymbol, InpBrokerGmtOffset);

   m_market_engine.SetYieldSymbol(InpYieldSymbol);

   m_atr_handle = iATR(_Symbol, InpWorkingTF, 14);

   if(InpUseNewsFilter)
      m_news_filter.Configure(InpNewsCurrencies, InpNewsBlackoutBefore, InpNewsBlackoutAfter, InpNewsWarnMinutes);

   m_telegram.Initialize(InpTelegramBotToken, InpTelegramChatId, InpUseTelegramNotify);
   m_journal.Initialize(_Symbol, InpEnableJournal, InpJournalEvalMin, InpExpansionATRMult);

   m_system_halted = false;
   m_peak_drawdown_halted = false;
   m_news_caution = false;
   m_has_decision = false;
   m_basket_active = false;
   m_next_grid_attempt = 0;

   LoadState();

   m_last_decision.bias = FINAL_BIAS_WAIT;

   Print("Didinska Grid V2 v2.03 Initialized");
   Print("Provider AI: ", EnumToString(InpAIProvider), " | Model: ", InpAIModel);
   Print("Mode: ", (InpMode == MODE_AI_ON) ? "AI ON" : "AI OFF (Native, tanpa API - siap backtest)",
         " | Proxy: ", m_groq_client.IsProxyEnabled() ? "AKTIF" : "tidak (key langsung)",
         " | Pool key: ", m_groq_client.PoolSize());
   Print("News Filter: ", InpUseNewsFilter ? "ENABLED" : "DISABLED",
         " | Telegram: ", InpUseTelegramNotify ? "ENABLED" : "DISABLED",
         " | Basket risk max: ", DoubleToString(InpMaxBasketRiskPct, 2), "%");

   if(InpMode == MODE_AI_ON && !m_groq_client.IsProxyEnabled() && m_groq_client.PoolSize() == 0 &&
      StringLen(InpApiKey_Analyst5) == 0 && StringLen(InpApiKey_Reserve) == 0)
      Print("PERINGATAN: Mode AI ON tapi Proxy URL, Pool key, dan API key kosong -> semua panggilan AI akan gagal (fallback WAIT). ",
            "Isi InpProxyUrl/InpProxyToken atau InpApiKeyPool, atau pakai MODE_AI_OFF.");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   SavePeak();
   SaveDayState();
   SaveRiskState();

   if(CheckPointer(m_analyst_engine) == POINTER_DYNAMIC) delete m_analyst_engine;
   if(CheckPointer(m_ai_summarizer)  == POINTER_DYNAMIC) delete m_ai_summarizer;

   if(m_atr_handle != INVALID_HANDLE)
   {
      IndicatorRelease(m_atr_handle);
      m_atr_handle = INVALID_HANDLE;
   }

   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Waktu & rem darurat risiko
   ManageDayReset();
   if(CheckRiskCircuitBreaker()) return;

   // 2. Status berita & filter waktu
   UpdateNewsState();
   m_time_blocked = IsTimeBlocked(m_time_block_reason);

   // 3. Proteksi Jumat: tutup semua sebelum akhir pekan
   if(IsFridayCloseTime())
   {
      if(CountManagedPositions() > 0 || CountManagedOrders() > 0)
         FlattenAll("Proteksi akhir pekan (Jumat)");
      RefreshDashboard("FRIDAY CLOSE - FLAT");
      return;
   }

   // 4. Evaluasi jurnal (tiap 30 detik)
   if(InpEnableJournal && (TimeCurrent() - m_last_journal_eval) >= 30)
   {
      m_last_journal_eval = TimeCurrent();
      m_journal.Evaluate(SymbolInfoDouble(_Symbol, SYMBOL_BID));
   }

   // 5. Siklus analisa AI.
   //    SENGAJA tidak dijalankan saat ada posisi live: WebRequest bersifat
   //    memblokir, dan saat posisi terbuka EA harus bebas mengelola trailing/BE.
   //    Keputusan AI hanya dipakai saat EA FLAT (membangun grid baru), dan
   //    begitu posisi tertutup siklus akan langsung berjalan.
   bool can_run_ai = !m_time_blocked &&
                     m_news_state != NFS_BLACKOUT &&
                     TimeCurrent() >= m_loss_cooldown_until &&
                     CountManagedPositions() == 0;
   if(can_run_ai && ShouldRunAIAnalysis() && m_market_engine.IsReady())
   {
      RunFullAIAnalysisCycle();
   }

   // 6. Posisi terbuka SELALU dikelola (trailing/BE), tidak peduli spread
   ProcessActiveTrades();

   // 7. Grid (spread hanya menahan pembuatan grid BARU)
   bool spread_ok = (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpread);
   ManageGridStructure(spread_ok);

   // 8. Dashboard
   string status = m_dashboard_status;
   if(!spread_ok) status = "SPREAD LEBAR - tidak buka grid baru";
   RefreshDashboard(status);
}

//+------------------------------------------------------------------+
//| Deteksi event trading untuk notifikasi Telegram (SATU ARAH)        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   if(!InpUseTelegramNotify) return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal_ticket = trans.deal;
   if(deal_ticket == 0) return;
   if(!HistoryDealSelect(deal_ticket)) return;

   long deal_magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
   if(deal_magic != (long)InpMagicNumber) return;

   string deal_symbol = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
   if(deal_symbol != _Symbol) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);

   // --- Posisi BARU terbuka (termasuk grid yang ke-trigger) ---
   if(entry == DEAL_ENTRY_IN)
   {
      ulong position_id = (ulong)HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
      if(!m_position.SelectByTicket(position_id)) return;

      bool is_buy = (m_position.PositionType() == POSITION_TYPE_BUY);
      m_telegram.NotifyOrderFilled(_Symbol, is_buy, m_position.PriceOpen(),
                                    m_position.Volume(), m_position.StopLoss(), m_position.TakeProfit());
      return;
   }

   // --- Posisi DITUTUP (cek alasan: SL atau TP) ---
   if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
   {
      ENUM_DEAL_REASON reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);
      double close_price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
      double profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT) +
                       HistoryDealGetDouble(deal_ticket, DEAL_SWAP) +
                       HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);

      if(reason == DEAL_REASON_SL)
         m_telegram.NotifyStopLossHit(_Symbol, close_price, profit);
      else if(reason == DEAL_REASON_TP)
         m_telegram.NotifyTakeProfitHit(_Symbol, close_price, profit);
   }
}

//+------------------------------------------------------------------+
//| Status berita (Kalender MT5)                                       |
//+------------------------------------------------------------------+
void UpdateNewsState()
{
   if(!InpUseNewsFilter)
   {
      m_news_state = NFS_CLEAR;
      m_news_title = "";
      m_news_caution = false;
      return;
   }

   int minutes = 0;
   string title = "";
   m_news_state   = m_news_filter.GetState(title, minutes);
   m_news_title   = title;
   m_news_minutes = minutes;
   m_news_caution = (m_news_state != NFS_CLEAR);

   if(m_news_state != m_prev_news_state)
   {
      if(m_news_state == NFS_BLACKOUT)
      {
         m_day_blackouts++;
         Print("NEWS BLACKOUT: ", title, " (", minutes, " mnt) -> pending dihapus, grid baru dilarang.");
      }
      else if(m_news_state == NFS_CAUTION)
         Print("NEWS CAUTION: ", title, " dalam ", minutes, " mnt -> lot dikurangi, syarat probabilitas naik.");
      else
         Print("NEWS CLEAR: kembali normal.");
      m_prev_news_state = m_news_state;
   }
}

//+------------------------------------------------------------------+
//| Filter waktu: rollover, Minggu, Senin pagi, Jumat                  |
//+------------------------------------------------------------------+
bool IsTimeBlocked(string &reason)
{
   reason = "";
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);
   int minutes = dt.hour * 60 + dt.min;

   if(InpBlockSunday && dt.day_of_week == 0)
   {
      reason = "Hari Minggu";
      return true;
   }
   if(InpMondayDelayMin > 0 && dt.day_of_week == 1 && minutes < InpMondayDelayMin)
   {
      reason = "Tunda pembukaan Senin";
      return true;
   }
   if(InpAvoidRollover && InpRolloverMinutes > 0)
   {
      if(minutes < InpRolloverMinutes || minutes >= (1440 - InpRolloverMinutes))
      {
         reason = "Window rollover";
         return true;
      }
   }
   if(InpFridayProtection && dt.day_of_week == 5 && dt.hour >= InpFridayStopNewHour)
   {
      reason = "Proteksi Jumat (stop grid baru)";
      return true;
   }
   return false;
}

bool IsFridayCloseTime()
{
   if(!InpFridayProtection) return false;
   MqlDateTime dt;
   TimeToStruct(TimeTradeServer(), dt);
   return (dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour);
}

//+------------------------------------------------------------------+
//| Jalankan siklus penuh: snapshot -> 10 analis -> Penyimpul           |
//+------------------------------------------------------------------+
void RunFullAIAnalysisCycle()
{
   m_last_snapshot = m_market_engine.BuildSnapshot();

   SFinalDecision native_decision = {};
   int raw_ai_bias = 0;
   m_vetoed = false;

   if(InpMode == MODE_AI_ON)
   {
      Print("=== Memulai siklus analisa AI penuh (MODE: AI ON) ===");

      // Ringkasan berita (aktual vs perkiraan) dari Kalender MT5 untuk analis berita
      m_last_snapshot.news_digest = InpUseNewsFilter ? m_news_filter.BuildDigest()
                                                     : "(filter berita dimatikan)";

      m_analyst_engine.AnalyzeAll(m_last_snapshot, m_last_opinions);
      m_last_decision = m_ai_summarizer.Summarize(m_last_opinions, m_last_snapshot);
      raw_ai_bias = (int)m_last_decision.bias;

      // Native Engine: pembanding akurasi (jurnal) + gerbang veto (opsional)
      if(InpNativeGate != NGATE_OFF || InpEnableJournal)
         native_decision = m_native_engine.Decide(m_last_snapshot, (double)InpMaxSpread, InpADXTrendThreshold);

      ApplyNativeGate(native_decision);
   }
   else
   {
      Print("=== Memulai siklus analisa native (MODE: AI OFF, tanpa API) ===");
      ArrayResize(m_last_opinions, 0);
      m_last_decision = m_native_engine.Decide(m_last_snapshot, (double)InpMaxSpread, InpADXTrendThreshold);
      // Native tidak menghitung ekspansi -> pastikan field tidak berisi sampah
      m_last_decision.expansion_valid     = false;
      m_last_decision.expansion_prob      = 0.0;
      m_last_decision.invalidation_level  = 0.0;
      m_last_decision.expansion_votes     = 0;
      native_decision = m_last_decision;
      raw_ai_bias = (int)m_last_decision.bias;
   }

   m_has_decision     = true;
   m_last_ai_analysis = TimeCurrent();
   m_grid_needs_refresh = true;

   // Statistik harian
   m_day_cycles++;
   m_day_failed_sum += m_last_decision.analysts_failed;
   if(m_last_decision.used_builtin_fallback) m_day_fallbacks++;

   // Jurnal
   m_journal.Record(m_last_snapshot, m_last_opinions, m_last_decision, raw_ai_bias,
                    native_decision, (InpMode == MODE_AI_ON));

   string bias_text = (m_last_decision.bias == FINAL_BIAS_BUY) ? "BUY" :
                       (m_last_decision.bias == FINAL_BIAS_SELL) ? "SELL" : "WAIT";
   string engine_label = (InpMode == MODE_AI_ON) ? "AI Penyimpul" : "Native Engine";
   string total_label  = (InpMode == MODE_AI_ON) ? "/10" : "/9";

   m_dashboard_status = engine_label + ": " + bias_text +
                        " (Prob: " + DoubleToString(m_last_decision.probability * 100, 0) + "%" +
                        (m_last_decision.used_builtin_fallback ? ", FALLBACK NATIVE" : "") + ")";

   Print("Keputusan Final [", engine_label, "]: ", bias_text,
         " | Probabilitas=", DoubleToString(m_last_decision.probability, 2),
         " | Sepakat=", m_last_decision.analysts_agreed, total_label,
         (InpMode == MODE_AI_ON) ? (" | Gagal=" + IntegerToString(m_last_decision.analysts_failed) + "/10") : "",
         (m_last_decision.used_builtin_fallback ? " | [FALLBACK NATIVE DIPAKAI]" : ""));
   if(m_last_decision.expansion_valid)
      Print("Ekspansi (>=", DoubleToString(InpExpansionATRMult, 1), "xATR dlm ", InpJournalEvalMin, " mnt): ",
            DoubleToString(m_last_decision.expansion_prob, 2), " dari ", m_last_decision.expansion_votes,
            " analis | Skenario batal di: ", (m_last_decision.invalidation_level > 0.0 ?
            DoubleToString(m_last_decision.invalidation_level, m_last_snapshot.digits) : "-"));
   Print("Alasan: ", m_last_decision.reasoning);
}

//+------------------------------------------------------------------+
//| Gerbang Native: veto keputusan AI yang bertentangan                  |
//+------------------------------------------------------------------+
void ApplyNativeGate(const SFinalDecision &native)
{
   if(InpMode != MODE_AI_ON || InpNativeGate == NGATE_OFF) return;
   if(m_last_decision.bias == FINAL_BIAS_WAIT) return;

   bool veto = false;
   string why = "";

   if(InpNativeGate == NGATE_BLOCK_OPPOSITE)
   {
      if(native.bias != FINAL_BIAS_WAIT && native.bias != m_last_decision.bias)
      {
         veto = true;
         why = "Native berlawanan arah";
      }
   }
   else if(InpNativeGate == NGATE_REQUIRE_AGREE)
   {
      if(native.bias != m_last_decision.bias)
      {
         veto = true;
         why = "Native tidak searah (WAIT/berlawanan)";
      }
   }

   if(veto)
   {
      m_last_decision.bias = FINAL_BIAS_WAIT;
      m_vetoed = true;
      m_last_decision.reasoning += " [VETO NATIVE: " + why + "]";
      m_day_vetos++;
      Print("ApplyNativeGate: keputusan AI di-VETO -> WAIT. Alasan: ", why);
   }
}

//+------------------------------------------------------------------+
//| Kapan siklus AI penuh berikutnya harus dijalankan?                  |
//+------------------------------------------------------------------+
bool ShouldRunAIAnalysis()
{
   int elapsed = (int)(TimeCurrent() - m_last_ai_analysis);
   return elapsed >= InpAIAnalysisInterval;
}

//+------------------------------------------------------------------+
//| Kelola struktur grid berdasarkan keputusan final                    |
//+------------------------------------------------------------------+
void ManageGridStructure(const bool spread_ok)
{
   int live_positions  = CountManagedPositions();
   int standing_orders = CountManagedOrders();

   // --- Lacak basket: dari ada posisi live sampai semua tertutup ---
   if(live_positions > 0)
   {
      if(!m_basket_active)
      {
         m_basket_active = true;
         m_basket_start  = TimeCurrent() - 120;
      }
   }
   else if(m_basket_active)
   {
      m_basket_active = false;
      EvaluateBasketResult();
   }

   // --- Berita/waktu: hapus pending walau sudah ada posisi live (jangan tambah layer) ---
   if(standing_orders > 0 && (m_news_state == NFS_BLACKOUT || m_time_blocked))
   {
      PurgeAllPending();
      Print("ManageGridStructure: pending dihapus (", (m_news_state == NFS_BLACKOUT ? "NEWS BLACKOUT" : m_time_block_reason), ").");
      return;
   }

   bool allow_state = ShouldAllowNewTrades();   // tanpa spread
   bool can_build   = allow_state && spread_ok;

   // REFRESH PAKSA: ada keputusan AI baru dan belum ada posisi live
   if(live_positions == 0 && standing_orders > 0 && m_grid_needs_refresh)
   {
      PurgeAllPending();
      m_grid_needs_refresh = false;
      Print("ManageGridStructure: grid lama dibatalkan untuk refresh paksa (keputusan AI baru tersedia).");
      return;
   }

   if(live_positions > 0 && InpDeleteOpposite && standing_orders > 0)
      CancelOppositeGridSide();

   if(live_positions == 0 && standing_orders == 0 && can_build)
   {
      BuildSmartGrid();
      m_grid_needs_refresh = false;
   }

   if(live_positions == 0 && standing_orders > 0 && !allow_state)
      PurgeAllPending();
}

//+------------------------------------------------------------------+
//| Hasil 1 basket selesai -> update hitungan loss beruntun             |
//+------------------------------------------------------------------+
void EvaluateBasketResult()
{
   int trades = 0, wins = 0;
   double pnl = SumClosedPnL(m_basket_start, TimeCurrent() + 60, trades, wins);

   if(pnl < 0.0)      m_consec_losses++;
   else if(pnl > 0.0) m_consec_losses = 0;

   Print("Basket selesai: PnL=", DoubleToString(pnl, 2), " USD (", trades,
         " trade). Loss beruntun=", m_consec_losses);

   if(InpMaxConsecLosses > 0 && m_consec_losses >= InpMaxConsecLosses)
   {
      m_loss_cooldown_until = TimeCurrent() + (InpLossCooldownMin * 60);
      string msg = "<b>⏸ Cooldown aktif</b>\n" + IntegerToString(m_consec_losses) +
                   " basket rugi beruntun. Tidak buka grid baru selama " +
                   IntegerToString(InpLossCooldownMin) + " menit.";
      Print("COOLDOWN: ", m_consec_losses, " basket rugi beruntun -> jeda ", InpLossCooldownMin, " menit.");
      m_telegram.NotifyCustom(msg);
      m_consec_losses = 0;
   }

   SaveRiskState();
}

//+------------------------------------------------------------------+
//| Jumlah PnL deal tertutup (milik EA ini) dalam rentang waktu         |
//+------------------------------------------------------------------+
double SumClosedPnL(const datetime from, const datetime to, int &trades, int &wins)
{
   trades = 0;
   wins   = 0;
   double sum = 0.0;

   if(!HistorySelect(from, to)) return 0.0;

   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != (long)InpMagicNumber) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;

      long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);
      double commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION) +
                          HistoryDealGetDouble(ticket, DEAL_FEE);

      if(entry == DEAL_ENTRY_IN)
      {
         sum += commission;   // komisi sisi masuk
         continue;
      }

      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY || entry == DEAL_ENTRY_INOUT)
      {
         double pnl = HistoryDealGetDouble(ticket, DEAL_PROFIT) +
                      HistoryDealGetDouble(ticket, DEAL_SWAP) + commission;
         sum += pnl;
         trades++;
         if(pnl > 0.0) wins++;
      }
   }
   return sum;
}

//+------------------------------------------------------------------+
//| Apakah boleh membuka grid baru saat ini? (TANPA cek spread)         |
//+------------------------------------------------------------------+
bool ShouldAllowNewTrades()
{
   if(m_system_halted) return false;
   if(!m_has_decision) return false;
   if(m_time_blocked) return false;
   if(m_news_state == NFS_BLACKOUT) return false;
   if(TimeCurrent() < m_loss_cooldown_until) return false;
   if(TimeCurrent() < m_next_grid_attempt) return false;

   // Keputusan terlalu basi (misal siklus tertahan lama) -> jangan dipakai
   if((TimeCurrent() - m_last_ai_analysis) > (InpAIAnalysisInterval * 3)) return false;

   // --- Gerbang EKSPANSI: grid stop-order untung dari gerak jauh, rugi di pasar sempit ---
   bool use_expansion = (InpMode == MODE_AI_ON && InpUseExpansionGate && m_last_decision.expansion_valid);
   if(use_expansion && m_last_decision.expansion_prob < InpMinExpansionProb) return false;

   bool symmetric = false;
   if(m_last_decision.bias == FINAL_BIAS_WAIT)
   {
      // Arah tidak jelas: hanya boleh kalau mode simetris diizinkan, ekspansi tinggi, dan tidak di-veto Native
      symmetric = (InpAllowSymmetricGrid && use_expansion && !m_vetoed &&
                   m_last_decision.expansion_prob >= InpSymmetricExpansionProb);
      if(!symmetric) return false;
   }
   else
   {
      // Probabilitas arah terlalu rendah -> terlalu tidak yakin untuk dibuka
      if(m_last_decision.probability < InpMinProbability) return false;

      // Skenario sudah batal? (harga sudah melewati level pembatal sebelum grid dibangun)
      double bid_now = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double inv = m_last_decision.invalidation_level;
      if(inv > 0.0)
      {
         if(m_last_decision.bias == FINAL_BIAS_BUY  && bid_now <= inv) return false;
         if(m_last_decision.bias == FINAL_BIAS_SELL && bid_now >= inv) return false;
      }
   }

   // Mode waspada berita -> syarat keyakinan dinaikkan
   if(m_news_caution)
   {
      double need = (symmetric ? InpSymmetricExpansionProb : InpMinProbability) + 0.10;
      double have = symmetric ? m_last_decision.expansion_prob : m_last_decision.probability;
      if(have < need) return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Jarak SL/TP efektif (dalam satuan HARGA, bukan poin)                 |
//+------------------------------------------------------------------+
// Sumber utama: ATR asli dari snapshot (lihat MarketData.mqh). Input poin
// hanya fallback kalau belum ada siklus analisa yang selesai.
double GetEffectiveSLDistance()
{
   if(m_has_decision && m_last_snapshot.suggested_sl_distance > 0)
      return m_last_snapshot.suggested_sl_distance;

   return InpStopLoss * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

double GetEffectiveTPDistance()
{
   if(m_has_decision && m_last_snapshot.suggested_tp_distance > 0)
      return m_last_snapshot.suggested_tp_distance;

   return InpTakeProfit * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
}

//+------------------------------------------------------------------+
//| Bangun grid dengan parameter dari keputusan final                   |
//+------------------------------------------------------------------+
void BuildSmartGrid()
{
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(ask <= 0.0 || bid <= 0.0 || point <= 0.0) return;

   // --- Jarak minimum broker (stops level / freeze level) ---
   double min_dist = MinStopDistance();
   double sl_distance = MathMax(GetEffectiveSLDistance(), min_dist * 1.2);
   double tp_distance = MathMax(GetEffectiveTPDistance(), min_dist * 1.2);

   // --- Jarak antar layer: ATR (lintas-broker) atau poin tetap ---
   double atr = GetLiveATR();
   if(atr <= 0.0) atr = m_last_snapshot.atr14;

   double base_step = (InpUseATRGridDistance && atr > 0.0) ? (atr * InpGridDistanceATR)
                                                           : (InpGridDistance * point);
   double grid_step = base_step * m_last_decision.grid_distance_multiplier;
   double min_step  = min_dist + (ask - bid) + (2.0 * point);
   grid_step = MathMax(grid_step, min_step);

   // --- Jumlah layer per sisi (dibatasi InpMaxLayersPerSide) ---
   int buy_orders  = InpGridOrders;
   int sell_orders = InpGridOrders;
   bool buy_side_is_minimal_hedge  = false;
   bool sell_side_is_minimal_hedge = false;

   if(m_last_decision.bias == FINAL_BIAS_BUY)
   {
      buy_orders = InpGridOrders + m_last_decision.buy_weight - 1;
      if(m_last_decision.probability >= InpHighConfidenceThreshold)
      {
         sell_orders = 1;
         sell_side_is_minimal_hedge = true;
      }
      else
         sell_orders = MathMax(1, InpGridOrders - 1);
   }
   else if(m_last_decision.bias == FINAL_BIAS_SELL)
   {
      sell_orders = InpGridOrders + m_last_decision.sell_weight - 1;
      if(m_last_decision.probability >= InpHighConfidenceThreshold)
      {
         buy_orders = 1;
         buy_side_is_minimal_hedge = true;
      }
      else
         buy_orders = MathMax(1, InpGridOrders - 1);
   }

   int max_layers = MathMax(1, InpMaxLayersPerSide);
   buy_orders  = MathMax(1, MathMin(max_layers, buy_orders));
   sell_orders = MathMax(1, MathMin(max_layers, sell_orders));

   // --- Lot: budget risiko BASKET dibagi ke jumlah layer terbanyak 1 sisi ---
   int total_layers = buy_orders + sell_orders;
   int risk_layers  = InpDeleteOpposite ? MathMax(buy_orders, sell_orders) : total_layers;
   double lot_size  = GetSmartLotSize(risk_layers, total_layers, sl_distance);
   double min_lot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   if(lot_size <= 0.0)
   {
      m_next_grid_attempt = TimeCurrent() + 60;
      Print("BuildSmartGrid: grid DIBATALKAN (lot tidak memenuhi budget risiko/margin). Coba lagi 60 detik.");
      return;
   }

   double buy_lot  = buy_side_is_minimal_hedge  ? min_lot : lot_size;
   double sell_lot = sell_side_is_minimal_hedge ? min_lot : lot_size;

   // --- Masa kedaluwarsa pending (kalau broker mendukung) ---
   ENUM_ORDER_TYPE_TIME type_time = ORDER_TIME_GTC;
   datetime expiration = 0;
   long exp_mode = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   if(InpPendingExpiryMin > 0 && ((int)exp_mode & SYMBOL_EXPIRATION_SPECIFIED) != 0)
   {
      type_time  = ORDER_TIME_SPECIFIED;
      expiration = TimeTradeServer() + (InpPendingExpiryMin * 60);
   }

   int placed_buy = 0, placed_sell = 0;

   for(int i = 1; i <= buy_orders; i++)
   {
      double target = NormalizePrice(ask + (grid_step * i));
      double sl     = NormalizePrice(target - sl_distance);
      double tp     = NormalizePrice(target + tp_distance);

      if(m_trade.BuyStop(buy_lot, target, _Symbol, sl, tp, type_time, expiration, "DGV2"))
         placed_buy++;
      else
         Print("BuildSmartGrid: BuyStop layer ", i, " GAGAL. retcode=", m_trade.ResultRetcode(),
               " (", m_trade.ResultRetcodeDescription(), ") harga=", DoubleToString(target, digits));
   }

   for(int i = 1; i <= sell_orders; i++)
   {
      double target = NormalizePrice(bid - (grid_step * i));
      double sl     = NormalizePrice(target + sl_distance);
      double tp     = NormalizePrice(target - tp_distance);

      if(m_trade.SellStop(sell_lot, target, _Symbol, sl, tp, type_time, expiration, "DGV2"))
         placed_sell++;
      else
         Print("BuildSmartGrid: SellStop layer ", i, " GAGAL. retcode=", m_trade.ResultRetcode(),
               " (", m_trade.ResultRetcodeDescription(), ") harga=", DoubleToString(target, digits));
   }

   if(placed_buy + placed_sell == 0)
   {
      // Semua gagal -> jangan coba lagi tiap tick
      m_next_grid_attempt = TimeCurrent() + 30;
      Print("BuildSmartGrid: SEMUA order gagal dipasang. Coba lagi 30 detik.");
      return;
   }

   double basket_risk_pct = (AccountInfoDouble(ACCOUNT_BALANCE) > 0.0) ?
      (MathMax(placed_buy, placed_sell) * ExpectedLayerLossMoney(lot_size, sl_distance) /
       AccountInfoDouble(ACCOUNT_BALANCE) * 100.0) : 0.0;

   if(m_last_decision.bias == FINAL_BIAS_WAIT)
      Print("BuildSmartGrid: MODE SIMETRIS (arah WAIT, ekspansi ", DoubleToString(m_last_decision.expansion_prob, 2), ")");
   Print("BuildSmartGrid: Buy=", placed_buy, "/", buy_orders, " (lot ", DoubleToString(buy_lot, 2), buy_side_is_minimal_hedge ? " HEDGE-MIN" : "", ")",
         " Sell=", placed_sell, "/", sell_orders, " (lot ", DoubleToString(sell_lot, 2), sell_side_is_minimal_hedge ? " HEDGE-MIN" : "", ")",
         " Step=", DoubleToString(grid_step, digits), " (x", DoubleToString(m_last_decision.grid_distance_multiplier, 2), ")",
         " SL_dist=", DoubleToString(sl_distance, digits), " TP_dist=", DoubleToString(tp_distance, digits),
         " | Risiko basket sisi terbesar ~", DoubleToString(basket_risk_pct, 2), "%");
}

//+------------------------------------------------------------------+
//| Perkiraan kerugian uang 1 layer kalau kena SL                       |
//+------------------------------------------------------------------+
double ExpectedLayerLossMoney(const double lot, const double sl_distance)
{
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tick_value <= 0.0) tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_value <= 0.0 || tick_size <= 0.0) return 0.0;
   return lot * (sl_distance / tick_size) * tick_value;
}

//+------------------------------------------------------------------+
//| Hitung lot size dengan BUDGET RISIKO BASKET                         |
//+------------------------------------------------------------------+
// risk_layers : jumlah layer yang bisa kena SL BERSAMAAN (sisi terbesar)
// total_layers: total pending (buy+sell) -> dipakai membagi cap margin
// Mengembalikan 0.0 kalau lot minimum broker sudah melebihi budget risiko
// atau margin tidak cukup (grid dibatalkan, bukan dipaksa).
double GetSmartLotSize(const int risk_layers, const int total_layers, const double stop_loss_distance)
{
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int    lot_dg   = LotDigits(lot_step);

   if(!InpDynamicPositionSizing)
      return min_lot;

   double balance = m_account.Balance();

   // Risiko per layer: dibatasi input DAN budget basket / jumlah layer
   double per_layer_pct = InpMaxRiskPerTrade;
   if(InpMaxBasketRiskPct > 0.0)
      per_layer_pct = MathMin(per_layer_pct, InpMaxBasketRiskPct / (double)MathMax(1, risk_layers));

   double risk_amount = balance * (per_layer_pct / 100.0);

   // Kurangi risiko kalau AI kurang yakin (rentang 50%-100%)
   double confidence_factor = m_has_decision ? m_last_decision.probability : 0.5;
   if(m_has_decision && m_last_decision.bias == FINAL_BIAS_WAIT && m_last_decision.expansion_valid)
      confidence_factor = m_last_decision.expansion_prob;   // grid simetris: keyakinan = peluang ekspansi
   double adjusted_risk = risk_amount * (0.5 + confidence_factor * 0.5);

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tick_value <= 0.0) tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tick_value <= 0.0 || tick_size <= 0.0 || stop_loss_distance <= 0.0)
   {
      Print("GetSmartLotSize: data tick/SL tidak valid, grid dibatalkan.");
      return 0.0;
   }

   double risk_per_lot = (stop_loss_distance / tick_size) * tick_value;
   double lot_size = adjusted_risk / risk_per_lot;

   // Mode waspada berita: setengah lot
   if(m_news_caution) lot_size *= 0.5;

   lot_size = FloorToStep(lot_size, lot_step);
   lot_size = MathMin(max_lot, lot_size);

   if(lot_size < min_lot)
   {
      // Lot minimum broker lebih besar dari budget? Toleransi 1.5x, lebih dari itu batalkan.
      double min_lot_risk = min_lot * risk_per_lot;
      if(min_lot_risk > adjusted_risk * 1.5)
      {
         Print("GetSmartLotSize: lot minimum (", DoubleToString(min_lot, 2), ") berisiko ",
               DoubleToString(min_lot_risk, 2), " USD/layer > budget ", DoubleToString(adjusted_risk, 2),
               " USD/layer. Saldo terlalu kecil untuk jumlah layer ini -> grid dibatalkan.");
         return 0.0;
      }
      lot_size = min_lot;
   }
   lot_size = NormalizeDouble(lot_size, lot_dg);

   // PENGAMAN MARGIN: cap 25% free margin dibagi rata ke SEMUA layer
   double required_margin = 0.0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot_size, SymbolInfoDouble(_Symbol, SYMBOL_ASK), required_margin))
   {
      double free_margin = m_account.FreeMargin();
      int safe_layers = MathMax(1, total_layers);
      double max_affordable_margin = (free_margin * 0.25) / safe_layers;

      if(required_margin > max_affordable_margin && required_margin > 0.0)
      {
         double scale_factor = max_affordable_margin / required_margin;
         double scaled = FloorToStep(lot_size * scale_factor, lot_step);

         if(scaled < min_lot)
         {
            double min_margin = 0.0;
            if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, min_lot, SymbolInfoDouble(_Symbol, SYMBOL_ASK), min_margin) &&
               (min_margin * safe_layers) > (free_margin * 0.5))
            {
               Print("GetSmartLotSize: free margin tidak cukup untuk ", safe_layers, " layer -> grid dibatalkan.");
               return 0.0;
            }
            scaled = min_lot;
         }

         lot_size = NormalizeDouble(MathMin(max_lot, scaled), lot_dg);
         Print("GetSmartLotSize: lot dikecilkan karena margin (dibagi ", safe_layers,
               " layer). Free margin=", DoubleToString(free_margin, 2), " Lot=", DoubleToString(lot_size, lot_dg));
      }
   }

   return lot_size;
}

//+------------------------------------------------------------------+
//| ATR "segar" untuk trailing/BE & jarak grid (handle dibuat SEKALI)   |
//+------------------------------------------------------------------+
double GetLiveATR()
{
   if(m_atr_handle == INVALID_HANDLE)
      m_atr_handle = iATR(_Symbol, InpWorkingTF, 14);
   if(m_atr_handle == INVALID_HANDLE) return 0.0;

   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(m_atr_handle, 0, 1, 1, buf) > 0) return buf[0];   // candle tertutup terakhir
   return 0.0;
}

//+------------------------------------------------------------------+
//| Proses posisi terbuka: trailing stop & break-even BERBASIS ATR      |
//+------------------------------------------------------------------+
// Tidak ada modifikasi yang melanggar stops level, dan trailing hanya
// digeser kalau perbaikannya berarti (tidak spam PositionModify tiap tick).
void ProcessActiveTrades()
{
   double atr = GetLiveATR();
   if(atr <= 0.0) return;

   double min_dist = MinStopDistance();
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double be_trigger_distance  = InpBreakEvenTriggerATR * atr;
   double be_offset_distance   = InpBreakEvenOffsetATR  * atr;
   double trailing_start_dist  = InpTrailingStartATR    * atr;
   double trailing_step_dist   = InpTrailingStepATR     * atr;
   double min_improve          = MathMax(trailing_step_dist * 0.25, tick_size);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber &&
           m_position.Symbol() == _Symbol))
         continue;

      double base_entry = m_position.PriceOpen();
      double current_sl = m_position.StopLoss();
      double current_tp = m_position.TakeProfit();
      ulong  ticket     = m_position.Ticket();

      if(m_position.PositionType() == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit_distance = bid - base_entry;

         if(profit_distance >= be_trigger_distance && current_sl < base_entry)
         {
            double new_sl = NormalizePrice(base_entry + be_offset_distance);
            if(new_sl > current_sl && (bid - new_sl) >= min_dist)
               m_trade.PositionModify(ticket, new_sl, current_tp);
            continue;
         }

         if(profit_distance >= trailing_start_dist)
         {
            double new_sl = NormalizePrice(bid - trailing_step_dist);
            if(new_sl > (current_sl + min_improve) && (bid - new_sl) >= min_dist)
               m_trade.PositionModify(ticket, new_sl, current_tp);
         }
      }
      else if(m_position.PositionType() == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit_distance = base_entry - ask;

         if(profit_distance >= be_trigger_distance && (current_sl > base_entry || current_sl == 0.0))
         {
            double new_sl = NormalizePrice(base_entry - be_offset_distance);
            if((current_sl == 0.0 || new_sl < current_sl) && (new_sl - ask) >= min_dist)
               m_trade.PositionModify(ticket, new_sl, current_tp);
            continue;
         }

         if(profit_distance >= trailing_start_dist)
         {
            double new_sl = NormalizePrice(ask + trailing_step_dist);
            if((current_sl == 0.0 || new_sl < (current_sl - min_improve)) && (new_sl - ask) >= min_dist)
               m_trade.PositionModify(ticket, new_sl, current_tp);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Batalkan grid sisi lawan setelah salah satu sisi ke-trigger          |
//+------------------------------------------------------------------+
void CancelOppositeGridSide()
{
   ENUM_POSITION_TYPE active_trend = POSITION_TYPE_BUY;
   bool track = false;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber &&
         m_position.Symbol() == _Symbol)
      {
         active_trend = m_position.PositionType();
         track = true;
         break;
      }
   }

   if(!track) return;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(m_order.SelectByIndex(i) && m_order.Magic() == InpMagicNumber &&
         m_order.Symbol() == _Symbol)
      {
         if(active_trend == POSITION_TYPE_BUY && m_order.OrderType() == ORDER_TYPE_SELL_STOP)
            m_trade.OrderDelete(m_order.Ticket());

         if(active_trend == POSITION_TYPE_SELL && m_order.OrderType() == ORDER_TYPE_BUY_STOP)
            m_trade.OrderDelete(m_order.Ticket());
      }
   }
}

//+------------------------------------------------------------------+
//| Hapus semua pending order milik EA ini                              |
//+------------------------------------------------------------------+
void PurgeAllPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(m_order.SelectByIndex(i) && m_order.Magic() == InpMagicNumber &&
         m_order.Symbol() == _Symbol)
      {
         m_trade.OrderDelete(m_order.Ticket());
      }
   }
}

//+------------------------------------------------------------------+
//| Tutup semua posisi + hapus semua pending milik EA ini               |
//+------------------------------------------------------------------+
void FlattenAll(const string reason)
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Magic() == InpMagicNumber &&
         m_position.Symbol() == _Symbol)
      {
         if(m_trade.PositionClose(m_position.Ticket()))
            closed++;
         else
            Print("FlattenAll: gagal menutup tiket ", m_position.Ticket(),
                  " retcode=", m_trade.ResultRetcode(), " (akan dicoba lagi di tick berikutnya)");
      }
   }
   PurgeAllPending();
   Print("FlattenAll [", reason, "]: ", closed, " posisi ditutup, pending dihapus.");
}

//+------------------------------------------------------------------+
//| Circuit breaker risiko harian/drawdown/PUNCAK EQUITY                 |
//+------------------------------------------------------------------+
bool CheckRiskCircuitBreaker()
{
   // Sudah halt: pastikan TIDAK ada sisa posisi/pending (close bisa gagal sesaat)
   if(m_system_halted)
   {
      if(CountManagedPositions() > 0 || CountManagedOrders() > 0)
         FlattenAll("Halt aktif - bersihkan sisa");
      return true;
   }

   double account_equity  = m_account.Equity();
   double account_balance = m_account.Balance();

   // Update puncak equity (high-water mark) dan simpan berkala
   if(account_equity > m_peak_equity)
   {
      m_peak_equity = account_equity;
      if((TimeCurrent() - m_last_peak_save) >= 60) SavePeak();
   }

   double daily_loss_evaluation = (m_start_day_balance > 0.0) ?
      ((m_start_day_balance - account_equity) / m_start_day_balance) * 100.0 : 0.0;
   double drawdown_evaluation = (account_balance > 0.0) ?
      ((account_balance - account_equity) / account_balance) * 100.0 : 0.0;
   double drawdown_from_peak = (m_peak_equity > 0.0) ?
      ((m_peak_equity - account_equity) / m_peak_equity) * 100.0 : 0.0;

   bool peak_drawdown_triggered = (drawdown_from_peak >= InpMaxDrawdownFromPeakPct);

   if(daily_loss_evaluation >= InpMaxDailyLossPct || drawdown_evaluation >= InpMaxDrawdownPct ||
      peak_drawdown_triggered)
   {
      FlattenAll("Circuit breaker");
      m_system_halted = true;

      string msg = "";
      if(peak_drawdown_triggered)
      {
         m_peak_drawdown_halted = true;
         Print("CRITICAL: PEAK DRAWDOWN circuit breaker triggered! HALT PERMANEN ",
               "(set InpResetPeakOnInit=TRUE lalu restart EA untuk lanjut).");
         Print("Puncak Equity: ", DoubleToString(m_peak_equity, 2),
               " | Equity Sekarang: ", DoubleToString(account_equity, 2),
               " | Drawdown dari Puncak: ", DoubleToString(drawdown_from_peak, 2), "%");
         msg = "<b>🚨 HALT PERMANEN - Peak Drawdown</b>\nDrawdown dari puncak: " +
               DoubleToString(drawdown_from_peak, 2) + "%\nEquity: " + DoubleToString(account_equity, 2) +
               " USD\nSemua posisi ditutup. Butuh keputusan manual untuk lanjut.";
      }
      else
      {
         Print("CRITICAL: Risk circuit breaker HARIAN triggered! (auto-resume besok)");
         Print("Daily Loss: ", DoubleToString(daily_loss_evaluation, 2), "%");
         Print("Drawdown: ", DoubleToString(drawdown_evaluation, 2), "%");
         msg = "<b>🛑 HALT HARIAN</b>\nRugi harian: " + DoubleToString(daily_loss_evaluation, 2) +
               "% | Drawdown: " + DoubleToString(drawdown_evaluation, 2) +
               "%\nSemua posisi ditutup. Lanjut otomatis besok.";
      }
      m_telegram.NotifyCustom(msg);
      SavePeak();
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Reset harian + laporan harian                                       |
//+------------------------------------------------------------------+
void ManageDayReset()
{
   int key = TodayKey();
   if(key == m_current_day_key) return;

   bool first_run = (m_current_day_key == -1);

   // Laporan hari sebelumnya (kalau ada)
   if(!first_run && InpUseTelegramNotify && InpDailyReport)
      SendDailyReport(m_day_start_time);

   m_current_day_key   = key;
   m_start_day_balance = m_account.Balance();
   m_day_start_time    = TimeCurrent();

   // halt akibat PEAK DRAWDOWN sengaja TIDAK di-reset di sini
   if(!m_peak_drawdown_halted)
      m_system_halted = false;

   m_day_cycles = 0;
   m_day_failed_sum = 0;
   m_day_fallbacks = 0;
   m_day_vetos = 0;
   m_day_blackouts = 0;

   SaveDayState();
   Print("New trading day started. Balance: ", DoubleToString(m_start_day_balance, 2));
}

void SendDailyReport(const datetime from)
{
   int trades = 0, wins = 0;
   double pnl = SumClosedPnL(from, TimeCurrent() + 60, trades, wins);

   string t = "<b>📊 Laporan Harian - DIDINSKA GRID V2</b>\n";
   t += "Symbol: " + _Symbol + "\n";
   t += "P/L: " + (pnl >= 0.0 ? "+" : "") + DoubleToString(pnl, 2) + " USD\n";
   t += "Trade tertutup: " + IntegerToString(trades) + " (menang " + IntegerToString(wins) + ")\n";
   t += "Balance: " + DoubleToString(m_account.Balance(), 2) + " | Equity: " + DoubleToString(m_account.Equity(), 2) + "\n";
   t += "Peak Equity: " + DoubleToString(m_peak_equity, 2) + "\n";
   t += "Siklus AI: " + IntegerToString(m_day_cycles);
   if(m_day_cycles > 0 && InpMode == MODE_AI_ON)
      t += " | rata-rata analis gagal: " + DoubleToString((double)m_day_failed_sum / m_day_cycles, 1) + "/10";
   t += "\nFallback native: " + IntegerToString(m_day_fallbacks) + " | Veto native: " + IntegerToString(m_day_vetos);
   t += " | Blackout berita: " + IntegerToString(m_day_blackouts) + "\n";
   t += m_telegram.HtmlEscape(m_journal.SummaryText());

   m_telegram.NotifyCustom(t);
}

//+------------------------------------------------------------------+
//| Dashboard                                                            |
//+------------------------------------------------------------------+
void RefreshDashboard(string engine_msg)
{
   double profit_tracking = m_account.Equity() - m_start_day_balance;

   string ai_status = "";
   if(m_has_decision)
   {
      string bias_text = (m_last_decision.bias == FINAL_BIAS_BUY) ? "BUY" :
                          (m_last_decision.bias == FINAL_BIAS_SELL) ? "SELL" : "WAIT";
      ai_status = bias_text + " | Prob: " + DoubleToString(m_last_decision.probability * 100, 0) + "%";

      if(InpMode == MODE_AI_ON)
      {
         ai_status += " | Sepakat: " + IntegerToString(m_last_decision.analysts_agreed) + "/10";
         ai_status += " | Gagal: " + IntegerToString(m_last_decision.analysts_failed) + "/10";
         if(m_last_decision.expansion_valid)
            ai_status += " | Ekspansi: " + DoubleToString(m_last_decision.expansion_prob * 100, 0) + "%";
         if(m_last_decision.invalidation_level > 0.0)
            ai_status += " | Batal di: " + DoubleToString(m_last_decision.invalidation_level, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
         if(m_last_decision.used_builtin_fallback) ai_status += " | [FALLBACK]";
      }
      else
      {
         ai_status += " | Domain searah: " + IntegerToString(m_last_decision.analysts_agreed) + "/9";
      }
   }
   else
   {
      ai_status = "Menunggu siklus pertama...";
   }

   string news_status = "DISABLED";
   if(InpUseNewsFilter)
   {
      if(!m_news_filter.IsAvailable()) news_status = "TIDAK TERSEDIA (kalender/tester)";
      else if(m_news_state == NFS_BLACKOUT) news_status = "BLACKOUT: " + m_news_title + " (" + IntegerToString(m_news_minutes) + " mnt)";
      else if(m_news_state == NFS_CAUTION)  news_status = "CAUTION: " + m_news_title + " (" + IntegerToString(m_news_minutes) + " mnt)";
      else news_status = "CLEAR";
   }

   string next_cycle = "";
   if(CountManagedPositions() > 0)
      next_cycle = "ditahan (ada posisi live)";
   else
   {
      int next_analysis_in = MathMax(0, InpAIAnalysisInterval - (int)(TimeCurrent() - m_last_ai_analysis));
      next_cycle = IntegerToString(next_analysis_in) + " detik lagi";
   }

   string guard = "";
   if(m_time_blocked) guard = "WAKTU: " + m_time_block_reason;
   else if(TimeCurrent() < m_loss_cooldown_until)
      guard = "COOLDOWN loss beruntun s/d " + TimeToString(m_loss_cooldown_until, TIME_MINUTES);
   else guard = "OK";

   string ui = "========================================\n";
   ui += " DIDINSKA GRID V2 v2.03 - " + string((InpMode == MODE_AI_ON) ? "AI ON" : "AI OFF (Native)") +
         (m_groq_client.IsProxyEnabled() ? " [PROXY]" : "") + "\n";
   ui += "========================================\n";
   ui += " Engine     : " + engine_msg + "\n";
   if(m_peak_drawdown_halted)
      ui += " *** HALT PERMANEN (Peak Drawdown) - lihat Experts log ***\n";
   else if(m_system_halted)
      ui += " *** HALT HARIAN - lanjut otomatis besok ***\n";
   ui += " Balance    : " + DoubleToString(m_account.Balance(), 2) + " USD\n";
   ui += " Equity     : " + DoubleToString(m_account.Equity(), 2) + " USD\n";
   ui += " Peak Equity: " + DoubleToString(m_peak_equity, 2) + " USD\n";
   ui += " P/L Today  : " + DoubleToString(profit_tracking, 2) + " USD\n";
   ui += " Spread     : " + IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) + " pts\n";
   ui += "----------------------------------------\n";
   ui += " AI Status  : " + ai_status + "\n";
   ui += " Next Cycle : " + next_cycle + "\n";
   ui += " News       : " + news_status + "\n";
   ui += " Guard      : " + guard + " | LossStreak: " + IntegerToString(m_consec_losses) + "/" + IntegerToString(InpMaxConsecLosses) + "\n";
   ui += " Basket Risk: max " + DoubleToString(InpMaxBasketRiskPct, 2) + "% | Layer/sisi max " + IntegerToString(InpMaxLayersPerSide) + "\n";
   ui += " Telegram   : " + (InpUseTelegramNotify ? "ON" : "OFF") + "\n";
   ui += "========================================\n";

   Comment(ui);
}
