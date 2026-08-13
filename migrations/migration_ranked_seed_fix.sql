-- ============================================================
-- LETTRIX — Corrige pontuação/MMR não sendo salvos em revanches
-- ranqueadas. Roda no SQL Editor do Supabase depois do
-- migration_ranked_wo.sql (esse aqui depende dele já ter rodado).
--
-- Problema: ranked_match_submissions usava só o room_code como chave
-- única. Isso funciona pra primeira partida da sala, mas a revanche
-- reaproveita o MESMO room_code (é a mesma sala/canal) — então, na
-- hora de reportar o resultado da revanche, o insert batia numa
-- violação de chave primária, o RPC inteiro dava erro, e (como esse
-- erro tava sendo engolido em silêncio no front) o MMR e o ranking
-- global simplesmente não eram atualizados, sem nenhum aviso.
--
-- Solução: troca a chave única pra (room_code, match_seed). Cada
-- partida real (incluindo cada revanche) já gera um "seed" novo e
-- aleatório pra sortear as palavras — é um identificador único de
-- partida de graça, sem precisar inventar sala nova a cada revanche.
-- ============================================================

-- Tabelas de controle de partida em si não guardam histórico
-- importante (o histórico de verdade é match_history) — pode limpar
-- sem perder nada, evita conflito de chave primária duplicada ao
-- recriar as constraints abaixo.
truncate table ranked_match_acks;
truncate table ranked_match_submissions;

alter table ranked_match_acks add column if not exists match_seed bigint not null default 0;
alter table ranked_match_acks drop constraint if exists ranked_match_acks_pkey;
alter table ranked_match_acks add primary key (room_code, match_seed, user_id);

alter table ranked_match_submissions add column if not exists match_seed bigint not null default 0;
alter table ranked_match_submissions drop constraint if exists ranked_match_submissions_pkey;
alter table ranked_match_submissions add primary key (room_code, match_seed);

create or replace function submit_ranked_match(
  p_room_code text,
  p_match_seed bigint,
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
  ack_count integer;
begin
  if p_winner_id = p_loser_id then
    raise exception 'invalid match';
  end if;

  if p_room_code is null or length(p_room_code) = 0 then
    raise exception 'missing room code';
  end if;

  if auth.uid() is null or (auth.uid() <> p_winner_id and auth.uid() <> p_loser_id) then
    raise exception 'not a participant';
  end if;

  -- aperto de mão dos dois lados, específico desta partida (mesma sala
  -- pode ter tido revanches antes — só conta o aperto de mão do seed
  -- desta partida em particular).
  select count(*) into ack_count
  from ranked_match_acks
  where room_code = p_room_code
    and match_seed = p_match_seed
    and ((user_id = p_winner_id and opponent_id = p_loser_id)
      or (user_id = p_loser_id and opponent_id = p_winner_id));

  if ack_count < 2 then
    raise exception 'match not acknowledged by both players';
  end if;

  insert into ranked_match_submissions (room_code, match_seed, winner_id, loser_id)
  values (p_room_code, p_match_seed, p_winner_id, p_loser_id);

  insert into ranked_stats (user_id, name, avatar_url, avatar_pos)
    values (p_winner_id, p_winner_name, p_winner_avatar_url, p_winner_avatar_pos)
    on conflict (user_id) do nothing;
  insert into ranked_stats (user_id, name, avatar_url, avatar_pos)
    values (p_loser_id, p_loser_name, p_loser_avatar_url, p_loser_avatar_pos)
    on conflict (user_id) do nothing;

  select mmr, games into w_mmr, w_games from ranked_stats where user_id = p_winner_id for update;
  select mmr, games into l_mmr, l_games from ranked_stats where user_id = p_loser_id for update;

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

-- assinatura mudou de novo (ganhou p_match_seed logo depois de
-- p_room_code) — troca o grant da versão anterior pela nova.
revoke execute on function submit_ranked_match(text, uuid, text, text, text, uuid, text, text, text) from anon, authenticated;
grant execute on function submit_ranked_match(text, bigint, uuid, text, text, text, uuid, text, text, text) to authenticated;
