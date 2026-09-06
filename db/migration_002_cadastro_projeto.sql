-- ============================================================================
-- Migração 002 — Cadastro completo do Projeto + import CSV de Requisitos
-- Rode este script no SQL Editor do Supabase (banco que já existe).
-- Não recria nada — só adiciona colunas/valor de enum que ainda não existem.
-- ============================================================================

ALTER TYPE entidade_anexo_enum ADD VALUE IF NOT EXISTS 'projeto';

ALTER TABLE projetos
  ADD COLUMN IF NOT EXISTS sigla text,
  ADD COLUMN IF NOT EXISTS fiscal_projeto text,
  ADD COLUMN IF NOT EXISTS gestor_projeto text,
  ADD COLUMN IF NOT EXISTS gerente_projeto_cliente text,
  ADD COLUMN IF NOT EXISTS gerente_projeto_techne text,
  ADD COLUMN IF NOT EXISTS lider_projeto_techne text,
  ADD COLUMN IF NOT EXISTS data_abertura date,
  ADD COLUMN IF NOT EXISTS data_inicio_real date,
  ADD COLUMN IF NOT EXISTS prazo_total_meses numeric(5,1);
