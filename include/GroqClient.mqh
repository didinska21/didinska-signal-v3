//+------------------------------------------------------------------+
//|                                                  GroqClient.mqh   |
//|         Didinska Grid V2 - Lapisan Komunikasi Groq API Bersama    |
//|                                                                    |
//|   Modul ini adalah SATU-SATUNYA titik yang boleh memanggil Groq   |
//|   API secara langsung di seluruh EA. Semua 10 AI analis dan 1 AI  |
//|   Penyimpul WAJIB lewat CGroqClient::Call() supaya:                |
//|     - Skema 12 API key (10 analis + 1 penyimpul + 1 cadangan)      |
//|       dikelola konsisten di satu tempat, tidak duplikat logic.     |
//|     - Deteksi rate-limit (HTTP 429) dan fallback ke key cadangan   |
//|       berjalan seragam untuk semua pemanggil.                      |
//|     - Parsing amplop respons (OpenAI/Groq chat.completions) dan    |
//|       unescape isi "content" hanya perlu ditulis & diuji sekali.   |
//+------------------------------------------------------------------+
// PENJELASAN SKEMA 12 API KEY (bahasa sederhana):
//   Slot 0-9   -> khusus 10 AI analis (1 slot per analis, biar kuota/rate
//                 limit tidak saling rebutan antar analis).
//   Slot 10    -> khusus AI Penyimpul (model reasoning, butuh token lebih
//                 besar, dipisah supaya tidak berebut kuota dengan analis).
//   Slot 11    -> CADANGAN UNIVERSAL. Kalau slot 0-10 (siapa pun, bahkan
//                 lebih dari satu sekaligus) kena rate limit/gagal, modul
//                 ini otomatis mencoba ulang panggilan itu memakai key di
//                 slot 11. Jadi 1 key cadangan menutupi semua kemungkinan
//                 kegagalan, tidak perlu 1 cadangan per analis.
//
//   Kalau slot cadangan (11) SENDIRI juga gagal/kosong, panggilan itu
//   dianggap gagal untuk siklus ini -> pemanggil (Analysts.mqh /
//   AISummarizer.mqh) harus siap menangani hasil kosong (skip opini AI
//   tersebut, jangan sampai EA crash atau salah membaca data kosong
//   sebagai sinyal valid).
//+------------------------------------------------------------------+
#property copyright "Didinska Grid V2"
#property strict

//+------------------------------------------------------------------+
//| Jumlah total slot API key yang dikelola modul ini                  |
//+------------------------------------------------------------------+
#define GROQ_TOTAL_SLOTS   12
#define GROQ_RESERVE_SLOT  11   // index slot cadangan universal (slot ke-12)

//+------------------------------------------------------------------+
//| Hasil mentah satu kali pemanggilan AI                              |
//+------------------------------------------------------------------+
// PENJELASAN: struct ini dikembalikan oleh Call() ke pemanggil (misalnya
// CAnalystEngine di Analysts.mqh). Isinya masih berupa TEKS JSON hasil
// analisa AI (sudah dibongkar dari amplop chat.completions, sudah
// di-unescape) -- parsing field spesifik seperti "signal"/"bias" tetap
// jadi tanggung jawab pemanggil, karena tiap analis punya skema JSON
// yang berbeda-beda.
struct GroqCallResult
{
   bool     success;          // true kalau berhasil dapat balasan dari AI
   string   content;          // isi JSON hasil analisa AI (mentah, sudah di-unescape)
   int      http_status;      // status HTTP percobaan TERAKHIR (untuk debug/log)
   bool     used_reserve_key; // true kalau yang berhasil menjawab adalah slot cadangan (11)
   string   error_message;    // penjelasan singkat kalau success = false
};

//+------------------------------------------------------------------+
//| CGroqClient - pengelola koneksi Groq API bersama                   |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Provider AI yang didukung                                          |
//+------------------------------------------------------------------+
enum ENUM_AI_PROVIDER
{
   AIP_GROQ       = 0,   // Groq (OpenAI-compatible)
   AIP_OPENROUTER = 1,   // OpenRouter (OpenAI-compatible)
   AIP_OPENAI     = 2,   // OpenAI
   AIP_ANTHROPIC  = 3,   // Anthropic Claude (Messages API native)
   AIP_CUSTOM     = 4    // Custom OpenAI-compatible (FastRouter, DeepSeek, Together, dll) - isi InpAIBaseUrl
};

class CGroqClient
{
private:
   string      m_api_keys[GROQ_TOTAL_SLOTS];   // 12 API key, index 0..11
   bool        m_key_filled[GROQ_TOTAL_SLOTS]; // true kalau slot itu diisi user (bukan string kosong)
   datetime    m_cooldown_until[GROQ_TOTAL_SLOTS]; // slot ini "istirahat" sampai jam berapa (rate limit)

   string      m_base_url;
   string      m_model;
   int         m_max_tokens;
   double      m_temperature;
   int         m_timeout_ms;

   // --- Mode PROXY (Cloudflare Worker): 1 request -> Worker memanggil Groq paralel ---
   // --- POOL KEY: banyak key (dipisah koma/baris baru), dirotasi merata ---
   // Key yang ditolak (401/402/403) atau saldonya habis diistirahatkan 6-12 jam,
   // key yang kena rate limit (429) diistirahatkan sebentar. Panggilan berikutnya
   // otomatis memakai key lain yang masih hidup.
   string      m_pool[];
   datetime    m_pool_cooldown[];
   datetime    m_pool_dead[];
   int         m_pool_next;

   // --- PROVIDER (v2.03): alamat, bentuk request, & field tambahan bisa dikustom ---
   int         m_provider;          // ENUM_AI_PROVIDER
   string      m_chat_url;          // URL lengkap endpoint (chat/completions atau messages)
   string      m_extra_json;        // field tambahan body request (tanpa kurung kurawal)
   bool        m_extra_override;    // true = user mengisi sendiri (dikirim juga ke Worker)
   string      m_token_param;       // "max_tokens" atau "max_completion_tokens"

   bool        m_use_proxy;
   string      m_proxy_url;
   string      m_proxy_token;

   //+---------------------------------------------------------------+
   //| Escape teks biasa supaya aman ditaruh sebagai value JSON        |
   //+---------------------------------------------------------------+
   // PENJELASAN: urutan penggantian TIDAK BOLEH diacak -- backslash wajib
   // diganti PALING AWAL, supaya backslash baru yang ditambahkan pada
   // langkah berikutnya (untuk kutip/baris baru) tidak ikut ke-escape lagi.
   string JsonEscape(const string text)
   {
      string result = text;
      StringReplace(result, "\\", "\\\\");
      StringReplace(result, "\"", "\\\"");
      StringReplace(result, "\r", "");
      StringReplace(result, "\n", "\\n");
      StringReplace(result, "\t", "\\t");
      return result;
   }

   //+---------------------------------------------------------------+
   //| Bongkar field "content" dari amplop chat.completions Groq/OpenAI |
   //+---------------------------------------------------------------+
   // PENJELASAN: balasan mentah Groq berbentuk:
   //   {"choices":[{"message":{"content":"{\"signal\":\"BUY\",...}"}}]}
   // JSON hasil analisa AI yang sebenarnya ada DI DALAM field "content"
   // sebagai teks ter-escape. Fungsi ini membongkarnya karakter demi
   // karakter (bukan regex, MQL5 tidak punya regex native) supaya escape
   // sequence (\", \\, \n, \t) diproses dengan benar.
   // Ambil nilai string dari field JSON pertama bernama `key` (toleran spasi/format
   // pretty-print; melewati kemunculan yang nilainya bukan string, mis. "content":null).
   string ExtractJsonString(const string body, const string key, const int from_pos)
   {
      string needle = "\"" + key + "\"";
      int len = StringLen(body);
      int search_from = MathMax(0, from_pos);

      while(search_from < len)
      {
         int pos = StringFind(body, needle, search_from);
         if(pos < 0) return "";

         int i = pos + StringLen(needle);
         while(i < len && (StringGetCharacter(body, i) == ' ' || StringGetCharacter(body, i) == '\n' ||
                           StringGetCharacter(body, i) == '\r' || StringGetCharacter(body, i) == '\t')) i++;
         if(i >= len || StringGetCharacter(body, i) != ':') { search_from = pos + 1; continue; }
         i++;
         while(i < len && (StringGetCharacter(body, i) == ' ' || StringGetCharacter(body, i) == '\n' ||
                           StringGetCharacter(body, i) == '\r' || StringGetCharacter(body, i) == '\t')) i++;
         if(i >= len || StringGetCharacter(body, i) != '"') { search_from = pos + 1; continue; }
         i++;   // lewati tanda kutip pembuka

         string content = "";
         while(i < len)
         {
            ushort ch = StringGetCharacter(body, i);

            if(ch == '\\' && i + 1 < len)
            {
               ushort next = StringGetCharacter(body, i + 1);
               if(next == '"')  { content += "\""; i += 2; continue; }
               if(next == '\\') { content += "\\"; i += 2; continue; }
               if(next == '/')  { content += "/";  i += 2; continue; }
               if(next == 'n')  { content += "\n"; i += 2; continue; }
               if(next == 't')  { content += "\t"; i += 2; continue; }
               if(next == 'r' || next == 'b' || next == 'f') { i += 2; continue; }
               if(next == 'u' && i + 5 < len)
               {
                  int code = 0;
                  bool ok = true;
                  for(int h = 0; h < 4; h++)
                  {
                     ushort hc = StringGetCharacter(body, i + 2 + h);
                     int v = -1;
                     if(hc >= '0' && hc <= '9') v = hc - '0';
                     else if(hc >= 'a' && hc <= 'f') v = 10 + (hc - 'a');
                     else if(hc >= 'A' && hc <= 'F') v = 10 + (hc - 'A');
                     if(v < 0) { ok = false; break; }
                     code = code * 16 + v;
                  }
                  if(ok) { content += ShortToString((ushort)code); i += 6; continue; }
               }
               i += 1;   // escape tidak dikenal -> lewati backslash-nya saja
               continue;
            }

            if(ch == '"') break;   // tanda kutip TANPA backslash = akhir string

            content += StringSubstr(body, i, 1);
            i++;
         }
         return content;
      }
      return "";
   }

   // Respons Worker (proxy) selalu ringkas: {"ok":true,"content":"..."}
   string ExtractMessageContent(const string api_response)
   {
      return ExtractJsonString(api_response, "content", 0);
   }

   // Respons LANGSUNG dari provider (format beda-beda):
   //   OpenAI-compatible : choices[0].message.content
   //   Anthropic         : content[].text (blok "text"; blok "thinking" dilewati)
   string ExtractCompletionText(const string api_response)
   {
      if(m_provider == AIP_ANTHROPIC)
         return ExtractJsonString(api_response, "text", 0);

      int from_pos = StringFind(api_response, "\"message\"");
      if(from_pos < 0) from_pos = 0;
      return ExtractJsonString(api_response, "content", from_pos);
   }

   //+---------------------------------------------------------------+
   //| Cari nilai header "retry-after" (detik) dari response headers   |
   //+---------------------------------------------------------------+
   int ExtractRetryAfterSeconds(const string response_headers)
   {
      string lower_headers = response_headers;
      StringToLower(lower_headers);

      int pos = StringFind(lower_headers, "retry-after:");
      if(pos < 0) return 0;

      pos += StringLen("retry-after:");
      // Lewati spasi setelah titik dua
      while(pos < StringLen(lower_headers) && StringGetCharacter(lower_headers, pos) == ' ')
         pos++;

      string value = "";
      while(pos < StringLen(lower_headers))
      {
         ushort ch = StringGetCharacter(lower_headers, pos);
         if(ch == '\r' || ch == '\n') break;
         value += StringSubstr(lower_headers, pos, 1);
         pos++;
      }

      int seconds = (int)StringToInteger(value);
      return MathMax(0, seconds);
   }

   //+---------------------------------------------------------------+
   //| Kirim satu kali request HTTP POST ke Groq chat/completions      |
   //+---------------------------------------------------------------+
   int SendRequest(const string api_key, const string payload, string &out_body, string &out_headers)
   {
      string url = m_chat_url;
      if(StringLen(url) == 0)
      {
         Print("GroqClient: alamat API kosong. Untuk provider CUSTOM isi InpAIBaseUrl.");
         out_body = "";
         return -1;
      }

      char post_data[];
      StringToCharArray(payload, post_data, 0, StringLen(payload), CP_UTF8);

      char result[];
      string request_headers = "";
      if(m_provider == AIP_ANTHROPIC)
         request_headers = "x-api-key: " + api_key + "\r\n" +
                           "anthropic-version: 2023-06-01\r\n" +
                           "Content-Type: application/json\r\n";
      else
         request_headers = "Authorization: Bearer " + api_key + "\r\n" +
                           "Content-Type: application/json\r\n";
      out_headers = "";

      ResetLastError();
      int status = WebRequest("POST", url, request_headers, m_timeout_ms, post_data, result, out_headers);

      if(status < 0)
      {
         Print("GroqClient: WebRequest gagal total (error=", GetLastError(),
               "). Cek apakah ", url, " (host-nya) sudah diizinkan di Tools > Options > Expert Advisors > Allow WebRequest.");
         out_body = "";
         return -1;
      }

      out_body = (ArraySize(result) > 0) ? CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8) : "";
      return status;
   }

   //+---------------------------------------------------------------+
   //| Bangun payload JSON chat/completions siap kirim                 |
   //+---------------------------------------------------------------+
   string BuildPayload(const string system_prompt, const string user_prompt)
   {
      string safe_system = JsonEscape(system_prompt);
      string safe_user   = JsonEscape(user_prompt);
      string temp_part   = (m_temperature >= 0.0) ? ("\"temperature\":" + DoubleToString(m_temperature, 2) + ",") : "";

      string payload = "{";
      payload += "\"model\":\"" + m_model + "\",";

      if(m_provider == AIP_ANTHROPIC)
      {
         // Anthropic Messages API: system terpisah dari messages
         payload += "\"max_tokens\":" + IntegerToString(m_max_tokens) + ",";
         payload += temp_part;
         payload += "\"system\":\"" + safe_system + "\",";
         payload += "\"messages\":[{\"role\":\"user\",\"content\":\"" + safe_user + "\"}]";
      }
      else
      {
         // OpenAI-compatible (Groq, OpenRouter, OpenAI, custom)
         payload += "\"messages\":[";
         payload += "{\"role\":\"system\",\"content\":\"" + safe_system + "\"},";
         payload += "{\"role\":\"user\",\"content\":\"" + safe_user + "\"}";
         payload += "],";
         payload += temp_part;
         payload += "\"" + m_token_param + "\":" + IntegerToString(m_max_tokens);
      }

      // Field tambahan khusus provider/model (mis. reasoning_effort, response_format).
      // Bawaan Groq: reasoning_effort=low supaya model reasoning tidak menghabiskan
      // max_tokens untuk berpikir sebelum sempat menulis JSON (HTTP 400 json_validate_failed).
      string extra = m_extra_json;
      StringTrimLeft(extra);
      StringTrimRight(extra);
      while(StringLen(extra) > 0 && StringGetCharacter(extra, 0) == ',')
         extra = StringSubstr(extra, 1);
      while(StringLen(extra) > 0 && StringGetCharacter(extra, StringLen(extra) - 1) == ',')
         extra = StringSubstr(extra, 0, StringLen(extra) - 1);
      if(StringLen(extra) > 0)
         payload += "," + extra;

      payload += "}";
      return payload;
   }

   //+---------------------------------------------------------------+
   //| BLOK POOL KEY: rotasi banyak key                                   |
   //+---------------------------------------------------------------+
   string MaskKey(const string key)
   {
      int n = StringLen(key);
      return "..." + ((n > 4) ? StringSubstr(key, n - 4) : key);
   }

   bool PoolContains(const string key)
   {
      for(int i = 0; i < ArraySize(m_pool); i++)
         if(m_pool[i] == key) return true;
      return false;
   }

   // Satu panggilan memakai pool: coba sampai 6 key hidup berbeda, mulai dari
   // key giliran berikutnya (rotasi merata, bukan selalu key pertama).
   bool PoolCall(const string payload, GroqCallResult &result)
   {
      int n = ArraySize(m_pool);
      if(n == 0) return false;

      datetime now = TimeCurrent();
      int max_attempts = MathMin(n, 6);
      int tried = 0;

      for(int step = 0; step < n && tried < max_attempts; step++)
      {
         int idx = (m_pool_next + step) % n;
         if(m_pool_dead[idx] > now || m_pool_cooldown[idx] > now) continue;

         tried++;
         m_pool_next = (idx + 1) % n;

         string body = "";
         string headers = "";
         int status = SendRequest(m_pool[idx], payload, body, headers);
         result.http_status = status;

         if(status == 200 && body != "")
         {
            string inner = ExtractCompletionText(body);
            if(inner == "")
            {
               result.success = false;
               result.error_message = "Pool: HTTP 200 tapi gagal membongkar field content";
               return false;
            }
            result.success = true;
            result.content = inner;
            result.error_message = "";
            return true;
         }

         if(status < 0)
         {
            // WebRequest gagal total (URL belum diizinkan / tidak ada internet) -> bukan salah key
            result.success = false;
            result.error_message = "Pool: WebRequest gagal total";
            return false;
         }

         if(status == 401 || status == 402 || status == 403)
         {
            m_pool_dead[idx] = now + (12 * 3600);
            Print("GroqClient[POOL]: key ", MaskKey(m_pool[idx]), " ditolak (HTTP ", status, ") -> diistirahatkan 12 jam.");
         }
         else if(status == 429)
         {
            string lower = body;
            StringToLower(lower);
            bool exhausted = (StringFind(lower, "quota") >= 0 || StringFind(lower, "billing") >= 0 ||
                              StringFind(lower, "credit") >= 0 || StringFind(lower, "insufficient") >= 0 ||
                              StringFind(lower, "spend") >= 0  || StringFind(lower, "balance") >= 0);
            if(exhausted)
            {
               m_pool_dead[idx] = now + (6 * 3600);
               Print("GroqClient[POOL]: key ", MaskKey(m_pool[idx]), " tampaknya habis saldo/kuota -> diistirahatkan 6 jam.");
            }
            else
            {
               int retry_after = ExtractRetryAfterSeconds(headers);
               if(retry_after <= 0) retry_after = 60;
               m_pool_cooldown[idx] = now + retry_after;
               Print("GroqClient[POOL]: key ", MaskKey(m_pool[idx]), " kena rate limit, cooldown ", retry_after, " detik.");
            }
         }
         else if(status >= 500)
         {
            // gangguan sisi Groq: coba key berikutnya saja
         }
         else
         {
            string lower400 = body;
            StringToLower(lower400);
            bool credit_words = (StringFind(lower400, "credit") >= 0 || StringFind(lower400, "billing") >= 0 ||
                                 StringFind(lower400, "quota") >= 0  || StringFind(lower400, "balance") >= 0);
            if(status == 400 && credit_words)
            {
               // mis. Anthropic: "credit balance is too low" -> key habis saldo, bukan salah payload
               m_pool_dead[idx] = now + (6 * 3600);
               Print("GroqClient[POOL]: key ", MaskKey(m_pool[idx]), " habis kredit (HTTP 400) -> diistirahatkan 6 jam.");
            }
            else
            {
               // 400/404 dsb: payload/model bermasalah, mengganti key tidak akan membantu
               string snippet = (StringLen(body) > 200) ? StringSubstr(body, 0, 200) : body;
               Print("GroqClient[POOL]: HTTP ", status, " body=", snippet);
               result.success = false;
               result.error_message = "Pool: HTTP status " + IntegerToString(status);
               return false;
            }
         }
      }

      result.success = false;
      result.error_message = "Pool: tidak ada key yang berhasil (dicoba " + IntegerToString(tried) +
                             " key, hidup " + IntegerToString(PoolAliveCount()) + "/" + IntegerToString(n) + ")";
      return false;
   }

   //+---------------------------------------------------------------+
   //| BLOK PROXY: helper komunikasi ke Cloudflare Worker                |
   //+---------------------------------------------------------------+
   bool AnyDirectKeyFilled()
   {
      for(int i = 0; i < GROQ_TOTAL_SLOTS; i++)
         if(m_key_filled[i]) return true;
      return false;
   }

   // Bagian umum body ke Worker. Alamat provider SENGAJA TIDAK dikirim
   // (ditetapkan di Worker) supaya token yang bocor tidak bisa dipakai
   // mengarahkan key Anda ke server lain.
   string ProviderId()
   {
      switch(m_provider)
      {
         case AIP_OPENROUTER: return "openrouter";
         case AIP_OPENAI:     return "openai";
         case AIP_ANTHROPIC:  return "anthropic";
         case AIP_CUSTOM:     return "custom";
         default:             return "groq";
      }
   }

   string BuildProxyCommon()
   {
      string b = "\"provider\":\"" + ProviderId() + "\",";
      b += "\"model\":\"" + JsonEscape(m_model) + "\",";
      b += "\"max_tokens\":" + IntegerToString(m_max_tokens) + ",";
      b += (m_temperature >= 0.0) ? ("\"temperature\":" + DoubleToString(m_temperature, 2))
                                  : "\"temperature\":null";
      if(m_extra_override)
         b += ",\"extra\":{" + m_extra_json + "}";   // kosong -> {} = tanpa tambahan
      return b;
   }

   // Body request untuk 1 panggilan tunggal ke Worker (/call)
   string BuildProxyCallBody(const string system_prompt, const string user_prompt)
   {
      string b = "{";
      b += BuildProxyCommon() + ",";
      b += "\"system\":\"" + JsonEscape(system_prompt) + "\",";
      b += "\"user\":\"" + JsonEscape(user_prompt) + "\"";
      b += "}";
      return b;
   }

   // Kirim POST ke Worker. Mengembalikan status HTTP (-1 = gagal total)
   int SendProxyRequest(const string path, const string body, const int timeout_ms, string &out_body)
   {
      char post_data[];
      StringToCharArray(body, post_data, 0, StringLen(body), CP_UTF8);

      char result[];
      string request_headers = "Content-Type: application/json\r\n" +
                                "X-EA-Token: " + m_proxy_token + "\r\n";
      string response_headers = "";

      ResetLastError();
      int status = WebRequest("POST", m_proxy_url + path, request_headers, timeout_ms,
                               post_data, result, response_headers);

      if(status < 0)
      {
         Print("GroqClient[PROXY]: WebRequest gagal total (error=", GetLastError(),
               "). Pastikan URL Worker sudah diizinkan di Tools > Options > Expert Advisors > Allow WebRequest.");
         out_body = "";
         return -1;
      }

      out_body = (ArraySize(result) > 0) ? CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8) : "";
      return status;
   }

   bool ProxyCall(const string system_prompt, const string user_prompt, GroqCallResult &result)
   {
      string body = "";
      int status = SendProxyRequest("/call", BuildProxyCallBody(system_prompt, user_prompt),
                                     m_timeout_ms + 15000, body);
      result.http_status = status;

      if(status == 200 && StringFind(body, "\"ok\":true") >= 0)
      {
         string inner = ExtractMessageContent(body);
         if(inner != "")
         {
            result.success = true;
            result.content = inner;
            result.error_message = "";
            return true;
         }
         result.success = false;
         result.error_message = "Proxy HTTP 200 tapi field content kosong";
         return false;
      }

      result.success = false;
      result.error_message = "Proxy HTTP status " + IntegerToString(status);
      return false;
   }

   //+---------------------------------------------------------------+
   //| Coba satu slot key tertentu. Mengisi cooldown kalau kena limit  |
   //+---------------------------------------------------------------+
   bool TryOneSlot(const int slot, const string payload, GroqCallResult &result)
   {
      string body = "";
      string headers = "";
      int status = SendRequest(m_api_keys[slot], payload, body, headers);

      result.http_status = status;

      if(status == 200 && body != "")
      {
         string inner = ExtractCompletionText(body);
         if(inner == "")
         {
            result.success = false;
            result.error_message = "HTTP 200 tapi gagal membongkar field content (format respons berubah?)";
            return false;
         }

         result.success = true;
         result.content = inner;
         result.error_message = "";
         return true;
      }

      // HTTP 429 = rate limited -> catat cooldown slot ini sesuai header retry-after
      if(status == 429)
      {
         int retry_after = ExtractRetryAfterSeconds(headers);
         if(retry_after <= 0) retry_after = 30; // fallback aman kalau header tidak ada
         m_cooldown_until[slot] = TimeCurrent() + retry_after;

         Print("GroqClient: slot ", slot, " kena rate limit (429), cooldown ", retry_after, " detik.");
      }
      else if(status != 200)
      {
         string snippet = (StringLen(body) > 200) ? StringSubstr(body, 0, 200) : body;
         Print("GroqClient: slot ", slot, " gagal, HTTP status=", status, " body=", snippet);
      }

      result.success = false;
      result.error_message = "HTTP status " + IntegerToString(status);
      return false;
   }

public:
   //+---------------------------------------------------------------+
   //| Constructor - nilai default aman kalau belum di-Initialize()    |
   //+---------------------------------------------------------------+
   CGroqClient()
   {
      m_base_url    = "https://api.groq.com/openai/v1/";
      ArrayResize(m_pool, 0);
      ArrayResize(m_pool_cooldown, 0);
      ArrayResize(m_pool_dead, 0);
      m_pool_next   = 0;
      m_provider       = AIP_GROQ;
      m_chat_url       = "https://api.groq.com/openai/v1/chat/completions";
      m_extra_json     = "\"reasoning_effort\":\"low\",\"response_format\":{\"type\":\"json_object\"}";
      m_extra_override = false;
      m_token_param    = "max_tokens";
      m_use_proxy   = false;
      m_proxy_url   = "";
      m_proxy_token = "";
      m_model       = "openai/gpt-oss-120b";
      m_max_tokens  = 1000;
      m_temperature = 0.3;
      m_timeout_ms  = 30000;

      for(int i = 0; i < GROQ_TOTAL_SLOTS; i++)
      {
         m_api_keys[i]        = "";
         m_key_filled[i]      = false;
         m_cooldown_until[i]  = 0;
      }
   }

   //+---------------------------------------------------------------+
   //| Inisialisasi dengan 12 API key + parameter model                |
   //+---------------------------------------------------------------+
   // PENJELASAN: dipanggil dari OnInit() EA utama, isi keys[0..11] persis
   // urutan slot (0-9 analis, 10 penyimpul, 11 cadangan). String kosong
   // untuk slot yang memang belum diisi user dianggap valid (slot itu
   // otomatis dilewati saat Call() dipanggil untuknya, lihat catatan di
   // Call()).
   void Initialize(string &keys[], const string model = "openai/gpt-oss-120b",
                    const int max_tokens = 1000, const double temperature = 0.3,
                    const int timeout_ms = 30000)
   {
      m_model       = model;
      m_max_tokens  = max_tokens;
      m_temperature = temperature;
      m_timeout_ms  = timeout_ms;

      int count = MathMin(ArraySize(keys), GROQ_TOTAL_SLOTS);
      for(int i = 0; i < GROQ_TOTAL_SLOTS; i++)
      {
         m_api_keys[i]   = (i < count) ? keys[i] : "";
         m_key_filled[i] = (StringLen(m_api_keys[i]) > 0);
         m_cooldown_until[i] = 0;
      }

      if(!m_use_proxy && ArraySize(m_pool) == 0 && !m_key_filled[GROQ_RESERVE_SLOT])
      {
         Print("GroqClient PERINGATAN: slot cadangan (slot 12) kosong. ",
               "Kalau salah satu dari 11 slot lain kena rate limit, TIDAK ADA fallback.");
      }

      int filled_count = 0;
      for(int i = 0; i < GROQ_TOTAL_SLOTS; i++)
         if(m_key_filled[i]) filled_count++;

      Print("GroqClient: Initialize selesai. ", filled_count, "/", GROQ_TOTAL_SLOTS, " slot API key terisi.");
   }

   //+---------------------------------------------------------------+
   //| Apakah slot tertentu sedang dalam masa cooldown (rate limit)?   |
   //+---------------------------------------------------------------+
   bool IsSlotCoolingDown(const int slot)
   {
      if(slot < 0 || slot >= GROQ_TOTAL_SLOTS) return true;
      return TimeCurrent() < m_cooldown_until[slot];
   }

   //+---------------------------------------------------------------+
   //| PROVIDER: pilih provider, alamat, field tambahan                  |
   //+---------------------------------------------------------------+
   // base_url   : kosong = bawaan provider. Boleh alamat dasar (".../v1") atau
   //              alamat lengkap (".../chat/completions" / ".../messages").
   // extra_json : "auto" = bawaan provider; "" = tanpa tambahan; selain itu pakai
   //              teks Anda (potongan JSON TANPA kurung kurawal), mis.
   //              "reasoning_effort":"low","response_format":{"type":"json_object"}
   // token_param: "auto" atau nama field batas token ("max_tokens" / "max_completion_tokens")
   // CATATAN: di mode Worker, alamat provider ditentukan di Worker, bukan di sini.
   void SetProvider(const int provider, const string base_url, const string extra_json, const string token_param)
   {
      m_provider = provider;

      string base = base_url;
      StringTrimLeft(base);
      StringTrimRight(base);
      if(StringLen(base) == 0)
      {
         switch(provider)
         {
            case AIP_OPENROUTER: base = "https://openrouter.ai/api/v1";  break;
            case AIP_OPENAI:     base = "https://api.openai.com/v1";     break;
            case AIP_ANTHROPIC:  base = "https://api.anthropic.com/v1";   break;
            case AIP_CUSTOM:     base = "";                               break;
            default:             base = "https://api.groq.com/openai/v1"; break;
         }
      }
      while(StringLen(base) > 0 && StringGetCharacter(base, StringLen(base) - 1) == '/')
         base = StringSubstr(base, 0, StringLen(base) - 1);

      if(StringLen(base) == 0)
         m_chat_url = "";
      else if(StringFind(base, "/chat/completions") >= 0 || StringFind(base, "/messages") >= 0)
         m_chat_url = base;                                                  // sudah alamat lengkap
      else
         m_chat_url = base + ((provider == AIP_ANTHROPIC) ? "/messages" : "/chat/completions");

      string extra = extra_json;
      StringTrimLeft(extra);
      StringTrimRight(extra);
      string extra_lower = extra;
      StringToLower(extra_lower);
      if(extra_lower == "auto")
      {
         m_extra_override = false;
         switch(provider)
         {
            case AIP_GROQ:       m_extra_json = "\"reasoning_effort\":\"low\",\"response_format\":{\"type\":\"json_object\"}"; break;
            case AIP_OPENROUTER:
            case AIP_OPENAI:     m_extra_json = "\"response_format\":{\"type\":\"json_object\"}"; break;
            default:             m_extra_json = ""; break;
         }
      }
      else
      {
         m_extra_override = true;
         m_extra_json = extra;
      }

      string tp = token_param;
      StringTrimLeft(tp);
      StringTrimRight(tp);
      string tp_lower = tp;
      StringToLower(tp_lower);
      if(StringLen(tp) == 0 || tp_lower == "auto")
         m_token_param = (provider == AIP_OPENAI) ? "max_completion_tokens" : "max_tokens";
      else
         m_token_param = tp;

      Print("GroqClient: provider=", ProviderId(), " | alamat langsung=", (StringLen(m_chat_url) > 0 ? m_chat_url : "(kosong)"),
            " | field token=", m_token_param, " | tambahan=", (m_extra_override ? "kustom" : "bawaan"));
   }

   //+---------------------------------------------------------------+
   //| POOL KEY: tambah banyak key sekaligus                              |
   //+---------------------------------------------------------------+
   // Menerima teks berisi key dipisah koma, titik-koma, spasi, atau baris baru.
   // Duplikat dibuang. Mengembalikan jumlah key BARU yang ditambahkan.
   int AddKeysFromText(const string text)
   {
      int added = 0;
      string cur = "";
      int len = StringLen(text);

      for(int i = 0; i <= len; i++)
      {
         ushort ch = (i < len) ? StringGetCharacter(text, i) : (ushort)',';
         bool is_sep = (ch == ',' || ch == ';' || ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t');
         if(!is_sep)
         {
            cur += ShortToString(ch);
            continue;
         }

         if(StringLen(cur) >= 10 && !PoolContains(cur))
         {
            int n = ArraySize(m_pool);
            ArrayResize(m_pool, n + 1);
            ArrayResize(m_pool_cooldown, n + 1);
            ArrayResize(m_pool_dead, n + 1);
            m_pool[n] = cur;
            m_pool_cooldown[n] = 0;
            m_pool_dead[n] = 0;
            added++;
         }
         cur = "";
      }
      return added;
   }

   // Baca key dari file di folder MQL5\Files (dipisah koma atau baris baru).
   // Cocok untuk puluhan/ratusan key karena kolom input MT5 terbatas panjangnya.
   int LoadKeysFromFile(const string filename)
   {
      int h = FileOpen(filename, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ);
      if(h == INVALID_HANDLE)
      {
         Print("GroqClient[POOL]: file key '", filename, "' tidak ditemukan di MQL5\\Files (dilewati).");
         return 0;
      }

      string all = "";
      while(!FileIsEnding(h))
         all += FileReadString(h) + ",";
      FileClose(h);

      return AddKeysFromText(all);
   }

   int PoolSize() { return ArraySize(m_pool); }

   int PoolAliveCount()
   {
      datetime now = TimeCurrent();
      int alive = 0;
      for(int i = 0; i < ArraySize(m_pool); i++)
         if(m_pool_dead[i] <= now) alive++;
      return alive;
   }

   //+---------------------------------------------------------------+
   //| MODE PROXY: SetProxy / IsProxyEnabled / CallBatch                |
   //+---------------------------------------------------------------+
   // PENJELASAN: kalau URL Worker diisi, EA memanggil Worker (bukan Groq
   // langsung). Worker memegang API key (tidak ada key di kode/EA) dan
   // memanggil 10 analis SECARA PARALEL, jadi total tunggu ~1 panggilan,
   // bukan 10 panggilan berurutan.
   void SetProxy(const string url, const string token)
   {
      string u = url;
      StringTrimLeft(u);
      StringTrimRight(u);
      while(StringLen(u) > 0 && StringGetCharacter(u, StringLen(u) - 1) == '/')
         u = StringSubstr(u, 0, StringLen(u) - 1);

      m_proxy_url   = u;
      m_proxy_token = token;
      m_use_proxy   = (StringLen(u) > 0);

      if(m_use_proxy)
         Print("GroqClient: mode PROXY aktif -> ", m_proxy_url);
   }

   bool IsProxyEnabled() { return m_use_proxy; }

   // Panggil N analis sekaligus lewat Worker (/analysts).
   // results[] selalu berukuran N; item gagal ditandai success=false.
   bool CallBatch(const string &system_prompts[], const string &user_prompts[], GroqCallResult &results[])
   {
      int n = MathMin(ArraySize(system_prompts), ArraySize(user_prompts));
      ArrayResize(results, n);
      for(int i = 0; i < n; i++)
      {
         results[i].success          = false;
         results[i].content          = "";
         results[i].http_status      = 0;
         results[i].used_reserve_key = false;
         results[i].error_message    = "Belum dipanggil";
      }
      if(!m_use_proxy || n <= 0) return false;

      string b = "{";
      b += BuildProxyCommon() + ",";
      b += "\"items\":[";
      for(int i = 0; i < n; i++)
      {
         if(i > 0) b += ",";
         b += "{\"system\":\"" + JsonEscape(system_prompts[i]) + "\",";
         b += "\"user\":\"" + JsonEscape(user_prompts[i]) + "\"}";
      }
      b += "]}";

      string body = "";
      int status = SendProxyRequest("/analysts", b, m_timeout_ms * 2, body);

      if(status != 200 || body == "")
      {
         for(int i = 0; i < n; i++)
         {
            results[i].http_status   = status;
            results[i].error_message = "Proxy batch HTTP status " + IntegerToString(status);
         }
         Print("GroqClient[PROXY]: batch gagal, HTTP status=", status);
         return false;
      }

      // Pecah respons: tiap item diawali {"ok":
      string marker = "{\"ok\":";
      int starts[];
      ArrayResize(starts, 0);
      int pos = 0;
      while(true)
      {
         int p = StringFind(body, marker, pos);
         if(p < 0) break;
         int sz = ArraySize(starts);
         ArrayResize(starts, sz + 1);
         starts[sz] = p;
         pos = p + StringLen(marker);
      }

      int found = ArraySize(starts);
      int total_len = StringLen(body);
      for(int i = 0; i < n && i < found; i++)
      {
         int seg_end = (i + 1 < found) ? starts[i + 1] : total_len;
         string seg = StringSubstr(body, starts[i], seg_end - starts[i]);

         results[i].http_status = 200;
         if(StringFind(seg, "{\"ok\":true") == 0)
         {
            string inner = ExtractMessageContent(seg);
            if(inner != "")
            {
               results[i].success       = true;
               results[i].content       = inner;
               results[i].error_message = "";
               continue;
            }
            results[i].error_message = "Proxy item ok tapi content kosong";
         }
         else
         {
            results[i].error_message = "Proxy item gagal (Groq menolak/limit)";
         }
      }

      return true;
   }

   //+---------------------------------------------------------------+
   //| Panggilan utama - satu-satunya fungsi yang dipakai pemanggil    |
   //+---------------------------------------------------------------+
   // PARAMETER:
   //   slot          -> 0-9 untuk analis ke-(slot+1), 10 untuk Penyimpul.
   //                    JANGAN pernah panggil dengan slot=11 (GROQ_RESERVE_SLOT)
   //                    secara langsung dari luar -- itu murni cadangan internal.
   //   system_prompt -> instruksi peran AI (system message)
   //   user_prompt   -> data pasar & pertanyaan analisa (user message)
   //
   // ALUR:
   //   1. Kalau slot utama kosong (belum diisi user) atau sedang cooldown,
   //      langsung lompat ke slot cadangan (11) tanpa buang waktu mencoba
   //      slot yang sudah diketahui akan gagal.
   //   2. Kalau slot utama tersedia, coba dulu. Kalau gagal (429/error apa
   //      pun) DAN itu bukan slot cadangan itu sendiri, otomatis retry satu
   //      kali pakai slot cadangan (11).
   //   3. Kalau slot cadangan juga gagal/kosong -> result.success = false,
   //      pemanggil WAJIB menangani ini (skip opini analis tsb di siklus
   //      ini, jangan dianggap error fatal EA).
   GroqCallResult Call(const int slot, const string system_prompt, const string user_prompt,
                        const bool skip_proxy = false)
   {
      GroqCallResult result;
      result.success          = false;
      result.content          = "";
      result.http_status      = 0;
      result.used_reserve_key = false;
      result.error_message    = "";

      if(slot < 0 || slot >= GROQ_TOTAL_SLOTS)
      {
         result.error_message = "Nomor slot tidak valid: " + IntegerToString(slot);
         Print("GroqClient: ", result.error_message);
         return result;
      }

      // Mode PROXY: coba Worker dulu. Kalau gagal dan ada key langsung -> lanjut jalur lama.
      if(m_use_proxy && !skip_proxy)
      {
         if(ProxyCall(system_prompt, user_prompt, result))
         {
            result.used_reserve_key = false;
            return result;
         }
         if(!AnyDirectKeyFilled() && ArraySize(m_pool) == 0)
         {
            Print("GroqClient: proxy gagal (", result.error_message,
                  ") dan tidak ada API key langsung sebagai cadangan.");
            return result;
         }
         Print("GroqClient: proxy gagal (", result.error_message, "), mencoba key langsung...");
      }

      string payload = BuildPayload(system_prompt, user_prompt);

      // POOL KEY (banyak key dirotasi). Kalau pool gagal total dan ada slot lama -> lanjut ke slot.
      if(ArraySize(m_pool) > 0)
      {
         if(PoolCall(payload, result))
         {
            result.used_reserve_key = false;
            return result;
         }
         if(!AnyDirectKeyFilled())
         {
            Print("GroqClient: pool key gagal (", result.error_message, ").");
            return result;
         }
      }

      bool primary_usable = m_key_filled[slot] && !IsSlotCoolingDown(slot);
      bool primary_is_reserve = (slot == GROQ_RESERVE_SLOT);

      if(primary_usable)
      {
         if(TryOneSlot(slot, payload, result))
         {
            result.used_reserve_key = primary_is_reserve;
            return result;
         }
      }
      else if(!m_key_filled[slot])
      {
         result.error_message = "Slot " + IntegerToString(slot) + " belum diisi API key.";
      }
      else
      {
         result.error_message = "Slot " + IntegerToString(slot) + " sedang cooldown rate limit.";
      }

      // Primary gagal/tidak tersedia -> coba cadangan, KECUALI slot yang
      // diminta memang sudah slot cadangan itu sendiri (hindari panggil 2x).
      if(!primary_is_reserve)
      {
         bool reserve_usable = m_key_filled[GROQ_RESERVE_SLOT] && !IsSlotCoolingDown(GROQ_RESERVE_SLOT);
         if(reserve_usable)
         {
            Print("GroqClient: slot ", slot, " gagal (", result.error_message,
                  "), mencoba slot cadangan (12)...");

            GroqCallResult reserve_result;
            if(TryOneSlot(GROQ_RESERVE_SLOT, payload, reserve_result))
            {
               reserve_result.used_reserve_key = true;
               return reserve_result;
            }

            result = reserve_result;
            result.used_reserve_key = true;
         }
      }

      if(!result.success)
      {
         Print("GroqClient: panggilan untuk slot ", slot, " gagal total (primer & cadangan). ",
               "Detail: ", result.error_message);
      }

      return result;
   }
};
