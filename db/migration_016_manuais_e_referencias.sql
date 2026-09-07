-- ============================================================================
-- Migração 016 — Manuais do Sistema + Análise de Requisitos TR x Manuais
-- ============================================================================
-- Nova funcionalidade (25ª rodada de implantação): a tela "Analisar
-- Requisitos" busca, por PALAVRA-CHAVE (sem nenhuma chamada de IA — só
-- tsvector/tsquery/ts_rank/ts_headline nativos do Postgres, configuração
-- "portuguese"), referências nos manuais do sistema para o texto de cada
-- requisito do TR, sugerindo manual + página + trecho como candidato pra
-- revisão do consultor. Ver backend/app/manuais.py para a lógica de busca.
--
-- Cria três tabelas novas:
--   manuais                     — catálogo GLOBAL (não por projeto) dos PDFs
--                                  dos manuais, gravados em base64 no banco
--                                  (mesmo padrão da migração 015 — logo — e
--                                  014 — documentação: o Render de produção
--                                  não tem disco persistente entre deploys).
--   manual_paginas               — texto extraído por página de cada manual
--                                  (via pypdf, sem OCR), com uma coluna
--                                  tsvector gerada automaticamente pelo
--                                  próprio Postgres para a busca.
--   requisito_referencia_manual  — as referências (manual+página+trecho)
--                                  encontradas ou cadastradas à mão para
--                                  cada requisito do TR.
--
-- E adiciona duas colunas em requisitos_tr:
--   resposta_oficial  — texto livre, preenchido pelo consultor.
--   analisado_em      — timestamp da última execução da busca automática.
--
-- Seguro rodar a qualquer momento: só cria tabelas/colunas novas (nada
-- existente é alterado ou removido). Puramente aditivo.

BEGIN;

ALTER TABLE requisitos_tr
  ADD COLUMN IF NOT EXISTS resposta_oficial text,
  ADD COLUMN IF NOT EXISTS analisado_em timestamptz;

COMMENT ON COLUMN requisitos_tr.resposta_oficial IS
  'Resposta do consultor no processo de Análise TR x Manuais (Configurações '
  '> Manuais do Sistema / tela Analisar Requisitos) — complementa as '
  'referências encontradas automaticamente, sempre humana.';
COMMENT ON COLUMN requisitos_tr.analisado_em IS
  'Última vez que a busca por referência nos manuais (ver '
  'requisito_referencia_manual) foi executada para este requisito.';

CREATE TABLE IF NOT EXISTS manuais (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nome            text NOT NULL,
  versao          text,
  arquivo_nome    text NOT NULL,
  arquivo_mime    text NOT NULL DEFAULT 'application/pdf',
  arquivo_dados   text NOT NULL,
  tamanho_bytes   integer NOT NULL,
  paginas_total   integer NOT NULL DEFAULT 0,
  ativo           boolean NOT NULL DEFAULT true,
  enviado_em      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE manuais IS
  'Catálogo global (não por projeto) dos manuais do sistema Ergon, usados na '
  'análise de Requisitos TR x Manuais (Configurações > Manuais do Sistema).';

CREATE TABLE IF NOT EXISTS manual_paginas (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  manual_id       uuid NOT NULL REFERENCES manuais(id) ON DELETE CASCADE,
  numero_pagina   integer NOT NULL,
  texto           text NOT NULL DEFAULT '',
  busca           tsvector GENERATED ALWAYS AS (to_tsvector('portuguese', texto)) STORED,
  UNIQUE (manual_id, numero_pagina)
);
CREATE INDEX IF NOT EXISTS idx_manual_paginas_busca ON manual_paginas USING GIN (busca);
COMMENT ON TABLE manual_paginas IS
  'Texto extraído por página de cada manual (via pypdf, sem OCR), usado na '
  'busca textual (tsvector/ts_rank) da tela Analisar Requisitos.';

CREATE TABLE IF NOT EXISTS requisito_referencia_manual (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requisito_id    uuid NOT NULL REFERENCES requisitos_tr(id) ON DELETE CASCADE,
  manual_id       uuid REFERENCES manuais(id) ON DELETE SET NULL,
  manual_nome     text NOT NULL,
  pagina          integer NOT NULL,
  trecho          text,
  relevancia      real,
  origem          text NOT NULL DEFAULT 'busca' CHECK (origem IN ('busca', 'manual')),
  criado_em       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_requisito_referencia_requisito ON requisito_referencia_manual(requisito_id);
COMMENT ON TABLE requisito_referencia_manual IS
  'Referências (manual + página + trecho) encontradas ou cadastradas '
  'manualmente pra cada requisito, na tela Analisar Requisitos. '
  'origem=busca (achada pela busca por palavra-chave) ou manual (adicionada '
  'à mão pelo consultor).';

COMMIT;
