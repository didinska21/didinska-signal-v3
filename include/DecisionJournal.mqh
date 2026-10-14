//+------------------------------------------------------------------+
//|                                              DecisionJournal.mqh  |
//|        Didinska Grid V2 - Jurnal Keputusan & Evaluasi Akurasi AI   |
//|                                                                    |
//|   Tujuan: MENGUKUR apakah analisa AI benar-benar punya edge.       |
//|   Dua file CSV dibuat di folder MQL5\Files :                       |
//|     1. DidinskaGridV2_<SYMBOL>_decisions.csv                       |
//|        Satu baris tiap siklus analisa: snapshot ringkas, vote 10   |
//|        analis, keputusan final, keputusan Native (pembanding).     |
//|     2. DidinskaGridV2_<SYMBOL>_outcomes.csv                        |
//|        Satu baris per keputusan SETELAH N menit: harga bergerak    |
//|        ke mana, dan tiap analis HIT atau MISS.                     |
//|                                                                    |
//|   Kode arah (sama untuk analis, keputusan final, dan hasil harga): |
//|     0 = netral/WAIT/sideways, 1 = naik/BUY/BULLISH,                |
//|     2 = turun/SELL/BEARISH, -1 = analis gagal/tidak ada data       |
//|                                                                    |
//|   Definisi HIT: arah yang diprediksi sama dengan arah gerak harga  |
//|   yang melebihi 0.25 x ATR dalam N menit. Gerak lebih kecil dari   |
//|   itu dihitung sideways (prediksi arah = MISS).                    |
//+------------------------------------------------------------------+
#property copyright "Didinska Grid V2"
#property strict

#include "MarketData.mqh"
#include "Analysts.mqh"
#include "AISummarizer.mqh"

#define JOURNAL_MAX_PENDING 48

//+------------------------------------------------------------------+
//| Satu keputusan yang menunggu dievaluasi                            |
//+------------------------------------------------------------------+
struct SJournalPending
{
   datetime time;
   double   price;
   double   atr;
   int      final_bias;                  // 0 wait, 1 buy, 2 sell
   double   probability;
   int      native_bias;                 // 0 wait, 1 buy, 2 sell
   int      an_bias[ANALYST_COUNT];      // -1 gagal, 0 netral, 1 bullish, 2 bearish
   double   an_conf[ANALYST_COUNT];
};

class CDecisionJournal
{
private:
   bool     m_enabled;
   string   m_symbol;
   int      m_eval_minutes;
   string   m_file_decisions;
   string   m_file_outcomes;
   string   m_names[ANALYST_COUNT];

   SJournalPending m_pending[];

   int      m_final_calls;
   int      m_final_hits;
   int      m_native_calls;
   int      m_native_hits;
   int      m_an_calls[ANALYST_COUNT];
   int      m_an_hits[ANALYST_COUNT];

   //+---------------------------------------------------------------+
   //| Bersihkan teks agar aman jadi 1 sel CSV                          |
   //+---------------------------------------------------------------+
   string Clean(const string text)
   {
      string r = text;
      StringReplace(r, ",", " ");
      StringReplace(r, ";", " ");
      StringReplace(r, "\"", "'");
      StringReplace(r, "\r", " ");
      StringReplace(r, "\n", " ");
      if(StringLen(r) > 220) r = StringSubstr(r, 0, 220);
      return r;
   }

   //+---------------------------------------------------------------+
   //| Tambah 1 baris ke file (header ditulis otomatis kalau file baru) |
   //+---------------------------------------------------------------+
   void AppendLine(const string file, const string header, const string line)
   {
      int h = FileOpen(file, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
      if(h == INVALID_HANDLE)
      {
         Print("DecisionJournal: gagal membuka file ", file, " (error=", GetLastError(), ")");
         return;
      }
      if(FileSize(h) == 0) FileWriteString(h, header + "\r\n");
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, line + "\r\n");
      FileClose(h);
   }

   void RemoveFirst()
   {
      int n = ArraySize(m_pending);
      if(n <= 0) return;
      for(int i = 0; i < n - 1; i++)
         m_pending[i] = m_pending[i + 1];
      ArrayResize(m_pending, n - 1);
   }

   //+---------------------------------------------------------------+
   //| Hitung hasil 1 keputusan terhadap pergerakan harga sebenarnya    |
   //+---------------------------------------------------------------+
   void ProcessOutcome(const SJournalPending &p, const double bid_now)
   {
      double move = bid_now - p.price;
      double thr  = p.atr * 0.25;
      int dir = 0;
      if(move > thr)       dir = 1;
      else if(move < -thr) dir = 2;

      double move_atr = (p.atr > 0.0) ? (move / p.atr) : 0.0;

      string final_result = "NA";
      if(p.final_bias == 1 || p.final_bias == 2)
      {
         m_final_calls++;
         if(p.final_bias == dir) { m_final_hits++; final_result = "HIT"; }
         else final_result = "MISS";
      }

      string native_result = "NA";
      if(p.native_bias == 1 || p.native_bias == 2)
      {
         m_native_calls++;
         if(p.native_bias == dir) { m_native_hits++; native_result = "HIT"; }
         else native_result = "MISS";
      }

      string row = TimeToString(p.time, TIME_DATE | TIME_SECONDS) + ",";
      row += DoubleToString(p.price, 3) + ",";
      row += DoubleToString(bid_now, 3) + ",";
      row += DoubleToString(move, 3) + ",";
      row += DoubleToString(move_atr, 2) + ",";
      row += IntegerToString(dir) + ",";
      row += IntegerToString(p.final_bias) + ",";
      row += DoubleToString(p.probability, 2) + ",";
      row += final_result + ",";
      row += IntegerToString(p.native_bias) + ",";
      row += native_result;

      for(int a = 0; a < ANALYST_COUNT; a++)
      {
         string res = "NA";
         if(p.an_bias[a] == 1 || p.an_bias[a] == 2)
         {
            m_an_calls[a]++;
            if(p.an_bias[a] == dir) { m_an_hits[a]++; res = "HIT"; }
            else res = "MISS";
         }
         row += "," + res;
      }

      string header = "time,price_at_decision,price_after,move,move_in_atr,actual_dir,final_bias,probability,final_result,native_bias,native_result";
      for(int a = 0; a < ANALYST_COUNT; a++)
         header += ",an" + IntegerToString(a + 1) + "_" + m_names[a];

      AppendLine(m_file_outcomes, header, row);
   }

public:
   CDecisionJournal()
   {
      m_enabled      = false;
      m_symbol       = "";
      m_eval_minutes = 60;
      m_final_calls  = 0;
      m_final_hits   = 0;
      m_native_calls = 0;
      m_native_hits  = 0;

      m_names[0] = "Trend";
      m_names[1] = "Momentum";
      m_names[2] = "Volatilitas";
      m_names[3] = "Volume";
      m_names[4] = "SR";
      m_names[5] = "SMC";
      m_names[6] = "PriceAction";
      m_names[7] = "MTF";
      m_names[8] = "Makro";
      m_names[9] = "Risk";

      for(int i = 0; i < ANALYST_COUNT; i++)
      {
         m_an_calls[i] = 0;
         m_an_hits[i]  = 0;
      }
      ArrayResize(m_pending, 0);
   }

   void Initialize(const string symbol, const bool enabled, const int eval_minutes)
   {
      m_enabled        = enabled;
      m_symbol         = symbol;
      m_eval_minutes   = MathMax(5, eval_minutes);
      m_file_decisions = "DidinskaGridV2_" + symbol + "_decisions.csv";
      m_file_outcomes  = "DidinskaGridV2_" + symbol + "_outcomes.csv";

      if(m_enabled)
         Print("DecisionJournal: aktif. File: ", m_file_decisions, " & ", m_file_outcomes,
               " (evaluasi setelah ", m_eval_minutes, " menit).");
   }

   bool IsEnabled() { return m_enabled; }

   //+---------------------------------------------------------------+
   //| Catat satu siklus analisa                                         |
   //+---------------------------------------------------------------+
   // raw_ai_bias : bias AI SEBELUM veto Native (0/1/2)
   // decision    : keputusan final yang benar-benar dipakai grid
   // native      : keputusan Native Engine (pembanding)
   void Record(const SMarketSnapshot &snap, const SAnalystOpinion &opinions[],
               const SFinalDecision &decision, const int raw_ai_bias,
               const SFinalDecision &native, const bool ai_mode)
   {
      if(!m_enabled) return;

      string row = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + ",";
      row += DoubleToString(snap.bid, snap.digits) + ",";
      row += DoubleToString(snap.atr14, snap.digits + 1) + ",";
      row += (ai_mode ? "AI_ON" : "AI_OFF") + ",";
      row += IntegerToString(raw_ai_bias) + ",";
      row += IntegerToString((int)decision.bias) + ",";
      row += DoubleToString(decision.probability, 2) + ",";
      row += IntegerToString(decision.analysts_agreed) + ",";
      row += IntegerToString(decision.analysts_failed) + ",";
      row += (decision.used_builtin_fallback ? "1" : "0") + ",";
      row += IntegerToString((int)native.bias) + ",";
      row += DoubleToString(native.probability, 2) + ",";
      row += DoubleToString(decision.grid_distance_multiplier, 2) + ",";
      row += IntegerToString(decision.buy_weight) + ",";
      row += IntegerToString(decision.sell_weight);

      SJournalPending p;
      p.time        = TimeCurrent();
      p.price       = snap.bid;
      p.atr         = snap.atr14;
      p.final_bias  = (int)decision.bias;
      p.probability = decision.probability;
      p.native_bias = (int)native.bias;

      int n_op = ArraySize(opinions);
      for(int a = 0; a < ANALYST_COUNT; a++)
      {
         int code = -1;
         double conf = 0.0;
         if(a < n_op && opinions[a].success)
         {
            code = (int)opinions[a].bias;
            conf = opinions[a].confidence;
         }
         p.an_bias[a] = code;
         p.an_conf[a] = conf;
         row += "," + IntegerToString(code) + "," + DoubleToString(conf, 2);
      }
      row += "," + Clean(decision.reasoning);

      string header = "time,bid,atr14,mode,ai_bias_raw,final_bias,probability,agreed,failed,fallback,native_bias,native_prob,grid_mult,buy_w,sell_w";
      for(int a = 0; a < ANALYST_COUNT; a++)
         header += ",an" + IntegerToString(a + 1) + "_" + m_names[a] + "_bias,an" + IntegerToString(a + 1) + "_conf";
      header += ",reasoning";

      AppendLine(m_file_decisions, header, row);

      // Masukkan ke antrean evaluasi
      int n = ArraySize(m_pending);
      if(n >= JOURNAL_MAX_PENDING)
      {
         RemoveFirst();
         n = ArraySize(m_pending);
      }
      ArrayResize(m_pending, n + 1);
      m_pending[n] = p;
   }

   //+---------------------------------------------------------------+
   //| Evaluasi keputusan yang sudah cukup umur (panggil berkala)       |
   //+---------------------------------------------------------------+
   void Evaluate(const double bid_now)
   {
      if(!m_enabled || bid_now <= 0.0) return;

      datetime now = TimeCurrent();
      while(ArraySize(m_pending) > 0)
      {
         if((now - m_pending[0].time) < (m_eval_minutes * 60)) break; // sisanya lebih baru lagi
         ProcessOutcome(m_pending[0], bid_now);
         RemoveFirst();
      }
   }

   //+---------------------------------------------------------------+
   //| Ringkasan akurasi (untuk laporan Telegram & log)                  |
   //+---------------------------------------------------------------+
   string SummaryText()
   {
      if(!m_enabled) return "Jurnal AI: nonaktif";

      string s = "Akurasi arah (" + IntegerToString(m_eval_minutes) + " mnt): ";
      if(m_final_calls > 0)
         s += "Final " + DoubleToString(100.0 * m_final_hits / m_final_calls, 0) + "% (n=" + IntegerToString(m_final_calls) + ")";
      else
         s += "Final belum ada data";

      if(m_native_calls > 0)
         s += " | Native " + DoubleToString(100.0 * m_native_hits / m_native_calls, 0) + "% (n=" + IntegerToString(m_native_calls) + ")";

      // Analis terbaik & terburuk (minimal 5 panggilan arah)
      int best = -1, worst = -1;
      double best_rate = -1.0, worst_rate = 2.0;
      for(int a = 0; a < ANALYST_COUNT; a++)
      {
         if(m_an_calls[a] < 5) continue;
         double rate = (double)m_an_hits[a] / (double)m_an_calls[a];
         if(rate > best_rate)  { best_rate = rate;  best = a; }
         if(rate < worst_rate) { worst_rate = rate; worst = a; }
      }
      if(best >= 0 && worst >= 0 && best != worst)
      {
         s += "\nAnalis terbaik: " + m_names[best] + " " + DoubleToString(best_rate * 100.0, 0) + "%";
         s += " | terburuk: " + m_names[worst] + " " + DoubleToString(worst_rate * 100.0, 0) + "%";
      }
      return s;
   }
};
