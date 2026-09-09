-- ============================================================================
-- Migração 021 — Log de Auditoria (32ª rodada)
-- Rode este script no SQL Editor do Supabase. Só cria coisa nova — não
-- mexe em nenhuma tabela existente, então pode rodar numa transação só,
-- sem a pegadinha de enum das migrações 020a/020b.
-- ============================================================================
--
-- Contexto: o usuário pediu um "log do sistema" — quem entrou, o que fez,
-- uma auditoria. A ideia usada aqui: em vez de instrumentar cada uma das
-- ~30 rotas de criar/editar/excluir do sistema uma por uma, o backend já
-- canaliza quase todas elas por só 3 funções genéricas (insert_row,
-- patch_row, delete_row, em main.py) — então o gancho de auditoria entra
-- ali, cobrindo de uma vez ~16 entidades (atividades, requisitos, faturas,
-- riscos, marcos, recursos, etapas, frentes, tipos de atividade, usuários,
-- manuais, calendário, projetos) sem duplicar lógica em cada rota. Login,
-- logout e tentativa de senha errada são gravados à parte (não passam por
-- essas 3 funções — são eventos de sessão, não de dado).
--
-- Cada linha é UM salvamento (não um campo por linha) — um `UPDATE` que
-- mexeu em 3 campos gera 1 linha com os 3 no `detalhes` (jsonb) e uma
-- `descricao` já pronta juntando os três, pra não inflar a lista com uma
-- linha por campo.
CREATE TABLE log_auditoria (
  id              bigserial PRIMARY KEY,     -- sequencial simples (ordem = tempo), tabela só cresce (append-only)
  criado_em       timestamptz NOT NULL DEFAULT now(),
  usuario_id      uuid REFERENCES usuarios(id) ON DELETE SET NULL,
  usuario_nome    text,             -- snapshot do nome no momento do evento — sobrevive a usuário desativado/renomeado depois
  usuario_email   text,             -- idem, útil em login_falho (não há usuario_id quando a senha/e-mail está errado)
  projeto_id      uuid REFERENCES projetos(id) ON DELETE SET NULL,  -- NULL = evento global (recurso, tipo de atividade, usuário, manual, login/logout)
  tipo_evento     text NOT NULL,    -- 'login' | 'login_falho' | 'logout' | 'senha_redefinida' | 'criacao' | 'edicao' | 'exclusao'
  entidade        text,             -- nome da tabela afetada (ex.: 'atividades') — NULL em login/logout
  entidade_id     text,             -- id do registro afetado — NULL em login/logout
  entidade_rotulo text,             -- identificação amigável do registro no momento do evento (ex.: nome da atividade) — sobrevive a exclusão/renomeação depois
  descricao       text NOT NULL,    -- frase pronta pra exibir na lista, já com os campos alterados
  detalhes        jsonb,            -- diff estruturado {campo: {rotulo, de, para}} — pra quem quiser abrir e ver exatamente o que mudou
  sensivel        boolean NOT NULL DEFAULT false,  -- mudança crítica sinalizada (prazo empurrado, exclusão, etc.) — ver auditoria.py
  ip              text
);
COMMENT ON TABLE log_auditoria IS 'Trilha de auditoria do sistema: acessos (login/logout/tentativa malsucedida) e alterações de dados (criação/edição/exclusão), com diff campo a campo quando aplicável. Alimentada centralmente por insert_row/patch_row/delete_row (main.py) e pelas rotas de autenticação — ver auditoria.py.';

CREATE INDEX idx_log_auditoria_projeto ON log_auditoria (projeto_id, criado_em DESC);
CREATE INDEX idx_log_auditoria_entidade ON log_auditoria (entidade, entidade_id, criado_em DESC);
CREATE INDEX idx_log_auditoria_usuario ON log_auditoria (usuario_id, criado_em DESC);
CREATE INDEX idx_log_auditoria_criado_em ON log_auditoria (criado_em DESC);
