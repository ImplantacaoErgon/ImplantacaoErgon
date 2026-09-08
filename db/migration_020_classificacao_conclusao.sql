-- ============================================================================
-- Migração 020 — classificação automática de conclusão (29ª rodada)
-- Rode este script no SQL Editor do Supabase. Não recria nada.
-- ============================================================================
--
-- Contexto: na 28ª rodada, o sistema passou a impedir gravar uma atividade
-- num estado contraditório entre Status/percentual_concluido/Fim Real, mas
-- ficou faltando a parte que o usuário pediu desde o início — classificar
-- AUTOMATICAMENTE uma atividade concluída conforme ela terminou dentro ou
-- fora do prazo, e dentro ou acima do esforço previsto. Esta migração
-- acrescenta o vocabulário novo (3 valores a mais no enum de Status; a
-- classificação "no prazo e no esforço" continua sendo o valor 'Concluída'
-- já existente, sem renomear nada) e atualiza as views de apoio a relatório
-- para reconhecerem a família toda de status concluídos, não só o literal
-- 'Concluída'. O cálculo em si (qual das 4 variantes vale) é feito pela
-- aplicação (main.py/classificar_conclusao), na hora de salvar — ver
-- comentário em schema.sql.
--
-- 1) Vocabulário novo do enum de Status.
--    ALTER TYPE ... ADD VALUE não pode ficar dentro de um bloco de
--    transação explícito junto de outros comandos que já usem o valor novo
--    (mesma restrição de que a migração 004 já tratava para prioridade_enum
--    'Urgente') — por isso os três ALTER TYPE ficam soltos, sem BEGIN/COMMIT
--    ao redor do arquivo inteiro.
-- Os três ficam ancorados em 'Concluída' (valor já existente antes desta
-- migração), nunca uns nos outros, para não esbarrar na restrição do
-- Postgres de não poder referenciar, na mesma transação, um valor de enum
-- que também acabou de ser adicionado nela.
ALTER TYPE status_atividade_enum ADD VALUE IF NOT EXISTS 'Concluída com atraso e esforço maior' AFTER 'Concluída';
ALTER TYPE status_atividade_enum ADD VALUE IF NOT EXISTS 'Concluída com esforço maior' AFTER 'Concluída';
ALTER TYPE status_atividade_enum ADD VALUE IF NOT EXISTS 'Concluída com atraso' AFTER 'Concluída';

-- 2) Views de apoio a relatório — precisam parar de reconhecer só o literal
--    'Concluída' como "atividade concluída", senão uma atividade concluída
--    com atraso/esforço maior passaria a contar como "não concluída" nelas
--    (regressão, já que hoje ela conta certo como 'Concluída').
--    Aproveitado para também reconhecer o caso "atividade Não iniciada cujo
--    início previsto já passou" como atraso — antes só o Fim Previsto
--    vencido contava; uma atividade que nem começou e já deveria ter
--    começado é um atraso tão real quanto, só que mais cedo no cronograma.
CREATE OR REPLACE VIEW vw_atividades_atrasadas AS
SELECT a.*, e.numero AS etapa_numero, e.nome AS etapa_nome, f.nome AS frente_nome,
       (SELECT string_agg(r.nome, ', ' ORDER BY r.nome)
        FROM atividade_recurso ar JOIN recursos r ON r.id = ar.recurso_id
        WHERE ar.atividade_id = a.id) AS responsaveis_nomes,
       CASE
         WHEN a.status = 'Não iniciada' AND a.dtini_prev IS NOT NULL AND a.dtini_prev < CURRENT_DATE
              AND (a.dtfim_prev IS NULL OR a.dtfim_prev >= CURRENT_DATE)
           THEN CURRENT_DATE - a.dtini_prev
         ELSE CURRENT_DATE - a.dtfim_prev
       END AS dias_atraso
FROM atividades a
JOIN etapas e ON e.id = a.etapa_id
JOIN frentes_trabalho f ON f.id = a.frente_trabalho_id
WHERE a.status NOT IN ('Concluída','Concluída com atraso','Concluída com esforço maior',
                        'Concluída com atraso e esforço maior','Cancelada')
  AND (
    (a.dtfim_prev IS NOT NULL AND a.dtfim_prev < CURRENT_DATE)
    OR (a.status = 'Não iniciada' AND a.dtini_prev IS NOT NULL AND a.dtini_prev < CURRENT_DATE)
  );
COMMENT ON VIEW vw_atividades_atrasadas IS 'Atividades não concluídas/canceladas cujo fim previsto já passou, ou que nem começaram e já deveriam ter começado (início previsto no passado).';

CREATE OR REPLACE VIEW vw_resumo_frente AS
SELECT f.projeto_id, f.id AS frente_trabalho_id, f.nome AS frente_nome,
       count(a.id) AS total_atividades,
       count(*) FILTER (WHERE a.status IN ('Concluída','Concluída com atraso','Concluída com esforço maior',
                                            'Concluída com atraso e esforço maior')) AS concluidas,
       count(*) FILTER (WHERE a.status = 'Em andamento') AS em_andamento,
       count(*) FILTER (WHERE a.status = 'Não iniciada') AS nao_iniciadas,
       count(*) FILTER (
         WHERE a.status NOT IN ('Concluída','Concluída com atraso','Concluída com esforço maior',
                                 'Concluída com atraso e esforço maior','Cancelada')
           AND (
             (a.dtfim_prev IS NOT NULL AND a.dtfim_prev < CURRENT_DATE)
             OR (a.status = 'Não iniciada' AND a.dtini_prev IS NOT NULL AND a.dtini_prev < CURRENT_DATE)
           )
       ) AS atrasadas
FROM frentes_trabalho f
LEFT JOIN atividades a ON a.frente_trabalho_id = f.id
GROUP BY f.projeto_id, f.id, f.nome;

-- 3) Nada a corrigir em dados existentes nesta migração — toda atividade já
--    gravada como 'Concluída' continua válida (é exatamente a variante "no
--    prazo e no esforço previsto"/"sem informação suficiente pra saber
--    outra coisa"); a aplicação só passa a reclassificar automaticamente a
--    partir da próxima vez que cada atividade for salva pela tela.
