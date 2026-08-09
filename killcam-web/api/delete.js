import { del, list } from '@vercel/blob';

// Deletion rides the same trust boundary as publishing: only holders of the
// upload secret (the game master's app) can remove a clip. Also sweeps the
// clip's like/save markers so no social residue orphans.
const clean = (s) => String(s ?? '').replace(/[^A-Za-z0-9-_.]/g, '').slice(0, 96);

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  if (req.headers['x-upload-key'] !== process.env.KILLCAM_UPLOAD_KEY) {
    return res.status(401).json({ error: 'bad key' });
  }
  const key = clean(req.query.clip);
  if (!key) return res.status(400).json({ error: 'missing clip' });

  const targets = [`clips/${key}`];
  for (const kind of ['likes', 'saves']) {
    const { blobs } = await list({ prefix: `social/${kind}/${key}/`, limit: 1000 });
    targets.push(...blobs.map((b) => b.pathname));
  }
  try { await del(targets); } catch {}   // already-gone is fine: idempotent
  res.status(200).json({ ok: true, removed: targets.length });
}
