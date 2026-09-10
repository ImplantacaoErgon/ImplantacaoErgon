-- ============================================================================
-- Migração 023 — adiciona o campo `objetivo` em `atividades` (19ª rodada).
-- Puramente aditiva (uma coluna nova, nullable) — não apaga nem transforma
-- nenhum dado existente.
-- ============================================================================
--
-- Contexto: além de `descricao` (texto livre sobre a atividade), o time
-- pediu um campo separado para registrar o *objetivo* dela — o que essa
-- atividade entrega/produz — como forma de ajudar a não perder de vista o
-- resultado esperado ao planejar/revisar o cronograma. Fica exibido na tela
-- de Atividades com um texto de apoio no próprio campo (placeholder),
-- sugerindo o preenchimento no estilo "o que essa atividade entrega...".

ALTER TABLE atividades ADD COLUMN objetivo text;
