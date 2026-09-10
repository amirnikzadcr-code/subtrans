# SubTrans — زیرنویس یوتیوب با ترجمه ۱۳۰+ زبان

کلون معماری اپ **Video Translate (net.yaysoft.ytranslate v3.0.2)** — فقط قابلیت زیرنویس/ترجمه فعال است.

## معماری (کپی از سورس اصلی)

```
Flutter app (thin client)
   │  GET /?action=youtube_asr&v=<id>&target=<lang>
   ▼
Cloudflare Worker (fat server)  ──►  YouTube (InnerTube + caption tracks)
   │                                   ├─ کپشن دستی اول، بعد ASR خودکار
   ▼                                   └─ خطاهای دسته‌بندی‌شده (video_is_live, age_restricted, …)
ترجمه ۱۳۰+ زبان
   ├─ Gemini (primary) — اگر GEMINI_API_KEY ست شده باشد
   └─ Google gtx (fallback بدون کلید)
```

- نام اکشن‌ها همان سورس اصلی: `youtube_asr`، `youtube_asr_languages`، `translate`
- کلیدهای خطا همان سورس: `video_not_found`، `video_is_live`، `age_restricted`، `copyright_blocked`، `no_speech`، `transcript_fetch_failed`
- کش نتیجه با Cache API کلافلر (کلید: video+lang+target)

## ساختار ریپو

| مسیر | توضیح |
|---|---|
| `worker/src/index.js` | بک‌اند Cloudflare Worker |
| `worker/wrangler.toml` | کانفیگ دیپلوی |
| `app/` | اپ Flutter (اسکلت اندروید در CI با `flutter create .` ساخته می‌شود) |
| `.github/workflows/android.yml` | بیلد خودکار APK در GitHub Actions |

## بیلد APK

پوش به `main` → تب **Actions** → workflow «Build APK» → دانلود آرتیفکت `subtrans-apk`.
(یا دستی: تب Actions → Run workflow)

## دیپلوی Worker

```bash
cd worker
npx wrangler login
npx wrangler deploy
```

فعال‌کردن Gemini به‌عنوان موتور اصلی ترجمه (دقیقاً مثل سورس):

```bash
npx wrangler secret put GEMINI_API_KEY
```

آدرس Worker را در `app/lib/api_client.dart` (ثابت `Api.baseUrl`) یا با فلگ بیلد عوض کن:

```bash
flutter build apk --release --dart-define=API_BASE_URL=https://your-worker.workers.dev
```

## 🔐 نکته امنیتی

- هیچ توکنی در این ریپو کامیت نشده است.
- توکن‌هایی که در چت به اشتراک گذاشته شده را بعد از اتمام کار **قطعاً rotate/revoke کن** (GitHub → Settings → Developer settings؛ Cloudflare → My Profile → API Tokens).
