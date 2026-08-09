import { configured, db, publicURL } from '../lib/supabase-store.js';

// The response is the same for every viewer (per-device liked/saved flags live
// in the browser's localStorage), so the CDN absorbs the gallery's polling:
// at most ~2 database reads per 30 s globally, not per tab.
export default async function handler(req, res) {
  if (!configured()) {
    res.setHeader('Cache-Control', 'no-store');
    return res.status(200).json({ clips: [] });   // store not wired up yet
  }
  const limit = Math.min(parseInt(req.query.limit) || 100, 500);
  const supa = db();
  const [clipRows, likeRows] = await Promise.all([
    supa.from('clips').select('*').order('ts', { ascending: false }).limit(limit),
    supa.from('social_marks').select('clip_key').eq('kind', 'like'),
  ]);
  if (clipRows.error) throw new Error(`clips query: ${clipRows.error.message}`);
  if (likeRows.error) throw new Error(`likes query: ${likeRows.error.message}`);

  const likeCounts = {};
  for (const m of likeRows.data) likeCounts[m.clip_key] = (likeCounts[m.clip_key] || 0) + 1;

  const clips = clipRows.data.map((c) => ({
    url: publicURL(`clips/${c.key}`),
    key: c.key,
    killer: c.killer,
    victim: c.victim,
    matchId: c.match_id,
    timestamp: Number(c.ts),
    size: Number(c.size),
    likes: likeCounts[c.key] || 0,
  }));

  res.setHeader('Cache-Control', 'public, s-maxage=30, stale-while-revalidate=300');
  res.status(200).json({ clips });
}
