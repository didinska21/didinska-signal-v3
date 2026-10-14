//+------------------------------------------------------------------+
//|                                                    Analysts.mqh   |
//|         Didinska Grid V2 - 10 AI Analis Spesialis                  |
//|                                                                    |
//|   Modul ini adalah "otak" 10 sudut pandang berbeda. Tiap analis     |
//|   membaca SATU SNAPSHOT PASAR YANG SAMA (SMarketSnapshot dari       |
//|   MarketData.mqh), tapi fokus ke aspek berbeda dan dikirim ke Groq  |
//|   lewat slot API key masing-masing (0-9, lihat GroqClient.mqh).     |
//|                                                                    |
//|   SEMUA analis WAJIB balas dengan skema JSON yang SAMA supaya       |
//|   AISummarizer.mqh bisa merangkum tanpa perlu tahu analis mana      |
//|   yang bicara:                                                     |
//|     { "bias": "BULLISH"|"BEARISH"|"NEUTRAL",                       |
//|       "confidence": 0.0-1.0,                                       |
//|       "reasoning": "penjelasan singkat 1-2 kalimat" }              |
//+------------------------------------------------------------------+
#property copyright "Didinska Grid V2"
#property strict

#include "GroqClient.mqh"
#include "MarketData.mqh"

//+------------------------------------------------------------------+
//| Jumlah analis spesialis (TIDAK termasuk AI Penyimpul)               |
//+------------------------------------------------------------------+
#define ANALYST_COUNT 10

//+------------------------------------------------------------------+
//| Arah pandangan satu analis                                         |
//+------------------------------------------------------------------+
enum ENUM_ANALYST_BIAS
{
   ANALYST_BIAS_NEUTRAL = 0,
   ANALYST_BIAS_BULLISH = 1,
   ANALYST_BIAS_BEARISH = 2
};

//+------------------------------------------------------------------+
//| Hasil opini satu analis (setelah di-parse dari JSON)                |
//+------------------------------------------------------------------+
struct SAnalystOpinion
{
   int                  analyst_id;     // 0-9
   string               analyst_name;   // nama tampilan, misal "Trend (Moving Averages)"
   bool                 success;        // false kalau pemanggilan AI gagal total (primer+cadangan)
   bool                 used_reserve_key;
   ENUM_ANALYST_BIAS    bias;
   double               confidence;     // 0.0 - 1.0
   string               reasoning;
   string               error_message;  // terisi kalau success = false
};

//+------------------------------------------------------------------+
//| CAnalystEngine - orkestrasi 10 pemanggilan AI analis                |
//+------------------------------------------------------------------+
class CAnalystEngine
{
private:
   CGroqClient       *m_groq_client;   // pointer ke instance bersama (dibuat di EA utama)
   string             m_analyst_names[ANALYST_COUNT];

   //+---------------------------------------------------------------+
   //| Instruksi skema JSON yang WAJIB dipatuhi semua analis            |
   //+---------------------------------------------------------------+
   string BuildSystemPrompt(const string role_description)
   {
      string prompt = "Anda adalah seorang analis trading profesional khusus XAUUSD (emas). ";
      prompt += "Peran spesifik Anda: " + role_description + " ";
      prompt += "Balas HANYA dengan satu objek JSON valid, tanpa markdown, tanpa teks tambahan, ";
      prompt += "dengan skema PERSIS berikut:\n";
      prompt += "{\"bias\":\"BULLISH\"|\"BEARISH\"|\"NEUTRAL\",";
      prompt += "\"confidence\":0.0-1.0,";
      prompt += "\"reasoning\":\"penjelasan singkat 1-2 kalimat dalam Bahasa Indonesia\"}";
      return prompt;
   }

   //+---------------------------------------------------------------+
   //| Helper format enum -> teks untuk ditaruh di prompt               |
   //+---------------------------------------------------------------+
   string SessionToText(const ENUM_TRADING_SESSION session)
   {
      switch(session)
      {
         case SESSION_ASIA:                return "Asia (likuiditas rendah, rawan choppy)";
         case SESSION_LONDON:               return "London (volatilitas mulai naik)";
         case SESSION_LONDON_NY_OVERLAP:     return "Overlap London-NY (volatilitas TERTINGGI)";
         case SESSION_NY:                   return "New York (masih aktif)";
         case SESSION_QUIET:                return "Quiet/Sepi (likuiditas sangat rendah)";
         default:                           return "Tidak diketahui";
      }
   }

   string CandlePatternToText(const ENUM_CANDLE_PATTERN pattern)
   {
      switch(pattern)
      {
         case PATTERN_BULLISH_ENGULFING:  return "Bullish Engulfing";
         case PATTERN_BEARISH_ENGULFING:  return "Bearish Engulfing";
         case PATTERN_BULLISH_PIN_BAR:    return "Bullish Pin Bar (rejection dari bawah)";
         case PATTERN_BEARISH_PIN_BAR:    return "Bearish Pin Bar (rejection dari atas)";
         case PATTERN_INSIDE_BAR:         return "Inside Bar (konsolidasi)";
         default:                         return "Tidak ada pola signifikan";
      }
   }

   //+---------------------------------------------------------------+
   //| AI #1: Trend (Moving Averages)                                   |
   //+---------------------------------------------------------------+
   string BuildPrompt_Trend(const SMarketSnapshot &s)
   {
      string p = "Analisa TREND berdasarkan Moving Average:\n";
      p += "- Harga saat ini: " + DoubleToString(s.bid, s.digits) + "\n";
      p += "- EMA 20: " + DoubleToString(s.ema20, s.digits) + "\n";
      p += "- EMA 50: " + DoubleToString(s.ema50, s.digits) + "\n";
      p += "- EMA 200: " + DoubleToString(s.ema200, s.digits) + "\n";
      p += "Tentukan apakah trend sedang BULLISH, BEARISH, atau NEUTRAL berdasarkan susunan EMA ";
      p += "dan posisi harga terhadap ketiganya.";
      return p;
   }

   //+---------------------------------------------------------------+
   //| AI #2: Momentum (Oscillators)                                    |
   //+---------------------------------------------------------------+
   string BuildPrompt_Momentum(const SMarketSnapshot &s)
   {
      string p = "Analisa MOMENTUM berdasarkan indikator osilator:\n";
      p += "- RSI(14): " + DoubleToString(s.rsi14, 2) + "\n";
      p += "- MACD Main: " + DoubleToString(s.macd_main, 5) + "\n";
      p += "- MACD Signal: " + DoubleToString(s.macd_signal, 5) + "\n";
      p += "- MACD Histogram: " + DoubleToString(s.macd_histogram, 5) + "\n";
      p += "- Stochastic Main: " + DoubleToString(s.stoch_main, 2) + "\n";
      p += "- Stochastic Signal: " + DoubleToString(s.stoch_signal, 2) + "\n";
      p += "Tentukan momentum saat ini: apakah mendukung penerusan (BULLISH/BEARISH) atau jenuh/divergen (NEUTRAL).";
      return p;
   }

   //+---------------------------------------------------------------+
   //| AI #3: Volatilitas (Bands & ATR)                                 |
   //+---------------------------------------------------------------+
   string BuildPrompt_Volatility(const SMarketSnapshot &s)
   {
      string p = "Analisa VOLATILITAS berdasarkan Bollinger Bands & ATR:\n";
      p += "- Harga saat ini: " + DoubleToString(s.bid, s.digits) + "\n";
      p += "- Bollinger Upper: " + DoubleToString(s.bb_upper, s.digits) + "\n";
      p += "- Bollinger Mid: " + DoubleToString(s.bb_mid, s.digits) + "\n";
      p += "- Bollinger Lower: " + DoubleToString(s.bb_lower, s.digits) + "\n";
      p += "- ATR(14) saat ini: " + DoubleToString(s.atr14, 5) + "\n";
      p += "- ATR(14) rata-rata 50 bar: " + DoubleToString(s.atr14_avg50, 5) + "\n";
      p += "Tentukan apakah volatilitas mendukung breakout (dan ke arah mana) atau justru mean-reversion ke tengah band.";
      return p;
   }

   //+---------------------------------------------------------------+
   //| AI #4: Volume (Aliran Uang)                                      |
   //+---------------------------------------------------------------+
   string BuildPrompt_Volume(const SMarketSnapshot &s)
   {
      string p = "Analisa ALIRAN VOLUME (tick volume dipakai sebagai proksi, karena XAUUSD CFD tidak punya volume transaksi asli):\n";
      p += "- Tick Volume candle saat ini: " + IntegerToString((int)s.tick_volume_current) + "\n";
      p += "- Rata-rata Tick Volume 20 candle: " + IntegerToString((int)s.tick_volume_avg20) + "\n";
      p += "- OBV proksi (akumulasi volume searah candle): " + DoubleToString(s.obv_proxy, 0) + "\n";
      p += "Tentukan apakah aliran volume mengkonfirmasi pergerakan harga (BULLISH/BEARISH) atau menunjukkan pelemahan minat (NEUTRAL).";
      return p;
   }

   //+---------------------------------------------------------------+
   //| AI #5: Support & Resistance                                      |
   //+---------------------------------------------------------------+
   string BuildPrompt_SupportResistance(const SMarketSnapshot &s)
   {
      string p = "Analisa SUPPORT & RESISTANCE berdasarkan Pivot Point dan Fibonacci:\n";
      p += "- Harga saat ini: " + DoubleToString(s.bid, s.digits) + "\n";
      p += "- Pivot Point: " + DoubleToString(s.pivot_pp, s.digits) + "\n";
      p += "- Resistance: R1=" + DoubleToString(s.pivot_r1, s.digits) +
           " R2=" + DoubleToString(s.pivot_r2, s.digits) +
           " R3=" + DoubleToString(s.pivot_r3, s.digits) + "\n";
      p += "- Support: S1=" + DoubleToString(s.pivot_s1, s.digits) +
           " S2=" + DoubleToString(s.pivot_s2, s.digits) +
           " S3=" + DoubleToString(s.pivot_s3, s.digits) + "\n";
      p += "- Fibonacci dari swing " + DoubleToString(s.fib_swing_low, s.digits) +
           " - " + DoubleToString(s.fib_swing_high, s.digits) + ": ";
      p += "23.6%=" + DoubleToString(s.fib_236, s.digits) +
           " 38.2%=" + DoubleToString(s.fib_382, s.digits) +
           " 50%=" + DoubleToString(s.fib_500, s.digits) +
           " 61.8%=" + DoubleToString(s.fib_618, s.digits) +
           " 78.6%=" + DoubleToString(s.fib_786, s.digits) + "\n";
      p += "Tentukan apakah harga sedang dekat level kunci yang mendukung reversal/lanjutan, dan ke arah mana.";
      return p;
   }

   //+---------------------------------------------------------------+
   //| AI #6: Smart Money Concepts                                      |
   //+---------------------------------------------------------------+
   string BuildPrompt_SMC(const SMarketSnapshot &s)
   {
      string p = "Analisa SMART MONEY CONCEPTS (heuristik order block, FVG, break of structure, liquidity grab):\n";
      p += "- Order Block Bullish terdeteksi: " + (s.smc_bullish_order_block ? ("YA, di harga " + DoubleToString(s.smc_bullish_ob_price, s.digits)) : "TIDAK") + "\n";
      p += "- Order Block Bearish terdeteksi: " + (s.smc_bearish_order_block ? ("YA, di harga " + DoubleToString(s.smc_bearish_ob_price, s.digits)) : "TIDAK") + "\n";
      p += "- Fair Value Gap Bullish: " + (s.smc_bullish_fvg ? ("YA, area " + DoubleToString(s.smc_fvg_lower, s.digits) + "-" + DoubleToString(s.smc_fvg_upper, s.digits)) : "TIDAK") + "\n";
      p += "- Fair Value Gap Bearish: " + (s.smc_bearish_fvg ? "YA" : "TIDAK") + "\n";
      p += "- Break of Structure ke atas: " + (s.smc_bos_bullish ? "YA" : "TIDAK") + "\n";
      p += "- Break of Structure ke bawah: " + (s.smc_bos_bearish ? "YA" : "TIDAK") + "\n";
      p += "- Liquidity Grab di atas (sweep lalu turun): " + (s.smc_liquidity_grab_high ? "YA" : "TIDAK") + "\n";
      p += "- Liquidity Grab di bawah (sweep lalu naik): " + (s.smc_liquidity_grab_low ? "YA" : "TIDAK") + "\n";
      p += "Tentukan bias arah berdasarkan konfluensi sinyal SMC di atas.";
      return p;
   }

   //+---------------------------------------------------------------+
   //| AI #7: Price Action Native + Sesi (pengganti AI foto project 1)  |
   //+---------------------------------------------------------------+
   string BuildPrompt_PriceActionSession(const SMarketSnapshot &s)
   {
      string p = "Analisa PRICE ACTION & KONTEKS SESI TRADING:\n";
      p += "- Pola candlestick terakhir: " + CandlePatternToText(s.candle_pattern) + "\n";
      p += "- Sesi trading aktif saat ini: " + SessionToText(s.current_session) + "\n";
      p += "- Volatilitas relatif (ATR sekarang vs rata-rata 50 bar): " + DoubleToString(s.volatility_relative_pct, 1) + "%\n";
      p += "  (di atas 100% = lebih volatile dari biasanya, di bawah 100% = lebih tenang dari biasanya)\n";
      p += "Pertimbangkan bahwa sesi Asia rawan pergerakan choppy/breakout palsu, sementara sesi Overlap London-NY ";
      p += "pergerakannya lebih bisa dipercaya. Tentukan bias arah dari kombinasi pola candlestick dan konteks sesi ini.";
      return p;
   }

   //+---------------------------------------------------------------+
   //| AI #8: Multi-Timeframe Alignment                                 |
   //+---------------------------------------------------------------+
   string BuildPrompt_MTF(const SMarketSnapshot &s)
   {
      string p = "Analisa KESELARASAN MULTI-TIMEFRAME:\n";
      p += "- Trend di timeframe kerja (working TF): " + s.trend_working_tf + "\n";
      p += "- Trend di timeframe lebih tinggi (higher TF): " + s.trend_higher_tf + "\n";
      p += "- Status keselarasan: " + (s.mtf_aligned ? "SELARAS (searah)" : "TIDAK SELARAS (berlawanan/campuran)") + "\n";
      p += "Trend higher TF lebih dominan sebagai konteks utama. Tentukan bias arah dengan mempertimbangkan ";
      p += "bahwa sinyal working TF yang searah higher TF jauh lebih dipercaya daripada yang melawannya.";
      return p;
   }

   //+---------------------------------------------------------------+
   //| AI #9: Konteks Makro XAUUSD (pengganti AI Makro Kripto)          |
   //+---------------------------------------------------------------+
   string BuildPrompt_MacroXAUUSD(const SMarketSnapshot &s)
   {
      string p = "Analisa KONTEKS MAKRO untuk XAUUSD (emas):\n";
      if(s.macro_dxy_available)
      {
         p += "- Dollar Index (DXY) tersedia, harga: " + DoubleToString(s.macro_dxy_price, 3) + "\n";
         p += "- Perubahan DXY sejak siklus analisa sebelumnya: " + DoubleToString(s.macro_dxy_change_pct, 3) + "%\n";
         p += "Ingat: DXY dan XAUUSD secara historis berkorelasi NEGATIF (DXY naik -> gold cenderung tertekan, dan sebaliknya).\n";
      }
      else
      {
         p += "- Data DXY tidak tersedia di broker ini, dipakai proksi:\n";
      }
      p += "- Korelasi return XAUUSD vs EURUSD (30 bar terakhir): " + DoubleToString(s.macro_correlation_eurusd, 3) + "\n";
      p += "  (rentang -1.0 s/d 1.0; historis XAUUSD-EURUSD cenderung POSITIF karena sama-sama pergerakan anti-dolar; ";
      p += "korelasi yang melemah/negatif mengindikasikan ada faktor safe-haven/lain yang lebih dominan dari sekadar tren dolar)\n";
      p += "Tentukan bias arah XAUUSD dari konteks makro dolar di atas.";
      return p;
   }

   //+---------------------------------------------------------------+
   //| AI #10: Risk Management                                          |
   //+---------------------------------------------------------------+
   string BuildPrompt_RiskManagement(const SMarketSnapshot &s)
   {
      string p = "Analisa RISK MANAGEMENT untuk kesiapan entry:\n";
      p += "- Spread saat ini: " + DoubleToString(s.spread_points, 1) + " poin\n";
      p += "- Daily High: " + DoubleToString(s.daily_high, s.digits) + "\n";
      p += "- Daily Low: " + DoubleToString(s.daily_low, s.digits) + "\n";
      p += "- Daily Open: " + DoubleToString(s.daily_open, s.digits) + "\n";
      p += "- Saran jarak SL berbasis ATR: " + DoubleToString(s.suggested_sl_distance, s.digits) + "\n";
      p += "- Saran jarak TP berbasis ATR (risk-reward ~1:2): " + DoubleToString(s.suggested_tp_distance, s.digits) + "\n";
      p += "Nilai apakah kondisi risiko saat ini (spread, jarak dari daily high/low) cukup aman untuk entry baru. ";
      p += "Bias NEUTRAL kalau kondisi risiko dinilai kurang mendukung (misal harga terlalu dekat daily high/low ekstrem, spread melebar).";
      return p;
   }

   //+---------------------------------------------------------------+
   //| Susun prompt sesuai nomor analis (0-9)                           |
   //+---------------------------------------------------------------+
   string BuildUserPrompt(const int analyst_id, const SMarketSnapshot &s)
   {
      switch(analyst_id)
      {
         case 0: return BuildPrompt_Trend(s);
         case 1: return BuildPrompt_Momentum(s);
         case 2: return BuildPrompt_Volatility(s);
         case 3: return BuildPrompt_Volume(s);
         case 4: return BuildPrompt_SupportResistance(s);
         case 5: return BuildPrompt_SMC(s);
         case 6: return BuildPrompt_PriceActionSession(s);
         case 7: return BuildPrompt_MTF(s);
         case 8: return BuildPrompt_MacroXAUUSD(s);
         case 9: return BuildPrompt_RiskManagement(s);
         default: return "";
      }
   }

   string GetRoleDescription(const int analyst_id)
   {
      switch(analyst_id)
      {
         case 0: return "spesialis TREND, membaca arah pasar dari susunan Moving Average.";
         case 1: return "spesialis MOMENTUM, membaca kekuatan/kelemahan pergerakan dari osilator (RSI, MACD, Stochastic).";
         case 2: return "spesialis VOLATILITAS, membaca potensi breakout/reversion dari Bollinger Bands dan ATR.";
         case 3: return "spesialis VOLUME, membaca konfirmasi pergerakan dari aliran tick volume.";
         case 4: return "spesialis SUPPORT & RESISTANCE, membaca level kunci dari Pivot Point dan Fibonacci.";
         case 5: return "spesialis SMART MONEY CONCEPTS, membaca jejak institusional dari order block, FVG, break of structure, dan liquidity grab.";
         case 6: return "spesialis PRICE ACTION & SESI TRADING, membaca pola candlestick dan konteks likuiditas sesi.";
         case 7: return "spesialis MULTI-TIMEFRAME, memastikan sinyal timeframe kerja selaras dengan timeframe lebih tinggi.";
         case 8: return "spesialis MAKRO XAUUSD, membaca konteks Dollar Index/korelasi dolar terhadap harga emas.";
         case 9: return "spesialis RISK MANAGEMENT, menilai kelayakan risiko sebelum entry baru dibuka.";
         default: return "analis umum.";
      }
   }

   //+---------------------------------------------------------------+
   //| Parsing sederhana JSON opini analis (skema seragam)              |
   //+---------------------------------------------------------------+
   // PENJELASAN: sengaja tidak dipisah ke file JSON parser generik --
   // skema opini analis SELALU sama (bias/confidence/reasoning), jadi
   // parser ringan di sini cukup dan menghindari dependency antar modul
   // yang tidak perlu.
   ENUM_ANALYST_BIAS ParseBias(const string json)
   {
      if(StringFind(json, "\"bias\":\"BULLISH\"") >= 0 || StringFind(json, "\"bias\": \"BULLISH\"") >= 0)
         return ANALYST_BIAS_BULLISH;
      if(StringFind(json, "\"bias\":\"BEARISH\"") >= 0 || StringFind(json, "\"bias\": \"BEARISH\"") >= 0)
         return ANALYST_BIAS_BEARISH;
      return ANALYST_BIAS_NEUTRAL;
   }

   double ParseConfidence(const string json)
   {
      string key = "\"confidence\":";
      int pos = StringFind(json, key);
      if(pos < 0) return 0.5;

      pos += StringLen(key);
      while(pos < StringLen(json) && StringGetCharacter(json, pos) == ' ') pos++;

      string value = "";
      while(pos < StringLen(json))
      {
         ushort ch = StringGetCharacter(json, pos);
         if(ch == ',' || ch == '}') break;
         value += StringSubstr(json, pos, 1);
         pos++;
      }

      double conf = StringToDouble(value);
      return MathMax(0.0, MathMin(1.0, conf));
   }

   string ParseReasoning(const string json)
   {
      string key = "\"reasoning\":\"";
      int pos = StringFind(json, key);
      if(pos < 0) return "";

      pos += StringLen(key);
      string value = "";
      while(pos < StringLen(json))
      {
         ushort ch = StringGetCharacter(json, pos);
         if(ch == '"') break;
         if(ch == '\\' && pos + 1 < StringLen(json))
         {
            ushort next = StringGetCharacter(json, pos + 1);
            if(next == '"') { value += "\""; pos += 2; continue; }
            if(next == 'n') { value += " "; pos += 2; continue; }
         }
         value += StringSubstr(json, pos, 1);
         pos++;
      }
      return value;
   }

public:
   //+---------------------------------------------------------------+
   //| Constructor - butuh pointer ke instance CGroqClient bersama      |
   //+---------------------------------------------------------------+
   CAnalystEngine(CGroqClient *groq_client)
   {
      m_groq_client = groq_client;

      m_analyst_names[0] = "Trend (Moving Averages)";
      m_analyst_names[1] = "Momentum (Oscillators)";
      m_analyst_names[2] = "Volatilitas (Bands & ATR)";
      m_analyst_names[3] = "Volume (Aliran Uang)";
      m_analyst_names[4] = "Support & Resistance";
      m_analyst_names[5] = "Smart Money Concepts";
      m_analyst_names[6] = "Price Action Native + Sesi";
      m_analyst_names[7] = "Multi-Timeframe Alignment";
      m_analyst_names[8] = "Konteks Makro XAUUSD";
      m_analyst_names[9] = "Risk Management";
   }

   //+---------------------------------------------------------------+
   //| Jalankan 10 analis sekaligus (berurutan) atas 1 snapshot pasar   |
   //+---------------------------------------------------------------+
   // CATATAN: MQL5 WebRequest bersifat SINKRON (blocking), jadi 10
   // pemanggilan ini berjalan berurutan (bukan paralel/async). Dengan
   // interval siklus 10 menit, waktu tunggu total (biasanya beberapa
   // detik per panggilan) masih sangat wajar dan tidak mengganggu OnTick.
   void AnalyzeAll(const SMarketSnapshot &snapshot, SAnalystOpinion &opinions[])
   {
      ArrayResize(opinions, ANALYST_COUNT);

      // Susun semua prompt dulu (dipakai baik oleh jalur proxy/batch maupun jalur langsung)
      string system_prompts[];
      string user_prompts[];
      ArrayResize(system_prompts, ANALYST_COUNT);
      ArrayResize(user_prompts, ANALYST_COUNT);
      for(int i = 0; i < ANALYST_COUNT; i++)
      {
         system_prompts[i] = BuildSystemPrompt(GetRoleDescription(i));
         user_prompts[i]   = BuildUserPrompt(i, snapshot);
      }

      // MODE PROXY: 1 request ke Worker -> 10 analis dipanggil PARALEL di sisi Worker.
      GroqCallResult batch_results[];
      bool use_batch = false;
      if(m_groq_client.IsProxyEnabled())
      {
         m_groq_client.CallBatch(system_prompts, user_prompts, batch_results);
         use_batch = (ArraySize(batch_results) == ANALYST_COUNT);
      }

      for(int i = 0; i < ANALYST_COUNT; i++)
      {
         opinions[i].analyst_id   = i;
         opinions[i].analyst_name = m_analyst_names[i];

         GroqCallResult result;
         if(use_batch)
         {
            result = batch_results[i];
            if(!result.success)
            {
               // Item ini gagal di batch -> coba jalur key langsung (kalau user mengisinya)
               GroqCallResult retry = m_groq_client.Call(i, system_prompts[i], user_prompts[i], true);
               if(retry.success) result = retry;
            }
         }
         else
         {
            result = m_groq_client.Call(i, system_prompts[i], user_prompts[i]);
         }

         opinions[i].success          = result.success;
         opinions[i].used_reserve_key = result.used_reserve_key;
         opinions[i].error_message    = result.error_message;

         if(result.success)
         {
            opinions[i].bias       = ParseBias(result.content);
            opinions[i].confidence = ParseConfidence(result.content);
            opinions[i].reasoning  = ParseReasoning(result.content);
         }
         else
         {
            // Gagal total -> opini ini DILEWATI oleh AISummarizer.mqh (bukan dianggap
            // NEUTRAL, supaya tidak mencemari rata-rata dengan data kosong).
            opinions[i].bias       = ANALYST_BIAS_NEUTRAL;
            opinions[i].confidence = 0.0;
            opinions[i].reasoning  = "Analisa gagal: " + result.error_message;

            Print("AnalystEngine: analis #", i, " (", m_analyst_names[i], ") gagal dianalisa. ",
                  result.error_message);
         }
      }
   }
};
