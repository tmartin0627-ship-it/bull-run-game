-- ============================================================
--  BULL RUN — leaderboard server-side hardening
--
--  The Supabase URL and anon key ship inside index.html, so anyone
--  can talk to the database directly. The client-side clamps in
--  Leaderboard.submitScore() are cosmetic; these constraints and
--  policies are what actually protect the leaderboard.
--
--  Apply in the Supabase dashboard: SQL Editor -> paste -> Run.
--  Safe to re-run (statements are idempotent where possible).
-- ============================================================

-- ── 1. Data validity constraints ────────────────────────────
-- Mirror the client clamps so out-of-range rows are rejected even
-- when inserted directly via the REST API.

alter table public.scores
  drop constraint if exists scores_score_range,
  add constraint scores_score_range
    check (score between 0 and 49999);

alter table public.scores
  drop constraint if exists scores_bulls_range,
  add constraint scores_bulls_range
    check (bulls_collected between 0 and 99);

alter table public.scores
  drop constraint if exists scores_time_min,
  add constraint scores_time_min
    check (time_taken >= 10.1);

alter table public.scores
  drop constraint if exists scores_character_valid,
  add constraint scores_character_valid
    check (character_used in ('chad', 'diana'));

alter table public.scores
  drop constraint if exists scores_name_valid,
  add constraint scores_name_valid
    check (
      player_name is not null
      and length(trim(player_name)) between 1 and 16
    );

-- Basic plausibility: the score is dominated by the level-finish time
-- bonus (max 5000/level, 3 levels) plus collectibles/kills. A high score
-- with a very short run time is physically impossible in the game.
alter table public.scores
  drop constraint if exists scores_plausible,
  add constraint scores_plausible
    check (score <= 2000 + time_taken * 600);

-- ── 2. Row Level Security ───────────────────────────────────
-- Anonymous players may read the leaderboard and append rows.
-- Nobody (anon) may update or delete existing rows.

alter table public.scores enable row level security;

drop policy if exists "anon can read scores" on public.scores;
create policy "anon can read scores"
  on public.scores for select
  to anon
  using (true);

drop policy if exists "anon can insert scores" on public.scores;
create policy "anon can insert scores"
  on public.scores for insert
  to anon
  with check (true);  -- validity is enforced by the CHECK constraints above

-- No update/delete policies are created, so RLS denies both by default.
-- Belt and braces: revoke the privileges too.
revoke update, delete on public.scores from anon;

-- ── 3. Rate limiting ────────────────────────────────────────
-- The game submits at most once per session; a flood of inserts for the
-- same player name is a script. Allow one insert per name per 60 seconds.
-- Requires a created_at column (add it if the table predates this file).

alter table public.scores
  add column if not exists created_at timestamptz not null default now();

create or replace function public.scores_rate_limit()
returns trigger
language plpgsql
security definer
as $$
begin
  if exists (
    select 1 from public.scores
    where player_name = new.player_name
      and created_at > now() - interval '60 seconds'
  ) then
    raise exception 'Rate limit: one submission per minute per player';
  end if;
  return new;
end;
$$;

drop trigger if exists scores_rate_limit_trigger on public.scores;
create trigger scores_rate_limit_trigger
  before insert on public.scores
  for each row execute function public.scores_rate_limit();

-- ── 4. Notes / future work ──────────────────────────────────
-- * These measures stop casual cheating (curl with absurd values),
--   not determined cheaters who submit plausible fake scores. For
--   real verification, submit the ReplayLib recording with the score
--   and validate it in a Supabase Edge Function before inserting.
-- * get_player_rank() RPC is read-only and unaffected by RLS changes
--   as long as it is declared SECURITY DEFINER or has a select policy.
