import { list } from '@vercel/blob';

export default async function handler(req, res) {
  const limit = Math.min(parseInt(req.query.limit) || 100, 500);
  const { blobs } = await list({ prefix: 'clips/', limit: 1000 });
  const clips = blobs
    .map((b) => {
      const parts = b.pathname.slice('clips/'.length).replace(/\.mp4$/, '').split('__');
      if (parts.length !== 4) return null;
      const [tsRand, matchId, killer, victim] = parts;
      return {
        url: b.url,
        killer,
        victim,
        matchId,
        timestamp: parseInt(tsRand, 10),
        size: b.size,
      };
    })
    .filter(Boolean)
    .sort((a, b) => b.timestamp - a.timestamp)
    .slice(0, limit);
  res.setHeader('Cache-Control', 'public, s-maxage=5, stale-while-revalidate=30');
  res.status(200).json({ clips });
}
