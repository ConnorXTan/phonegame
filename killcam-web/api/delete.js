import { db, BUCKET } from '../lib/supabase-store.js';

// Deletion rides the same trust boundary as publishing: only holders of the
// upload secret (the game master's app) can remove a clip. The row delete
// cascades to like/save marks so no social residue orphans.
const clean = (s) => String(s ?? '').replace(/[^A-Za-z0-9-_.]/g, '').slice(0, 96);

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  if (req.headers['x-upload-key'] !== process.env.KILLCAM_UPLOAD_KEY) {
    return res.status(401).json({ error: 'bad key' });
  }
  const key = clean(req.query.clip);
  if (!key) return res.status(400).json({ error: 'missing clip' });

  const supa = db();
  const marks = await supa.from('social_marks')
    .select('*', { count: 'exact', head: true }).eq('clip_key', key);
  const del = await supa.from('clips').delete().eq('key', key).select();
  if (del.error) throw new Error(`clip delete: ${del.error.message}`);
  await supa.storage.from(BUCKET).remove([`clips/${key}`]);   // already-gone is fine

  res.status(200).json({ ok: true, removed: (del.data?.length ?? 0) + (marks.count ?? 0) });
}
