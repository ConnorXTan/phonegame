# Killcam gallery — deploys automatically from main (root: killcam-web)

Storage is Supabase (project `ltn-killcam`, ref `ghwdeywxlpqosusimxor`): MP4s in
the public `killcams` Storage bucket served via Supabase's CDN, clip metadata and
like/save/visit marks in Postgres (`lib/supabase-store.js`). This replaced Vercel
Blob after the hobby-tier "advanced operations" quota paused the store. Tables are
RLS-enabled with no policies — only the service key (held by these functions) can
touch them.

Environment variables (Vercel project settings):

- `KILLCAM_UPLOAD_KEY` — shared secret the app sends to publish/delete clips
- `SUPABASE_URL` — https://ghwdeywxlpqosusimxor.supabase.co
- `SUPABASE_SERVICE_ROLE_KEY` — service key (bypasses RLS; server-side only)

CLI deploys must run from the repo root (the Vercel project's Root Directory is
`killcam-web`, so deploying from inside this folder fails).
