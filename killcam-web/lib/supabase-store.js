// Supabase-backed store: Storage bucket `killcams` holds the MP4s (served via
// Supabase's CDN from the public bucket), Postgres holds clip metadata and the
// social marks. Replaced Vercel Blob when the hobby-tier quota paused the
// store mid-event. The tables are RLS-enabled with no policies, so only this
// service key can touch them; the anon key can do nothing.
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const key = process.env.SUPABASE_SERVICE_ROLE_KEY;

export const BUCKET = 'killcams';
export const configured = () => Boolean(url && key);
export const publicURL = (path) => `${url}/storage/v1/object/public/${BUCKET}/${path}`;

let client;
export function db() {
  if (!client) client = createClient(url, key, { auth: { persistSession: false } });
  return client;
}
