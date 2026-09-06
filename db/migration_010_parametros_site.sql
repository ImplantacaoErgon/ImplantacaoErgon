-- Migration 010: Parâmetros do site (identidade visual: logo e nome da
-- empresa exibidos no topo do sistema). Ver Configurações > Parâmetros no
-- frontend, as rotas /api/parametros em backend/app/main.py, e a seção
-- "Parâmetros do site" do README.
--
-- Tabela "singleton": mesma convenção já usada em `projetos` — sem
-- constraint de banco forçando 1 linha só; a aplicação sempre lê/edita a
-- primeira linha, e cria uma linha padrão automaticamente na primeira
-- leitura (GET /api/parametros) se ainda não existir nenhuma.
--
-- O tema da página (claro/escuro/automático) NÃO fica guardado aqui: por
-- decisão explícita, é uma preferência pessoal de cada usuário, salva só
-- no navegador dela (localStorage) — não afeta o que os demais usuários
-- veem, então não faz sentido morar numa tabela compartilhada.

CREATE TABLE IF NOT EXISTS parametros_site (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome_empresa  text NOT NULL DEFAULT '',
  logo_arquivo  text,
  atualizado_em timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE parametros_site IS
  'Parâmetros de identidade visual do site (logo e nome da empresa), '
  'exibidos no topo do sistema. Tabela "singleton" — a aplicação sempre '
  'usa a primeira linha, criando uma linha padrão automaticamente se '
  'necessário. Qualquer usuário autenticado pode editar (mesmo nível '
  'único de acesso das demais telas de Configurações — ver tabela '
  'usuarios).';
COMMENT ON COLUMN parametros_site.logo_arquivo IS
  'Nome do arquivo de imagem armazenado em backend/uploads/ (mesmo '
  'diretório usado pelos anexos). NULL enquanto nenhum logo foi enviado.';
