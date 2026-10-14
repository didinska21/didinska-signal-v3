//+------------------------------------------------------------------+
//|                                              TelegramNotify.mqh   |
//|         Didinska Grid V2 - Notifikasi Telegram Satu Arah           |
//|                                                                    |
//|   Modul ini HANYA mengirim pesan (EA -> Telegram), TIDAK menerima  |
//|   perintah dari Telegram (tidak ada bot polling/webhook, tidak ada |
//|   kontrol dua arah). Sengaja dibatasi 3 event saja sesuai kebutuhan:|
//|     1. Order terisi (posisi baru terbuka, termasuk dari grid)       |
//|     2. Posisi kena Stop Loss                                        |
//|     3. Posisi kena Take Profit                                      |
//|   TIDAK ada notifikasi sinyal AI / update analisa -- supaya tidak   |
//|   spam dan sesuai kesepakatan awal.                                 |
//|                                                                    |
//|   Kegagalan kirim notifikasi TIDAK BOLEH mengganggu jalannya EA --  |
//|   semua fungsi di sini gagal secara "diam" (hanya Print ke log),    |
//|   trading tetap berjalan normal walau Telegram sedang bermasalah.   |
//+------------------------------------------------------------------+
#property copyright "Didinska Grid V2"
#property strict

//+------------------------------------------------------------------+
//| CTelegramNotify - pengirim notifikasi satu arah ke Telegram         |
//+------------------------------------------------------------------+
class CTelegramNotify
{
private:
   string   m_bot_token;
   string   m_chat_id;
   bool     m_enabled;
   int      m_timeout_ms;

   //+---------------------------------------------------------------+
   //| Escape teks supaya aman ditaruh sebagai value JSON               |
   //+---------------------------------------------------------------+
   string JsonEscape(const string text)
   {
      string result = text;
      StringReplace(result, "\\", "\\\\");
      StringReplace(result, "\"", "\\\"");
      StringReplace(result, "\r", "");
      StringReplace(result, "\n", "\\n");
      return result;
   }

   //+---------------------------------------------------------------+
   //| Kirim satu pesan mentah ke Telegram Bot API (sendMessage)        |
   //+---------------------------------------------------------------+
   bool SendMessage(const string text)
   {
      if(!m_enabled)
         return true; // notifikasi dimatikan user -> anggap "berhasil" (tidak ada yang perlu dikirim)

      if(StringLen(m_bot_token) == 0 || StringLen(m_chat_id) == 0)
      {
         Print("TelegramNotify: bot token / chat id belum diisi, notifikasi dilewati.");
         return false;
      }

      string url = "https://api.telegram.org/bot" + m_bot_token + "/sendMessage";

      string payload = "{";
      payload += "\"chat_id\":\"" + m_chat_id + "\",";
      payload += "\"text\":\"" + JsonEscape(text) + "\",";
      payload += "\"parse_mode\":\"HTML\"";
      payload += "}";

      char post_data[];
      StringToCharArray(payload, post_data, 0, StringLen(payload), CP_UTF8);

      char result[];
      string request_headers = "Content-Type: application/json; charset=utf-8\r\n";
      string response_headers = "";

      ResetLastError();
      int status = WebRequest("POST", url, request_headers, m_timeout_ms, post_data, result, response_headers);

      if(status == 200)
         return true;

      if(status < 0)
      {
         Print("TelegramNotify: WebRequest gagal total (error=", GetLastError(),
               "). Cek apakah https://api.telegram.org sudah diizinkan di Tools > Options > Expert Advisors > Allow WebRequest.");
      }
      else
      {
         string body = (ArraySize(result) > 0) ? CharArrayToString(result) : "";
         string snippet = (StringLen(body) > 200) ? StringSubstr(body, 0, 200) : body;
         Print("TelegramNotify: gagal kirim pesan, HTTP status=", status, " response=", snippet);
      }

      return false;
   }

   //+---------------------------------------------------------------+
   //| Format angka profit/loss dengan tanda +/- yang jelas             |
   //+---------------------------------------------------------------+
   string FormatMoney(const double amount)
   {
      string sign = (amount >= 0) ? "+" : "";
      return sign + DoubleToString(amount, 2) + " USD";
   }

public:
   //+---------------------------------------------------------------+
   //| Constructor                                                       |
   //+---------------------------------------------------------------+
   CTelegramNotify()
   {
      m_bot_token  = "";
      m_chat_id    = "";
      m_enabled    = false;
      m_timeout_ms = 10000;
   }

   //+---------------------------------------------------------------+
   //| Inisialisasi - dipanggil dari OnInit() EA utama                   |
   //+---------------------------------------------------------------+
   void Initialize(const string bot_token, const string chat_id, const bool enabled)
   {
      m_bot_token = bot_token;
      m_chat_id   = chat_id;
      m_enabled   = enabled && StringLen(bot_token) > 0 && StringLen(chat_id) > 0;

      if(enabled && !m_enabled)
      {
         Print("TelegramNotify PERINGATAN: notifikasi diaktifkan tapi bot token/chat id kosong -> notifikasi TIDAK akan terkirim.");
      }
      else if(m_enabled)
      {
         Print("TelegramNotify: notifikasi aktif.");
      }
   }

   //+---------------------------------------------------------------+
   //| Pesan bebas (laporan harian, peringatan halt/cooldown)           |
   //+---------------------------------------------------------------+
   // Teks boleh memakai tag HTML sederhana (<b>, <i>). Kalau teks berisi
   // karakter < > & dari sumber luar, escape dulu lewat HtmlEscape().
   bool NotifyCustom(const string text)
   {
      return SendMessage(text);
   }

   string HtmlEscape(const string text)
   {
      string r = text;
      StringReplace(r, "&", "&amp;");
      StringReplace(r, "<", "&lt;");
      StringReplace(r, ">", "&gt;");
      return r;
   }

   //+---------------------------------------------------------------+
   //| Event 1: Order terisi (posisi baru terbuka, termasuk dari grid)  |
   //+---------------------------------------------------------------+
   void NotifyOrderFilled(const string symbol, const bool is_buy, const double entry_price,
                           const double lot, const double sl, const double tp)
   {
      string direction_icon = is_buy ? "🟢 BUY" : "🔴 SELL";

      string text = "<b>" + direction_icon + " - Order Terisi</b>\n";
      text += "Symbol: " + symbol + "\n";
      text += "Lot: " + DoubleToString(lot, 2) + "\n";
      text += "Entry: " + DoubleToString(entry_price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) + "\n";
      text += "SL: " + DoubleToString(sl, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) + "\n";
      text += "TP: " + DoubleToString(tp, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));

      SendMessage(text);
   }

   //+---------------------------------------------------------------+
   //| Event 2: Posisi kena Stop Loss                                    |
   //+---------------------------------------------------------------+
   void NotifyStopLossHit(const string symbol, const double close_price, const double loss_amount)
   {
      string text = "<b>🛑 Stop Loss Kena</b>\n";
      text += "Symbol: " + symbol + "\n";
      text += "Harga Close: " + DoubleToString(close_price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) + "\n";
      text += "Hasil: " + FormatMoney(loss_amount);

      SendMessage(text);
   }

   //+---------------------------------------------------------------+
   //| Event 3: Posisi kena Take Profit                                  |
   //+---------------------------------------------------------------+
   void NotifyTakeProfitHit(const string symbol, const double close_price, const double profit_amount)
   {
      string text = "<b>✅ Take Profit Kena</b>\n";
      text += "Symbol: " + symbol + "\n";
      text += "Harga Close: " + DoubleToString(close_price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) + "\n";
      text += "Hasil: " + FormatMoney(profit_amount);

      SendMessage(text);
   }
};
