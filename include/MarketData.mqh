//+------------------------------------------------------------------+
//|                                                   MarketData.mqh  |
//|         Didinska Grid V2 - Mesin Pengumpul Data Pasar Native      |
//|                                                                    |
//|   Modul ini mengisi SATU struct besar (SMarketSnapshot) yang jadi  |
//|   "bahan baku" bersama untuk SEMUA 10 AI analis + AI Penyimpul.    |
//|   Dipanggil SEKALI per siklus analisa (misal tiap 10 menit),       |
//|   bukan tiap tick -- supaya semua analis menganalisa data yang     |
//|   persis sama (konsisten), dan hemat komputasi (indikator native   |
//|   MQL5 tidak perlu dihitung ulang 10x untuk 10 analis berbeda).    |
//+------------------------------------------------------------------+
// PENJELASAN PEMBAGIAN TANGGUNG JAWAB (bahasa sederhana):
//   - MarketData.mqh (file ini)  -> KUMPULKAN angka mentah & heuristik
//   - Analysts.mqh                -> BACA snapshot ini, susun prompt per
//                                    analis, kirim ke GroqClient
//   - AISummarizer.mqh            -> BACA 10 opini analis, minta AI
//                                    Penyimpul merangkum jadi 1 keputusan
//   File ini TIDAK memanggil AI sama sekali -- murni MQL5 native.
//+------------------------------------------------------------------+
#property copyright "Didinska Grid V2"
#property strict

//+------------------------------------------------------------------+
//| Sesi trading aktif saat ini                                        |
//+------------------------------------------------------------------+
// PENJELASAN: dipakai AI #7 (Price Action Native + Sesi) karena XAUUSD
// paling volatile & paling "jujur" pergerakannya di overlap London-NY,
// sementara sesi Asia lebih rawan choppy/breakout palsu untuk grid.
// Jam dihitung dari waktu SERVER broker (TimeTradeServer), BUKAN GMT --
// karena tiap broker punya offset GMT berbeda, offset ini diserahkan ke
// input EA (InpBrokerGmtOffset) supaya user bisa sesuaikan dengan broker
// masing-masing tanpa perlu edit kode.
enum ENUM_TRADING_SESSION
{
   SESSION_ASIA = 0,            // ~00:00-08:00 GMT, likuiditas rendah, rawan choppy
   SESSION_LONDON = 1,          // ~08:00-13:00 GMT, volatilitas naik
   SESSION_LONDON_NY_OVERLAP = 2, // ~13:00-16:00 GMT, volatilitas TERTINGGI (paling jujur)
   SESSION_NY = 3,              // ~16:00-21:00 GMT, masih aktif setelah overlap
   SESSION_QUIET = 4            // ~21:00-24:00 GMT, likuiditas sangat rendah
};

//+------------------------------------------------------------------+
//| Hasil deteksi pola candlestick sederhana (native, tanpa foto)      |
//+------------------------------------------------------------------+
enum ENUM_CANDLE_PATTERN
{
   PATTERN_NONE = 0,
   PATTERN_BULLISH_ENGULFING,
   PATTERN_BEARISH_ENGULFING,
   PATTERN_BULLISH_PIN_BAR,     // hammer / rejection dari bawah
   PATTERN_BEARISH_PIN_BAR,     // shooting star / rejection dari atas
   PATTERN_INSIDE_BAR           // konsolidasi, sinyal breakout berikutnya
};

//+------------------------------------------------------------------+
//| Snapshot lengkap data pasar untuk 1 siklus analisa AI               |
//+------------------------------------------------------------------+
struct SMarketSnapshot
{
   // --- Identitas & harga dasar ---
   string               symbol;
   datetime             snapshot_time;
   double               bid;
   double               ask;
   double               spread_points;
   double               point;
   int                  digits;

   // --- AI #1: Trend (Moving Averages) ---
   double               ema20;
   double               ema50;
   double               ema200;

   // --- AI #2: Momentum (Oscillators) ---
   double               rsi14;
   double               macd_main;
   double               macd_signal;
   double               macd_histogram;
   double               stoch_main;
   double               stoch_signal;

   // --- AI #3: Volatilitas (Bands & ATR) ---
   double               atr14;
   double               atr14_avg50;       // rata-rata ATR 50 bar, untuk baseline "normal"
   double               bb_upper;
   double               bb_mid;
   double               bb_lower;

   // --- AI #4: Volume (Aliran Uang) ---
   // CATATAN: XAUUSD (CFD/Forex) tidak punya volume transaksi asli seperti
   // saham/crypto -- tick_volume (jumlah perubahan harga) dipakai sebagai
   // proksi standar di MT5, sama seperti indikator Volume bawaan platform.
   long                 tick_volume_current;
   long                 tick_volume_avg20;
   double               obv_proxy;         // OBV dihitung dari tick_volume + arah candle

   // --- AI #5: Support & Resistance ---
   double               pivot_pp, pivot_r1, pivot_r2, pivot_r3;
   double               pivot_s1, pivot_s2, pivot_s3;
   double               fib_swing_high;
   double               fib_swing_low;
   double               fib_236, fib_382, fib_500, fib_618, fib_786;

   // --- AI #6: Smart Money Concepts (heuristik) ---
   bool                 smc_bullish_order_block;
   double               smc_bullish_ob_price;
   bool                 smc_bearish_order_block;
   double               smc_bearish_ob_price;
   bool                 smc_bullish_fvg;
   double               smc_fvg_upper;
   double               smc_fvg_lower;
   bool                 smc_bearish_fvg;
   bool                 smc_bos_bullish;      // Break of Structure ke atas
   bool                 smc_bos_bearish;      // Break of Structure ke bawah
   bool                 smc_liquidity_grab_high; // sweep di atas swing high lalu reversal
   bool                 smc_liquidity_grab_low;  // sweep di bawah swing low lalu reversal

   // --- AI #7: Price Action Native + Sesi (pengganti AI foto project 1) ---
   ENUM_CANDLE_PATTERN  candle_pattern;
   ENUM_TRADING_SESSION current_session;
   double               volatility_relative_pct; // range candle terakhir vs atr14_avg50, dalam %

   // --- AI #8: Multi-Timeframe Alignment ---
   string               trend_working_tf;   // "BULLISH" / "BEARISH" / "SIDEWAYS"
   string               trend_higher_tf;
   bool                 mtf_aligned;         // true kalau working TF searah higher TF

   // --- AI #9: Konteks Makro XAUUSD (pengganti AI Makro Kripto project 1) ---
   bool                 macro_dxy_available;      // true kalau symbol DXY/USDX tersedia di broker
   double               macro_dxy_price;          // harga DXY kalau tersedia (0 kalau tidak)
   double               macro_dxy_change_pct;     // perubahan DXY sejak snapshot sebelumnya (0 kalau baseline belum ada)
   double               macro_correlation_eurusd;  // korelasi return XAUUSD vs EURUSD, -1..1 (proksi dolar kalau DXY tidak ada)

   // --- AI #10: Risk Management ---
   double               daily_high;
   double               daily_low;
   double               daily_open;
   double               suggested_sl_distance;   // jarak SL berbasis ATR (dalam harga, bukan poin)
   double               suggested_tp_distance;   // jarak TP berbasis ATR & risk-reward
};

//+------------------------------------------------------------------+
//| CMarketDataEngine - pembangun SMarketSnapshot                      |
//+------------------------------------------------------------------+
class CMarketDataEngine
{
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_working_tf;
   ENUM_TIMEFRAMES   m_higher_tf;
   string            m_macro_proxy_symbol;  // default "EURUSD"
   string            m_dxy_symbol;          // kosong kalau broker tidak sediakan
   int               m_broker_gmt_offset;   // jam, misal +2 atau +3 tergantung broker

   double            m_prev_macro_dxy_price; // untuk hitung macro_dxy_change_pct antar siklus

   // Handle indikator dibuat SEKALI (Configure) dan dipakai ulang tiap siklus.
   // PENJELASAN FIX: sebelumnya handle dibuat lalu langsung dibaca -> sering
   // kosong karena indikator belum selesai dihitung, dan bocor performa.
   int               m_h_ema20, m_h_ema50, m_h_ema200;
   int               m_h_rsi, m_h_macd, m_h_stoch, m_h_atr, m_h_bb;
   int               m_h_htf_fast, m_h_htf_slow;
   bool              m_not_ready_logged;

   void ReleaseHandles()
   {
      if(m_h_ema20    != INVALID_HANDLE) { IndicatorRelease(m_h_ema20);    m_h_ema20    = INVALID_HANDLE; }
      if(m_h_ema50    != INVALID_HANDLE) { IndicatorRelease(m_h_ema50);    m_h_ema50    = INVALID_HANDLE; }
      if(m_h_ema200   != INVALID_HANDLE) { IndicatorRelease(m_h_ema200);   m_h_ema200   = INVALID_HANDLE; }
      if(m_h_rsi      != INVALID_HANDLE) { IndicatorRelease(m_h_rsi);      m_h_rsi      = INVALID_HANDLE; }
      if(m_h_macd     != INVALID_HANDLE) { IndicatorRelease(m_h_macd);     m_h_macd     = INVALID_HANDLE; }
      if(m_h_stoch    != INVALID_HANDLE) { IndicatorRelease(m_h_stoch);    m_h_stoch    = INVALID_HANDLE; }
      if(m_h_atr      != INVALID_HANDLE) { IndicatorRelease(m_h_atr);      m_h_atr      = INVALID_HANDLE; }
      if(m_h_bb       != INVALID_HANDLE) { IndicatorRelease(m_h_bb);       m_h_bb       = INVALID_HANDLE; }
      if(m_h_htf_fast != INVALID_HANDLE) { IndicatorRelease(m_h_htf_fast); m_h_htf_fast = INVALID_HANDLE; }
      if(m_h_htf_slow != INVALID_HANDLE) { IndicatorRelease(m_h_htf_slow); m_h_htf_slow = INVALID_HANDLE; }
   }

   void CreateHandles()
   {
      m_h_ema20    = iMA(m_symbol, m_working_tf, 20, 0, MODE_EMA, PRICE_CLOSE);
      m_h_ema50    = iMA(m_symbol, m_working_tf, 50, 0, MODE_EMA, PRICE_CLOSE);
      m_h_ema200   = iMA(m_symbol, m_working_tf, 200, 0, MODE_EMA, PRICE_CLOSE);
      m_h_rsi      = iRSI(m_symbol, m_working_tf, 14, PRICE_CLOSE);
      m_h_macd     = iMACD(m_symbol, m_working_tf, 12, 26, 9, PRICE_CLOSE);
      m_h_stoch    = iStochastic(m_symbol, m_working_tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      m_h_atr      = iATR(m_symbol, m_working_tf, 14);
      m_h_bb       = iBands(m_symbol, m_working_tf, 20, 0, 2.0, PRICE_CLOSE);
      m_h_htf_fast = iMA(m_symbol, m_higher_tf, 20, 0, MODE_EMA, PRICE_CLOSE);
      m_h_htf_slow = iMA(m_symbol, m_higher_tf, 50, 0, MODE_EMA, PRICE_CLOSE);
   }

   bool HandleReady(const int handle)
   {
      return (handle != INVALID_HANDLE && BarsCalculated(handle) > 0);
   }

   //+---------------------------------------------------------------+
   //| Ambil 1 nilai terakhir dari indicator handle (helper generik)   |
   //+---------------------------------------------------------------+
   double ReadHandleValue(const int handle, const int buffer_index = 0, const int shift = 1)
   {
      if(handle == INVALID_HANDLE) return 0.0;

      double buf[];
      ArraySetAsSeries(buf, true);
      if(CopyBuffer(handle, buffer_index, shift, 1, buf) <= 0) return 0.0;

      return buf[0];
   }

   //+---------------------------------------------------------------+
   //| Trend & Momentum & Volatilitas & Volume (AI #1-4)                |
   //+---------------------------------------------------------------+
   void FillIndicators(SMarketSnapshot &snap)
   {
      // PENJELASAN: semua nilai dibaca dari candle TERTUTUP terakhir (shift=1),
      // bukan candle yang masih berjalan, supaya sinyal tidak berubah-ubah.
      snap.ema20  = ReadHandleValue(m_h_ema20);
      snap.ema50  = ReadHandleValue(m_h_ema50);
      snap.ema200 = ReadHandleValue(m_h_ema200);

      snap.rsi14 = ReadHandleValue(m_h_rsi);

      snap.macd_main      = ReadHandleValue(m_h_macd, 0);
      snap.macd_signal    = ReadHandleValue(m_h_macd, 1);
      snap.macd_histogram = snap.macd_main - snap.macd_signal;

      snap.stoch_main   = ReadHandleValue(m_h_stoch, 0);
      snap.stoch_signal = ReadHandleValue(m_h_stoch, 1);

      snap.atr14 = ReadHandleValue(m_h_atr);
      // Rata-rata ATR 50 bar tertutup terakhir, untuk baseline "volatilitas normal"
      double atr_sum = 0.0;
      int atr_count = 0;
      double atr_buf[];
      ArraySetAsSeries(atr_buf, true);
      if(m_h_atr != INVALID_HANDLE && CopyBuffer(m_h_atr, 0, 1, 50, atr_buf) > 0)
      {
         atr_count = ArraySize(atr_buf);
         for(int i = 0; i < atr_count; i++) atr_sum += atr_buf[i];
      }
      snap.atr14_avg50 = (atr_count > 0) ? (atr_sum / atr_count) : snap.atr14;

      snap.bb_upper = ReadHandleValue(m_h_bb, 1);
      snap.bb_mid   = ReadHandleValue(m_h_bb, 0);
      snap.bb_lower = ReadHandleValue(m_h_bb, 2);

      // Volume: XAUUSD tidak punya volume asli, pakai tick_volume sebagai proksi.
      // Dibaca dari candle TERTUTUP (start 1) -- volume candle yang masih berjalan
      // selalu "kecil" dan menyesatkan kalau dibandingkan dengan rata-rata.
      long tick_vol[];
      ArraySetAsSeries(tick_vol, true);
      snap.tick_volume_current = 0;
      snap.tick_volume_avg20   = 0;
      if(CopyTickVolume(m_symbol, m_working_tf, 1, 20, tick_vol) > 0)
      {
         snap.tick_volume_current = tick_vol[0];
         long sum = 0;
         for(int i = 0; i < ArraySize(tick_vol); i++) sum += tick_vol[i];
         snap.tick_volume_avg20 = sum / ArraySize(tick_vol);
      }

      // OBV proksi: akumulasi tick_volume, + kalau candle naik, - kalau turun
      double obv = 0.0;
      double obv_close[];
      long   obv_vol[];
      ArraySetAsSeries(obv_close, true);
      ArraySetAsSeries(obv_vol, true);
      int obv_bars = 30;
      if(CopyClose(m_symbol, m_working_tf, 1, obv_bars, obv_close) > 0 &&
         CopyTickVolume(m_symbol, m_working_tf, 1, obv_bars, obv_vol) > 0)
      {
         int n = MathMin(ArraySize(obv_close), ArraySize(obv_vol));
         for(int i = n - 2; i >= 0; i--)
         {
            if(obv_close[i] > obv_close[i + 1]) obv += (double)obv_vol[i];
            else if(obv_close[i] < obv_close[i + 1]) obv -= (double)obv_vol[i];
         }
      }
      snap.obv_proxy = obv;
   }

   //+---------------------------------------------------------------+
   //| Support/Resistance klasik: Pivot Point + Fibonacci (AI #5)       |
   //+---------------------------------------------------------------+
   void FillSupportResistance(SMarketSnapshot &snap)
   {
      // Pivot Point standar dari candle Daily SEBELUMNYA (shift=1)
      double prev_high  = iHigh(m_symbol, PERIOD_D1, 1);
      double prev_low   = iLow(m_symbol, PERIOD_D1, 1);
      double prev_close = iClose(m_symbol, PERIOD_D1, 1);

      double pp = (prev_high + prev_low + prev_close) / 3.0;
      snap.pivot_pp = pp;
      snap.pivot_r1 = (2.0 * pp) - prev_low;
      snap.pivot_s1 = (2.0 * pp) - prev_high;
      snap.pivot_r2 = pp + (prev_high - prev_low);
      snap.pivot_s2 = pp - (prev_high - prev_low);
      snap.pivot_r3 = prev_high + 2.0 * (pp - prev_low);
      snap.pivot_s3 = prev_low - 2.0 * (prev_high - pp);

      // Fibonacci retracement dari swing high/low 50 candle terakhir di working TF
      int lookback = 50;
      double highs[], lows[];
      ArraySetAsSeries(highs, true);
      ArraySetAsSeries(lows, true);

      double swing_high = 0.0, swing_low = 0.0;
      if(CopyHigh(m_symbol, m_working_tf, 1, lookback, highs) > 0 &&
         CopyLow(m_symbol, m_working_tf, 1, lookback, lows) > 0)
      {
         swing_high = highs[ArrayMaximum(highs)];
         swing_low  = lows[ArrayMinimum(lows)];
      }

      snap.fib_swing_high = swing_high;
      snap.fib_swing_low  = swing_low;

      double range = swing_high - swing_low;
      // Retracement dihitung dari swing_high ke bawah (asumsi umum uptrend);
      // AI analis yang membaca angka ini tetap perlu membandingkan dengan
      // trend aktif (EMA) untuk menentukan level mana yang relevan.
      snap.fib_236 = swing_high - (range * 0.236);
      snap.fib_382 = swing_high - (range * 0.382);
      snap.fib_500 = swing_high - (range * 0.500);
      snap.fib_618 = swing_high - (range * 0.618);
      snap.fib_786 = swing_high - (range * 0.786);
   }

   //+---------------------------------------------------------------+
   //| Smart Money Concepts - heuristik sederhana (AI #6)               |
   //+---------------------------------------------------------------+
   // PENJELASAN: seperti smc.js di project 1, ini heuristik berbasis
   // aturan harga sederhana, BUKAN implementasi presisi institusional.
   // Order Block   -> candle berlawanan arah terakhir sebelum pergerakan
   //                  impulsif yang kuat (>1.5x ATR).
   // FVG           -> celah (gap) antara high candle[i-1] dan low candle[i+1]
   //                  yang tidak tertutup candle[i] (fair value gap 3-candle).
   // BoS           -> harga saat ini menembus swing high/low signifikan
   //                  sebelumnya (breakout struktur).
   // Liquidity Grab -> harga sempat menembus swing high/low lalu ditutup
   //                  kembali di dalamnya (sweep/stop hunt lalu reversal).
   void FillSmartMoneyConcepts(SMarketSnapshot &snap)
   {
      int bars = 30;
      double h[], l[], o[], c[];
      ArraySetAsSeries(h, true); ArraySetAsSeries(l, true);
      ArraySetAsSeries(o, true); ArraySetAsSeries(c, true);

      if(CopyHigh(m_symbol, m_working_tf, 1, bars, h) <= 0 ||
         CopyLow(m_symbol, m_working_tf, 1, bars, l) <= 0 ||
         CopyOpen(m_symbol, m_working_tf, 1, bars, o) <= 0 ||
         CopyClose(m_symbol, m_working_tf, 1, bars, c) <= 0)
      {
         return; // data tidak cukup, biarkan semua flag SMC default (false/0)
      }

      double atr = snap.atr14 > 0 ? snap.atr14 : 1.0;

      // --- Order Block: cari candle berlawanan sebelum gerakan impulsif ---
      for(int i = 2; i < bars - 1; i++)
      {
         double move = c[i - 1] - o[i - 1];
         bool impulsif_naik  = (move > atr * 1.5);
         bool impulsif_turun = (move < -atr * 1.5);

         bool candle_i_bearish = (c[i] < o[i]);
         bool candle_i_bullish = (c[i] > o[i]);

         if(impulsif_naik && candle_i_bearish && !snap.smc_bullish_order_block)
         {
            snap.smc_bullish_order_block = true;
            snap.smc_bullish_ob_price = o[i]; // open candle bearish = area order block bullish
         }
         if(impulsif_turun && candle_i_bullish && !snap.smc_bearish_order_block)
         {
            snap.smc_bearish_order_block = true;
            snap.smc_bearish_ob_price = o[i];
         }
      }

      // --- Fair Value Gap (3-candle gap) ---
      for(int i = 1; i < bars - 1; i++)
      {
         // Bullish FVG: low candle[i-1] > high candle[i+1] -> ada celah naik
         if(l[i - 1] > h[i + 1] && !snap.smc_bullish_fvg)
         {
            snap.smc_bullish_fvg = true;
            snap.smc_fvg_lower = h[i + 1];
            snap.smc_fvg_upper = l[i - 1];
         }
         // Bearish FVG: high candle[i-1] < low candle[i+1] -> ada celah turun
         if(h[i - 1] < l[i + 1] && !snap.smc_bearish_fvg)
         {
            snap.smc_bearish_fvg = true;
         }
      }

      // --- Break of Structure: harga sekarang tembus swing high/low 20 bar sebelumnya ---
      double recent_high = h[ArrayMaximum(h, 2, 20)];
      double recent_low  = l[ArrayMinimum(l, 2, 20)];
      snap.smc_bos_bullish = (c[0] > recent_high);
      snap.smc_bos_bearish = (c[0] < recent_low);

      // --- Liquidity Grab: high/low candle terakhir menembus swing, tapi close balik masuk ---
      snap.smc_liquidity_grab_high = (h[0] > recent_high && c[0] < recent_high);
      snap.smc_liquidity_grab_low  = (l[0] < recent_low && c[0] > recent_low);
   }

   //+---------------------------------------------------------------+
   //| Deteksi pola candlestick native dari OHLC (pengganti AI foto)   |
   //+---------------------------------------------------------------+
   ENUM_CANDLE_PATTERN DetectCandlePattern()
   {
      // PENJELASAN FIX: versi lama memakai array statis (bukan series) sehingga
      // index [0] sebenarnya candle LAMA dan [1] candle baru -- terbalik dari
      // yang dikira logika di bawah. Sekarang array di-set series dan diambil
      // dari candle TERTUTUP: index 0 = candle tertutup terakhir, 1 = sebelumnya.
      double o[], h[], l[], c[];
      ArraySetAsSeries(o, true); ArraySetAsSeries(h, true);
      ArraySetAsSeries(l, true); ArraySetAsSeries(c, true);

      if(CopyOpen(m_symbol, m_working_tf, 1, 2, o) < 2)  return PATTERN_NONE;
      if(CopyHigh(m_symbol, m_working_tf, 1, 2, h) < 2)  return PATTERN_NONE;
      if(CopyLow(m_symbol, m_working_tf, 1, 2, l) < 2)   return PATTERN_NONE;
      if(CopyClose(m_symbol, m_working_tf, 1, 2, c) < 2) return PATTERN_NONE;

      double body0 = MathAbs(c[0] - o[0]);
      double range0 = h[0] - l[0];

      if(range0 <= 0) return PATTERN_NONE;

      // Bullish Engulfing: candle[1] bearish, candle[0] bullish & body-nya
      // membungkus penuh body candle[1]
      bool c1_bearish = c[1] < o[1];
      bool c0_bullish = c[0] > o[0];
      if(c1_bearish && c0_bullish && c[0] > o[1] && o[0] < c[1])
         return PATTERN_BULLISH_ENGULFING;

      bool c1_bullish = c[1] > o[1];
      bool c0_bearish = c[0] < o[0];
      if(c1_bullish && c0_bearish && o[0] > c[1] && c[0] < o[1])
         return PATTERN_BEARISH_ENGULFING;

      // Pin Bar: body kecil (<30% range), ekor panjang di satu sisi (>60% range)
      double upper_wick = h[0] - MathMax(o[0], c[0]);
      double lower_wick = MathMin(o[0], c[0]) - l[0];

      if(body0 < range0 * 0.3)
      {
         if(lower_wick > range0 * 0.6) return PATTERN_BULLISH_PIN_BAR;
         if(upper_wick > range0 * 0.6) return PATTERN_BEARISH_PIN_BAR;
      }

      // Inside Bar: high/low candle[0] sepenuhnya di dalam range candle[1]
      if(h[0] < h[1] && l[0] > l[1]) return PATTERN_INSIDE_BAR;

      return PATTERN_NONE;
   }

   //+---------------------------------------------------------------+
   //| Tentukan sesi trading aktif dari waktu server broker (AI #7)    |
   //+---------------------------------------------------------------+
   ENUM_TRADING_SESSION DetectSession()
   {
      MqlDateTime dt;
      TimeToStruct(TimeTradeServer(), dt);

      // Konversi jam server ke perkiraan jam GMT memakai offset broker
      int gmt_hour = (dt.hour - m_broker_gmt_offset + 24) % 24;

      if(gmt_hour >= 0  && gmt_hour < 8)  return SESSION_ASIA;
      if(gmt_hour >= 8  && gmt_hour < 13) return SESSION_LONDON;
      if(gmt_hour >= 13 && gmt_hour < 16) return SESSION_LONDON_NY_OVERLAP;
      if(gmt_hour >= 16 && gmt_hour < 21) return SESSION_NY;
      return SESSION_QUIET;
   }

   //+---------------------------------------------------------------+
   //| Multi-Timeframe Alignment (AI #8)                                |
   //+---------------------------------------------------------------+
   string TrendLabelFromHandles(const int h_fast, const int h_slow)
   {
      double fast = ReadHandleValue(h_fast);
      double slow = ReadHandleValue(h_slow);

      if(fast == 0.0 || slow == 0.0) return "SIDEWAYS";

      double diff_pct = MathAbs(fast - slow) / slow * 100.0;
      if(diff_pct < 0.05) return "SIDEWAYS"; // terlalu dekat, anggap netral

      return (fast > slow) ? "BULLISH" : "BEARISH";
   }

   void FillMultiTimeframe(SMarketSnapshot &snap)
   {
      snap.trend_working_tf = TrendLabelFromHandles(m_h_ema20, m_h_ema50);
      snap.trend_higher_tf  = TrendLabelFromHandles(m_h_htf_fast, m_h_htf_slow);

      bool both_bullish = (snap.trend_working_tf == "BULLISH" && snap.trend_higher_tf == "BULLISH");
      bool both_bearish = (snap.trend_working_tf == "BEARISH" && snap.trend_higher_tf == "BEARISH");
      snap.mtf_aligned = both_bullish || both_bearish;
   }

   //+---------------------------------------------------------------+
   //| Konteks Makro XAUUSD: DXY kalau ada, fallback korelasi EURUSD    |
   //+---------------------------------------------------------------+
   void FillMacroContext(SMarketSnapshot &snap)
   {
      snap.macro_dxy_available  = false;
      snap.macro_dxy_price      = 0.0;
      snap.macro_dxy_change_pct = 0.0;

      if(StringLen(m_dxy_symbol) > 0 && SymbolSelect(m_dxy_symbol, true))
      {
         double dxy_price = SymbolInfoDouble(m_dxy_symbol, SYMBOL_BID);
         if(dxy_price > 0)
         {
            snap.macro_dxy_available = true;
            snap.macro_dxy_price = dxy_price;

            if(m_prev_macro_dxy_price > 0)
            {
               snap.macro_dxy_change_pct =
                  (dxy_price - m_prev_macro_dxy_price) / m_prev_macro_dxy_price * 100.0;
            }
            m_prev_macro_dxy_price = dxy_price;
         }
      }

      // Korelasi return XAUUSD vs EURUSD (proksi dolar kalau symbol DXY
      // tidak tersedia di broker). Korelasi historis XAUUSD-EURUSD cenderung
      // POSITIF (keduanya sama-sama "anti-dolar"), jadi korelasi yang
      // MELEMAH/berbalik negatif justru sinyal ada faktor lain yang dominan
      // (misal safe-haven flow khusus emas, bukan sekadar pelemahan dolar).
      snap.macro_correlation_eurusd = CalculateCorrelation(m_symbol, m_macro_proxy_symbol, m_working_tf, 30);
   }

   //+---------------------------------------------------------------+
   //| Hitung korelasi Pearson sederhana dari return 2 simbol           |
   //+---------------------------------------------------------------+
   double CalculateCorrelation(const string sym_a, const string sym_b,
                                const ENUM_TIMEFRAMES tf, const int bars)
   {
      if(!SymbolSelect(sym_b, true)) return 0.0;

      double close_a[], close_b[];
      ArraySetAsSeries(close_a, true);
      ArraySetAsSeries(close_b, true);

      int copied_a = CopyClose(sym_a, tf, 0, bars + 1, close_a);
      int copied_b = CopyClose(sym_b, tf, 0, bars + 1, close_b);
      if(copied_a <= 1 || copied_b <= 1) return 0.0;

      int n = MathMin(copied_a, copied_b) - 1;
      if(n < 5) return 0.0; // data terlalu sedikit untuk korelasi yang berarti

      double ret_a[], ret_b[];
      ArrayResize(ret_a, n);
      ArrayResize(ret_b, n);
      for(int i = 0; i < n; i++)
      {
         ret_a[i] = (close_a[i] - close_a[i + 1]) / close_a[i + 1];
         ret_b[i] = (close_b[i] - close_b[i + 1]) / close_b[i + 1];
      }

      double mean_a = 0.0, mean_b = 0.0;
      for(int i = 0; i < n; i++) { mean_a += ret_a[i]; mean_b += ret_b[i]; }
      mean_a /= n; mean_b /= n;

      double cov = 0.0, var_a = 0.0, var_b = 0.0;
      for(int i = 0; i < n; i++)
      {
         double da = ret_a[i] - mean_a;
         double db = ret_b[i] - mean_b;
         cov   += da * db;
         var_a += da * da;
         var_b += db * db;
      }

      if(var_a <= 0.0 || var_b <= 0.0) return 0.0;

      double correlation = cov / MathSqrt(var_a * var_b);
      return MathMax(-1.0, MathMin(1.0, correlation));
   }

   //+---------------------------------------------------------------+
   //| Risk Management: saran jarak SL/TP berbasis ATR (AI #10)        |
   //+---------------------------------------------------------------+
   void FillRiskManagement(SMarketSnapshot &snap)
   {
      snap.daily_high = iHigh(m_symbol, PERIOD_D1, 0);
      snap.daily_low  = iLow(m_symbol, PERIOD_D1, 0);
      snap.daily_open = iOpen(m_symbol, PERIOD_D1, 0);

      double atr = (snap.atr14 > 0) ? snap.atr14 : (snap.atr14_avg50 > 0 ? snap.atr14_avg50 : 0.001);
      snap.suggested_sl_distance = atr * 1.5;
      snap.suggested_tp_distance = atr * 3.0; // risk-reward ~1:2 sebagai baseline
   }

public:
   //+---------------------------------------------------------------+
   //| Constructor                                                       |
   //+---------------------------------------------------------------+
   CMarketDataEngine()
   {
      m_symbol             = _Symbol;
      m_working_tf         = PERIOD_M15;
      m_higher_tf          = PERIOD_H4;
      m_macro_proxy_symbol = "EURUSD";
      m_dxy_symbol         = "";
      m_broker_gmt_offset  = 0;
      m_prev_macro_dxy_price = 0.0;

      m_h_ema20 = m_h_ema50 = m_h_ema200 = INVALID_HANDLE;
      m_h_rsi = m_h_macd = m_h_stoch = m_h_atr = m_h_bb = INVALID_HANDLE;
      m_h_htf_fast = m_h_htf_slow = INVALID_HANDLE;
      m_not_ready_logged = false;
   }

   ~CMarketDataEngine()
   {
      ReleaseHandles();
   }

   //+---------------------------------------------------------------+
   //| Apakah semua indikator sudah selesai dihitung terminal?          |
   //+---------------------------------------------------------------+
   // EA utama menunda siklus analisa sampai ini true, supaya snapshot
   // tidak pernah berisi nol-nol palsu di menit-menit pertama.
   bool IsReady()
   {
      bool ready = HandleReady(m_h_ema20) && HandleReady(m_h_ema50) && HandleReady(m_h_ema200) &&
                   HandleReady(m_h_rsi) && HandleReady(m_h_macd) && HandleReady(m_h_stoch) &&
                   HandleReady(m_h_atr) && HandleReady(m_h_bb) &&
                   HandleReady(m_h_htf_fast) && HandleReady(m_h_htf_slow);
      if(!ready && !m_not_ready_logged)
      {
         Print("MarketData: indikator belum siap dihitung terminal, siklus analisa ditunda sebentar...");
         m_not_ready_logged = true;
      }
      if(ready) m_not_ready_logged = false;
      return ready;
   }

   //+---------------------------------------------------------------+
   //| Konfigurasi parameter engine - dipanggil dari OnInit() EA        |
   //+---------------------------------------------------------------+
   void Configure(const string symbol, const ENUM_TIMEFRAMES working_tf,
                  const ENUM_TIMEFRAMES higher_tf, const string macro_proxy_symbol,
                  const string dxy_symbol, const int broker_gmt_offset)
   {
      m_symbol             = symbol;
      m_working_tf         = working_tf;
      m_higher_tf          = higher_tf;
      m_macro_proxy_symbol = macro_proxy_symbol;
      m_dxy_symbol         = dxy_symbol;
      m_broker_gmt_offset  = broker_gmt_offset;

      // Buat ulang handle indikator sesuai symbol/timeframe terbaru
      ReleaseHandles();
      CreateHandles();
   }

   //+---------------------------------------------------------------+
   //| Bangun snapshot lengkap - dipanggil 1x per siklus analisa AI     |
   //+---------------------------------------------------------------+
   SMarketSnapshot BuildSnapshot()
   {
      // PENJELASAN FIX: ZeroMemory() TIDAK AMAN dipakai pada struct yang
      // punya field string (string di MQL5 adalah objek ber-reference-count,
      // di-zero paksa lewat memori mentah bisa merusak internal string dan
      // menyebabkan crash). Inisialisasi "={}" adalah cara resmi MQL5 untuk
      // menzero-kan struct campuran string+angka dengan aman.
      SMarketSnapshot snap = {};

      snap.symbol        = m_symbol;
      snap.snapshot_time = TimeCurrent();
      snap.bid           = SymbolInfoDouble(m_symbol, SYMBOL_BID);
      snap.ask           = SymbolInfoDouble(m_symbol, SYMBOL_ASK);
      snap.spread_points = (double)SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
      snap.point         = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      snap.digits        = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);

      FillIndicators(snap);
      FillSupportResistance(snap);
      FillSmartMoneyConcepts(snap);

      snap.candle_pattern   = DetectCandlePattern();
      snap.current_session  = DetectSession();
      snap.volatility_relative_pct =
         (snap.atr14_avg50 > 0) ? ((snap.atr14 / snap.atr14_avg50) * 100.0) : 100.0;

      FillMultiTimeframe(snap);
      FillMacroContext(snap);
      FillRiskManagement(snap);

      return snap;
   }
};
