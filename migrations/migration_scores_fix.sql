-- ============================================================
-- LETTRIX — Correção do ranking global (foto/nome não atualizavam)
-- Roda no SQL Editor do Supabase.
--
-- Problema: o "on conflict ... where excluded.score > scores.score"
-- fazia a linha inteira só ser atualizada quando a nova pontuação
-- batia o recorde salvo — então avatar_url e name (foto e @) ficavam
-- travados na versão antiga sempre que você jogava sem superar seu
-- recorde.
--
-- Correção: nome e foto passam a atualizar em TODO envio; só
-- score/wave/lang continuam condicionados a bater o recorde.
-- (mantém a mesma assinatura da função já usada pelo app: com
-- p_user_id como primeiro parâmetro — não precisa mudar o índex.html)
-- ============================================================

create or replace function bump_score(
  p_user_id uuid,
  p_name text,
  p_score integer,
  p_wave integer,
  p_lang text,
  p_avatar_url text default null,
  p_avatar_pos text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if length(p_name) < 1 or length(p_name) > 18 then
    raise exception 'invalid name';
  end if;
  if p_score < 0 or p_score >= 100000000 then
    raise exception 'invalid score';
  end if;

  insert into scores (user_id, name, score, wave, lang, avatar_url, avatar_pos)
  values (p_user_id, p_name, p_score, p_wave, p_lang, p_avatar_url, p_avatar_pos)
  on conflict (user_id) do update
    set name = excluded.name,
        avatar_url = excluded.avatar_url,
        avatar_pos = excluded.avatar_pos,
        score = case when excluded.score > scores.score then excluded.score else scores.score end,
        wave = case when excluded.score > scores.score then excluded.wave else scores.wave end,
        lang = case when excluded.score > scores.score then excluded.lang else scores.lang end,
        created_at = case when excluded.score > scores.score then now() else scores.created_at end;
end;
$$;

grant execute on function bump_score(uuid, text, integer, integer, text, text, text)
  to anon, authenticated;
