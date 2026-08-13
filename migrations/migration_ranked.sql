-- ============================================================
-- LETTRIX — Sistema de Ranked 1v1 (ELO/MMR + matchmaking)
-- Rode tudo isso de uma vez no SQL Editor do Supabase.
-- ============================================================

-- 1) Estatísticas de ranked por conta
create table if not exists ranked_stats (
  user_id uuid primary key references auth.users(id),
  name text not null,
  avatar_url text,
  avatar_pos text,
  mmr integer not null default 1000,
  wins integer not null default 0,
  losses integer not null default 0,
  games integer not null default 0,
  updated_at timestamptz not null default now()
);

alter table ranked_stats enable row level security;

create policy "Qualquer um pode ver o ranking de elos"
  on ranked_stats for select
  to anon
  using (true);

-- Sem policy de insert/update pra anon: só a função abaixo (security definer)
-- pode escrever, pra ninguém conseguir forjar vitórias direto pela API.

-- 2) Fila de matchmaking (usada só durante a busca por oponente)
create table if not exists matchmaking_queue (
  user_id uuid primary key references auth.users(id),
  name text not null,
  avatar_url text,
  avatar_pos text,
  mmr integer not null default 1000,
  invite_code text,
  invite_target uuid,
  created_at timestamptz not null default now()
);

alter table matchmaking_queue enable row level security;

create policy "Qualquer um pode ver a fila"
  on matchmaking_queue for select
  to authenticated
  using (true);

create policy "Usuário pode entrar na fila"
  on matchmaking_queue for insert
  to authenticated
  with check (auth.uid() = user_id);

create policy "Usuário pode atualizar sua própria entrada na fila"
  on matchmaking_queue for update
  to authenticated
  using (auth.uid() = user_id);

create policy "Usuário pode sair da fila"
  on matchmaking_queue for delete
  to authenticated
  using (auth.uid() = user_id);

-- 3) Função que aplica o resultado de uma partida ranqueada (ELO)
create or replace function submit_ranked_match(
  p_winner_id uuid,
  p_winner_name text,
  p_winner_avatar_url text,
  p_winner_avatar_pos text,
  p_loser_id uuid,
  p_loser_name text,
  p_loser_avatar_url text,
  p_loser_avatar_pos text
) returns table(winner_mmr integer, loser_mmr integer, winner_delta integer, loser_delta integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  w_mmr integer; l_mmr integer;
  w_games integer; l_games integer;
  w_k integer; l_k integer;
  expected_w numeric;
  w_new integer; l_new integer;
begin
  if p_winner_id = p_loser_id then
    raise exception 'invalid match';
  end if;

  insert into ranked_stats (user_id, name, avatar_url, avatar_pos)
    values (p_winner_id, p_winner_name, p_winner_avatar_url, p_winner_avatar_pos)
    on conflict (user_id) do nothing;
  insert into ranked_stats (user_id, name, avatar_url, avatar_pos)
    values (p_loser_id, p_loser_name, p_loser_avatar_url, p_loser_avatar_pos)
    on conflict (user_id) do nothing;

  select mmr, games into w_mmr, w_games from ranked_stats where user_id = p_winner_id for update;
  select mmr, games into l_mmr, l_games from ranked_stats where user_id = p_loser_id for update;

  -- Primeiras 10 partidas contam com K maior, pra "posicionar" mais rápido.
  w_k := case when w_games < 10 then 48 else 32 end;
  l_k := case when l_games < 10 then 48 else 32 end;

  expected_w := 1.0 / (1.0 + power(10, (l_mmr - w_mmr) / 400.0));

  w_new := greatest(0, round(w_mmr + w_k * (1 - expected_w)));
  l_new := greatest(0, round(l_mmr - l_k * (1 - expected_w)));

  update ranked_stats set
    name = p_winner_name, avatar_url = p_winner_avatar_url, avatar_pos = p_winner_avatar_pos,
    mmr = w_new, wins = wins + 1, games = games + 1, updated_at = now()
  where user_id = p_winner_id;

  update ranked_stats set
    name = p_loser_name, avatar_url = p_loser_avatar_url, avatar_pos = p_loser_avatar_pos,
    mmr = l_new, losses = losses + 1, games = games + 1, updated_at = now()
  where user_id = p_loser_id;

  return query select w_new, l_new, (w_new - w_mmr), (l_new - l_mmr);
end;
$$;

grant execute on function submit_ranked_match(uuid, text, text, text, uuid, text, text, text)
  to anon, authenticated;

-- 4) Estatísticas do 1v1 casual (salas por código — não afeta MMR/tier)
create table if not exists casual_versus_stats (
  user_id uuid primary key references auth.users(id),
  name text not null,
  avatar_url text,
  avatar_pos text,
  wins integer not null default 0,
  losses integer not null default 0,
  games integer not null default 0,
  updated_at timestamptz not null default now()
);

alter table casual_versus_stats enable row level security;

create policy "Qualquer um pode ver o placar do 1v1 casual"
  on casual_versus_stats for select
  to anon
  using (true);

create or replace function submit_casual_result(
  p_winner_id uuid,
  p_winner_name text,
  p_winner_avatar_url text,
  p_winner_avatar_pos text,
  p_loser_id uuid,
  p_loser_name text,
  p_loser_avatar_url text,
  p_loser_avatar_pos text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_winner_id = p_loser_id then
    raise exception 'invalid match';
  end if;

  insert into casual_versus_stats (user_id, name, avatar_url, avatar_pos, wins, games)
    values (p_winner_id, p_winner_name, p_winner_avatar_url, p_winner_avatar_pos, 1, 1)
    on conflict (user_id) do update
      set name = p_winner_name, avatar_url = p_winner_avatar_url, avatar_pos = p_winner_avatar_pos,
          wins = casual_versus_stats.wins + 1, games = casual_versus_stats.games + 1, updated_at = now();

  insert into casual_versus_stats (user_id, name, avatar_url, avatar_pos, losses, games)
    values (p_loser_id, p_loser_name, p_loser_avatar_url, p_loser_avatar_pos, 1, 1)
    on conflict (user_id) do update
      set name = p_loser_name, avatar_url = p_loser_avatar_url, avatar_pos = p_loser_avatar_pos,
          losses = casual_versus_stats.losses + 1, games = casual_versus_stats.games + 1, updated_at = now();
end;
$$;

grant execute on function submit_casual_result(uuid, text, text, text, uuid, text, text, text)
  to anon, authenticated;

-- 5) Histórico de partidas (solo, 1v1 casual e ranqueada)
create table if not exists match_history (
  id bigserial primary key,
  user_id uuid not null references auth.users(id),
  mode text not null check (mode in ('solo','casual_1v1','ranked')),
  result text check (result in ('win','loss','tie')),
  score integer,
  wave integer,
  opponent_name text,
  mmr_delta integer,
  created_at timestamptz not null default now()
);

alter table match_history enable row level security;

create policy "Usuário vê seu próprio histórico"
  on match_history for select
  to authenticated
  using (auth.uid() = user_id);

create policy "Usuário registra sua própria partida"
  on match_history for insert
  to authenticated
  with check (auth.uid() = user_id);

create index if not exists match_history_user_idx on match_history(user_id, created_at desc);
