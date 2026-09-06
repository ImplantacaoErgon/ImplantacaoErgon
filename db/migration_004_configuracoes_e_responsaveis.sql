-- ============================================================================
-- Migração 004 — Tela de Configurações (CRUD de Responsável, Etapa, Frente de
-- Trabalho e Tipo de Atividade Elementar), prioridade "Urgente", e separação
-- de Responsável Techne / Responsável cliente no cronograma.
-- Rode este script no SQL Editor do Supabase. Não recria nada.
-- ============================================================================

-- 1. Prioridade "Urgente" (mais grave que "Alta")
ALTER TYPE prioridade_enum ADD VALUE IF NOT EXISTS 'Urgente' BEFORE 'Alta';

-- 2. Responsáveis: classificação fixa (tipo_vinculo) + empresa vira texto livre
--    + cargo (renomeado de "papel") + telefone.
DO $$ BEGIN
  CREATE TYPE tipo_vinculo_enum AS ENUM ('Techne','Cliente','Terceirizado');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

ALTER TABLE recursos ADD COLUMN IF NOT EXISTS tipo_vinculo tipo_vinculo_enum;
UPDATE recursos SET tipo_vinculo = empresa::text::tipo_vinculo_enum
  WHERE tipo_vinculo IS NULL;
ALTER TABLE recursos ALTER COLUMN tipo_vinculo SET DEFAULT 'Techne';
ALTER TABLE recursos ALTER COLUMN tipo_vinculo SET NOT NULL;

-- empresa passa a ser o nome real da empresa/instituição (texto livre),
-- não mais restrito a 'Techne'/'Cliente'. Os valores existentes continuam
-- como estavam ("Techne"/"Cliente" literais) — edite-os na tela de
-- Configurações > Responsáveis para colocar o nome real de cada empresa,
-- se quiser mais precisão (ex: o nome do órgão, ou de uma terceirizada).
ALTER TABLE recursos ALTER COLUMN empresa DROP NOT NULL;
ALTER TABLE recursos ALTER COLUMN empresa TYPE text USING empresa::text;

ALTER TABLE recursos RENAME COLUMN papel TO cargo;
ALTER TABLE recursos ADD COLUMN IF NOT EXISTS telefone text;

COMMENT ON TABLE recursos IS 'Pessoas responsáveis (consultores Techne, terceirizados, analistas/gestores do cliente). tipo_vinculo classifica o lado; empresa guarda o nome real da empresa/instituição.';

-- 3. Frentes de trabalho e tipos de atividade elementar ganham "ativo", para
--    permitir "aposentar" um item sem quebrar atividades já lançadas nele.
ALTER TABLE frentes_trabalho ADD COLUMN IF NOT EXISTS ativo boolean NOT NULL DEFAULT true;
ALTER TABLE tipos_atividade_elementar ADD COLUMN IF NOT EXISTS ativo boolean NOT NULL DEFAULT true;

-- 4. Atividades: separa Responsável Techne (era só "responsavel_id") de um
--    novo Responsável cliente (contraparte que valida/participa).
ALTER TABLE atividades RENAME COLUMN responsavel_id TO responsavel_techne_id;
ALTER TABLE atividades ADD COLUMN IF NOT EXISTS responsavel_cliente_id uuid REFERENCES recursos(id);

-- 5. Views que dependiam de atividades.responsavel_id precisam ser recriadas
--    (o rename da coluna muda o que "a.*" expande, então CREATE OR REPLACE
--    não basta — precisa dropar e recriar).
DROP VIEW IF EXISTS vw_atividades_atrasadas;
DROP VIEW IF EXISTS vw_caminho_critico;

CREATE VIEW vw_atividades_atrasadas AS
SELECT a.*, e.numero AS etapa_numero, e.nome AS etapa_nome, f.nome AS frente_nome,
       rt.nome AS responsavel_techne_nome, rc.nome AS responsavel_cliente_nome,
       (CURRENT_DATE - a.dtfim_prev) AS dias_atraso
FROM atividades a
JOIN etapas e ON e.id = a.etapa_id
JOIN frentes_trabalho f ON f.id = a.frente_trabalho_id
LEFT JOIN recursos rt ON rt.id = a.responsavel_techne_id
LEFT JOIN recursos rc ON rc.id = a.responsavel_cliente_id
WHERE a.status NOT IN ('Concluída','Cancelada')
  AND a.dtfim_prev IS NOT NULL
  AND a.dtfim_prev < CURRENT_DATE;
COMMENT ON VIEW vw_atividades_atrasadas IS 'Atividades cujo fim previsto já passou e que não foram concluídas/canceladas.';

CREATE VIEW vw_caminho_critico AS
SELECT a.*, e.numero AS etapa_numero, e.nome AS etapa_nome, f.nome AS frente_nome,
       rt.nome AS responsavel_techne_nome, rc.nome AS responsavel_cliente_nome
FROM atividades a
JOIN etapas e ON e.id = a.etapa_id
JOIN frentes_trabalho f ON f.id = a.frente_trabalho_id
LEFT JOIN recursos rt ON rt.id = a.responsavel_techne_id
LEFT JOIN recursos rc ON rc.id = a.responsavel_cliente_id
WHERE a.cpm_critica = true
ORDER BY a.cpm_es_dias;
COMMENT ON VIEW vw_caminho_critico IS 'Última foto do caminho crítico calculado (ver endpoint /api/cpm/recalcular no backend).';

-- Observação: o enum antigo "empresa_recurso_enum" fica sem uso depois desta
-- migração (a coluna que o usava agora é texto). Não é removido aqui de
-- propósito — DROP TYPE em produção é seguro só depois de confirmar que
-- nada mais referencia ele; deixar órfão não causa nenhum problema.
