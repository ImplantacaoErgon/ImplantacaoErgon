-- ============================================================================
-- Migração 011 — Horas diárias da atividade ("Minhas atividades")
-- ============================================================================
-- Nova página "Minhas atividades": cada usuário logado vê, numa planilha, os
-- dias úteis da semana corrente x as atividades em que o profissional
-- vinculado a ele (por e-mail — ver comentário na tabela abaixo) é
-- Responsável Techne ou Responsável cliente, com a hora prevista de cada
-- dia — e pode ajustar o número ou simplesmente confirmar a execução.
--
-- Só ADITIVA: cria a tabela nova e um índice de apoio em `recursos`. Não
-- altera nenhuma coluna existente. Segura para rodar sobre um banco de
-- produção já em uso (Supabase incluído) — aplique com o usuário/schema que
-- você já vem usando nas migrações anteriores.
--
-- Ver a seção "18. HORAS DIÁRIAS DA ATIVIDADE" em db/schema.sql (schema novo,
-- já inclui esta migração) e backend/app/minhas_atividades.py para o
-- detalhamento completo da regra de geração/edição/confirmação.

CREATE TABLE atividade_horas_dia (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  atividade_id      uuid NOT NULL REFERENCES atividades(id) ON DELETE CASCADE,
  data              date NOT NULL,
  horas_previstas   numeric(5,2) NOT NULL DEFAULT 0,
  horas_realizadas  numeric(5,2),
  confirmado        boolean NOT NULL DEFAULT false,
  confirmado_em     timestamptz,
  confirmado_por    uuid REFERENCES usuarios(id),
  atualizado_em     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (atividade_id, data)
);
CREATE INDEX idx_horas_dia_atividade ON atividade_horas_dia(atividade_id, data);
CREATE INDEX idx_horas_dia_data ON atividade_horas_dia(data);
CREATE TRIGGER trg_horas_dia_atualizado_em BEFORE UPDATE ON atividade_horas_dia
  FOR EACH ROW EXECUTE FUNCTION set_atualizado_em();
COMMENT ON TABLE atividade_horas_dia IS
  'Quebra diária das horas previstas/confirmadas de uma atividade — alimenta '
  'a página "Minhas atividades" (grade semanal por consultor). Gerada '
  'automaticamente uma única vez por atividade; a partir daí é a fonte de '
  'verdade daquela atividade, dia a dia.';

-- Acelera o casamento usuário-logado -> profissional por e-mail (usuarios.email
-- comparado com recursos.email, case-insensitive) — mesmo padrão do índice
-- funcional já existente em usuarios(lower(email)) desde a migration_009.
CREATE INDEX idx_recursos_email_lower ON recursos (lower(email)) WHERE email IS NOT NULL;
