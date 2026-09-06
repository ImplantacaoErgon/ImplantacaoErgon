-- ============================================================================
-- Migração 003 — Tipo do requisito (Funcional/Não Funcional) + rastreabilidade
-- de módulo de origem, usados pela importação automática a partir do
-- documento do Termo de Referência (HTML/DOCX/PDF/TXT).
-- Rode este script no SQL Editor do Supabase. Não recria nada.
-- ============================================================================

DO $$ BEGIN
  CREATE TYPE tipo_requisito_enum AS ENUM ('Funcional','Não Funcional');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

ALTER TABLE requisitos_tr
  ADD COLUMN IF NOT EXISTS tipo_requisito tipo_requisito_enum NOT NULL DEFAULT 'Funcional',
  ADD COLUMN IF NOT EXISTS modulo_origem text;
