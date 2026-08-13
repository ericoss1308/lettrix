-- ============================================================
-- LETTRIX — Validação real de partida ranqueada + vitória por W.O.
-- Roda no SQL Editor do Supabase. Pode rodar depois dos migrations
-- anteriores, não precisa refazer nada.
--
-- Problema 1: submit_ranked_match confiava cegamente nos ids de
-- vencedor/perdedor que o cliente mandava. Qualquer pessoa autenticada
-- podia chamar a função direto pela API REST com QUALQUER par de uids
-- e forjar uma vitória (ou fazer outra conta perder MMR), sem nunca
-- ter jogado contra ninguém.
--
-- Problema 2: só o host da sala podia reportar o resultado. Se o host
-- fosse quem fechasse o navegador/travasse o celular no meio da
-- partida, o adversário ficava com a vitória só na tela local — o MMR
-- dele nunca era atualizado, porque ele não tinha permissão de enviar.
--
-- Solução:
--  - ranked_match_acks: cada cliente, ao ver a partida começar,
--    registra (com o próprio auth.uid(), a RLS garante que não dá pra
--    forjar em nome de outra conta) que vai jogar contra tal
--    adversário naquela sala. Isso é o "aperto de mão" dos dois lados.
--  - submit_ranked_match passa a exigir: (a) quem está chamando é um
--    dos dois jogadores do resultado, e (b) existe o aperto de mão dos
--    DOIS lados pra aquela sala — ou seja, os dois realmente se
--    conectaram um no outro antes de qualquer resultado ser aceito.
--  - ranked_match_submissions trava a sala pra só aceitar um envio,
--    então tanto faz se for o host ou o adversário que reporta (ex:
--    vitória por W.O. quando o host abandona) — só o primeiro envio
--    válido conta.
-- ============================================================

-- 1) "Aperto de mão": cada jogador confirma, com a própria sessão, que
--    vai jogar contra um adversário específico numa sala específica.
create table if not exists ranked_match_acks (
  room_code text not null,
  user_id uuid not null references auth.users(id),
  opponent_id uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  primary key (room_code, user_id)
);

alter table ranked_match_acks enable row level security;

drop policy if exists "Usuário registra seu próprio aperto de mão" on ranked_match_acks;
create policy "Usuário registra seu próprio aperto de mão"
  on ranked_match_acks for insert
  to authenticated
  with check (auth.uid() = user_id and auth.uid() <> opponent_id);

drop policy if exists "Usuário vê os apertos de mão da própria sala" on ranked_match_acks;
create policy "Usuário vê os apertos de mão da própria sala"
  on ranked_match_acks for select
  to authenticated
  using (auth.uid() = user_id or auth.uid() = opponent_id);

-- limpeza de linhas velhas (evita a tabela crescer pra sempre — salas
-- de partida não duram mais que alguns minutos)
delete from ranked_match_acks where created_at < now() - interval '1 day';

-- 2) Controle de "essa sala já foi reportada" — cada room_code só pode
--    resultar numa atualização de MMR uma única vez.
create table if not exists ranked_match_submissions (
  room_code text primary key,
  winner_id uuid not null,
  loser_id uuid not null,
  created_at timestamptz not null default now()
);

alter table ranked_match_submissions enable row level security;
-- sem policy nenhuma pra anon/authenticated: só a função abaixo
-- (security definer, dona da tabela) grava e lê aqui.

-- 3) submit_ranked_match agora exige sala + valida aperto de mão dos
--    dois lados + só aceita uma vez por sala.
create or replace function submit_ranked_match(
  p_room_code text,
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

  -- só um dos dois jogadores do próprio resultado pode reportar —
  -- ninguém reporta partida em nome de terceiros.
  if auth.uid() is null or (auth.uid() <> p_winner_id and auth.uid() <> p_loser_id) then
    raise exception 'not a participant';
  end if;

  -- precisa existir o aperto de mão dos DOIS lados pra essa sala —
  -- prova que as duas contas realmente se conectaram uma na outra,
  -- não só um cliente inventando um adversário na hora de reportar.
  select count(*) into ack_count
  from ranked_match_acks
  where room_code = p_room_code
    and ((user_id = p_winner_id and opponent_id = p_loser_id)
      or (user_id = p_loser_id and opponent_id = p_winner_id));

  if ack_count < 2 then
    raise exception 'match not acknowledged by both players';
  end if;

  -- reserva a sala pra esse resultado; se já tiver sido reportada
  -- antes (por qualquer um dos dois lados), a chave primária duplicada
  -- barra aqui e nada abaixo é aplicado.
  insert into ranked_match_submissions (room_code, winner_id, loser_id)
  values (p_room_code, p_winner_id, p_loser_id);

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

-- assinatura mudou (ganhou p_room_code) — troca o grant antigo pelo novo
revoke execute on function submit_ranked_match(uuid, text, text, text, uuid, text, text, text) from anon, authenticated;
grant execute on function submit_ranked_match(text, uuid, text, text, text, uuid, text, text, text) to authenticated;
-- anon não entra mais no grant: sem sessão logada não tem como passar
-- na checagem de auth.uid(), então nem faz sentido conceder pra anon.
