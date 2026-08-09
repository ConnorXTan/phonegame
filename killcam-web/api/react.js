import { put, del } from '@vercel/blob';

// One marker blob per (kind, clip, device): social/likes/<clipKey>/<deviceId>.
// Idempotent puts make a like per device structurally unrepeatable — liking
// twice overwrites the same marker. Marker content logs the device's
// user-agent and timestamp (the "who was here" ledger).
const clean = (s, extra = '') =>
  String(s ?? '').replace(new RegExp(`[^A-Za-z0-9-_${extra}]`, 'g'), '').slice(0, 96);

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  const device = clean(req.query.device);
  if (device.length < 8) return res.status(400).json({ error: 'missing device' });
  const stamp = JSON.stringify({
    ua: String(req.headers['user-agent'] ?? '').slice(0, 300),
    at: Date.now(),
  });
  const action = req.query.action;

  if (action === 'visit') {
    await put(`social/visits/${device}`, stamp, {
      access: 'public', contentType: 'application/json',
      addRandomSuffix: false, allowOverwrite: true,
    });
    return res.status(200).json({ ok: true });
  }

  const key = clean(req.query.clip, '.');
  if (!key) return res.status(400).json({ error: 'missing clip' });
  const kinds = { like: 'likes', unlike: 'likes', save: 'saves', unsave: 'saves' };
  const kind = kinds[action];
  if (!kind) return res.status(400).json({ error: 'bad action' });

  const pathname = `social/${kind}/${key}/${device}`;
  if (action === 'like' || action === 'save') {
    await put(pathname, stamp, {
      access: 'public', contentType: 'application/json',
      addRandomSuffix: false, allowOverwrite: true,
    });
  } else {
    try { await del(pathname); } catch {}
  }
  res.status(200).json({ ok: true });
}
