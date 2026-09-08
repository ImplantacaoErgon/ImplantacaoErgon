-- ============================================================================
-- Migração 018 — Faturas (faturamento dos entregáveis do cronograma)
-- ============================================================================
-- Nova funcionalidade (27ª rodada de implantação): tela "Faturas", registrando
-- as notas fiscais/faturas emitidas para as atividades marcadas como
-- entregável (atividades.eh_entregavel, migração 017), com número, prazos de
-- envio/pagamento, responsável pela entrega (recurso Techne), responsável pelo
-- recebimento (recurso cadastrado ou nome livre de alguém do cliente) e
-- valores (total, impostos, líquido — calculado pelo próprio Postgres).
--
-- Também acrescenta `valor_global_contrato` em `projetos` (Configurações >
-- Dados do Projeto), pedido junto pelo usuário como referência para
-- acompanhamento de faturamento.
--
-- Puramente aditiva — pode rodar a qualquer momento, sem risco pro código
-- antigo enquanto ele ainda estiver no ar.
-- ============================================================================
BEGIN;

ALTER TABLE projetos
  ADD COLUMN IF NOT EXISTS valor_global_contrato numeric(14,2);

COMMENT ON COLUMN projetos.valor_global_contrato IS
  'Valor global do contrato, digitado direto no cadastro do projeto — referência para acompanhamento de faturamento.';

CREATE TABLE IF NOT EXISTS faturas (
  id                                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  projeto_id                          uuid NOT NULL REFERENCES projetos(id) ON DELETE CASCADE,
  atividade_id                        uuid NOT NULL REFERENCES atividades(id),
  numero_fatura                       text NOT NULL,
  data_emissao                        date,
  data_envio                          date,
  data_pagamento_previsao             date,
  data_pagamento                      date,
  descricao                           text,
  responsavel_entrega_id              uuid NOT NULL REFERENCES recursos(id),
  responsavel_recebimento_recurso_id  uuid REFERENCES recursos(id) ON DELETE SET NULL,
  responsavel_recebimento_nome        text,
  responsavel_recebimento_cargo       text,
  valor_total                         numeric(14,2) NOT NULL DEFAULT 0,
  impostos                            numeric(14,2) NOT NULL DEFAULT 0,
  valor_liquido                       numeric(14,2) GENERATED ALWAYS AS (valor_total - impostos) STORED,
  criado_em                           timestamptz NOT NULL DEFAULT now(),
  atualizado_em                       timestamptz NOT NULL DEFAULT now(),
  CHECK (responsavel_recebimento_recurso_id IS NOT NULL OR responsavel_recebimento_nome IS NOT NULL),
  UNIQUE (projeto_id, numero_fatura)
);
CREATE INDEX IF NOT EXISTS idx_faturas_projeto ON faturas(projeto_id);
CREATE INDEX IF NOT EXISTS idx_faturas_atividade ON faturas(atividade_id);

DROP TRIGGER IF EXISTS trg_faturas_atualizado_em ON faturas;
CREATE TRIGGER trg_faturas_atualizado_em BEFORE UPDATE ON faturas
  FOR EACH ROW EXECUTE FUNCTION set_atualizado_em();

COMMENT ON TABLE faturas IS 'Faturas emitidas para os entregáveis do cronograma (atividades.eh_entregavel = true), com prazos de envio/pagamento e valores. valor_liquido é sempre valor_total - impostos, calculado pelo próprio Postgres.';

COMMIT;
