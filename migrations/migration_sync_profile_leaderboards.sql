-- ============================================================
-- LETTRIX — Foto/@ trocados na conta não refletiam no ranking até
-- jogar de novo. Roda no SQL Editor do Supabase.
--
-- Motivo: o ranking (scores, ranked_stats, casual_versus_stats) guarda
-- uma CÓPIA do nome/foto de quando a pessoa jogou por último — não é
-- "ao vivo" ligado à conta. Isso é proposital (evita ter que juntar
-- com a tabela de usuários toda vez que alguém carrega o ranking),
-- mas faz sentido também atualizar essa cópia na hora, assim que a
-- pessoa troca a foto ou o @, sem precisar jogar uma partida só pra
-- "empurrar" a atualização.
--
-- Solução: uma função que atualiza (só se já existir linha — não cria
-- linha nova pra quem nunca jogou) o nome/foto da PRÓPRIA conta
-- logada nas três tabelas de placar de uma vez. O app chama isso
-- automaticamente depois de trocar a foto ou o @.
-- ============================================================

create or replace function sync_profile_to_leaderboards(
  p_name text,
  p_avatar_url text,
  p_avatar_pos text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not authorized';
  end if;

  update scores set
    name = p_name, avatar_url = p_avatar_url, avatar_pos = p_avatar_pos
  where user_id = auth.uid();

  update ranked_stats set
    name = p_name, avatar_url = p_avatar_url, avatar_pos = p_avatar_pos, updated_at = now()
  where user_id = auth.uid();

  update casual_versus_stats set
    name = p_name, avatar_url = p_avatar_url, avatar_pos = p_avatar_pos, updated_at = now()
  where user_id = auth.uid();
end;
$$;

grant execute on function sync_profile_to_leaderboards(text, text, text) to authenticated;
