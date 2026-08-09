import { list } from '@vercel/blob';

// Blob list() calls are the metered "advanced operations", and this endpoint
// used to run two of them per request while every open tab polled with
// no-store — the whole event's quota went here. The response is now the same
// for every viewer (per-device liked/saved flags live in the browser's
// localStorage instead), so the CDN absorbs the polling: at most ~2 list
// calls per 30 s globally, not per tab.
export default async function handler(req, res) {
  const limit = Math.min(parseInt(req.query.limit) || 100, 500);
  const [clipList, socialList] = await Promise.all([
    list({ prefix: 'clips/', limit: 1000 }),
    list({ prefix: 'social/', limit: 1000 }),
  ]);

  const likeCounts = {};
  for (const b of socialList.blobs) {
    const parts = b.pathname.split('/');   // social/<kind>/<clipKey>/<deviceId>
    if (parts.length !== 4) continue;
    const [, kind, key] = parts;
    if (kind === 'likes') likeCounts[key] = (likeCounts[key] || 0) + 1;
  }

  const clips = clipList.blobs
    .map((b) => {
      const key = b.pathname.slice('clips/'.length);
      const parts = key.replace(/\.mp4$/, '').split('__');
      if (parts.length !== 4) return null;
      const [tsRand, matchId, killer, victim] = parts;
      return {
        url: b.url,
        key,
        killer,
        victim,
        matchId,
        timestamp: parseInt(tsRand, 10),
        size: b.size,
        likes: likeCounts[key] || 0,
      };
    })
    .filter(Boolean)
    .sort((a, b) => b.timestamp - a.timestamp)
    .slice(0, limit);

  res.setHeader('Cache-Control', 'public, s-maxage=30, stale-while-revalidate=300');
  res.status(200).json({ clips });
}
