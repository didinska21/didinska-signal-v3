//+------------------------------------------------------------------+
//|                                                AISummarizer.mqh   |
//|         Didinska Grid V2 - AI Penyimpul (Keputusan Final)          |
//|                                                                    |
//|   Modul ini adalah "hakim" yang membaca 10 opini dari Analysts.mqh  |
//|   dan merangkumnya jadi SATU keputusan final yang langsung dipakai  |
//|   EA utama untuk menyusun grid: arah bias, level kunci, probabilitas|
//|   keyakinan, dan parameter grid (jarak & bobot buy/sell).           |
//|                                                                    |
//|   PENTING - LAPISAN PENGAMAN GANDA:                                 |
//|     1. Pemanggilan AI Penyimpul sendiri sudah dilindungi retry ke   |
//|        slot cadangan lewat GroqClient.mqh (slot 10 -> fallback 12). |
//|     2. Kalau AI Penyimpul GAGAL TOTAL (primer+cadangan sama-sama    |
//|        gagal), modul ini punya FALLBACK NATIVE: voting sederhana    |
//|        dari opini 10 analis yang berhasil (tanpa AI tambahan),      |
//|        supaya EA tidak berhenti total analisa hanya karena 1 titik  |
//|        kegagalan API. Fallback ini SELALU lebih konservatif         |
//|        (probabilitas dibatasi maksimum) karena tidak melalui        |
//|        penalaran AI yang sesungguhnya.                              |
//+------------------------------------------------------------------+
#property copyright "Didinska Grid V2"
#property strict

#include "GroqClient.mqh"
#include "MarketData.mqh"
#include "Analysts.mqh"

//+------------------------------------------------------------------+
//| Slot API key khusus AI Penyimpul (lihat skema 12-key di GroqClient)|
//+------------------------------------------------------------------+
#define SUMMARIZER_SLOT 10

//+------------------------------------------------------------------+
//| Arah keputusan final                                                |
//+------------------------------------------------------------------+
enum ENUM_FINAL_BIAS
{
   FINAL_BIAS_WAIT = 0,   // tidak cukup keyakinan -> jangan buka grid baru
   FINAL_BIAS_BUY  = 1,
   FINAL_BIAS_SELL = 2
};

//+------------------------------------------------------------------+
//| Keputusan final AI Penyimpul - dikonsumsi langsung oleh Grid.mqh    |
//+------------------------------------------------------------------+
struct SFinalDecision
{
   bool              success;                  // false hanya kalau data terlalu minim untuk keputusan apapun
   bool              used_builtin_fallback;     // true kalau AI Penyimpul gagal total & dipakai voting native
   ENUM_FINAL_BIAS   bias;
   double            probability;               // 0.0 - 1.0, keyakinan keputusan final
   double            key_support;               // level support kunci untuk referensi grid/SL
   double            key_resistance;            // level resistance kunci untuk referensi grid/SL
   double            grid_distance_multiplier;  // kalikan ke InpGridDistance dasar (0.5 = lebih rapat, 2.0 = lebih lebar)
   int               buy_weight;                // bobot relatif jumlah BuyStop (1-5)
   int               sell_weight;               // bobot relatif jumlah SellStop (1-5)
   string            reasoning;
   int               analysts_agreed;           // jumlah analis yang bias-nya searah dengan keputusan final
   int               analysts_failed;           // jumlah analis yang gagal dianalisa siklus ini
   string            error_message;
};

//+------------------------------------------------------------------+
//| CAISummarizer - perangkum 10 opini jadi 1 keputusan                 |
//+------------------------------------------------------------------+
class CAISummarizer
{
private:
   CGroqClient  *m_groq_client;

   //+---------------------------------------------------------------+
   //| System prompt AI Penyimpul                                       |
   //+---------------------------------------------------------------+
   string BuildSystemPrompt()
   {
      string p = "Anda adalah AI PENYIMPUL (kepala analis) untuk trading XAUUSD (emas). ";
      p += "Tugas Anda merangkum opini dari beberapa analis spesialis menjadi SATU keputusan final ";
      p += "untuk sistem grid trading. Pertimbangkan konfluensi (berapa banyak analis yang searah) ";
      p += "dan bobot keyakinan (confidence) tiap analis -- JANGAN sekadar menghitung suara terbanyak, ";
      p += "analis dengan confidence tinggi harus lebih berpengaruh daripada yang ragu-ragu. ";
      p += "Bersikap KONSERVATIF: kalau opini analis terpecah/saling bertentangan tanpa konfluensi jelas, ";
      p += "pilih WAIT daripada memaksakan BUY/SELL.\n";
      p += "Balas HANYA dengan satu objek JSON valid, tanpa markdown, tanpa teks tambahan, skema PERSIS berikut:\n";
      p += "{\"bias\":\"BUY\"|\"SELL\"|\"WAIT\",";
      p += "\"probability\":0.0-1.0,";
      p += "\"key_support\":harga_angka,";
      p += "\"key_resistance\":harga_angka,";
      p += "\"grid_distance_multiplier\":0.5-2.0,";
      p += "\"buy_weight\":1-5,";
      p += "\"sell_weight\":1-5,";
      p += "\"reasoning\":\"penjelasan singkat 2-3 kalimat dalam Bahasa Indonesia\"}";
      return p;
   }

   string BiasToText(const ENUM_ANALYST_BIAS bias)
   {
      switch(bias)
      {
         case ANALYST_BIAS_BULLISH: return "BULLISH";
         case ANALYST_BIAS_BEARISH: return "BEARISH";
         default:                   return "NEUTRAL";
      }
   }

   //+---------------------------------------------------------------+
   //| Susun user prompt: rangkuman 10 opini + konteks harga penting    |
   //+---------------------------------------------------------------+
   string BuildUserPrompt(const SAnalystOpinion &opinions[], const SMarketSnapshot &snap,
                           int &out_valid_count)
   {
      string p = "DATA HARGA SAAT INI:\n";
      p += "- Symbol: " + snap.symbol + "\n";
      p += "- Bid/Ask: " + DoubleToString(snap.bid, snap.digits) + " / " + DoubleToString(snap.ask, snap.digits) + "\n";
      p += "- Pivot Point: " + DoubleToString(snap.pivot_pp, snap.digits) + "\n";
      p += "- ATR(14): " + DoubleToString(snap.atr14, 5) + "\n\n";

      p += "OPINI 10 ANALIS SPESIALIS:\n";

      out_valid_count = 0;
      int total = ArraySize(opinions);
      for(int i = 0; i < total; i++)
      {
         if(!opinions[i].success)
         {
            p += "- [" + opinions[i].analyst_name + "]: GAGAL DIANALISA (dilewati)\n";
            continue;
         }

         out_valid_count++;
         p += "- [" + opinions[i].analyst_name + "]: " + BiasToText(opinions[i].bias) +
              " (confidence " + DoubleToString(opinions[i].confidence, 2) + ") - " +
              opinions[i].reasoning + "\n";
      }

      p += "\nRangkum semua opini di atas menjadi satu keputusan final untuk grid trading.";
      return p;
   }

   //+---------------------------------------------------------------+
   //| Parser field JSON keputusan final (skema khusus Penyimpul)       |
   //+---------------------------------------------------------------+
   ENUM_FINAL_BIAS ParseFinalBias(const string json)
   {
      if(StringFind(json, "\"bias\":\"BUY\"") >= 0 || StringFind(json, "\"bias\": \"BUY\"") >= 0)
         return FINAL_BIAS_BUY;
      if(StringFind(json, "\"bias\":\"SELL\"") >= 0 || StringFind(json, "\"bias\": \"SELL\"") >= 0)
         return FINAL_BIAS_SELL;
      return FINAL_BIAS_WAIT;
   }

   double ParseNumericField(const string json, const string key, const double default_value)
   {
      int pos = StringFind(json, key);
      if(pos < 0) return default_value;

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

      if(StringLen(value) == 0) return default_value;
      return StringToDouble(value);
   }

   string ParseReasoningField(const string json)
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

   //+---------------------------------------------------------------+
   //| Hitung berapa analis yang searah dengan keputusan final          |
   //+---------------------------------------------------------------+
   int CountAgreement(const SAnalystOpinion &opinions[], const ENUM_FINAL_BIAS final_bias)
   {
      if(final_bias == FINAL_BIAS_WAIT) return 0;

      ENUM_ANALYST_BIAS target = (final_bias == FINAL_BIAS_BUY) ? ANALYST_BIAS_BULLISH : ANALYST_BIAS_BEARISH;

      int count = 0;
      int total = ArraySize(opinions);
      for(int i = 0; i < total; i++)
      {
         if(opinions[i].success && opinions[i].bias == target) count++;
      }
      return count;
   }

   int CountFailed(const SAnalystOpinion &opinions[])
   {
      int count = 0;
      int total = ArraySize(opinions);
      for(int i = 0; i < total; i++)
         if(!opinions[i].success) count++;
      return count;
   }

   //+---------------------------------------------------------------+
   //| FALLBACK NATIVE: voting berbobot confidence, tanpa AI            |
   //+---------------------------------------------------------------+
   // PENJELASAN: dipakai HANYA kalau AI Penyimpul gagal total (primer +
   // cadangan slot 12 sama-sama gagal). Ini bukan pengganti penalaran AI
   // Penyimpul -- sengaja dibuat KONSERVATIF (probabilitas dibatasi
   // maksimum 0.6, dan butuh minimal 5 dari 10 analis berhasil) supaya
   // EA tidak asal buka grid besar berdasarkan voting sederhana saat
   // API sedang bermasalah secara luas.
   SFinalDecision BuildFallbackDecision(const SAnalystOpinion &opinions[], const SMarketSnapshot &snap)
   {
      // Lihat catatan fix di MarketData.mqh: "={}" dipakai, bukan ZeroMemory(),
      // karena struct ini punya field string (reasoning, error_message).
      SFinalDecision decision = {};
      decision.used_builtin_fallback = true;

      int total = ArraySize(opinions);
      int valid_count = 0;
      double bullish_weight = 0.0;
      double bearish_weight = 0.0;

      for(int i = 0; i < total; i++)
      {
         if(!opinions[i].success) continue;
         valid_count++;

         if(opinions[i].bias == ANALYST_BIAS_BULLISH) bullish_weight += opinions[i].confidence;
         else if(opinions[i].bias == ANALYST_BIAS_BEARISH) bearish_weight += opinions[i].confidence;
      }

      decision.analysts_failed = total - valid_count;

      // Syarat minimum data: kalau lebih dari separuh analis gagal, data
      // dianggap terlalu tidak lengkap untuk dipercaya -> paksa WAIT.
      if(valid_count < 5)
      {
         decision.success     = true; // tetap berhasil membuat keputusan, keputusannya adalah WAIT
         decision.bias         = FINAL_BIAS_WAIT;
         decision.probability  = 0.0;
         decision.reasoning    = "Fallback native: hanya " + IntegerToString(valid_count) +
                                  "/10 analis berhasil dianalisa, data terlalu minim -> WAIT.";
         decision.analysts_agreed = 0;
         return decision;
      }

      double total_weight = bullish_weight + bearish_weight;
      if(total_weight <= 0.0)
      {
         decision.success    = true;
         decision.bias        = FINAL_BIAS_WAIT;
         decision.probability = 0.0;
         decision.reasoning   = "Fallback native: tidak ada konfluensi arah yang jelas dari analis yang berhasil -> WAIT.";
         decision.analysts_agreed = 0;
         return decision;
      }

      bool is_bullish = bullish_weight > bearish_weight;
      double dominant_weight = is_bullish ? bullish_weight : bearish_weight;
      double raw_probability = dominant_weight / total_weight; // 0.5 - 1.0

      decision.success    = true;
      decision.bias        = is_bullish ? FINAL_BIAS_BUY : FINAL_BIAS_SELL;
      // Dibatasi maksimum 0.6 -- fallback native tidak boleh se-yakin AI Penyimpul sungguhan
      decision.probability = MathMin(0.6, raw_probability);
      decision.key_support    = snap.pivot_s1;
      decision.key_resistance = snap.pivot_r1;
      decision.grid_distance_multiplier = 1.0; // netral, tidak menyesuaikan lebar grid tanpa penalaran AI
      decision.buy_weight  = is_bullish ? 2 : 1;
      decision.sell_weight = is_bullish ? 1 : 2;
      decision.reasoning   = "Fallback native (AI Penyimpul gagal total): voting berbobot confidence dari " +
                              IntegerToString(valid_count) + " analis yang berhasil, bias " +
                              (is_bullish ? "BULLISH" : "BEARISH") + ".";
      decision.analysts_agreed = CountAgreement(opinions, decision.bias);

      return decision;
   }

public:
   //+---------------------------------------------------------------+
   //| Constructor - butuh pointer ke instance CGroqClient bersama      |
   //+---------------------------------------------------------------+
   CAISummarizer(CGroqClient *groq_client)
   {
      m_groq_client = groq_client;
   }

   //+---------------------------------------------------------------+
   //| Rangkum 10 opini analis menjadi 1 keputusan final                |
   //+---------------------------------------------------------------+
   SFinalDecision Summarize(const SAnalystOpinion &opinions[], const SMarketSnapshot &snap)
   {
      SFinalDecision decision = {};

      int valid_count = 0;
      string system_prompt = BuildSystemPrompt();
      string user_prompt   = BuildUserPrompt(opinions, snap, valid_count);

      // Kalau nyaris semua analis sudah gagal SEBELUM sampai ke Penyimpul,
      // tidak ada gunanya memanggil AI Penyimpul sama sekali -- langsung fallback.
      if(valid_count < 5)
      {
         Print("AISummarizer: hanya ", valid_count, "/10 analis valid, langsung pakai fallback native tanpa panggil AI Penyimpul.");
         return BuildFallbackDecision(opinions, snap);
      }

      GroqCallResult result = m_groq_client.Call(SUMMARIZER_SLOT, system_prompt, user_prompt);

      if(!result.success)
      {
         Print("AISummarizer: AI Penyimpul gagal total (", result.error_message, "), memakai fallback native.");
         return BuildFallbackDecision(opinions, snap);
      }

      decision.success                 = true;
      decision.used_builtin_fallback   = false;
      decision.bias                    = ParseFinalBias(result.content);
      decision.probability             = MathMax(0.0, MathMin(1.0, ParseNumericField(result.content, "\"probability\":", 0.5)));
      decision.key_support             = ParseNumericField(result.content, "\"key_support\":", snap.pivot_s1);
      decision.key_resistance          = ParseNumericField(result.content, "\"key_resistance\":", snap.pivot_r1);
      decision.grid_distance_multiplier = ParseNumericField(result.content, "\"grid_distance_multiplier\":", 1.0);
      decision.grid_distance_multiplier = MathMax(0.5, MathMin(2.0, decision.grid_distance_multiplier));
      decision.buy_weight              = (int)MathRound(ParseNumericField(result.content, "\"buy_weight\":", 1));
      decision.sell_weight             = (int)MathRound(ParseNumericField(result.content, "\"sell_weight\":", 1));
      decision.buy_weight              = (int)MathMax(1, MathMin(5, decision.buy_weight));
      decision.sell_weight             = (int)MathMax(1, MathMin(5, decision.sell_weight));
      decision.reasoning               = ParseReasoningField(result.content);
      decision.analysts_agreed         = CountAgreement(opinions, decision.bias);
      decision.analysts_failed         = CountFailed(opinions);
      decision.error_message           = "";

      return decision;
   }
};
