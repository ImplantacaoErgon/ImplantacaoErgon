-- ============================================================================
-- Migração 012 — Múltiplos responsáveis por atividade
-- ============================================================================
-- A pedido do usuário: uma atividade do cronograma pode ter N responsáveis
-- envolvidos (ex: uma reunião gerencial com 4 pessoas da Techne e 5 do
-- cliente), cada um apontando e confirmando as PRÓPRIAS horas em "Minhas
-- atividades" — mas sem que isso altere o previsto/realizado da atividade no
-- Cronograma (que continua sendo um número único, editado à parte: a reunião
-- continua prevista/realizada em 2h, por exemplo, não importa quantos
-- participaram nem quantas horas cada um apontou individualmente).
--
-- Os dois campos fixos `atividades.responsavel_techne_id` /
-- `responsavel_cliente_id` (um único responsável de cada lado) são
-- substituídos pela tabela `atividade_recurso` (N:N, já existente no schema
-- desde as primeiras rodadas mas nunca usada por "Minhas atividades" nem
-- exposta na interface — só a importação de cronograma MS Project a
-- alimentava, para participantes "extras" além dos dois principais).
--
-- Ver:
--  - backend/app/minhas_atividades.py — matching e apontamento por (atividade, recurso)
--  - backend/app/main.py — rotas /api/atividades/<id>/recursos (GET/POST/DELETE)
--  - frontend/index.html — aba "Responsáveis" no modal da atividade
--
-- NÃO é aditiva-somente: migra os dados dos 2 campos para atividade_recurso,
-- muda a granularidade de atividade_horas_dia (de "por atividade" para "por
-- atividade + responsável") e remove as 2 colunas antigas, recriando as 2
-- views que dependiam delas. Rode com atenção em produção — faça backup
-- antes se possível. Segura de rodar mesmo que ainda não tenha nenhum dado
-- de "Minhas atividades" confirmado (a situação da maioria dos ambientes até
-- aqui).

BEGIN;

-- 1) Migra os responsáveis já cadastrados nos 2 campos fixos para a tabela N:N.
INSERT INTO atividade_recurso (atividade_id, recurso_id)
SELECT id, responsavel_techne_id FROM atividades WHERE responsavel_techne_id IS NOT NULL
ON CONFLICT (atividade_id, recurso_id) DO NOTHING;

INSERT INTO atividade_recurso (atividade_id, recurso_id)
SELECT id, responsavel_cliente_id FROM atividades WHERE responsavel_cliente_id IS NOT NULL
ON CONFLICT (atividade_id, recurso_id) DO NOTHING;

-- 2) atividade_horas_dia precisa saber DE QUEM é cada dia apontado — até aqui
-- a grade era por atividade inteira (um único responsável implícito).
-- Backfill: usa o mesmo responsável que a atividade já tinha (Techne, senão
-- cliente) para as linhas já existentes.
ALTER TABLE atividade_horas_dia ADD COLUMN recurso_id uuid REFERENCES recursos(id) ON DELETE CASCADE;

UPDATE atividade_horas_dia hd
SET recurso_id = COALESCE(a.responsavel_techne_id, a.responsavel_cliente_id)
FROM atividades a
WHERE a.id = hd.atividade_id;

-- Linhas órfãs (atividade sem nenhum dos dois campos preenchidos — não deveria
-- acontecer, já que "Minhas atividades" só gera dias pra atividades com pelo
-- menos um responsável, mas por segurança) ficariam sem dono identificável;
-- removidas pra não travar o NOT NULL abaixo.
DELETE FROM atividade_horas_dia WHERE recurso_id IS NULL;

ALTER TABLE atividade_horas_dia ALTER COLUMN recurso_id SET NOT NULL;
ALTER TABLE atividade_horas_dia DROP CONSTRAINT atividade_horas_dia_atividade_id_data_key;
ALTER TABLE atividade_horas_dia ADD CONSTRAINT atividade_horas_dia_atividade_recurso_data_key UNIQUE (atividade_id, recurso_id, data);
CREATE INDEX idx_horas_dia_recurso ON atividade_horas_dia(recurso_id);

-- 3) Views que juntavam os 2 campos fixos por nome — precisam ser dropadas
-- antes de mexer nas colunas de que dependem, e recriadas com a lista
-- agregada de participantes.
DROP VIEW IF EXISTS vw_atividades_atrasadas;
DROP VIEW IF EXISTS vw_caminho_critico;

-- 4) Remove os 2 campos fixos de atividades — "responsável" agora vive só em atividade_recurso.
ALTER TABLE atividades DROP COLUMN responsavel_techne_id;
ALTER TABLE atividades DROP COLUMN responsavel_cliente_id;

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

COMMIT;
