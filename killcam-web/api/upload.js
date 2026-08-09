import { put } from '@vercel/blob';

// Metadata rides the filename so listing needs no sidecar reads:
//   clips/{epochMs}-{rand4}__{matchId}__{killer}__{victim}.mp4
// Fields are sanitized to [A-Za-z0-9-] so "__" can never be ambiguous.
const clean = (s) => String(s ?? '').replace(/[^A-Za-z0-9-]/g, '').slice(0, 24);

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  if (req.headers['x-upload-key'] !== process.env.KILLCAM_UPLOAD_KEY) {
    return res.status(401).json({ error: 'bad key' });
  }

  const { killer, victim, match, ts } = req.query;
  if (!killer || !victim || !match) {
    return res.status(400).json({ error: 'missing killer/victim/match' });
  }
  if (!req.body?.length) return res.status(400).json({ error: 'empty body' });

  const stamp = /^\d{13}$/.test(ts ?? '') ? ts : String(Date.now());
  const rand = Math.random().toString(36).slice(2, 6);
  const pathname = `clips/${stamp}-${rand}__${clean(match)}__${clean(killer)}__${clean(victim)}.mp4`;

  // Self-generated unique suffix; the SDK's addRandomSuffix would append into
  // the victim field and corrupt filename parsing.
  const blob = await put(pathname, req.body, {
    access: 'public',
    contentType: 'video/mp4',
    addRandomSuffix: false,
  });
  res.status(200).json({ ok: true, url: blob.url, pathname });
}
