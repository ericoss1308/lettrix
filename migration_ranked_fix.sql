-- ============================================================
-- LETTRIX — Correção do matchmaking ranqueado
-- Roda no SQL Editor do Supabase. Pode rodar depois do
-- migration_ranked.sql original, não precisa refazer nada.
--
-- Problema: cada cliente lia a fila e decidia sozinho quem
-- vira "host", com base numa leitura que podia estar
-- desatualizada em relação à do outro cliente. Nessa corrida,
-- os dois às vezes se achavam host ao mesmo tempo, cada um
-- gerava seu próprio código de sala, e nenhum dos dois nunca
-- entrava na sala do outro.
--
-- Solução: o pareamento passa a ser feito inteiro dentro do
-- banco, numa função com trava de linha (FOR UPDATE SKIP
-- LOCKED), então só um dos dois pode "ganhar" o mesmo
-- adversário — não tem mais como os dois virarem host da
-- mesma dupla.
-- ============================================================

create or replace function find_ranked_match(
  p_user_id uuid,
  p_name text,
  p_avatar_url text,
  p_avatar_pos text,
  p_mmr integer
) returns table(room_code text, is_host boolean)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_opponent record;
  v_invited record;
  v_code text;
begin
  -- remove entradas fantasma (mais de 2 min paradas na fila)
  delete from matchmaking_queue where created_at < now() - interval '2 minutes';

  -- alguém já me convidou pra sala dele?
  select * into v_invited from matchmaking_queue where invite_target = p_user_id limit 1;
  if found then
    delete from matchmaking_queue where user_id = p_user_id;
    return query select v_invited.invite_code, false;
    return;
  end if;

  -- eu já sou host de uma sala aberta (convidei alguém antes)?
  select * into v_invited from matchmaking_queue where user_id = p_user_id and invite_code is not null;
  if found then
    return query select v_invited.invite_code, true;
    return;
  end if;

  -- garante minha presença na fila (upsert, sem resetar o horário de entrada)
  insert into matchmaking_queue (user_id, name, avatar_url, avatar_pos, mmr)
  values (p_user_id, p_name, p_avatar_url, p_avatar_pos, p_mmr)
  on conflict (user_id) do update set
    name = excluded.name,
    avatar_url = excluded.avatar_url,
    avatar_pos = excluded.avatar_pos,
    mmr = excluded.mmr;

  -- procura um oponente livre e TRAVA a linha dele — se outro processo
  -- tentar pegar a mesma linha ao mesmo tempo, ele pula pra próxima
  -- (SKIP LOCKED) em vez de esperar ou pegar a mesma pessoa.
  select * into v_opponent
  from matchmaking_queue
  where user_id <> p_user_id and invite_target is null
  order by abs(mmr - p_mmr) asc, created_at asc
  for update skip locked
  limit 1;

  if not found then
    return query select null::text, false;
    return;
  end if;

  v_code := upper(substr(md5(random()::text), 1, 5));

  update matchmaking_queue
  set invite_code = v_code, invite_target = v_opponent.user_id
  where user_id = p_user_id;

  return query select v_code, true;
end;
$$;

grant execute on function find_ranked_match(uuid, text, text, text, integer) to authenticated;
