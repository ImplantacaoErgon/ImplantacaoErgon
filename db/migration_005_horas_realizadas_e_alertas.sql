-- ============================================================================
-- Migration 005 — Horas realizadas na atividade
-- ============================================================================
-- Contexto: o cronograma já guardava "prazo_horas" (quanto se planejou gastar
-- em cada atividade), mas não havia como registrar quanto foi efetivamente
-- gasto na execução. Como a execução real pode ficar acima ou abaixo do
-- planejado, esta migration adiciona uma coluna separada para o valor
-- realizado, permitindo comparar previsto x realizado por atividade e,
-- agregado, por responsável (ver relatório "Horas por responsável" no
-- Dashboard, calculado no frontend a partir dos dados já carregados).
--
-- Esta migration é aditiva e não remove nem renomeia nada: bancos que já
-- rodaram as migrations 002, 003 e 004 podem aplicar esta com segurança.
-- ============================================================================

ALTER TABLE atividades ADD COLUMN IF NOT EXISTS horas_realizadas numeric(8,2);

COMMENT ON COLUMN atividades.prazo_horas IS 'Horas previstas (estimativa de esforço planejada).';
COMMENT ON COLUMN atividades.horas_realizadas IS 'Horas efetivamente gastas na execução — pode ficar acima ou abaixo do previsto.';
