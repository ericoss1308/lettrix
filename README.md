# Lettrix

Jogo de digitação — atire nas palavras que se aproximam da sua nave
digitando as letras corretas antes que elas cheguem ao centro. Inspirado no
clássico [ZType](https://zty.pe/).

## Como rodar

Pré-requisito: [Node.js](https://nodejs.org/) 18 ou superior.

```bash
npm install
npm run dev
```

Abra o endereço mostrado no terminal (normalmente `http://localhost:5173`).

## Outros comandos

```bash
npm run build     # gera a versão de produção em dist/
npm run preview   # serve a versão de produção localmente
```

## Como jogar

- Palavras surgem nas bordas da tela e avançam até a nave no centro.
- Digite livremente — não é preciso "escolher" qual palavra atirar antes.
  Conforme você digita, o jogo mostra na barra inferior exatamente o que
  você escreveu (inclusive erros, em vermelho) e destaca todas as palavras
  em tela que ainda combinam com o que foi digitado até agora. Isso evita o
  problema de duas palavras com o mesmo início "roubarem" o alvo uma da
  outra.
- Corrija erros com `Backspace` e pressione `Enter` para confirmar e
  atirar. Só é aceito se o que você digitou for exatamente igual a alguma
  palavra ativa; caso contrário o disparo é rejeitado (a barra e a caixa da
  palavra piscam em vermelho) e você pode tentar de novo.
- Acentos são opcionais: digitar `orbita` também acerta `órbita`.
- Três palavras que chegarem até a nave encerram a missão.
- Cada palavra destruída aumenta a sequência (combo) e o multiplicador de
  pontos; um impacto na nave zera a sequência.
- `Esc` pausa e retoma o jogo a qualquer momento.
- A cor do jogo muda suavemente conforme a pontuação sobe: azul → roxo →
  verde → vermelho → preto (modo final).

## Configurações

Acessíveis pelo ícone de engrenagem na tela inicial, ou pelo botão "Configurações" no
menu de pausa (entre "Continuar" e "Encerrar missão"):

- **Volume** — controla todos os efeitos sonoros (laser, explosão, impacto).
- **Gráficos** (Baixa / Média / Alta) — ajusta quantidade de estrelas,
  partículas de explosão, brilho (glow) e intensidade do tremor de tela.
  Útil para melhorar o desempenho em computadores mais fracos.
- **Idioma das palavras** — Português, English, Español, Français, Deutsch
  ou Italiano. Só troca o vocabulário do jogo; a interface continua em
  português. Se você trocar o idioma no meio de uma missão, o jogo avisa
  que o progresso atual será perdido e reinicia a partida no novo idioma.

As preferências ficam salvas no navegador (`localStorage`) e são carregadas
automaticamente na próxima vez que o jogo for aberto.

## Ranking global

O jogo tem uma tela de ranking global (botão "Ranking global" na tela
inicial e no fim de jogo) que usa o [Supabase](https://supabase.com) como
banco de dados. Ninguém precisa criar conta pra jogar nem pra ver o
ranking — só pra aparecer nele, a pessoa digita um nome ao final da
partida.

### Passo a passo pra configurar

1. Crie uma conta gratuita em [supabase.com](https://supabase.com) e um
   novo projeto (escolha uma senha de banco de dados, não precisa
   guardar — não vamos usá-la aqui).
2. No painel do projeto, abra **SQL Editor** e rode:

   ```sql
   create table scores (
     id bigint generated always as identity primary key,
     name text not null,
     score integer not null,
     wave integer,
     lang text,
     created_at timestamptz not null default now()
   );

   alter table scores enable row level security;

   create policy "Qualquer um pode ver o ranking"
     on scores for select
     to anon
     using (true);

   create policy "Qualquer um pode enviar pontuação"
     on scores for insert
     to anon
     with check (
       length(name) between 1 and 18
       and score >= 0 and score < 100000000
     );
   ```

3. Em **Project Settings → API**, copie a **Project URL** e a chave
   **anon public**.
4. Abra `index.html`, procure por `SUPABASE_URL` e `SUPABASE_ANON_KEY`
   (bem no início do `<script>`) e cole os dois valores:

   ```js
   const SUPABASE_URL = "https://xxxxxxxx.supabase.co";
   const SUPABASE_ANON_KEY = "eyJhbGciOi...";
   ```

5. Salve, dê commit e publique. Pronto — o ranking passa a funcionar
   pra qualquer pessoa que abrir o jogo.

A chave `anon` é feita pra ser pública (fica visível no código do
navegador); a segurança vem das políticas de RLS acima, que limitam o
que pode ser inserido. Enquanto os dois valores não forem preenchidos,
o jogo funciona normalmente e o ranking mostra um aviso dizendo que
ainda não foi configurado.

### Uma pontuação única por @ (obrigatório para o ranking atual)

O `index.html` agora envia a pontuação através de uma função `bump_score`
(em vez de inserir uma linha nova a cada partida), que só substitui a
pontuação salva de um @ se a nova for maior. Pra isso funcionar, rode no
**SQL Editor** do Supabase (depois de já ter criado a tabela `scores`
acima):

```sql
alter table scores add constraint scores_name_key unique (name);

create or replace function bump_score(
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

  insert into scores (name, score, wave, lang, avatar_url, avatar_pos)
  values (p_name, p_score, p_wave, p_lang, p_avatar_url, p_avatar_pos)
  on conflict (name) do update
    set score = excluded.score,
        wave = excluded.wave,
        lang = excluded.lang,
        avatar_url = excluded.avatar_url,
        avatar_pos = excluded.avatar_pos,
        created_at = now()
    where excluded.score > scores.score;
end;
$$;

grant execute on function bump_score(text, integer, integer, text, text, text)
  to anon, authenticated;
```

Se algum @ já tiver mais de uma linha salva de antes (do formato antigo,
que inseria uma linha por partida), rode isto primeiro para deixar só a
melhor pontuação de cada @ antes de criar a constraint `unique`:

```sql
delete from scores a using scores b
  where a.name = b.name and a.score < b.score;
delete from scores a using scores b
  where a.name = b.name and a.ctid < b.ctid and a.score = b.score;
```

## Contas de jogador (login por e-mail e Google)

O jogo tem uma aba **"Minha conta"** na tela inicial, com criação de conta e
login por e-mail/senha, além de um botão para entrar com Google.
Isso usa o mesmo projeto Supabase do ranking (não precisa de outro serviço).

Assim como o ranking, ninguém precisa ter conta pra jogar — a conta é só uma
forma de identificar o piloto entre uma sessão e outra.

### 1. Login por e-mail e senha

Já funciona automaticamente assim que `SUPABASE_URL` e `SUPABASE_ANON_KEY`
estiverem preenchidos (mesmo passo do ranking, veja acima). Por padrão o
Supabase exige confirmação por e-mail antes do primeiro login — dá pra
desligar isso em **Authentication → Providers → Email → Confirm email**,
se preferir liberar o acesso imediato.

### 2. Login com Google

1. No painel do Supabase, vá em **Authentication → Providers** e habilite
   **Google**.
2. Crie um **OAuth Client ID** em
   [console.cloud.google.com](https://console.cloud.google.com/apis/credentials)
   (tipo "Web application").
3. Em **Authorized redirect URIs**, cole a URL de callback que o próprio
   Supabase mostra na tela do provedor Google (algo como
   `https://SEU-PROJETO.supabase.co/auth/v1/callback`).
4. Copie o **Client ID** e o **Client Secret** gerados pelo Google e cole
   nos campos correspondentes na tela do provedor Google no Supabase.
   Salve.

### 3. URL de redirecionamento (importante para produção)

Depois de publicar o jogo (Netlify ou outro), abra **Authentication → URL
Configuration** no Supabase e adicione a URL final do jogo (ex.:
`https://seu-jogo.netlify.app`) tanto em **Site URL** quanto em
**Redirect URLs**. Sem isso, o login com Google funciona em
`localhost` mas falha (ou redireciona para o lugar errado) no site
publicado.

Enquanto as contas não forem configuradas, a aba "Minha conta" mostra um
aviso e o jogo continua funcionando normalmente sem elas.

### Foto de perfil (avatar)

Quem cria conta pode tocar no avatar (dentro da aba "Minha conta") para
enviar uma foto — ela é recortada automaticamente em quadrado no próprio
navegador antes do envio, e passa a aparecer tanto na aba de conta quanto
ao lado do nome no ranking global.

Passo a passo para habilitar:

1. No painel do Supabase, abra **SQL Editor** e rode:

   ```sql
   alter table scores add column if not exists avatar_url text;
   ```

2. Vá em **Storage** → **New bucket**, crie um bucket chamado `avatars`
   e marque a opção **Public bucket**.
3. Ainda em Storage, na tabela `avatars`, abra a aba **Policies** e
   crie as políticas abaixo (ou rode no SQL Editor):

   ```sql
   create policy "Qualquer um pode ver os avatares"
     on storage.objects for select
     to public
     using (bucket_id = 'avatars');

   create policy "Usuário pode enviar seu próprio avatar"
     on storage.objects for insert
     to authenticated
     with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);

   create policy "Usuário pode atualizar seu próprio avatar"
     on storage.objects for update
     to authenticated
     using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
   ```

Cada foto é salva no caminho `avatars/<id-do-usuário>/avatar.jpg`, então as
políticas acima garantem que cada pessoa só consegue enviar ou substituir
o próprio avatar — mas qualquer um pode visualizar (é assim que o ranking
consegue mostrar as fotos para todo mundo). Enquanto o bucket não for
criado, o toque no avatar simplesmente mostra um erro amigável e o jogo
continua normal, exibindo a inicial do e-mail no lugar da foto.

## Publicar no GitHub e no Netlify

```bash
git init
git add .
git commit -m "Lettrix"
git branch -M main
git remote add origin <URL-do-seu-repositorio-no-GitHub>
git push -u origin main
```

Depois, no [Netlify](https://app.netlify.com):

1. **Add new site → Import an existing project** e conecte o repositório
   do GitHub.
2. O `netlify.toml` já vem configurado com o comando de build
   (`npm run build`) e a pasta de publicação (`dist`) — não precisa
   mexer em nada, é só clicar em **Deploy**.
3. Lembre de já ter preenchido `SUPABASE_URL` e `SUPABASE_ANON_KEY` no
   `index.html` (passo anterior) antes do commit/deploy, senão o
   ranking sobe desligado.

## Personalizar o banco de palavras

O vocabulário de cada idioma fica no objeto `WORD_POOLS`, no topo do
`<script>` em `index.html` — uma chave por idioma (`pt`, `en`, `es`, `fr`,
`de`, `it`). As palavras são classificadas automaticamente por tamanho
(curtas, médias, longas) para controlar a dificuldade conforme a onda
avança. Para adicionar um novo idioma, crie uma nova chave no objeto e
inclua o nome de exibição em `LANGUAGE_NAMES`, além de uma `<option>` no
seletor de idioma do HTML.

Cada idioma tem entre ~525 e ~550 palavras. O português foi montado à mão,
por categoria (família, corpo, casa, comida, natureza, animais, cores,
profissões, emoções, verbos, lugares, transporte, objetos e esportes). Os
outros cinco idiomas (inglês, espanhol, francês, alemão e italiano) foram
ampliados com a biblioteca Python [wordfreq](https://pypi.org/project/wordfreq/),
que lista as palavras mais usadas de cada idioma por frequência real de
uso, combinada com a biblioteca [stop-words](https://pypi.org/project/stop-words/)
pra remover artigos/preposições/pronomes, mais filtros manuais pra tirar
nomes próprios, gírias de internet e palavrões. Se quiser regenerar ou
ajustar essas listas, o processo é:

```bash
pip install wordfreq stop-words
```
```python
from wordfreq import top_n_list
from stop_words import get_stop_words
palavras = top_n_list("en", 10000)   # troque "en" pelo idioma desejado
stopwords = set(get_stop_words("en"))
```
