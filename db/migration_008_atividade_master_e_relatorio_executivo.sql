-- Suporte ao "Relatório Executivo" gerado por IA no Dashboard:
--
-- 1) atividades.eh_atividade_master — flag manual (checkbox no formulário de
--    atividade) para marcar qual (ou quais) atividade(s) representam o
--    "entregável mestre" do projeto (ex: "Folha definitiva"). O relatório
--    executivo usa essas atividades para calcular uma previsão de conclusão
--    e destacar o diagnóstico delas com prioridade.
--
-- 2) relatorios_executivos — histórico dos relatórios já gerados. Guarda o
--    texto (markdown) devolvido pela IA e também um retrato (JSON) dos
--    dados/números que foram enviados para gerá-lo — isso permite auditar
--    depois exatamente em cima de que informação o relatório foi escrito
--    (importante num projeto de órgão público: qualquer diagnóstico
--    apresentado ao cliente deve poder ser rastreado até os dados de origem).
--    Ver backend/app/relatorio_executivo.py e a seção "Relatório Executivo
--    (IA)" do README.

ALTER TABLE atividades ADD COLUMN IF NOT EXISTS eh_atividade_master boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN atividades.eh_atividade_master IS 'Marca esta atividade como um dos entregáveis mestres do projeto (ex: "Folha definitiva") — usado pelo Relatório Executivo (IA) para calcular previsão de conclusão e priorizar o diagnóstico. Marcação manual, feita no formulário da atividade.';

CREATE INDEX IF NOT EXISTS idx_atividades_master ON atividades(projeto_id) WHERE eh_atividade_master = true;

CREATE TABLE IF NOT EXISTS relatorios_executivos (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  projeto_id      uuid NOT NULL REFERENCES projetos(id) ON DELETE CASCADE,
  gerado_em       timestamptz NOT NULL DEFAULT now(),
  modelo_ia       text NOT NULL,        -- id do modelo usado (ex: "claude-sonnet-4-5-20250929") — registrado para
                                          -- rastreabilidade, já que a qualidade/estilo do texto pode variar entre modelos
  conteudo_md     text NOT NULL,        -- relatório em markdown, como devolvido pela IA
  dados_enviados  jsonb NOT NULL,       -- retrato dos dados/números calculados que foram enviados no prompt (auditoria)
  gerado_por      text                  -- e-mail/identificação de quem clicou em "Gerar" (se disponível)
);
CREATE INDEX IF NOT EXISTS idx_relatorios_executivos_projeto ON relatorios_executivos(projeto_id, gerado_em DESC);
COMMENT ON TABLE relatorios_executivos IS 'Histórico dos relatórios executivos gerados por IA no Dashboard — ver backend/app/relatorio_executivo.py.';
