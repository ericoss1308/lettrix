-- ============================================================
-- LETTRIX — Anfitrião do ranqueado tem que ser quem buscou primeiro
-- Roda no SQL Editor do Supabase. Pode rodar depois dos migrations
-- anteriores, não precisa refazer nada.
--
-- Problema: find_ranked_match escolhia como adversário quem estava
-- esperando há mais tempo na fila (order by created_at asc — correto),
-- mas depois marcava o CONVOCADOR (quem chegou agora, achou esse
-- adversário e rodou a função) como anfitrião — ou seja, quem entrou
-- na fila DEPOIS acabava virando host, e quem já estava esperando
-- virava convidado. Ao contrário do esperado.
--
-- Solução: inverte quem recebe o convite/código. Agora é a pessoa que
-- já estava esperando (v_opponent, escolhida por created_at asc) quem
-- vira anfitriã — a convocação é registrada na fila DELA, não na de
-- quem acabou de chegar.
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
  -- "created_at asc" já prioriza quem está esperando há mais tempo —
  -- é essa pessoa (v_opponent) que vai virar a anfitriã.
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

  -- quem já estava esperando (v_opponent) vira o anfitrião — a
  -- convocação fica registrada na fila DELE. No próximo poll dele, cai
  -- no segundo "if found" acima ("eu já sou host") e recebe o mesmo
  -- código como anfitrião.
  update matchmaking_queue
  set invite_code = v_code, invite_target = p_user_id
  where user_id = v_opponent.user_id;

  -- eu (que cheguei agora e achei o adversário) sou o convidado — já
  -- posso sair da fila, não preciso mais esperar nenhum poll.
  delete from matchmaking_queue where user_id = p_user_id;

  return query select v_code, false;
end;
$$;

grant execute on function find_ranked_match(uuid, text, text, text, integer) to authenticated;
