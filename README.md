# DidinskaGridV2 v2.00 - Petunjuk Pemasangan

Isi ZIP ini HANYA file yang berubah/baru. File lain (AISummarizer.mqh,
NativeDecisionEngine.mqh, NewsAPI.mqh) tidak disentuh.

| File | Status |
|---|---|
| DidinskaGridV2.mq5 | diubah besar |
| Include/GroqClient.mqh | diubah (mode proxy + batch) |
| Include/Analysts.mqh | diubah (panggilan paralel via proxy) |
| Include/MarketData.mqh | diubah (handle sekali, candle tertutup, fix pola candle) |
| Include/TelegramNotify.mqh | diubah (UTF-8, pesan bebas) |
| Include/NewsFilter.mqh | BARU (kalender MT5) |
| Include/DecisionJournal.mqh | BARU (jurnal + akurasi) |
| worker/ea-proxy-worker.js | BARU (Cloudflare Worker) |

NewsAPI.mqh tidak lagi di-include. Boleh dibiarkan atau dihapus.

## LANGKAH 0 - Ganti semua API key (WAJIB)
Key Groq, NewsAPI, dan token Telegram yang lama tertulis di kode.
1. Groq: buat key baru, hapus (revoke) yang lama.
2. NewsAPI: tidak dipakai lagi, hapus key lama.
3. Telegram: di @BotFather kirim /revoke lalu pilih bot -> token baru.
Kode baru TIDAK menyimpan key apa pun (semua default kosong).

## LANGKAH 1 - Pasang Worker (disarankan)
1. Cloudflare dashboard -> Workers & Pages -> Create -> Worker -> beri nama, misal `ea-proxy` -> Deploy.
2. Edit code -> hapus isi bawaan -> tempel seluruh isi `worker/ea-proxy-worker.js` -> Deploy.
3. Settings -> Variables and Secrets -> tambah (tipe Secret):
   - `EA_TOKEN` = kata sandi acak panjang buatan Anda
   - `GROQ_API_KEY` = key Groq BARU
   - (opsional) `GROQ_API_KEY_2` = key cadangan
4. Salin URL Worker, misal `https://ea-proxy.namamu.workers.dev`.
5. Tes: buka URL itu di browser HP. Harus muncul `{"service":"didinska-ea-proxy","status":"hidup"}`.

## LANGKAH 2 - Pasang EA di MT5 (PC/VPS tempat EA berjalan)
1. Timpa file di folder `MQL5/Experts/<folder EA Anda>/`:
   DidinskaGridV2.mq5 dan isi folder Include/ sesuai tabel di atas.
2. Buka DidinskaGridV2.mq5 di MetaEditor -> Compile (F7).
   Kirim ke saya semua pesan error/warning kalau ada.
3. MT5: Tools -> Options -> Expert Advisors -> centang "Allow WebRequest for listed URL"
   -> tambah URL Worker Anda (dan https://api.telegram.org untuk Telegram).
4. Pasang EA di chart XAUUSD, tab Inputs:
   - InpProxyUrl = URL Worker, InpProxyToken = EA_TOKEN
   - Telegram: isi InpTelegramBotToken & InpTelegramChatId yang baru
   - InpBrokerGmtOffset = offset GMT server broker Anda
   - Cek jam filter: InpFridayStopNewHour / InpFridayCloseHour (jam SERVER broker)
5. Mulai di akun DEMO minimal 4-6 minggu.

## Input baru yang penting
- InpMaxBasketRiskPct (2.0): batas risiko total 1 grid. Lot otomatis diperkecil.
- InpMaxLayersPerSide (4): batas layer per sisi.
- InpMaxConsecLosses (3) + InpLossCooldownMin (60): jeda setelah 3 basket rugi beruntun.
- InpNewsBlackoutBefore/After (20/15 menit): pending dihapus di sekitar berita HIGH.
- InpNativeGate: veto Native terhadap AI (default: veto kalau berlawanan).
- InpUseATRGridDistance (true) + InpGridDistanceATR (0.5): jarak grid pakai ATR.
- InpEnableJournal (true): file CSV di MQL5/Files (lihat bawah).

## Melanjutkan setelah HALT PERMANEN (peak drawdown)
Peak equity sekarang tersimpan walau EA di-restart. Untuk lanjut:
set InpResetPeakOnInit = true -> pasang ulang EA -> setelah jalan, kembalikan ke false.

## Membaca hasil jurnal (MQL5/Files)
- `DidinskaGridV2_XAUUSD_decisions.csv`: satu baris per siklus (vote tiap analis).
- `DidinskaGridV2_XAUUSD_outcomes.csv`: hasil harga setelah 60 menit, HIT/MISS per analis,
  dibandingkan dengan Native. Kumpulkan puluhan sampai ratusan baris sebelum menyimpulkan.
Kolom arah: 0 netral/WAIT, 1 naik/BUY, 2 turun/SELL, -1 analis gagal.

## Batasan yang perlu diketahui
- Strategy Tester: filter berita tidak aktif (kalender MT5 tidak ada di tester) dan
  mode AI ON tidak bisa di-backtest. Gunakan MODE_AI_OFF untuk backtest.
- WebRequest tetap memblokir EA selama panggilan berlangsung. Karena itu siklus AI
  sengaja TIDAK dijalankan saat ada posisi terbuka.
- Antrean evaluasi jurnal ada di memori: yang belum dievaluasi hilang saat EA di-restart.
