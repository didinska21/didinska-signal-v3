//+------------------------------------------------------------------+
//|                                                  NewsFilter.mqh   |
//|        Didinska Grid V2 - Filter Berita via Kalender Ekonomi MT5   |
//|                                                                    |
//|   PENGGANTI NewsAPI.mqh untuk fungsi filter berita.                |
//|   Kenapa diganti:                                                   |
//|     - Kalender bawaan MT5 punya field "importance" resmi (HIGH),    |
//|       tidak perlu menebak dampak dari kata kunci judul berita.      |
//|     - TANPA WebRequest -> tidak ada risiko rate limit / timeout,    |
//|       tidak membebani tiap tick.                                    |
//|     - Daftar event di-cache dan hanya di-refresh tiap 15 menit.     |
//|                                                                    |
//|   Dua tingkat status:                                               |
//|     BLACKOUT = dalam jendela [-after, +before] menit dari event     |
//|                HIGH -> EA hapus pending & dilarang buka grid baru.  |
//|     CAUTION  = event HIGH dalam <= warn menit ke depan -> lot       |
//|                dikurangi & syarat probabilitas dinaikkan.           |
//|                                                                    |
//|   CATATAN: Kalender TIDAK tersedia di Strategy Tester -> filter     |
//|   otomatis nonaktif saat backtest (EA tetap jalan normal).          |
//+------------------------------------------------------------------+
#property copyright "Didinska Grid V2"
#property strict

enum ENUM_NEWS_FILTER_STATE
{
   NFS_CLEAR    = 0,
   NFS_CAUTION  = 1,
   NFS_BLACKOUT = 2
};

class CNewsFilter
{
private:
   string    m_currencies[];
   int       m_before_min;
   int       m_after_min;
   int       m_warn_min;
   datetime  m_last_refresh;
   bool      m_available;
   bool      m_status_logged;

   datetime  m_event_times[];
   string    m_event_titles[];
   string    m_event_ccy[];

   void AddEvent(const datetime t, const string title, const string ccy)
   {
      int n = ArraySize(m_event_times);
      ArrayResize(m_event_times, n + 1);
      ArrayResize(m_event_titles, n + 1);
      ArrayResize(m_event_ccy, n + 1);
      m_event_times[n]  = t;
      m_event_titles[n] = title;
      m_event_ccy[n]    = ccy;
   }

public:
   CNewsFilter()
   {
      m_before_min    = 20;
      m_after_min     = 15;
      m_warn_min      = 60;
      m_last_refresh  = 0;
      m_available     = false;
      m_status_logged = false;
      ArrayResize(m_currencies, 0);
   }

   //+---------------------------------------------------------------+
   //| Konfigurasi: daftar mata uang (CSV), jendela blackout & waspada  |
   //+---------------------------------------------------------------+
   void Configure(const string currencies_csv, const int before_min, const int after_min, const int warn_min)
   {
      m_before_min = MathMax(0, before_min);
      m_after_min  = MathMax(0, after_min);
      m_warn_min   = MathMax(m_before_min, warn_min);

      ArrayResize(m_currencies, 0);
      string parts[];
      int n = StringSplit(currencies_csv, ',', parts);
      for(int i = 0; i < n; i++)
      {
         string c = parts[i];
         StringTrimLeft(c);
         StringTrimRight(c);
         StringToUpper(c);
         if(StringLen(c) == 0) continue;

         int sz = ArraySize(m_currencies);
         ArrayResize(m_currencies, sz + 1);
         m_currencies[sz] = c;
      }

      if(ArraySize(m_currencies) == 0)
      {
         ArrayResize(m_currencies, 1);
         m_currencies[0] = "USD";
      }

      m_last_refresh  = 0;
      m_status_logged = false;
      Refresh(true);
   }

   //+---------------------------------------------------------------+
   //| Muat ulang daftar event HIGH (maks tiap 15 menit)                |
   //+---------------------------------------------------------------+
   void Refresh(const bool force = false)
   {
      datetime now = TimeTradeServer();
      if(!force && m_last_refresh != 0 && (now - m_last_refresh) < 900) return;
      m_last_refresh = now;

      ArrayResize(m_event_times, 0);
      ArrayResize(m_event_titles, 0);
      ArrayResize(m_event_ccy, 0);

      if(MQLInfoInteger(MQL_TESTER))
      {
         m_available = false;
         if(!m_status_logged)
            Print("NewsFilter: Kalender Ekonomi tidak tersedia di Strategy Tester -> filter berita NONAKTIF selama backtest.");
         m_status_logged = true;
         return;
      }

      bool any_ok = false;
      datetime from = now - (datetime)((m_after_min + 5) * 60);
      datetime to   = now + (datetime)(36 * 3600);

      for(int c = 0; c < ArraySize(m_currencies); c++)
      {
         MqlCalendarValue values[];
         ResetLastError();
         if(!CalendarValueHistory(values, from, to, NULL, m_currencies[c]))
            continue;

         any_ok = true;
         for(int i = 0; i < ArraySize(values); i++)
         {
            MqlCalendarEvent ev;
            if(!CalendarEventById(values[i].event_id, ev)) continue;
            if(ev.importance != CALENDAR_IMPORTANCE_HIGH) continue;
            if(ev.type == CALENDAR_TYPE_HOLIDAY) continue;

            AddEvent(values[i].time, ev.name, m_currencies[c]);
         }
      }

      m_available = any_ok;

      if(!m_status_logged)
      {
         if(m_available)
            Print("NewsFilter: Kalender MT5 aktif, ", ArraySize(m_event_times),
                  " event HIGH dalam 36 jam ke depan (mata uang: ", ArraySize(m_currencies), ").");
         else
            Print("NewsFilter: Kalender MT5 TIDAK bisa dibaca (error=", GetLastError(),
                  "). Filter berita nonaktif. Coba buka tab Calendar di terminal sekali agar data tersinkron.");
         m_status_logged = true;
      }
   }

   //+---------------------------------------------------------------+
   //| Status berita saat ini + judul & jarak menit event terdekat      |
   //+---------------------------------------------------------------+
   // out_minutes: menit sampai event (negatif = event sudah lewat)
   ENUM_NEWS_FILTER_STATE GetState(string &out_title, int &out_minutes)
   {
      Refresh();

      out_title   = "";
      out_minutes = 0;
      if(!m_available) return NFS_CLEAR;

      datetime now = TimeTradeServer();
      ENUM_NEWS_FILTER_STATE state = NFS_CLEAR;

      for(int i = 0; i < ArraySize(m_event_times); i++)
      {
         double delta_min = (double)(m_event_times[i] - now) / 60.0;

         if(delta_min >= -(double)m_after_min && delta_min <= (double)m_before_min)
         {
            out_title   = m_event_ccy[i] + " " + m_event_titles[i];
            out_minutes = (int)MathRound(delta_min);
            return NFS_BLACKOUT;
         }

         if(delta_min > (double)m_before_min && delta_min <= (double)m_warn_min && state == NFS_CLEAR)
         {
            state       = NFS_CAUTION;
            out_title   = m_event_ccy[i] + " " + m_event_titles[i];
            out_minutes = (int)MathRound(delta_min);
         }
      }

      return state;
   }

   bool IsAvailable() { return m_available; }
};
