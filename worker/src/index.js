/**
 * SubTrans Worker — YouTube subtitle fetch + AI translation (130+ languages)
 * Architecture cloned from net.yaysoft.ytranslate (Video Translate) v3.0.2:
 *   - action-based API (same action names as the original)
 *   - captions-first strategy, ASR fallback flag, categorized error codes
 *   - thin client / fat server: all intelligence lives here
 */

const UA_DESKTOP =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

const MAX_SEGMENTS = 1200;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-API-KEY",
};

// ---------------------------------------------------------------------------
// Error model — same keys as the original app (youtube_asr family)
// ---------------------------------------------------------------------------
function err(code, status, message) {
  return new Response(
    JSON.stringify({ error: { code, message } }),
    { status, headers: { "Content-Type": "application/json; charset=utf-8", ...CORS } }
  );
}
function ok(obj) {
  return new Response(JSON.stringify(obj), {
    status: 200,
    headers: { "Content-Type": "application/json; charset=utf-8", ...CORS },
  });
}

// ---------------------------------------------------------------------------
// YouTube: player response via InnerTube (multi-client), watch-page fallback
// ---------------------------------------------------------------------------
// NOTE (2026-09): YouTube now hard-rejects older client versions with HTTP 400
// ("ANDROID 19.x" / "IOS 19.x" are dead). Versions below are verified live.
// IOS first — its caption baseUrls still honor fmt=json3; Android clients
// return srv3 XML, which we also parse (see parseSrv3).
const CLIENTS = [
  {
    name: "IOS",
    url: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
    headers: {
      "Content-Type": "application/json",
      "User-Agent": "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)",
      "X-YouTube-Client-Name": "5",
      "X-YouTube-Client-Version": "20.10.4",
    },
    context: {
      client: {
        clientName: "IOS",
        clientVersion: "20.10.4",
        deviceMake: "Apple",
        deviceModel: "iPhone16,2",
        osName: "iPhone",
        osVersion: "18.1.0.22B83",
        hl: "en",
        gl: "US",
      },
    },
  },
  {
    name: "ANDROID",
    url: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
    headers: {
      "Content-Type": "application/json",
      "User-Agent": "com.google.android.youtube/20.10.38 (Linux; U; Android 14) gzip",
      "X-YouTube-Client-Name": "3",
      "X-YouTube-Client-Version": "20.10.38",
    },
    context: {
      client: {
        clientName: "ANDROID",
        clientVersion: "20.10.38",
        androidSdkVersion: 34,
        hl: "en",
        gl: "US",
      },
    },
  },
  {
    name: "ANDROID_VR",
    url: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
    headers: {
      "Content-Type": "application/json",
      "User-Agent": "com.google.android.apps.youtube.vr.oculus/1.60.19 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
      "X-YouTube-Client-Name": "28",
      "X-YouTube-Client-Version": "1.60.19",
    },
    context: {
      client: {
        clientName: "ANDROID_VR",
        clientVersion: "1.60.19",
        deviceMake: "Oculus",
        deviceModel: "Quest 3",
        osName: "Android",
        osVersion: "12L",
        androidSdkVersion: "32",
        hl: "en",
        gl: "US",
      },
    },
  },
  {
    name: "WEB",
    url: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
    headers: {
      "Content-Type": "application/json",
      "User-Agent": UA_DESKTOP,
      "X-YouTube-Client-Name": "1",
      "X-YouTube-Client-Version": "2.20240401.00.00",
      "X-Goog-Api-Format-Version": "2",
    },
    context: {
      client: {
        clientName: "WEB",
        clientVersion: "2.20240401.00.00",
        hl: "en",
        gl: "US",
      },
    },
  },
  {
    name: "MWEB",
    url: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
    headers: {
      "Content-Type": "application/json",
      "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
      "X-YouTube-Client-Name": "2",
      "X-YouTube-Client-Version": "2.20240726.01.00",
    },
    context: {
      client: {
        clientName: "MWEB",
        clientVersion: "2.20240726.01.00",
        hl: "en",
        gl: "US",
      },
    },
  },
  {
    name: "TV_EMBEDDED",
    url: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
    headers: {
      "Content-Type": "application/json",
      "User-Agent": UA_DESKTOP,
      "X-YouTube-Client-Name": "85",
      "X-YouTube-Client-Version": "7.20250122.15.00",
    },
    context: {
      client: {
        clientName: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
        clientVersion: "7.20250122.15.00",
        hl: "en",
        gl: "US",
      },
      thirdParty: { embedUrl: "https://www.youtube.com/" },
    },
  },
];

async function tryClient(c, videoId) {
  try {
    const res = await fetch(c.url, {
      method: "POST",
      headers: c.headers,
      body: JSON.stringify({
        context: c.context,
        videoId,
        contentCheckOk: true,
        racyCheckOk: true,
      }),
    });
    if (!res.ok) return { client: c.name, status: "http_" + res.status, j: null };
    const j = await res.json();
    const hasCaptions = !!j?.captions?.playerCaptionsTracklistRenderer?.captionTracks?.length;
    return {
      client: c.name,
      status: j?.playabilityStatus?.status || "unknown",
      reason: j?.playabilityStatus?.reason || "",
      hasCaptions,
      hasDetails: !!j?.videoDetails,
      j,
    };
  } catch (e) {
    return { client: c.name, status: "fetch_error:" + (e && e.message), j: null };
  }
}

// Returns { j, client } — client is kept so the caption download can reuse
// the SAME User-Agent that minted the baseUrl (timedtext is UA-sensitive).
// YouTube bot-gates datacenter IPs PROBABILISTICALLY (same video often
// succeeds on retry), so we run parallel fan-out passes over all clients —
// parallel keeps the wall-clock low while preserving the retry effect.
const ROUNDS = 2;

function shuffled(arr) {
  const a = [...arr];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function getPlayerResponse(videoId) {
  let watchFallback = null;
  let watchClient = null;

  for (let round = 0; round < ROUNDS; round++) {
    const results = await Promise.all(shuffled(CLIENTS).map((c) => tryClient(c, videoId)));
    for (const r of results) {
      if (r.j && r.hasCaptions) {
        const c = CLIENTS.find((x) => x.name === r.client);
        return { j: r.j, client: c };
      }
      if (r.j && r.hasDetails && !watchFallback) {
        watchFallback = r.j;
        watchClient = CLIENTS.find((x) => x.name === r.client);
      }
    }
    if (round < ROUNDS - 1) await sleep(250 + Math.floor(Math.random() * 250));
  }

  // Watch page fallback
  const page = await fetch(`https://www.youtube.com/watch?v=${videoId}&hl=en`, {
    headers: {
      "User-Agent": UA_DESKTOP,
      "Accept-Language": "en-US,en;q=0.9",
      Cookie: "CONSENT=YES+cb; SOCS=CAI",
    },
  }).catch(() => null);
  if (page && page.ok) {
    const html = await page.text();
    const m = html.match(/ytInitialPlayerResponse\s*=\s*(\{.+?\})\s*;\s*(?:var|const|<\/script>)/s);
    if (m) {
      try {
        const j = JSON.parse(m[1]);
        if (j && (j.videoDetails || j.captions))
          return { j, client: { name: "WATCH_PAGE", headers: { "User-Agent": UA_DESKTOP } } };
      } catch {}
    }
  }
  return watchFallback ? { j: watchFallback, client: watchClient } : null;
}

function playabilityError(pr) {
  const ps = pr && pr.playabilityStatus;
  if (!ps) return "transcript_fetch_failed";
  const reason = (ps.reason || "").toLowerCase();
  switch (ps.status) {
    case "LIVE_STREAM_OFFLINE":
    case "UNPLAYABLE":
      if (reason.includes("live")) return "video_is_live";
      return "video_unavailable";
    case "LOGIN_REQUIRED":
      if (reason.includes("age") || reason.includes("sign in to confirm")) {
        if (reason.includes("bot") || reason.includes("confirm")) return "transcript_fetch_failed";
        return "age_restricted";
      }
      return "age_restricted";
    case "ERROR":
      if (reason.includes("copyright")) return "copyright_blocked";
      if (reason.includes("unavailable") || reason.includes("not found") || reason.includes("removed")) return "video_not_found";
      return "video_unavailable";
    default:
      return ps.status === "OK" ? null : "transcript_fetch_failed";
  }
}

// ---------------------------------------------------------------------------
// Caption tracks: prefer manual track of requested lang, else first manual,
// else auto-generated (ASR) — exactly the original's captions-first logic.
// ---------------------------------------------------------------------------
function pickTrack(pr, lang) {
  const tracks =
    pr?.captions?.playerCaptionsTracklistRenderer?.captionTracks || [];
  if (!tracks.length) return { track: null, hasAny: false };
  const manual = tracks.filter((t) => t.kind !== "asr");
  const asr = tracks.filter((t) => t.kind === "asr");
  if (lang) {
    const exact = tracks.find((t) => t.languageCode === lang);
    if (exact) return { track: exact, hasAny: true };
  }
  if (manual.length) return { track: manual[0], hasAny: true };
  return { track: asr[0] || null, hasAny: true };
}

function decodeEntities(s) {
  return s
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(parseInt(n, 10)));
}

// srv3 XML (innertube mobile clients): <p t="1200" d="3400"><s>word</s>…</p>
function parseSrv3(body) {
  const segs = [];
  const re = /<p t="(\d+)"(?: d="(\d+)")?[^>]*>([\s\S]*?)<\/p>/g;
  let m;
  while ((m = re.exec(body))) {
    const text = decodeEntities(m[3].replace(/<[^>]+>/g, "")).replace(/\s+/g, " ").trim();
    if (!text) continue;
    segs.push({ start: parseInt(m[1], 10) || 0, dur: parseInt(m[2] || "3000", 10) || 3000, text });
  }
  return segs;
}

// legacy XML (watch page / timedtext classic): <text start="1.2" dur="3.4">…</text>
function parseLegacyXml(body) {
  const segs = [];
  const re = /<text start="([\d.]+)"(?: dur="([\d.]+)")?[^>]*>([\s\S]*?)<\/text>/g;
  let m;
  while ((m = re.exec(body))) {
    const text = decodeEntities(m[3].replace(/<[^>]+>/g, "")).replace(/\s+/g, " ").trim();
    if (!text) continue;
    segs.push({
      start: Math.round(parseFloat(m[1]) * 1000),
      dur: Math.round(parseFloat(m[2] || "3") * 1000),
      text,
    });
  }
  return segs;
}

function parseJson3(body) {
  const j = JSON.parse(body);
  const segs = [];
  for (const e of j.events || []) {
    if (!e.segs) continue;
    const text = e.segs
      .map((s) => s.utf8 || "")
      .join("")
      .replace(/\s+/g, " ")
      .trim();
    if (!text) continue;
    segs.push({ start: e.tStartMs || 0, dur: e.dDurationMs || 0, text });
  }
  return segs;
}

// Timedtext download — MUST try the UA of the client that minted the baseUrl
// first (timedtext is UA/IP-session sensitive), across all three wire formats.
async function fetchSegments(track, ua) {
  const agents = [
    ua,
    "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)",
    UA_DESKTOP,
  ].filter(Boolean);
  const seenUa = new Set();
  let lastErr = null;
  for (const agent of agents) {
    if (seenUa.has(agent)) continue;
    seenUa.add(agent);
    const base = track.baseUrl;
    const urls = [
      base + (base.includes("?") ? "&" : "?") + "fmt=json3",
      base,
      base + (base.includes("?") ? "&" : "?") + "fmt=srv3",
    ];
    for (const u of urls) {
      try {
        const res = await fetch(u, {
          headers: { "User-Agent": agent, Referer: "https://www.youtube.com/" },
        });
        if (!res.ok) {
          lastErr = new Error("caption_http_" + res.status);
          continue;
        }
        const body = await res.text();
        let segs = [];
        const trimmed = body.trim();
        if (trimmed.startsWith("{")) segs = parseJson3(trimmed);
        else if (trimmed.startsWith("<")) {
          segs = parseSrv3(trimmed);
          if (!segs.length) segs = parseLegacyXml(trimmed);
        }
        if (segs.length) return mergeSegments(segs);
        lastErr = new Error("caption_empty");
      } catch (e) {
        lastErr = e;
      }
    }
  }
  throw lastErr || new Error("caption_failed");
}

function mergeSegments(segs) {
  const merged = [];
  let buf = null;
  for (const s of segs) {
    if (buf && s.start - buf.start < 4200 && buf.text.length < 90) {
      buf.text += " " + s.text;
      buf.dur = s.start + s.dur - buf.start;
    } else {
      if (buf) merged.push(buf);
      buf = { ...s };
    }
  }
  if (buf) merged.push(buf);
  return merged.slice(0, MAX_SEGMENTS);
}

// ---------------------------------------------------------------------------
// get_transcript InnerTube endpoint — bypasses timedtext PO-token wall
// (same trick YouTube's own "Show transcript" panel uses)
// ---------------------------------------------------------------------------
function pbEncode(obj) {
  // obj: {fieldNum: stringValue | number | nestedObj}
  const parts = [];
  for (const key of Object.keys(obj).map(Number).sort((a, b) => a - b)) {
    const val = obj[key];
    const tag = key << 3;
    if (typeof val === "object" && val !== null) {
      const nested = pbEncode(val);
      parts.push(Uint8Array.of(tag | 2, nested.length), nested);
    } else if (typeof val === "string") {
      const bytes = new TextEncoder().encode(val);
      parts.push(Uint8Array.of(tag | 2, bytes.length), bytes);
    } else if (typeof val === "number") {
      // varint
      const out = [];
      let n = val;
      do {
        let b = n & 0x7f;
        n = Math.floor(n / 128);
        if (n > 0) b |= 0x80;
        out.push(b);
      } while (n > 0);
      parts.push(Uint8Array.of(tag | 0, ...out));
    }
  }
  const total = parts.reduce((a, p) => a + p.length, 0);
  const buf = new Uint8Array(total);
  let off = 0;
  for (const p of parts) {
    buf.set(p, off);
    off += p.length;
  }
  return buf;
}

function transcriptParams(videoId, lang, kind, vssId) {
  const msg = {
    1: videoId,
    3: 1,
    5: "engagement-panel-searchable-transcript-search-panel",
    6: 1,
    7: 1,
    8: 1,
  };
  if (lang) {
    const inner = { 1: lang };
    if (kind === "asr") inner[2] = "asr";
    if (vssId) inner[3] = vssId;
    msg[2] = inner;
  }
  let bin = "";
  pbEncode(msg).forEach((b) => (bin += String.fromCharCode(b)));
  return btoa(bin);
}

function collectSegmentRenderers(node, out) {
  if (!node || typeof node !== "object") return;
  if (Array.isArray(node)) {
    for (const n of node) collectSegmentRenderers(n, out);
    return;
  }
  const t = node.transcriptSegmentRenderer;
  if (t) {
    const text = (t.snippet?.runs || []).map((r) => r.text || "").join("").replace(/\s+/g, " ").trim();
    if (text) {
      out.push({
        start: parseInt(t.startMs || "0", 10),
        dur: Math.max(1, parseInt(t.endMs || "0", 10) - parseInt(t.startMs || "0", 10)),
        text,
      });
    }
  }
  for (const k of Object.keys(node)) collectSegmentRenderers(node[k], out);
}

async function getTranscript(videoId, lang, kind, vssId, visitorData) {
  // two known param shapes: minimal + full engagement-panel
  const shapes = [];
  if (lang) {
    const inner = { 1: lang };
    if (kind === "asr") inner[2] = "asr";
    if (vssId) inner[3] = vssId;
    shapes.push({ 1: videoId, 2: inner });
    shapes.push({ 1: videoId, 2: inner, 3: 1, 5: "engagement-panel-searchable-transcript-search-panel", 6: 1, 7: 1, 8: 1 });
  } else {
    shapes.push({ 1: videoId });
    shapes.push({ 1: videoId, 3: 1, 5: "engagement-panel-searchable-transcript-search-panel", 6: 1, 7: 1, 8: 1 });
  }
  const client = { clientName: "WEB", clientVersion: "2.20240401.00.00", hl: "en", gl: "US" };
  if (visitorData) client.visitorData = visitorData;
  let lastErr = null;
  for (const shape of shapes) {
    let bin = "";
    pbEncode(shape).forEach((b) => (bin += String.fromCharCode(b)));
    try {
      const res = await fetch("https://www.youtube.com/youtubei/v1/get_transcript?prettyPrint=false", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "User-Agent": UA_DESKTOP,
          "X-YouTube-Client-Name": "1",
          "X-YouTube-Client-Version": "2.20240401.00.00",
          "X-Goog-Api-Format-Version": "2",
        },
        body: JSON.stringify({ context: { client }, params: btoa(bin) }),
      });
      if (!res.ok) {
        lastErr = new Error("get_transcript_http_" + res.status);
        continue;
      }
      const j = await res.json();
      const raw = [];
      collectSegmentRenderers(j, raw);
      if (raw.length) return raw;
      lastErr = new Error("get_transcript_empty");
    } catch (e) {
      lastErr = e;
    }
  }
  throw lastErr || new Error("get_transcript_failed");
}

// minted transcript params from /next (exactly what YouTube's own frontend uses)
async function getTranscriptEndpointParams(videoId) {
  const res = await fetch("https://www.youtube.com/youtubei/v1/next?prettyPrint=false", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "User-Agent": UA_DESKTOP,
      "X-Goog-Api-Format-Version": "2",
    },
    body: JSON.stringify({
      context: { client: { clientName: "WEB", clientVersion: "2.20240401.00.00", hl: "en", gl: "US" } },
      videoId,
    }),
  });
  if (!res.ok) return { status: "http_" + res.status };
  const j = await res.json();
  let params = null;
  (function walk(n) {
    if (!n || typeof n !== "object" || params) return;
    if (Array.isArray(n)) return n.forEach(walk);
    const ep = n.getTranscriptEndpoint;
    if (ep && ep.params) {
      params = ep.params;
      return;
    }
    for (const k of Object.keys(n)) walk(n[k]);
  })(j);
  return { status: "ok", params, visitorData: j?.responseContext?.visitorData || "" };
}

async function getTranscriptWithParams(params, visitorData) {
  const client = { clientName: "WEB", clientVersion: "2.20240401.00.00", hl: "en", gl: "US" };
  if (visitorData) client.visitorData = visitorData;
  const res = await fetch("https://www.youtube.com/youtubei/v1/get_transcript?prettyPrint=false", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "User-Agent": UA_DESKTOP,
      "X-Goog-Api-Format-Version": "2",
    },
    body: JSON.stringify({ context: { client }, params }),
  });
  if (!res.ok) throw new Error("get_transcript_http_" + res.status);
  const j = await res.json();
  const raw = [];
  collectSegmentRenderers(j, raw);
  if (!raw.length) throw new Error("get_transcript_empty");
  return raw;
}

// fetch transcript: timedtext with the winning client's UA first (verified
// working when client versions are current), then fresh player responses
// from the remaining clients (each UA-bound), then get_transcript last.
async function fetchTranscriptSegments(win, videoId, wantLang) {
  const pr = win.j;
  const triedClients = new Set([win.client?.name].filter(Boolean));

  const attemptTracks = async (prObj, ua) => {
    const tracks = prObj?.captions?.playerCaptionsTracklistRenderer?.captionTracks || [];
    const manual = tracks.filter((t) => t.kind !== "asr");
    const asrTracks = tracks.filter((t) => t.kind === "asr");
    const wanted = wantLang ? tracks.filter((t) => t.languageCode === wantLang) : [];
    const ordered = [...wanted, ...manual.filter((t) => !wanted.includes(t)), ...asrTracks];
    for (const t of ordered) {
      try {
        return await fetchSegments(t, ua);
      } catch (e) {
        // try next track
      }
    }
    return null;
  };

  // 1) timedtext straight from the winning player response
  const first = await attemptTracks(pr, win.client?.headers?.["User-Agent"]);
  if (first) return first;

  // 2) fresh player responses from the remaining clients (each UA-bound)
  const rest = CLIENTS.filter((c) => !triedClients.has(c.name));
  const fanout = await Promise.all(
    rest.map(async (c) => ({ c, r: await tryClient(c, videoId) }))
  );
  for (const { c, r } of fanout) {
    triedClients.add(c.name);
    if (!r.j || !r.hasCaptions) continue;
    const segs = await attemptTracks(r.j, c.headers["User-Agent"]);
    if (segs) return segs;
  }

  // 3) get_transcript (minted via /next, then manual params) — last resort
  try {
    const ep = await getTranscriptEndpointParams(videoId);
    if (ep.params) {
      const segs = await getTranscriptWithParams(ep.params, ep.visitorData || pr?.responseContext?.visitorData);
      if (segs.length) return mergeSegments(segs);
    }
  } catch (e) {
    // fall through
  }
  for (const t of pr?.captions?.playerCaptionsTracklistRenderer?.captionTracks || []) {
    try {
      const segs = await getTranscript(videoId, t.languageCode, t.kind === "asr" ? "asr" : "", t.vssId, pr?.responseContext?.visitorData);
      if (segs.length) return mergeSegments(segs);
    } catch (e) {
      // try next
    }
  }
  throw new Error("all_caption_sources_failed");
}

// ---------------------------------------------------------------------------
// Translation: Gemini primary (server key) → Google gtx fallback (keyless)
// Same "gemini (primary)" pattern as the original backend.
// ---------------------------------------------------------------------------
function normalizeLang(code) {
  const map = { "zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "pt-BR": "pt", "pt-PT": "pt" };
  return map[code] || code;
}

async function translateGemini(texts, target, source, apiKey) {
  const model = "gemini-2.0-flash";
  const sys =
    `Translate each item of the JSON array ${source && source !== "auto" ? `from ${source} ` : ""}to ${target}. ` +
    `Return ONLY a JSON array of translated strings, same length and order. ` +
    `Keep names/numbers. Do not add notes.`;
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        systemInstruction: { parts: [{ text: sys }] },
        contents: [{ role: "user", parts: [{ text: JSON.stringify(texts) }] }],
        generationConfig: { temperature: 0.1, maxOutputTokens: 8192 },
      }),
    }
  );
  if (!res.ok) throw new Error("gemini_http_" + res.status);
  const j = await res.json();
  const txt =
    j.candidates?.[0]?.content?.parts?.map((p) => p.text || "").join("") || "";
  const clean = txt.replace(/^```(?:json)?/m, "").replace(/```\s*$/m, "").trim();
  const arr = JSON.parse(clean);
  if (!Array.isArray(arr) || arr.length !== texts.length) throw new Error("gemini_shape");
  return arr;
}

async function translateGtx(texts, target, source) {
  const out = [];
  const CHUNK = 40;
  for (let i = 0; i < texts.length; i += CHUNK) {
    const chunk = texts.slice(i, i + CHUNK);
    const body = new URLSearchParams();
    for (const t of chunk) body.append("q", t);
    const url =
      `https://translate.googleapis.com/translate_a/t?client=gtx&dt=t` +
      `&sl=${encodeURIComponent(source || "auto")}&tl=${encodeURIComponent(target)}`;
    const res = await fetch(url, {
      method: "POST",
      headers: {
        "User-Agent": UA_DESKTOP,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: body.toString(),
    });
    if (!res.ok) throw new Error("gtx_http_" + res.status);
    const j = await res.json();
    // translate_a/t returns array of strings (or nested arrays)
    for (const item of j) {
      if (typeof item === "string") out.push(item);
      else if (Array.isArray(item) && typeof item[0] === "string") out.push(item[0]);
      else out.push("");
    }
  }
  if (out.length < texts.length) out.push(...Array(texts.length - out.length).fill(""));
  return out.slice(0, texts.length);
}

async function translateTexts(texts, target, source, env) {
  const t = normalizeLang(target);
  if (env.GEMINI_API_KEY && texts.length <= 800) {
    try {
      return {
        segments: await translateGemini(texts, t, source, env.GEMINI_API_KEY),
        engine: "gemini",
      };
    } catch (e) {
      // fall through to gtx — same fallback philosophy as the original
    }
  }
  return { segments: await translateGtx(texts, t, source), engine: "gtx" };
}

// ---------------------------------------------------------------------------
// Router
// ---------------------------------------------------------------------------
export default {
  async fetch(request, env, ctx) {
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    const url = new URL(request.url);
    const action = url.searchParams.get("action") || "";
    const v = (url.searchParams.get("v") || url.searchParams.get("video_id") || "").trim();

    if (action === "ping") return ok({ ok: true, service: "subtrans-api", ts: Date.now() });

    
    
    
    
    if (!["youtube_asr", "youtube_asr_languages", "translate", "summarize", "stream"].includes(action)) {
      return err("missing_or_invalid_action", 400, 'Unknown "action" parameter');
    }
    const videoId =
      action === "translate" || action === "summarize"
        ? ""
        : parseVideoId(v || url.searchParams.get("url") || "");
    if (action !== "translate" && action !== "summarize" && !videoId)
      return err("invalid_video_url", 400, "Could not parse a YouTube video id");

    // --- youtube_asr_languages: list available caption languages
    if (action === "youtube_asr_languages") {
      const win = await getPlayerResponse(videoId);
      const pr = win?.j;
      if (!pr) return err("transcript_fetch_failed", 502, "Could not fetch player response");
      const pe = playabilityError(pr);
      if (pe) return err(pe, 422, "Video cannot be transcribed");
      const tracks = pr?.captions?.playerCaptionsTracklistRenderer?.captionTracks || [];
      return ok({
        video_id: videoId,
        title: pr.videoDetails?.title || "",
        author: pr.videoDetails?.author || "",
        length_seconds: parseInt(pr.videoDetails?.lengthSeconds || "0", 10),
        source_lang: pickTrack(pr, null).track?.languageCode || null,
        languages: tracks.map((t) => ({
          code: t.languageCode,
          name: t.name?.simpleText || t.name?.runs?.[0]?.text || t.languageCode,
          kind: t.kind === "asr" ? "asr" : "manual",
        })),
      });
    }

    // --- youtube_asr: fetch transcript (optionally translate to ?target=)
    if (action === "youtube_asr") {
      const cache = caches.default;
      const target = url.searchParams.get("target") || "";
      const wantLang = url.searchParams.get("lang") || "";
      const cacheKey = new Request(
        `${url.origin}/__cache/${videoId}:${wantLang}:${target}`,
        request
      );
      const hit = await cache.match(cacheKey);
      if (hit) return hit;

      const sleep2 = (ms) => new Promise((r) => setTimeout(r, ms));
      // Definitive video errors fail fast; YouTube bot-gating is retried.
      const DEFINITIVE = new Set([
        "video_not_found", "video_is_live", "age_restricted",
        "copyright_blocked", "video_unavailable", "no_speech",
      ]);

      let win = null, pr = null, pe = null, track = null, hasAny = false;
      let segments = null, hardErr = null;
      for (let attempt = 0; attempt < 2 && !segments; attempt++) {
        if (attempt > 0) await sleep2(500 + Math.floor(Math.random() * 400));
        win = await getPlayerResponse(videoId);
        pr = win?.j;
        if (!pr) { hardErr = "player"; continue; }
        pe = playabilityError(pr);
        if (pe && DEFINITIVE.has(pe)) break; // fail fast, no retry
        if (pe) { hardErr = "playability"; continue; }
        const pick = pickTrack(pr, wantLang);
        track = pick.track; hasAny = pick.hasAny;
        if (!track || !hasAny) {
          // only a genuinely-OK response with zero tracks means "no captions";
          // gated/blocked responses must keep retrying instead
          if (!pe) { hardErr = "no_speech"; break; }
          hardErr = "playability";
          continue;
        }
        try {
          segments = await fetchTranscriptSegments(win, videoId, wantLang);
        } catch (e) {
          hardErr = "captions"; // retry once
        }
      }

      if (!segments) {
        if (pe && DEFINITIVE.has(pe))
          return err(pe, 422, "Video cannot be transcribed");
        if (hardErr === "no_speech" && pe === null)
          return err("no_speech", 422, "No captions/transcript available for this video");
        return err("transcript_fetch_failed", 502, "Caption download failed");
      }
      if (!segments.length) return err("no_speech", 422, "Empty transcript");

      const base = {
        video_id: videoId,
        title: pr.videoDetails?.title || "",
        author: pr.videoDetails?.author || "",
        length_seconds: parseInt(pr.videoDetails?.lengthSeconds || "0", 10),
        source_lang: track.languageCode,
        is_asr: track.kind === "asr",
        count: segments.length,
        segments,
      };

      if (!target) {
        const res = ok(base);
        ctx.waitUntil(cache.put(cacheKey, res.clone()));
        return res;
      }

      let tr, engine;
      try {
        ({ segments: tr, engine } = await translateTexts(
          segments.map((s) => s.text),
          target,
          track.languageCode,
          env
        ));
      } catch (e) {
        return err("translation_failed", 502, "Translation engine failed");
      }
      const out = {
        ...base,
        target_lang: target,
        engine,
        segments: segments.map((s, i) => ({ ...s, tr: tr[i] || "" })),
      };
      const res = ok(out);
      ctx.waitUntil(cache.put(cacheKey, res.clone()));
      return res;
    }

    // --- translate: standalone translation of raw text
    if (action === "translate") {
      if (request.method !== "POST")
        return err("method_not_allowed", 405, "Use POST with JSON body");
      let body;
      try {
        body = await request.json();
      } catch {
        return err("invalid_body", 400, "Body must be JSON");
      }
      const texts = Array.isArray(body.texts) ? body.texts.map(String).slice(0, MAX_SEGMENTS) : null;
      const target = body.target || "";
      if (!texts || !target) return err("invalid_body", 400, 'Required: texts[], target');
      try {
        const { segments, engine } = await translateTexts(texts, target, body.source || "", env);
        return ok({ engine, target, segments });
      } catch (e) {
        return err("translation_failed", 502, "Translation engine failed");
      }
    }

    // --- stream: server-side playback fallback (some videos pass from
    // Cloudflare IPs when they are gated elsewhere) — HLS / muxed URLs
    if (action === "stream") {
      const win = await getPlayerResponse(videoId);
      const pr = win?.j;
      if (!pr) return err("playback_failed", 502, "No player response");
      const ps = pr.playabilityStatus || {};
      if (ps.status && ps.status !== "OK") {
        const pe = playabilityError(pr);
        return err(pe || "playback_failed", pe ? 422 : 502, ps.reason || "Not playable");
      }
      const sd = pr.streamingData || {};
      let muxed = "", muxedItag = 0;
      for (const f of sd.formats || []) {
        if (!f.url) continue;
        if (f.itag === 22 || f.itag === 18) {
          if (f.itag > muxedItag) { muxed = f.url; muxedItag = f.itag; }
        }
      }
      const hls = (sd.hlsManifestUrl || "").toString();
      if (!hls && !muxed) return err("playback_failed", 502, "No playable stream in response");
      return ok({
        video_id: videoId,
        hls,
        muxed,
        muxed_itag: muxedItag,
        client: win?.client || "",
      });
    }

    // --- summarize: AI summary of a transcript (Gemini)
    if (action === "summarize") {
      if (request.method !== "POST")
        return err("method_not_allowed", 405, "Use POST with JSON body");
      let body;
      try {
        body = await request.json();
      } catch {
        return err("invalid_body", 400, "Body must be JSON");
      }
      const text = (body.text || "").toString();
      const title = (body.title || "").toString();
      const target = normalizeLang(body.target || "en");
      if (text.trim().length < 40)
        return err("invalid_body", 400, "Text too short to summarize");
      if (!env.GEMINI_API_KEY)
        return err("summarize_failed", 502, "Summarizer unavailable");
      const clipped = text.length > 14000 ? text.slice(0, 14000) : text;
      const sys =
        `You summarize YouTube video transcripts. Write a clear, well-structured summary IN ${target}. ` +
        `Format: a 2-4 sentence overview paragraph, then a short "نکات کلیدی:" (key points) list with 3-6 bullets. ` +
        `Keep it under 220 words total. No preamble, no explanations about yourself.`;
      try {
        const res = await fetch(
          `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${env.GEMINI_API_KEY}`,
          {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              systemInstruction: { parts: [{ text: sys }] },
              contents: [
                { role: "user", parts: [{ text: (title ? `Title: ${title}\n\n` : "") + clipped }] },
              ],
              generationConfig: { temperature: 0.4, maxOutputTokens: 1024 },
            }),
          }
        );
        if (!res.ok) throw new Error("gemini_http_" + res.status);
        const j = await res.json();
        const sum =
          j.candidates?.[0]?.content?.parts?.map((p) => p.text || "").join("").trim() || "";
        if (!sum) throw new Error("empty");
        return ok({ summary: sum });
      } catch (e) {
        return err("summarize_failed", 502, "Summarizer failed");
      }
    }

    return err("missing_or_invalid_action", 400, "Unknown action");
  },
};

function parseVideoId(input) {
  if (!input) return null;
  const s = input.trim();
  if (/^[\w-]{11}$/.test(s)) return s;
  const patterns = [
    /(?:youtube\.com\/watch\?[^#]*?v=)([\w-]{11})/,
    /(?:youtu\.be\/)([\w-]{11})/,
    /(?:youtube\.com\/shorts\/)([\w-]{11})/,
    /(?:youtube\.com\/embed\/)([\w-]{11})/,
    /(?:youtube\.com\/live\/)([\w-]{11})/,
  ];
  for (const p of patterns) {
    const m = s.match(p);
    if (m) return m[1];
  }
  return null;
}
