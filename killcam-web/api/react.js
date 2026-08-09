import { db } from '../lib/supabase-store.js';

// One row per (kind, clip, device): upserts make a like per device
// structurally unrepeatable — liking twice overwrites the same row. Rows log
// the device's user-agent and timestamp (the "who was here" ledger).
const clean = (s, extra = '') =>
  String(s ?? '').replace(new RegExp(`[^A-Za-z0-9-_${extra}]`, 'g'), '').slice(0, 96);

const FK_VIOLATION = '23503';   // clip vanished mid-action: fine, nothing to mark

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  const device = clean(req.query.device);
  if (device.length < 8) return res.status(400).json({ error: 'missing device' });
  const ua = String(req.headers['user-agent'] ?? '').slice(0, 300);
  const at_ms = Date.now();
  const action = req.query.action;
  const supa = db();

  if (action === 'visit') {
    const { error } = await supa.from('visits').upsert({ device, ua, at_ms });
    if (error) throw new Error(`visit upsert: ${error.message}`);
    return res.status(200).json({ ok: true });
  }

  const key = clean(req.query.clip, '.');
  if (!key) return res.status(400).json({ error: 'missing clip' });
  const kinds = { like: 'like', unlike: 'like', save: 'save', unsave: 'save' };
  const kind = kinds[action];
  if (!kind) return res.status(400).json({ error: 'bad action' });

  if (action === 'like' || action === 'save') {
    const { error } = await supa.from('social_marks')
      .upsert({ kind, clip_key: key, device, ua, at_ms });
    if (error && error.code !== FK_VIOLATION) throw new Error(`${action}: ${error.message}`);
  } else {
    const { error } = await supa.from('social_marks')
      .delete().match({ kind, clip_key: key, device });
    if (error) throw new Error(`${action}: ${error.message}`);
  }
  res.status(200).json({ ok: true });
}
