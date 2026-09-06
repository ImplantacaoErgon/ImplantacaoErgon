-- ============================================================================
-- Migration 009 — Usuários do sistema (login) e proteção de acesso
-- ============================================================================
-- Cadastro de usuários com autenticação. Autocadastro aberto: qualquer
-- pessoa acessa a tela de "Primeiro acesso / Cadastro", preenche todos os
-- campos (obrigatórios) e já sai com login liberado (a própria senha
-- digitada no cadastro). "Esqueci a senha" gera uma nova senha aleatória e
-- envia por e-mail (não é um link de redefinição).
--
-- Decisão tomada na 11ª rodada: tabela independente de "recursos" — nem
-- todo usuário de login é um responsável por atividades no cronograma, e
-- vice-versa. Todos os usuários autenticados têm o mesmo nível de acesso
-- (sem perfil "administrador" nesta rodada).
--
-- Ver backend/app/auth.py, as rotas /api/auth/* e /api/usuarios em
-- backend/app/main.py, e a seção "Login e cadastro de usuários" do README.
-- ============================================================================

CREATE TABLE IF NOT EXISTS usuarios (
  id                           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email                        text NOT NULL,
  nome                         text NOT NULL,
  telefone                     text NOT NULL,
  empresa                      text NOT NULL,
  cargo                        text NOT NULL,
  senha_hash                   text NOT NULL,
  recebe_relatorio_executivo   boolean NOT NULL DEFAULT true,
  recebe_notificacao_whatsapp  boolean NOT NULL DEFAULT true,
  ativo                        boolean NOT NULL DEFAULT true,
  criado_em                    timestamptz NOT NULL DEFAULT now(),
  ultimo_login_em              timestamptz
);

-- Unicidade de e-mail sem diferenciar maiúsculas/minúsculas (login é feito
-- por e-mail) — evita duplicidade tipo "Fulano@x.com" x "fulano@x.com".
CREATE UNIQUE INDEX IF NOT EXISTS idx_usuarios_email_lower ON usuarios (lower(email));

COMMENT ON TABLE usuarios IS
  'Usuários com login no sistema (equipe Techne e do cliente). Autocadastro '
  'aberto — ver README, seção "Login e cadastro de usuários". Distinta de '
  '"recursos" (pessoas responsáveis por atividades no cronograma): um '
  'usuário de login não precisa ser um recurso, e vice-versa.';
COMMENT ON COLUMN usuarios.senha_hash IS
  'Hash da senha (werkzeug.security.generate_password_hash) — a senha em '
  'texto puro nunca é armazenada.';
COMMENT ON COLUMN usuarios.recebe_relatorio_executivo IS
  'Reservado para uso futuro: se este usuário deve receber cópia dos '
  'Relatórios Executivos (IA) gerados no Dashboard (ex: por e-mail).';
COMMENT ON COLUMN usuarios.recebe_notificacao_whatsapp IS
  'Reservado para uso futuro: se este usuário deve receber notificações '
  'via WhatsApp no telefone cadastrado. Nenhum envio de WhatsApp é feito '
  'ainda nesta rodada — só o cadastro do telefone e da preferência.';
