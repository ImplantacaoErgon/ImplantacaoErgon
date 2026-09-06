-- ============================================================================
-- Ergon PM — banco de dados de gestão técnica da implantação
-- PostgreSQL 14+
--
-- Organização geral:
--   projetos > etapas > frentes_trabalho > atividades (WBS hierárquica)
--   atividades <-> atividade_dependencia   (grafo para caminho crítico / CPM)
--   atividades <-> recursos                (responsáveis, N:N)
--   atividades <-> requisitos_tr           (rastreabilidade com o Termo de Referência)
--   atividades -> ciclos_migracao          (execuções semanais da migração de dados)
--   atividades / requisitos_tr / riscos -> anexos (arquivos: xls, csv, txt, pdf, ...)
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()

-- ----------------------------------------------------------------------------
-- Tipos enumerados (vocabulário fechado e estável)
-- ----------------------------------------------------------------------------
CREATE TYPE prioridade_enum AS ENUM ('Urgente','Alta','Média','Baixa');

CREATE TYPE status_atividade_enum AS ENUM (
  'Não iniciada','Em andamento','Bloqueada','Concluída','Cancelada'
);

CREATE TYPE tipo_dependencia_enum AS ENUM ('FS','SS','FF','SF');
-- FS = Fim-Início (padrão), SS = Início-Início, FF = Fim-Fim, SF = Início-Fim

CREATE TYPE classificacao_tr_enum AS ENUM (
  'Essencial/Imediato','Obrigatório','Desejável',
  'Customizado Curto','Customizado Médio','Customizado Longo'
);

CREATE TYPE atendimento_tr_enum AS ENUM ('A analisar','Nativo','Parcial','Customizado','Não atende');

CREATE TYPE status_requisito_enum AS ENUM (
  'Não iniciado','Em levantamento','Especificado','Em desenvolvimento',
  'Em homologação','Entregue','Aprovado','Rejeitado'
);

CREATE TYPE cobranca_enum AS ENUM ('Sim','Não','N/A');

CREATE TYPE tipo_requisito_enum AS ENUM ('Funcional','Não Funcional');

CREATE TYPE tipo_vinculo_enum AS ENUM ('Techne','Cliente','Terceirizado');

CREATE TYPE nivel_risco_enum AS ENUM ('Baixo','Médio','Alto');

CREATE TYPE status_risco_enum AS ENUM ('Aberto','Mitigado','Encerrado');

CREATE TYPE entidade_anexo_enum AS ENUM ('atividade','requisito','risco','marco','projeto');

-- ----------------------------------------------------------------------------
-- Função utilitária: atualizar coluna atualizado_em automaticamente
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_atualizado_em() RETURNS trigger AS $$
BEGIN
  NEW.atualizado_em = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 1. PROJETOS
-- ============================================================================
CREATE TABLE projetos (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sigla           text,                          -- sigla curta do projeto, ex: "ERGON-PGFN"
  nome            text NOT NULL,
  cliente         text NOT NULL,                 -- Instituição/órgão cliente
  descricao       text,
  fiscal_projeto            text,                -- fiscal do contrato, nomeado pelo cliente
  gestor_projeto            text,                -- gestor do projeto pelo cliente
  gerente_projeto_cliente   text,
  gerente_projeto_techne    text,
  lider_projeto_techne      text,
  data_abertura       date,                      -- data de abertura/assinatura do projeto
  data_inicio         date,                      -- início previsto
  data_inicio_real    date,
  data_fim_prevista   date,
  prazo_total_meses   numeric(5,1),               -- prazo contratual total, em meses
  horas_dia_util  numeric(4,1) NOT NULL DEFAULT 8.0,   -- jornada padrão p/ conversão horas->dias no CPM
  criado_em       timestamptz NOT NULL DEFAULT now(),
  atualizado_em   timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_projetos_atualizado_em BEFORE UPDATE ON projetos
  FOR EACH ROW EXECUTE FUNCTION set_atualizado_em();
COMMENT ON TABLE projetos IS 'Um projeto de implantação (ex: Ergon num órgão específico). Permite reuso do modelo em outros clientes da Techne.';

-- ============================================================================
-- 2. ETAPAS  (Etapa 1, 2, 3 do documento de metodologia)
-- ============================================================================
CREATE TABLE etapas (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  projeto_id      uuid NOT NULL REFERENCES projetos(id) ON DELETE CASCADE,
  numero          int NOT NULL,                 -- 1, 2, 3...
  nome            text NOT NULL,                -- "Folha de Pagamento", "Módulos Isolados"...
  descricao       text,
  data_inicio_prev date,
  data_fim_prev   date,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (projeto_id, numero)
);
COMMENT ON TABLE etapas IS 'Macro-fases do projeto, conforme a metodologia (Etapa 1 = folha completa, Etapa 2 = módulos isolados, etc).';

-- ============================================================================
-- 3. FRENTES DE TRABALHO
-- ============================================================================
CREATE TABLE frentes_trabalho (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  projeto_id      uuid NOT NULL REFERENCES projetos(id) ON DELETE CASCADE,
  nome            text NOT NULL,      -- Parametrização, Migração de Dados, Folha de Pagamento, Treinamento...
  descricao       text,
  cor_hex         text,               -- para exibição consistente no front-end
  ordem           int NOT NULL DEFAULT 0,
  ativo           boolean NOT NULL DEFAULT true,  -- permite "aposentar" uma frente sem quebrar atividades já lançadas nela
  criado_em       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (projeto_id, nome)
);
COMMENT ON TABLE frentes_trabalho IS 'Catálogo de frentes: Parametrização, Migração de Dados, Folha de Pagamento, Customizações, Contagem de Tempo, Integrações, eSocial, Portal do Servidor, Workflow, BI, Treinamentos, Gestão.';

-- ============================================================================
-- 4. TIPOS DE ATIVIDADE ELEMENTAR  (campo tabelado pedido pelo usuário)
-- ============================================================================
CREATE TABLE tipos_atividade_elementar (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome            text NOT NULL UNIQUE,   -- Levantamento, Parametrização, Extração, Carga, Análise de Rejeição,
                                           -- Especificação de Customização, Programação, Homologação, Entrega,
                                           -- Treinamento, Teste, Comparação, Reunião...
  descricao       text,
  ordem           int NOT NULL DEFAULT 0,
  ativo           boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE tipos_atividade_elementar IS 'Vocabulário controlado do "tipo" de trabalho de cada atividade, reutilizável entre frentes — permite agregar, por exemplo, "todas as atividades de Levantamento", independente da frente.';

-- ============================================================================
-- 5. RECURSOS (pessoas: consultores Techne, analistas/gestores do cliente)
-- ============================================================================
CREATE TABLE recursos (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome            text NOT NULL,
  tipo_vinculo    tipo_vinculo_enum NOT NULL DEFAULT 'Techne',  -- Techne / Cliente / Terceirizado — usado para filtrar responsáveis
  empresa         text,               -- nome da empresa/instituição a que pertence (ex: "Techne", "TSE", "Consultoria XYZ")
  cargo           text,               -- "Consultor de Folha", "Líder Técnico", "Analista de TI", "Gestor de RH"...
  email           text,
  telefone        text,
  ativo           boolean NOT NULL DEFAULT true,
  criado_em       timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE recursos IS 'Pessoas responsáveis (consultores Techne, terceirizados, analistas/gestores do cliente). tipo_vinculo classifica o lado; empresa guarda o nome real da empresa/instituição.';

-- ============================================================================
-- 6. ATIVIDADES  (WBS hierárquica — o coração do cronograma)
-- ============================================================================
CREATE TABLE atividades (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  projeto_id        uuid NOT NULL REFERENCES projetos(id) ON DELETE CASCADE,
  etapa_id          uuid NOT NULL REFERENCES etapas(id),
  frente_trabalho_id uuid NOT NULL REFERENCES frentes_trabalho(id),
  tipo_atividade_elementar_id uuid REFERENCES tipos_atividade_elementar(id),
  atividade_pai_id  uuid REFERENCES atividades(id) ON DELETE CASCADE,  -- hierarquia WBS (subatividades)
  requisito_tr_id   uuid,             -- item do Termo de Referência ao qual esta atividade se relaciona (opcional).
                                       -- FK criada mais abaixo (requisitos_tr só é definida depois). Subatividades
                                       -- herdam este valor do pai automaticamente na criação (ver backend).

  codigo_wbs        text,             -- ex: "1.3.2" — numeração hierárquica, mantida pela aplicação
  origem_importacao_id text,          -- Id da tarefa na planilha de origem (MS Project), usado para casar a
                                       -- mesma atividade entre reimportações do cronograma (atualiza em vez de
                                       -- duplicar) — ver backend/app/cronograma_import.py. NULL se cadastrada manualmente.
  nome              text NOT NULL,    -- "Levantamento Grupo de Vencimento", "Extração de Pessoas"...
  descricao         text,
  -- Quem executa/participa da atividade (Techne, cliente ou terceirizado, quantos forem
  -- necessários) fica em `atividade_recurso` (N:N — ver seção 8), não mais em campos fixos
  -- aqui. Migração 012 removeu os antigos responsavel_techne_id/responsavel_cliente_id
  -- (um único responsável de cada lado) por essa tabela de relação.

  prazo_horas       numeric(8,2),     -- horas previstas (estimativa de esforço planejada)
  horas_realizadas  numeric(8,2),     -- horas efetivamente gastas na execução — pode ficar acima ou abaixo do previsto
  dtini_prev        date,
  dtfim_prev        date,
  dtini_real        date,
  dtfim_real        date,

  percentual_concluido smallint NOT NULL DEFAULT 0 CHECK (percentual_concluido BETWEEN 0 AND 100),
  status            status_atividade_enum NOT NULL DEFAULT 'Não iniciada',
  prioridade        prioridade_enum NOT NULL DEFAULT 'Média',

  -- resultado do último cálculo de caminho crítico (CPM), em dias úteis a partir do início do projeto
  cpm_es_dias       numeric(8,2),     -- early start
  cpm_ef_dias       numeric(8,2),     -- early finish
  cpm_ls_dias       numeric(8,2),     -- late start
  cpm_lf_dias       numeric(8,2),     -- late finish
  cpm_folga_dias    numeric(8,2),     -- folga total (slack)
  cpm_critica       boolean NOT NULL DEFAULT false,
  cpm_calculado_em  timestamptz,
  cpm_es_data       date,             -- datas de calendário equivalentes a es/ef/ls/lf (calculadas a partir do calendário útil)
  cpm_ef_data       date,
  cpm_ls_data       date,
  cpm_lf_data       date,

  observacoes       text,
  eh_atividade_master boolean NOT NULL DEFAULT false,  -- marca esta atividade como um dos entregáveis mestres do
                                       -- projeto (ex: "Folha definitiva") — usado pelo Relatório Executivo (IA)
                                       -- para calcular previsão de conclusão e priorizar o diagnóstico
  criado_em         timestamptz NOT NULL DEFAULT now(),
  atualizado_em     timestamptz NOT NULL DEFAULT now(),

  CHECK (dtfim_prev IS NULL OR dtini_prev IS NULL OR dtfim_prev >= dtini_prev),
  CHECK (dtfim_real IS NULL OR dtini_real IS NULL OR dtfim_real >= dtini_real)
);
CREATE INDEX idx_atividades_projeto ON atividades(projeto_id);
CREATE INDEX idx_atividades_etapa ON atividades(etapa_id);
CREATE INDEX idx_atividades_frente ON atividades(frente_trabalho_id);
CREATE INDEX idx_atividades_pai ON atividades(atividade_pai_id);
CREATE INDEX idx_atividades_status ON atividades(status);
CREATE INDEX idx_atividades_dtfim_prev ON atividades(dtfim_prev);
CREATE INDEX idx_atividades_dtini_prev ON atividades(dtini_prev);
CREATE INDEX idx_atividades_origem_importacao ON atividades(projeto_id, origem_importacao_id);
CREATE INDEX idx_atividades_master ON atividades(projeto_id) WHERE eh_atividade_master = true;
CREATE TRIGGER trg_atividades_atualizado_em BEFORE UPDATE ON atividades
  FOR EACH ROW EXECUTE FUNCTION set_atualizado_em();
COMMENT ON TABLE atividades IS 'Atividade elementar do cronograma. atividade_pai_id permite desdobrar uma atividade em subatividades quando necessário (WBS).';
COMMENT ON COLUMN atividades.cpm_folga_dias IS 'Folga total calculada pelo método do caminho crítico; 0 = atividade crítica.';
COMMENT ON COLUMN atividades.requisito_tr_id IS 'Item do Termo de Referência ao qual esta atividade se relaciona (opcional). Subatividades herdam do pai na criação.';

-- Histórico de mudança de status (auditoria automática via trigger)
CREATE TABLE historico_status_atividade (
  id              bigserial PRIMARY KEY,
  atividade_id    uuid NOT NULL REFERENCES atividades(id) ON DELETE CASCADE,
  status_anterior status_atividade_enum,
  status_novo     status_atividade_enum NOT NULL,
  alterado_em     timestamptz NOT NULL DEFAULT now(),
  alterado_por    text
);
CREATE INDEX idx_historico_atividade ON historico_status_atividade(atividade_id);

CREATE OR REPLACE FUNCTION registrar_historico_status_atividade() RETURNS trigger AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
    INSERT INTO historico_status_atividade(atividade_id, status_anterior, status_novo, alterado_por)
    VALUES (NEW.id, CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END, NEW.status,
            current_setting('app.usuario_atual', true));
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_atividades_historico
  AFTER INSERT OR UPDATE ON atividades
  FOR EACH ROW EXECUTE FUNCTION registrar_historico_status_atividade();

-- Relatos de andamento (consultores/cliente) — log temporal, append-only (sem UPDATE/DELETE pela aplicação).
-- Toda atividade com status diferente de "Não iniciada"/"Concluída" precisa ter ao menos um relato
-- (regra aplicada no backend). Quando eh_pendencia = true, guarda quem precisa resolver, um prazo
-- possível e uma data limite — insumo para futuras análises/relatórios executivos (IA analisa, não decide).
CREATE TABLE atividade_relato (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  atividade_id              uuid NOT NULL REFERENCES atividades(id) ON DELETE CASCADE,
  autor_id                  uuid REFERENCES recursos(id),      -- autor cadastrado como recurso (consultor Techne ou do cliente)
  autor_nome                text,                              -- alternativa livre, caso o autor não esteja cadastrado em recursos
  texto                     text NOT NULL,
  eh_pendencia              boolean NOT NULL DEFAULT false,
  pendencia_responsavel_id  uuid REFERENCES recursos(id),      -- obrigatório quando eh_pendencia = true
  pendencia_prazo_possivel  date,                              -- estimativa realista de resolução — obrigatório quando eh_pendencia = true
  pendencia_data_limite     date,                              -- prazo máximo tolerável — obrigatório quando eh_pendencia = true
  pendencia_resolvida       boolean NOT NULL DEFAULT false,
  pendencia_resolvida_em    timestamptz,
  criado_em                 timestamptz NOT NULL DEFAULT now(),
  CHECK (NOT eh_pendencia OR (pendencia_responsavel_id IS NOT NULL AND pendencia_prazo_possivel IS NOT NULL AND pendencia_data_limite IS NOT NULL))
);
CREATE INDEX idx_relato_atividade ON atividade_relato(atividade_id, criado_em DESC);
CREATE INDEX idx_relato_pendencia_aberta ON atividade_relato(atividade_id) WHERE eh_pendencia AND NOT pendencia_resolvida;
COMMENT ON TABLE atividade_relato IS 'Registro temporal (append-only) de relatos de andamento — insumo futuro para análise de IA e relatórios executivos (a IA analisa e sugere, não decide/coordena).';

-- ============================================================================
-- 7. DEPENDÊNCIAS ENTRE ATIVIDADES  (grafo usado no cálculo do caminho crítico)
-- ============================================================================
CREATE TABLE atividade_dependencia (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  atividade_id      uuid NOT NULL REFERENCES atividades(id) ON DELETE CASCADE,  -- sucessora
  predecessora_id   uuid NOT NULL REFERENCES atividades(id) ON DELETE CASCADE,
  tipo              tipo_dependencia_enum NOT NULL DEFAULT 'FS',
  lag_horas         numeric(8,2) NOT NULL DEFAULT 0,   -- tempo de espera adicional (pode ser negativo p/ antecipação)
  CHECK (atividade_id <> predecessora_id),
  UNIQUE (atividade_id, predecessora_id)
);
CREATE INDEX idx_dep_atividade ON atividade_dependencia(atividade_id);
CREATE INDEX idx_dep_predecessora ON atividade_dependencia(predecessora_id);
COMMENT ON TABLE atividade_dependencia IS 'Arestas do grafo de precedência. tipo/lag seguem a convenção clássica de CPM (FS, SS, FF, SF + lag).';

-- ============================================================================
-- 8. ALOCAÇÃO DE RECURSOS EM ATIVIDADES (N:N — quantos responsáveis forem necessários)
-- ============================================================================
-- Desde a migração 012, esta é a ÚNICA fonte de "quem participa/executa" uma
-- atividade — os antigos campos fixos atividades.responsavel_techne_id /
-- responsavel_cliente_id (um só de cada lado) foram removidos. Uma atividade
-- pode ter quantos participantes forem necessários, de qualquer tipo de
-- vínculo (ex: uma reunião gerencial com 4 pessoas da Techne e 5 do cliente).
-- Editável na aba "Responsáveis" do modal da atividade (ver frontend/index.html
-- e as rotas /api/atividades/<id>/recursos em backend/app/main.py). É também
-- esta lista que decide quem vê a atividade em "Minhas atividades" — cada
-- participante aponta e confirma as PRÓPRIAS horas lá, de forma independente
-- dos demais (ver seção 18 abaixo) — sem que isso altere o previsto/realizado
-- da atividade aqui no Cronograma (`atividades.prazo_horas`/`horas_realizadas`
-- continuam sendo um número único, editado à parte, igual para a atividade
-- inteira independente de quantos participaram ou de quantas horas cada um
-- apontou individualmente).
CREATE TABLE atividade_recurso (
  atividade_id    uuid NOT NULL REFERENCES atividades(id) ON DELETE CASCADE,
  recurso_id      uuid NOT NULL REFERENCES recursos(id) ON DELETE CASCADE,
  papel_na_atividade text,           -- "Executor", "Revisor", "Aprovador"
  horas_alocadas  numeric(8,2),
  PRIMARY KEY (atividade_id, recurso_id)
);

-- ============================================================================
-- 9. CICLOS DE MIGRAÇÃO  (execuções semanais — extração/carga/rejeições)
-- ============================================================================
CREATE TABLE ciclos_migracao (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  atividade_id          uuid NOT NULL REFERENCES atividades(id) ON DELETE CASCADE,
  numero_ciclo          int NOT NULL,
  data_execucao         date NOT NULL,
  qtd_registros_extraidos int,
  qtd_registros_carregados int,
  qtd_rejeicoes         int,
  percentual_rejeicao   numeric(5,2) GENERATED ALWAYS AS (
    CASE WHEN qtd_registros_extraidos > 0
         THEN round(100.0 * qtd_rejeicoes / qtd_registros_extraidos, 2)
         ELSE NULL END
  ) STORED,
  observacoes           text,
  criado_em             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (atividade_id, numero_ciclo)
);
COMMENT ON TABLE ciclos_migracao IS 'Uma linha por rodada semanal de migração de um tema (a atividade "pai" representa o tema, ex: Migração de Pessoas).';

-- ============================================================================
-- 10. REQUISITOS DO TERMO DE REFERÊNCIA
-- ============================================================================
CREATE TABLE requisitos_tr (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  projeto_id      uuid NOT NULL REFERENCES projetos(id) ON DELETE CASCADE,
  codigo          text NOT NULL,             -- número do item no edital, ex: "TR-014"
  titulo          text NOT NULL,
  descricao       text,                      -- texto literal do edital
  tipo_requisito  tipo_requisito_enum NOT NULL DEFAULT 'Funcional',
  modulo_origem   text,                      -- seção/módulo do TR de onde o item veio (rastreabilidade)
  frente_trabalho_id uuid REFERENCES frentes_trabalho(id),
  classificacao   classificacao_tr_enum NOT NULL DEFAULT 'Obrigatório',
  atendimento     atendimento_tr_enum NOT NULL DEFAULT 'A analisar',
  status          status_requisito_enum NOT NULL DEFAULT 'Não iniciado',
  responsavel_id  uuid REFERENCES recursos(id),
  prioridade      prioridade_enum NOT NULL DEFAULT 'Média',
  cobranca        cobranca_enum NOT NULL DEFAULT 'N/A',
  data_levantamento date,
  observacoes     text,
  criado_em       timestamptz NOT NULL DEFAULT now(),
  atualizado_em   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (projeto_id, codigo)
);
CREATE INDEX idx_requisitos_projeto ON requisitos_tr(projeto_id);
CREATE INDEX idx_requisitos_status ON requisitos_tr(status);
CREATE TRIGGER trg_requisitos_atualizado_em BEFORE UPDATE ON requisitos_tr
  FOR EACH ROW EXECUTE FUNCTION set_atualizado_em();

-- Agora que requisitos_tr existe, fecha a FK de atividades.requisito_tr_id (declarada lá em cima).
ALTER TABLE atividades ADD CONSTRAINT fk_atividades_requisito_tr FOREIGN KEY (requisito_tr_id) REFERENCES requisitos_tr(id);
CREATE INDEX idx_atividades_requisito_tr ON atividades(requisito_tr_id);

-- Rastreabilidade requisito <-> atividades que o atendem (N:N)
CREATE TABLE atividade_requisito (
  atividade_id    uuid NOT NULL REFERENCES atividades(id) ON DELETE CASCADE,
  requisito_id    uuid NOT NULL REFERENCES requisitos_tr(id) ON DELETE CASCADE,
  PRIMARY KEY (atividade_id, requisito_id)
);
COMMENT ON TABLE atividade_requisito IS 'Um requisito pode gerar várias atividades (levantamento, parametrização, migração, programação, teste) e uma atividade pode atender vários requisitos.';

-- ============================================================================
-- 11. MARCOS (milestones)
-- ============================================================================
CREATE TABLE marcos (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  projeto_id      uuid NOT NULL REFERENCES projetos(id) ON DELETE CASCADE,
  etapa_id        uuid REFERENCES etapas(id),
  nome            text NOT NULL,
  descricao       text,
  data_prevista   date NOT NULL,
  data_real       date,
  origem_importacao_id text,   -- mesmo propósito de atividades.origem_importacao_id, para marcos extraídos
                                -- de tarefas de duração zero na importação de cronograma (Excel/CSV)
  criado_em       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_marcos_origem_importacao ON marcos(projeto_id, origem_importacao_id);

-- ============================================================================
-- 12. RISCOS
-- ============================================================================
CREATE TABLE riscos (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  projeto_id      uuid NOT NULL REFERENCES projetos(id) ON DELETE CASCADE,
  descricao       text NOT NULL,
  categoria       text,
  probabilidade   nivel_risco_enum NOT NULL DEFAULT 'Médio',
  impacto         nivel_risco_enum NOT NULL DEFAULT 'Médio',
  mitigacao       text,
  responsavel_id  uuid REFERENCES recursos(id),
  status          status_risco_enum NOT NULL DEFAULT 'Aberto',
  identificado_em date NOT NULL DEFAULT CURRENT_DATE,
  atualizado_em   timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER trg_riscos_atualizado_em BEFORE UPDATE ON riscos
  FOR EACH ROW EXECUTE FUNCTION set_atualizado_em();

-- ============================================================================
-- 13. CALENDÁRIO ÚTIL (feriados/fins de semana do cliente — usado no CPM)
-- ============================================================================
CREATE TABLE calendario_util (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  projeto_id      uuid NOT NULL REFERENCES projetos(id) ON DELETE CASCADE,
  data            date NOT NULL,
  util            boolean NOT NULL DEFAULT false,
  descricao       text,      -- "Feriado municipal", "Recesso"...
  UNIQUE (projeto_id, data)
);
COMMENT ON TABLE calendario_util IS 'Exceções ao calendário padrão (seg-sex úteis). Usada para converter dias do CPM em datas de calendário reais.';

-- ============================================================================
-- 14. ANEXOS (arquivos: xls, csv, txt, pdf, ... vinculados a qualquer entidade)
-- ============================================================================
CREATE TABLE anexos (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entidade_tipo   entidade_anexo_enum NOT NULL,
  entidade_id     uuid NOT NULL,          -- id da atividade/requisito/risco/marco (FK polimórfica, validada na aplicação)
  nome_original   text NOT NULL,
  caminho_arquivo text NOT NULL,          -- caminho no armazenamento (disco/S3/MinIO)
  tipo_mime       text,
  tamanho_bytes   bigint,
  enviado_por     text,
  enviado_em      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_anexos_entidade ON anexos(entidade_tipo, entidade_id);
COMMENT ON TABLE anexos IS 'Metadados de arquivos (xls, csv, txt, pdf...) anexados a atividades, requisitos, riscos ou marcos. O conteúdo fica em disco/objeto; aqui só o caminho.';

-- ============================================================================
-- 15. RELATÓRIOS EXECUTIVOS GERADOS POR IA (Dashboard)
-- ============================================================================
-- Histórico dos relatórios executivos gerados no Dashboard — guarda o texto
-- (markdown) devolvido pela IA e também um retrato (JSON) dos dados/números
-- que foram enviados no prompt, para auditoria: qualquer diagnóstico
-- apresentado ao cliente deve poder ser rastreado até os dados de origem.
-- Ver backend/app/relatorio_executivo.py e a seção "Relatório Executivo (IA)"
-- do README.
CREATE TABLE relatorios_executivos (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  projeto_id      uuid NOT NULL REFERENCES projetos(id) ON DELETE CASCADE,
  gerado_em       timestamptz NOT NULL DEFAULT now(),
  modelo_ia       text NOT NULL,
  conteudo_md     text NOT NULL,
  dados_enviados  jsonb NOT NULL,
  gerado_por      text
);
CREATE INDEX idx_relatorios_executivos_projeto ON relatorios_executivos(projeto_id, gerado_em DESC);
COMMENT ON TABLE relatorios_executivos IS 'Histórico dos relatórios executivos gerados por IA no Dashboard — ver backend/app/relatorio_executivo.py.';

-- ============================================================================
-- 16. USUÁRIOS (login no sistema)
-- ============================================================================
-- Autocadastro aberto: qualquer pessoa acessa a tela de "Primeiro acesso /
-- Cadastro", preenche todos os campos (obrigatórios) e já sai com login
-- liberado (a própria senha digitada no cadastro). "Esqueci a senha" gera
-- uma nova senha aleatória e envia por e-mail (não é um link de
-- redefinição). Tabela independente de "recursos": nem todo usuário de
-- login é um responsável por atividades no cronograma, e vice-versa. Todos
-- os usuários autenticados têm o mesmo nível de acesso (sem perfil
-- "administrador" nesta rodada). Ver backend/app/auth.py, as rotas
-- /api/auth/* e /api/usuarios em backend/app/main.py, e a seção "Login e
-- cadastro de usuários" do README.
CREATE TABLE usuarios (
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
CREATE UNIQUE INDEX idx_usuarios_email_lower ON usuarios (lower(email));
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

-- ============================================================================
-- 17. PARÂMETROS DO SITE (identidade visual: logo e nome da empresa)
-- ============================================================================
-- Tabela "singleton" (mesma convenção de `projetos`): sem constraint de
-- banco forçando 1 linha só — a aplicação sempre lê/edita a primeira
-- linha, e cria uma linha padrão automaticamente na primeira leitura se
-- ainda não existir nenhuma. Ver Configurações > Parâmetros no frontend e
-- as rotas /api/parametros em backend/app/main.py.
--
-- O tema da página (claro/escuro/automático) NÃO fica guardado aqui: é
-- uma preferência pessoal de cada usuário, salva só no navegador dela
-- (localStorage) — não afeta o que os demais usuários veem.
CREATE TABLE parametros_site (
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

-- ============================================================================
-- 18. HORAS DIÁRIAS DA ATIVIDADE  ("Minhas atividades" — grade semanal do consultor)
-- ============================================================================
-- Quebra diária das horas previstas de uma atividade, POR RESPONSÁVEL.
-- Alimenta a página "Minhas atividades": cada usuário logado vê, numa
-- planilha, os dias úteis da semana corrente cruzados com as atividades em
-- que o profissional vinculado a ele (ver nota abaixo) é um dos participantes
-- (tabela `atividade_recurso`, seção 8) — com a hora prevista de cada dia — e
-- pode ajustar o número ou simplesmente confirmar a execução.
--
-- Desde a migração 012, a granularidade é por (atividade, recurso, dia), não
-- mais só (atividade, dia): uma atividade com N participantes (ex: uma
-- reunião gerencial com 4 pessoas da Techne e 5 do cliente) gera uma quebra
-- diária PRÓPRIA para cada participante, e cada um aponta/confirma as
-- próprias horas de forma totalmente independente dos demais — sem que isso
-- altere `atividades.prazo_horas`/`horas_realizadas`, que continuam sendo um
-- número único da atividade, editado à parte (a reunião continua
-- prevista/realizada em, por exemplo, 2h no Cronograma, não importa quantos
-- participaram nem quantas horas cada um apontou individualmente).
--
-- As linhas desta tabela são geradas automaticamente, por participante
-- (pelo backend, função garantir_dias() em backend/app/minhas_atividades.py)
-- na primeira vez que a grade da atividade é aberta por aquele participante:
-- o total de atividades.prazo_horas é dividido igualmente pelos dias úteis
-- entre dtini_prev e dtfim_prev (respeitando as exceções cadastradas em
-- calendario_util) — cada participante recebe a MESMA distribuição prevista
-- (não dividida entre eles), e cada um confirma seu próprio andamento. A
-- partir daí a geração NÃO se repete para aquele participante (mesmo que
-- prazo_horas/datas sejam editados depois por reimportação de cronograma ou
-- edição manual) — a grade diária, uma vez criada, passa a ser a fonte de
-- verdade e não deve ser sobrescrita por ajustes já feitos pelo consultor.
-- Isso é uma limitação conhecida: se o planejamento de uma atividade muda
-- muito depois que a grade já foi gerada, pode ser necessário um ajuste
-- manual dia a dia (não existe nesta rodada uma regeneração/redistribuição
-- automática).
--
-- O vínculo "usuário logado -> profissional (recursos)" NÃO é uma coluna
-- nova — é resolvido em tempo de consulta comparando o e-mail de login
-- (usuarios.email) com o e-mail cadastrado no Responsável (recursos.email),
-- ambos case-insensitive. Um usuário cujo e-mail de login não bate com
-- nenhum Responsável cadastrado simplesmente não vê nenhuma atividade nesta
-- tela (a interface avisa e orienta a cadastrar/corrigir o e-mail em
-- Configurações > Responsáveis).
CREATE TABLE atividade_horas_dia (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  atividade_id      uuid NOT NULL REFERENCES atividades(id) ON DELETE CASCADE,
  recurso_id        uuid NOT NULL REFERENCES recursos(id) ON DELETE CASCADE,
  data              date NOT NULL,
  horas_previstas   numeric(5,2) NOT NULL DEFAULT 0,
  horas_realizadas  numeric(5,2),        -- preenchido quando o consultor confirma (ajustado ou igual ao previsto)
  confirmado        boolean NOT NULL DEFAULT false,
  confirmado_em     timestamptz,
  confirmado_por    uuid REFERENCES usuarios(id),
  atualizado_em     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (atividade_id, recurso_id, data)
);
CREATE INDEX idx_horas_dia_atividade ON atividade_horas_dia(atividade_id, data);
CREATE INDEX idx_horas_dia_recurso ON atividade_horas_dia(recurso_id);
CREATE INDEX idx_horas_dia_data ON atividade_horas_dia(data);
CREATE TRIGGER trg_horas_dia_atualizado_em BEFORE UPDATE ON atividade_horas_dia
  FOR EACH ROW EXECUTE FUNCTION set_atualizado_em();
COMMENT ON TABLE atividade_horas_dia IS
  'Quebra diária das horas previstas/confirmadas de uma atividade, POR '
  'RESPONSÁVEL — alimenta a página "Minhas atividades" (grade semanal por '
  'consultor). Gerada automaticamente uma única vez por (atividade, '
  'recurso) (ver comentário acima); a partir daí é a fonte de verdade '
  'daquele participante naquela atividade, dia a dia — independente dos '
  'demais participantes da mesma atividade.';

-- Acelera o casamento usuário-logado -> profissional por e-mail (ver comentário
-- acima) — mesmo padrão do índice funcional já usado em usuarios(lower(email)).
CREATE INDEX idx_recursos_email_lower ON recursos (lower(email)) WHERE email IS NOT NULL;

-- ============================================================================
-- Views de apoio a relatórios
-- ============================================================================

CREATE VIEW vw_atividades_atrasadas AS
SELECT a.*, e.numero AS etapa_numero, e.nome AS etapa_nome, f.nome AS frente_nome,
       (SELECT string_agg(r.nome, ', ' ORDER BY r.nome)
        FROM atividade_recurso ar JOIN recursos r ON r.id = ar.recurso_id
        WHERE ar.atividade_id = a.id) AS responsaveis_nomes,
       (CURRENT_DATE - a.dtfim_prev) AS dias_atraso
FROM atividades a
JOIN etapas e ON e.id = a.etapa_id
JOIN frentes_trabalho f ON f.id = a.frente_trabalho_id
WHERE a.status NOT IN ('Concluída','Cancelada')
  AND a.dtfim_prev IS NOT NULL
  AND a.dtfim_prev < CURRENT_DATE;
COMMENT ON VIEW vw_atividades_atrasadas IS 'Atividades cujo fim previsto já passou e que não foram concluídas/canceladas.';

CREATE VIEW vw_caminho_critico AS
SELECT a.*, e.numero AS etapa_numero, e.nome AS etapa_nome, f.nome AS frente_nome,
       (SELECT string_agg(r.nome, ', ' ORDER BY r.nome)
        FROM atividade_recurso ar JOIN recursos r ON r.id = ar.recurso_id
        WHERE ar.atividade_id = a.id) AS responsaveis_nomes
FROM atividades a
JOIN etapas e ON e.id = a.etapa_id
JOIN frentes_trabalho f ON f.id = a.frente_trabalho_id
WHERE a.cpm_critica = true
ORDER BY a.cpm_es_dias;
COMMENT ON VIEW vw_caminho_critico IS 'Última foto do caminho crítico calculado (ver endpoint /api/cpm/recalcular no backend).';

CREATE VIEW vw_resumo_frente AS
SELECT f.projeto_id, f.id AS frente_trabalho_id, f.nome AS frente_nome,
       count(a.id) AS total_atividades,
       count(*) FILTER (WHERE a.status = 'Concluída') AS concluidas,
       count(*) FILTER (WHERE a.status = 'Em andamento') AS em_andamento,
       count(*) FILTER (WHERE a.status = 'Não iniciada') AS nao_iniciadas,
       count(*) FILTER (WHERE a.status NOT IN ('Concluída','Cancelada') AND a.dtfim_prev < CURRENT_DATE) AS atrasadas
FROM frentes_trabalho f
LEFT JOIN atividades a ON a.frente_trabalho_id = f.id
GROUP BY f.projeto_id, f.id, f.nome;
