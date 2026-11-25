-- NeuroPlay · migração "painel_professor_figuras_e_tentativas"
-- JÁ APLICADA no projeto Supabase atual (wafiswmrrpylcoynugen) em 16/11/2026.
-- Guardada aqui só para o caso de você recriar o projeto (por exemplo, na região de São Paulo).
-- Pré-requisito: as tabelas alunos, turmas, professores e progresso, e as funções do jogo, já existirem.

-- 1) Figuras (senha do aluno) visíveis só ao professor da turma
create table public.aluno_figuras (
  aluno_id uuid primary key references public.alunos(id) on delete cascade,
  figuras text not null check (figuras ~ '^[1-9]{3}$'),
  criado_em timestamptz not null default now()
);
alter table public.aluno_figuras enable row level security;

create policy "professor le figuras dos seus alunos"
  on public.aluno_figuras for select to authenticated
  using (aluno_id in (
    select a.id from public.alunos a
    join public.turmas t on t.id = a.turma_id
    where t.professor_id = (select auth.uid())
  ));

-- 2) Registro de erros e dicas por pergunta
create table public.tentativas (
  id uuid primary key,
  aluno_id uuid not null references public.alunos(id) on delete cascade,
  mapa text not null check (mapa = any (array['matematica','portugues','ciencias','historia','geografia'])),
  fase integer not null check (fase between 1 and 50),
  rodada integer check (rodada is null or rodada between 1 and 20),
  tipo text not null check (tipo in ('choice','wordsearch','order')),
  pergunta text not null check (char_length(pergunta) <= 200),
  esperada text check (esperada is null or char_length(esperada) <= 120),
  erros integer not null default 0 check (erros between 0 and 1000),
  respostas_erradas text[] not null default '{}',
  dicas_pedidas integer not null default 0 check (dicas_pedidas between 0 and 100),
  dica_auto boolean not null default false,
  acertou boolean not null default false,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index tentativas_aluno_idx on public.tentativas (aluno_id, criado_em desc);
alter table public.tentativas enable row level security;

create policy "aluno cria as proprias tentativas"
  on public.tentativas for insert to authenticated
  with check (aluno_id = (select auth.uid()));
create policy "aluno atualiza as proprias tentativas"
  on public.tentativas for update to authenticated
  using (aluno_id = (select auth.uid()))
  with check (aluno_id = (select auth.uid()));
create policy "aluno le as proprias tentativas"
  on public.tentativas for select to authenticated
  using (aluno_id = (select auth.uid()));
create policy "professor le tentativas dos seus alunos"
  on public.tentativas for select to authenticated
  using (aluno_id in (
    select a.id from public.alunos a
    join public.turmas t on t.id = a.turma_id
    where t.professor_id = (select auth.uid())
  ));

-- limita o tamanho dos textos e a quantidade de registros por aluno
create or replace function public.validar_tentativa()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if tg_op = 'INSERT'
     and (select count(*) from public.tentativas where aluno_id = new.aluno_id) >= 3000 then
    raise exception 'limite de registros por aluno';
  end if;
  new.respostas_erradas := coalesce(
    (select array_agg(left(e, 60) order by i)
       from unnest(new.respostas_erradas) with ordinality as t(e, i)
      where i <= 12),
    '{}');
  new.atualizado_em := now();
  return new;
end;
$$;

create trigger tentativas_validar
  before insert or update on public.tentativas
  for each row execute function public.validar_tentativa();

-- 3) O cadastro passa a guardar as figuras escolhidas (mesma função de antes + 1 linha)
create or replace function public.registrar_aluno(p_codigo text, p_nome text, p_email text, p_senha text)
returns text
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_turma uuid;
  v_id uuid := gen_random_uuid();
  v_nome text := trim(coalesce(p_nome, ''));
begin
  if not (char_length(v_nome) between 2 and 20)
     or p_senha is null or p_senha !~ '^np-[1-9]{3}$'
     or p_email is null or p_email !~ '^[a-z0-9-]+\.[a-z0-9-]+@neuroplay\.game$'
     or split_part(p_email, '.', 1) <> lower(trim(coalesce(p_codigo, ''))) then
    return 'dados_invalidos';
  end if;

  select id into v_turma from public.turmas where codigo = upper(trim(p_codigo));
  if v_turma is null then
    return 'turma_invalida';
  end if;

  if exists (select 1 from auth.users where email = p_email) then
    return 'nome_repetido';
  end if;

  begin
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change
    ) values (
      '00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated',
      p_email, extensions.crypt(p_senha, extensions.gen_salt('bf')), now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(),
      '', '', '', ''
    );

    insert into auth.identities (
      id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
    ) values (
      gen_random_uuid(), v_id, v_id::text,
      jsonb_build_object('sub', v_id::text, 'email', p_email, 'email_verified', true),
      'email', now(), now(), now()
    );

    insert into public.alunos (id, nome, turma_id) values (v_id, v_nome, v_turma);

    insert into public.aluno_figuras (aluno_id, figuras) values (v_id, substr(p_senha, 4));
  exception when unique_violation then
    return 'nome_repetido';
  end;

  return 'ok';
end;
$function$;

-- 4) Só para alunos que já existiam antes desta migração: recupera as figuras comparando
--    com o hash da senha (são só 729 combinações possíveis). Já executado uma vez.
insert into public.aluno_figuras (aluno_id, figuras)
select a.id, g.f
from public.alunos a
join auth.users u on u.id = a.id
join lateral (
  select x::text || y::text || z::text as f
  from generate_series(1,9) x, generate_series(1,9) y, generate_series(1,9) z
  where u.encrypted_password = extensions.crypt('np-' || x::text || y::text || z::text, u.encrypted_password)
  limit 1
) g on true
on conflict (aluno_id) do nothing;
