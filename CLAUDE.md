# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**ARANA TIME** — a single-file HR/attendance web app for Arana Clinic (multi-branch, Thailand). Vanilla JS/HTML/CSS, no build step, no framework. The user is the clinic's HR/owner, communicates in Thai, and this is a **live production system** with real staff depending on it daily.

- **The only app file is [teletest-arana-time.html](teletest-arana-time.html)** (~7,500 lines). **Never rename it or create a second copy** — the deployed URL is bookmarked and hardcoded elsewhere (`APP_URL` constant inside the file, Telegram message links, etc.).
- Deep technical/DB reference docs already exist in [arana-time-handoff/CLAUDE.md](arana-time-handoff/CLAUDE.md) (schema, permission tiers, feature history, business rules) and [arana-time-handoff/สรุประบบ-ARANA-TIME.md](arana-time-handoff/สรุประบบ-ARANA-TIME.md) (user-facing feature summary, Thai). **Read those before making non-trivial changes** — this file only covers what's needed to start working productively; it does not repeat that content.

## Commands

There is no build, lint, or test suite — this is a static file served as-is.

**Syntax-check after every edit** (the file is too large to safely eyeball; run from repo root):
```bash
node -e "
const fs = require('fs');
const t = fs.readFileSync('teletest-arana-time.html', 'utf-8');
const m = t.match(/<script>([\s\S]*)<\/script>\s*<\/body>/);
fs.writeFileSync('extracted_check.js', m[1]);
"
node --check extracted_check.js && rm -f extracted_check.js
```
(Do not use `python3` on this machine — it's a non-functional Windows Store stub.)

**Local preview against real production data**: create `.claude/launch.json` running `npx serve` on the project dir, open it in the browser preview tool, and navigate to `/teletest-arana-time.html`. Because `SUPABASE_URL`/`SUPABASE_ANON_KEY` are hardcoded in the file, this connects to the **real production Supabase database** — read-only testing only (never call save/write handlers, never trigger Telegram sends). Remove `.claude/launch.json` before committing.

**Deploy**: `git add`/`commit`/`push` to `origin/main` — GitHub Pages rebuilds automatically (30s–2min). No CI, no separate build/deploy step.

## Architecture

Everything lives in one file, in this order:
1. `<style>` — all CSS (design tokens as CSS custom properties near the top: `--pink`, `--bg`, `--green`, `--amber`, `--red`, etc.)
2. HTML markup — login view, employee view, admin view, modals/overlays
3. `<script>` (starts ~line 1823) — all logic, roughly in this order:
   - Supabase config (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `APP_URL`) + REST layer (`sbSelectAll`, `sbUpsertRow`, `sbDeleteRow` — direct `fetch()` calls to PostgREST, no Supabase client library)
   - Row↔object mappers per table (snake_case DB columns ↔ camelCase JS, e.g. `rowToOt`/`otToRow`)
   - `loadDB()` / `saveDB()` / per-table `save*Row()` / `delete*Row()`
   - Shared date-picker popup (`dateSelectHTML`, `getDateVal`, `setDateVal`, `wireDateChange`, `#globalCalPopup`) — **any new date input must use these four functions**, never a new date-picker implementation
   - Login flow (employee PIN, approver PIN, admin password fallback, remember-device/remember-session via `localStorage`)
   - Employee view (`render*Tab`, quick actions, face-scan camera flow via face-api.js)
   - Admin view (`render*` per tab, `switchATab`)
   - Telegram helpers (`tgSendMessage`, `tgSendPhoto`, `tgSendPhotoById`, `viewTelegramPhoto`, `approveLinkLine`)
   - `init()` at the very end — bootstraps the app on page load

**Backend**: Supabase Postgres, accessed via PostgREST REST calls with the anon key embedded client-side. All tables use an intentionally open RLS policy (`for all using (true) with check (true)`) — there is no per-user Supabase Auth; employees authenticate via a 4-digit PIN handled entirely in the app's own logic. This is a deliberate design choice, not an oversight.

**Notifications**: a Telegram bot (`central_token` in `settings`) posts to branch-specific chat rooms (`branches.chat_id_*` columns) for check-in/out, leave, OT, facility checks, etc. Several messages are also driven by scheduled `pg_cron` jobs on the Supabase side (see the `sql/` migrations for `send_*_reminder()` functions and their cron schedules) — client-side JS and server-side SQL functions both format Telegram messages, so a wording change often needs edits in both places.

**Schema**: real Postgres tables (not a JSONB blob) — `branches`, `employees`, `approvers`, `logs` (unified check-in/out/AC/cleaning/grooming log), `leaves`, `ot_requests`, `branch_transfers`, `audit_log`, `notifications`, `settings` (single row, id=1). FKs from these tables to `employees(id)` are `on delete set null` by design, so permanently deleting an employee keeps historical rows intact — replicate that `on delete set null` choice for any new employee-referencing table.

## Working conventions (non-negotiable, established by the user over many sessions)

1. **Confirm before implementing.** Every time a bug is reported or a change requested: investigate/diagnose first (read-only — grep, SQL `SELECT`s, read-only browser testing), then summarize the intended fix and wait for explicit go-ahead before editing files, applying migrations, or committing. Do not skip this for small or "obviously correct" fixes.
2. **Never send test messages into production Telegram groups.** Verify notification logic by reading code/data, not by triggering real sends.
3. **Edit surgically.** `grep -n` for a unique pattern, then targeted edits — never rewrite whole functions/the whole file when a small diff will do.
4. **Every DB schema change is a new `.sql` file** under `arana-time-handoff/sql/`, never edit an already-applied migration file. Name it descriptively and include a Thai-language comment header explaining the incident/root cause and the fix — this is the project's only migration history/documentation.
5. **Respond to the user in Thai**, polite/casual tone (ครับ/ค่ะ).
6. **Date handling**: compare `"YYYY-MM-DD"` strings against `Date` objects by appending `T00:00:00` (`new Date(dateStr+'T00:00:00')`) to avoid UTC-parsing drift in the Asia/Bangkok (UTC+7) timezone.
7. **No silent failures**: every Supabase `fetch()` call must check `res.ok` and return `{ok, error}` — never swallow errors in a bare `catch`.
