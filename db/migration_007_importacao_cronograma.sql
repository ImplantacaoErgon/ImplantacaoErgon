-- Suporte à importação de cronograma direto pela interface (Excel/CSV), com
-- reimportação segura: guarda o identificador da tarefa na planilha de
-- origem (a coluna "Id" do MS Project) em atividades e marcos, para que
-- reimportar uma versão atualizada da mesma planilha CASE com o que já
-- existe e ATUALIZE em vez de duplicar. Ver backend/app/cronograma_import.py
-- e a seção "Importar cronograma (Excel/CSV) pela interface" do README.
--
-- Atividades já cadastradas por importações anteriores (ex: via o script
-- scripts/importar_cronograma_pcr.py) não têm essa coluna preenchida ainda —
-- a própria importação faz o "match" de fallback pelo codigo_wbs (que já
-- era gravado desde o início) e preenche origem_importacao_id sozinha na
-- primeira vez que rodar por aqui, sem precisar de nenhum passo manual.

ALTER TABLE atividades ADD COLUMN IF NOT EXISTS origem_importacao_id text;
ALTER TABLE marcos ADD COLUMN IF NOT EXISTS origem_importacao_id text;

CREATE INDEX IF NOT EXISTS idx_atividades_origem_importacao ON atividades(projeto_id, origem_importacao_id);
CREATE INDEX IF NOT EXISTS idx_marcos_origem_importacao ON marcos(projeto_id, origem_importacao_id);

COMMENT ON COLUMN atividades.origem_importacao_id IS 'Id da tarefa na planilha de origem (MS Project), usado para casar a mesma atividade entre reimportações do cronograma (atualiza em vez de duplicar) — ver backend/app/cronograma_import.py. NULL se cadastrada manualmente.';
COMMENT ON COLUMN marcos.origem_importacao_id IS 'Mesmo propósito que atividades.origem_importacao_id, para marcos extraídos de tarefas de duração zero na importação de cronograma.';
