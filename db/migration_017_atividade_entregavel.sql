-- ============================================================================
-- Migração 017 — Atividade como Entregável (atrelado a faturamento)
-- ============================================================================
-- Nova funcionalidade (26ª rodada de implantação): o usuário pode marcar
-- qualquer atividade do cronograma como "Entregável" — um item atrelado a
-- faturamento (ex: "Aceite da Migração", "Aceite da programação de Grupo 10
-- da folha de pagamento", "Aceite da customização Bloco 1"). É um booleano
-- independente de `eh_atividade_master` (que continua marcando só os poucos
-- marcos mestres do projeto, usados pelo Relatório Executivo para previsão
-- de conclusão): o conjunto de entregáveis faturáveis tende a ser bem maior
-- e mais granular do que o de marcos mestres, e uma atividade pode ter as
-- duas marcações ao mesmo tempo, sem que uma implique a outra.
--
-- Por decisão do usuário, esta rodada cobre só a modelagem no cronograma
-- (a marcação em si). Valor de faturamento, número de fatura etc. ficam
-- para uma tela própria de faturamento, futura.
-- ============================================================================
BEGIN;

ALTER TABLE atividades
  ADD COLUMN IF NOT EXISTS eh_entregavel boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN atividades.eh_entregavel IS
  'Marca a atividade como um entregável atrelado a faturamento (ex: "Aceite da Migração"). '
  'Independente de eh_atividade_master. Valores de faturamento ficam para uma tela futura.';

CREATE INDEX IF NOT EXISTS idx_atividades_entregavel ON atividades(projeto_id) WHERE eh_entregavel = true;

COMMIT;
