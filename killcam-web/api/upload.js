import { db, publicURL, BUCKET } from '../lib/supabase-store.js';

// The filename convention survives from the Blob days so objects stay
// self-describing, but the row in `clips` is the source of truth:
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
  const filename = `${stamp}-${rand}__${clean(match)}__${clean(killer)}__${clean(victim)}.mp4`;
  const path = `clips/${filename}`;

  const supa = db();
  // Clips are immutable (unique filenames), so let the CDN keep them for a
  // year — default no-cache would re-hit origin per view and burn egress.
  const up = await supa.storage.from(BUCKET).upload(path, req.body, {
    contentType: 'video/mp4',
    cacheControl: '31536000',
  });
  if (up.error) throw new Error(`storage upload: ${up.error.message}`);

  const ins = await supa.from('clips').insert({
    key: filename,
    killer: clean(killer),
    victim: clean(victim),
    match_id: clean(match),
    ts: Number(stamp),
    size: req.body.length,
  });
  if (ins.error) {
    // No row means the gallery would never list it — don't strand the object.
    await supa.storage.from(BUCKET).remove([path]);
    throw new Error(`clip insert: ${ins.error.message}`);
  }
  res.status(200).json({ ok: true, url: publicURL(path), pathname: path });
}
