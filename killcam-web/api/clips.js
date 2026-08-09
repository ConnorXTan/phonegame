import { list } from '@vercel/blob';

export default async function handler(req, res) {
  const device = String(req.query.device ?? '').replace(/[^A-Za-z0-9-_]/g, '');
  const limit = Math.min(parseInt(req.query.limit) || 100, 500);
  const [clipList, socialList] = await Promise.all([
    list({ prefix: 'clips/', limit: 1000 }),
    list({ prefix: 'social/', limit: 1000 }),
  ]);

  const likeCounts = {};
  const saveCounts = {};
  const myLikes = new Set();
  const mySaves = new Set();
  for (const b of socialList.blobs) {
    const parts = b.pathname.split('/');   // social/<kind>/<clipKey>/<deviceId>
    if (parts.length !== 4) continue;
    const [, kind, key, dev] = parts;
    if (kind === 'likes') {
      likeCounts[key] = (likeCounts[key] || 0) + 1;
      if (device && dev === device) myLikes.add(key);
    } else if (kind === 'saves') {
      saveCounts[key] = (saveCounts[key] || 0) + 1;
      if (device && dev === device) mySaves.add(key);
    }
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
        liked: myLikes.has(key),
        saved: mySaves.has(key),
      };
    })
    .filter(Boolean)
    .sort((a, b) => b.timestamp - a.timestamp)
    .slice(0, limit);

  // Per-device liked/saved flags make this response personal — never let the
  // CDN serve one device's flags to another.
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json({ clips });
}
