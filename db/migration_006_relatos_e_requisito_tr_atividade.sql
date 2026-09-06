-- ============================================================================
-- Migration 006 — Relato de andamento nas atividades + vínculo com item do TR
-- ============================================================================
-- Contexto (fase 1 da evolução "cronograma -> sinal real de execução"):
--
--  1) Toda atividade pode, opcionalmente, indicar a qual item do Termo de
--     Referência ela se relaciona (requisito_tr_id). Isso é DIFERENTE da
--     tabela atividade_requisito (N:N, "quais atividades atendem este
--     requisito") já existente para a aba "Requisitos vinculados": aqui é
--     um vínculo único e simples, pensado para uso rápido no dia a dia.
--     Subatividades (atividade_pai_id) herdam este valor do pai
--     automaticamente na criação, se não for informado explicitamente
--     (lógica no backend, não em trigger — permanece editável depois).
--
--  2) Toda atividade cujo status não seja "Não iniciada" nem "Concluída"
--     (ou seja: Em andamento, Bloqueada ou Cancelada) precisa ter ao menos
--     um relato de andamento registrado (regra aplicada no backend, ao
--     salvar a mudança de status). Os relatos ficam num log temporal
--     (append-only — a aplicação não edita nem apaga relatos já criados).
--
--  3) Um relato pode ser marcado como "pendência": nesse caso é obrigatório
--     informar responsável, um prazo possível (estimativa realista) e uma
--     data limite (prazo máximo). Isso dá insumo estruturado para, em uma
--     fase futura, uma IA analisar o histórico de relatos e gerar relatórios
--     executivos com grau de importância/recomendações — sem que a IA
--     decida ou coordene o projeto, apenas analise e sinalize para os
--     gestores humanos decidirem.
--
-- Esta migration é aditiva: bancos que já rodaram as migrations 002 a 005
-- podem aplicar esta com segurança, sem perda de dados.
-- ============================================================================

ALTER TABLE atividades ADD COLUMN IF NOT EXISTS requisito_tr_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'fk_atividades_requisito_tr'
  ) THEN
    ALTER TABLE atividades
      ADD CONSTRAINT fk_atividades_requisito_tr FOREIGN KEY (requisito_tr_id) REFERENCES requisitos_tr(id);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_atividades_requisito_tr ON atividades(requisito_tr_id);

COMMENT ON COLUMN atividades.requisito_tr_id IS 'Item do Termo de Referência ao qual esta atividade se relaciona (opcional). Subatividades herdam do pai na criação.';

CREATE TABLE IF NOT EXISTS atividade_relato (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  atividade_id              uuid NOT NULL REFERENCES atividades(id) ON DELETE CASCADE,
  autor_id                  uuid REFERENCES recursos(id),
  autor_nome                text,
  texto                     text NOT NULL,
  eh_pendencia              boolean NOT NULL DEFAULT false,
  pendencia_responsavel_id  uuid REFERENCES recursos(id),
  pendencia_prazo_possivel  date,
  pendencia_data_limite     date,
  pendencia_resolvida       boolean NOT NULL DEFAULT false,
  pendencia_resolvida_em    timestamptz,
  criado_em                 timestamptz NOT NULL DEFAULT now(),
  CHECK (NOT eh_pendencia OR (pendencia_responsavel_id IS NOT NULL AND pendencia_prazo_possivel IS NOT NULL AND pendencia_data_limite IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_relato_atividade ON atividade_relato(atividade_id, criado_em DESC);
CREATE INDEX IF NOT EXISTS idx_relato_pendencia_aberta ON atividade_relato(atividade_id) WHERE eh_pendencia AND NOT pendencia_resolvida;

COMMENT ON TABLE atividade_relato IS 'Registro temporal (append-only) de relatos de andamento — insumo futuro para análise de IA e relatórios executivos (a IA analisa e sugere, não decide/coordena).';
