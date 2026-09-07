-- ============================================================================
-- Migração 014 — documentação viva do sistema (Documento Executivo e
-- Documento Técnico), acessível em Configurações > Documentação
--
-- Contexto: o usuário pediu uma opção "Documentação" em Configurações com
-- dois documentos sempre exportáveis em PDF (via impressão do navegador):
-- um "Documento Executivo" (visão geral de negócio de todo o sistema) e um
-- "Documento Técnico" (banco de dados, relacionamentos, arquitetura). Ambos
-- descrevem o próprio Ergon PM (a ferramenta de gestão da implantação), não
-- o sistema Ergon de RH/Folha que está sendo implantado no cliente.
--
-- Guardados no banco (não fixos no código) para poderem ser atualizados sem
-- precisar de um novo deploy do frontend — ver PUT /api/documentacao/<tipo>
-- em backend/app/main.py. Convenção adotada: cada rodada de desenvolvimento
-- que mude uma funcionalidade relevante do sistema deve também atualizar o
-- conteúdo destes dois documentos (é o pedido explícito do usuário: "Esses
-- documentos devem estar sempre atualizados").
-- ============================================================================
BEGIN;

CREATE TABLE IF NOT EXISTS documentacao (
  tipo            text PRIMARY KEY CHECK (tipo IN ('executivo','tecnico')),
  titulo          text NOT NULL,
  versao          text NOT NULL DEFAULT '1.0',
  conteudo_md     text NOT NULL DEFAULT '',
  atualizado_em   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE documentacao IS
  'Conteúdo (markdown) dos dois documentos vivos do sistema, exibidos em '
  'Configurações > Documentação e exportáveis em PDF via impressão do '
  'navegador. "executivo" = visão geral de negócio; "tecnico" = banco de '
  'dados, relacionamentos e arquitetura. Devem ser atualizados a cada '
  'mudança relevante do sistema.';

DROP TRIGGER IF EXISTS trg_documentacao_atualizado_em ON documentacao;
CREATE TRIGGER trg_documentacao_atualizado_em BEFORE UPDATE ON documentacao
  FOR EACH ROW EXECUTE FUNCTION set_atualizado_em();

INSERT INTO documentacao (tipo, titulo, versao, conteudo_md) VALUES
('executivo', 'Documento Executivo', '1.0', $doc$# Ergon PM — Documento Executivo

## 1. Visão geral

O **Ergon PM** é o sistema de gestão da própria implantação do Ergon (o sistema de Gestão de Recursos Humanos e Folha de Pagamento da Techne) em órgãos públicos. Ele não é o Ergon em si — é a ferramenta que a equipe Techne e a equipe do cliente usam, juntas, para planejar, acompanhar e prestar contas de todo o projeto de implantação: cronograma, requisitos do Termo de Referência, riscos, apontamento de horas da equipe, e a comunicação executiva do andamento.

O sistema foi desenhado para ser reutilizável: cada órgão/cliente onde a Techne implanta o Ergon vira um **projeto** independente dentro do mesmo sistema, com seu próprio cronograma, sua própria equipe alocada e seus próprios requisitos — mas todos os usuários (consultores Techne, em especial) enxergam, numa única tela ("Minhas atividades"), o apontamento de horas de todos os projetos em que estão atuando ao mesmo tempo.

## 2. Conceitos-chave

Antes de descrever cada tela, vale alinhar o vocabulário usado em todo o sistema.

**Projeto** — uma implantação do Ergon em um cliente específico (ex: "Implantação Ergon — TSE"). Tem sigla, nome, instituição/cliente, datas de início e fim previstas, prazo contratual e os nomes dos principais interlocutores (fiscal do contrato, gestor do projeto, gerentes e líder técnico). Um usuário pode participar de vários projetos e trocar entre eles pelo seletor no topo da tela.

**Etapa** — as macro-fases da metodologia de implantação (ex: Etapa 1 = folha de pagamento completa, Etapa 2 = módulos isolados). Cada atividade do cronograma pertence a uma etapa.

**Frente de trabalho** — as frentes técnicas do projeto: Parametrização, Migração de Dados, Folha de Pagamento, Customizações, Contagem de Tempo, Integrações, eSocial, Portal do Servidor, Workflow, BI, Treinamentos, Gestão, entre outras. Cada atividade pertence a uma frente.

**Recurso** — qualquer pessoa envolvida no projeto: consultor Techne, analista/gestor do cliente, ou terceirizado. Um recurso pode participar de quantas atividades forem necessárias, e uma atividade pode ter quantos recursos forem necessários (não há mais o limite antigo de "um responsável Techne + um responsável do cliente"). Cada recurso tem um vínculo (Techne, Cliente ou Terceirizado), pode ou não ter e-mail de login associado (o que o conecta à tela "Minhas atividades") e tem uma marcação de **controle de horas por atividade** — só recursos com essa marca ativa podem apontar e confirmar horas no sistema.

**Atividade** — a unidade elementar do cronograma (a WBS — Estrutura Analítica do Projeto). Toda atividade pertence a uma Etapa e a uma Frente de trabalho, tem um tipo elementar (Levantamento, Parametrização, Extração, Carga, Programação, Homologação, Treinamento, Reunião etc.), datas previstas/reais de início e fim, horas previstas/realizadas, percentual concluído, status e prioridade. Atividades podem ter subatividades (hierarquia WBS), dependências entre si (para o cálculo de caminho crítico) e podem estar vinculadas a um ou mais requisitos do Termo de Referência.

**Marco** — um evento de data única (sem duração), como a entrega de um produto ou uma virada de fase.

**Requisito TR** — um item do Termo de Referência do edital, com seu código, descrição, classificação (Essencial, Obrigatório, Desejável, Customizado curto/médio/longo), como está sendo atendido (nativo, parcial, customizado, não atende) e o status do trabalho de atendê-lo. Requisitos e atividades se relacionam em N:N: um requisito pode gerar várias atividades (levantar, parametrizar, migrar, programar, testar) e uma atividade pode atender vários requisitos ao mesmo tempo.

**Risco** — um risco identificado do projeto, com probabilidade, impacto, mitigação planejada, recurso responsável e status (aberto, mitigado, encerrado).

**Relato / Pendência** — qualquer atividade pode receber relatos de andamento ao longo do tempo (um histórico, nunca apagado). Um relato pode ser marcado como **pendência**, que exige um recurso responsável, um prazo possível de resolução e uma data limite — as pendências abertas aparecem nos alertas do Dashboard.

## 3. Telas do sistema

### 3.1 Login e cadastro

O acesso é por e-mail e senha. O cadastro é **autocadastro aberto**: qualquer pessoa preenche nome, e-mail, telefone, empresa, cargo e senha, e já sai com acesso liberado — não existe aprovação prévia nem hierarquia de perfil nesta versão (todo usuário autenticado enxerga as mesmas telas). "Esqueci a senha" gera uma senha nova aleatória e a envia por e-mail (não é um link de redefinição).

### 3.2 Seleção de projeto

O cabeçalho do sistema sempre mostra o projeto ativo, com um seletor para trocar entre os projetos em que o usuário tem atividades ou acesso, e a opção de cadastrar um novo projeto. A última escolha fica lembrada no navegador do usuário.

### 3.3 Dashboard

A tela inicial, com uma visão executiva do projeto selecionado: contagem de atividades por status, atividades atrasadas (fim previsto já passado e não concluídas/canceladas), horas previstas por recurso, e alertas de prioridade (atividades urgentes sem recurso definido ou sem prazo, pendências abertas se aproximando da data limite). A partir daqui também se geram os dois relatórios do sistema:

- **Relatório Executivo (IA)** — um relatório em linguagem natural, gerado por inteligência artificial a partir dos dados reais do projeto (atividades, prazos, status, riscos, pendências), analisando ritmo de execução e propondo diagnóstico — nunca decide nada sozinho, só analisa e sugere. Fica com histórico de gerações anteriores e pode ser baixado em PDF.
- **Relatório de Horas dos Recursos** — o apontamento de horas (previsto × realizado) que cada recurso lançou em "Minhas atividades", em **todos os projetos** em que atua, filtrável por recurso e por período (datas específicas ou mês/ano), exportável em PDF ou planilha Excel (com uma aba de resumo por recurso/atividade e outra de detalhe dia a dia).

### 3.4 Cronograma

A WBS completa do projeto, em lista, com filtros por período, etapa, frente de trabalho, recurso e status, e um indicador visual de atividades atrasadas. É possível: criar/editar atividades e marcos manualmente; importar um cronograma inteiro de uma planilha Excel/CSV ou de um arquivo de MS Project (a reimportação é sempre aditiva — atualiza atividades já existentes pelo código de origem, nunca duplica nem apaga participantes já cadastrados manualmente); e remover o cronograma inteiro de uma vez, quando necessário recomeçar.

O cadastro de cada atividade é organizado em abas:
- **Detalhes** — etapa, frente, código WBS, prioridade, nome, descrição, tipo elementar, item do TR vinculado, status e percentual concluído.
- **Recursos** — a lista de participantes da atividade (quantos forem necessários, de qualquer vínculo), com botão de adicionar/remover. É esta lista que decide quem vê a atividade em "Minhas atividades".
- **Relatos** — o histórico de andamento da atividade, com a opção de registrar uma pendência (recurso responsável, prazo possível, data limite).
- **Dependências** — os predecessores da atividade, usados no cálculo do caminho crítico.
- **Requisitos vinculados** — quais itens do Termo de Referência esta atividade atende.
- **Anexos** — arquivos (planilhas, PDFs, documentos) relacionados à atividade.

### 3.5 Caminho Crítico

O cálculo do método do caminho crítico (CPM) sobre a rede de dependências das atividades, convertendo horas previstas em dias úteis (considerando a jornada diária configurada no projeto e o calendário de feriados/recessos cadastrado). Mostra a sequência de atividades sem folga (as que, se atrasarem, atrasam o projeto inteiro) e as datas de início/fim mais cedo e mais tarde de cada uma.

### 3.6 Requisitos TR

A lista completa de requisitos do Termo de Referência, com seus filtros (classificação, atendimento, status, frente de trabalho) e a rastreabilidade com as atividades do cronograma que os atendem. Requisitos podem ser cadastrados manualmente, importados de uma planilha CSV, ou **extraídos automaticamente** a partir do próprio documento do Termo de Referência em Word ou PDF — o sistema lê o arquivo, reconhece os itens por padrões de texto (regras, sem inteligência artificial nesta extração) e apresenta uma prévia para conferência antes de confirmar a importação.

### 3.7 Riscos & Marcos

O cadastro de riscos do projeto (probabilidade, impacto, mitigação, recurso responsável, status) e a lista de marcos (eventos de data única, previstos e realizados).

### 3.8 Minhas atividades

A tela pessoal de apontamento de horas de cada consultor: uma grade semanal com os dias úteis cruzados com todas as atividades, **de todos os projetos**, em que o recurso vinculado ao usuário logado é um dos participantes. Cada dia mostra a hora prevista (distribuída automaticamente entre os dias úteis da atividade) e permite ajustar o valor ou simplesmente confirmar a execução. Cada participante de uma atividade aponta e confirma as próprias horas, de forma totalmente independente dos demais participantes da mesma atividade — isso nunca altera o previsto/realizado da atividade no Cronograma, que continua sendo um número único, editado à parte.

Só recursos marcados com "controla horas por atividade" conseguem usar esta tela; os demais recebem uma mensagem explicando o motivo (e-mail sem recurso cadastrado, ou recurso cadastrado sem essa marca habilitada).

### 3.9 Configurações

Os cadastros base do projeto, organizados em abas:
- **Dados do Projeto** — identificação, interlocutores e prazos do projeto ativo.
- **Recursos** — o cadastro de pessoas (nome, vínculo, empresa, cargo, e-mail, telefone, controle de horas, ativo/inativo).
- **Etapas** e **Frentes de Trabalho** — o vocabulário de fases e frentes do projeto.
- **Tipos de Atividade Elementar** — o vocabulário de "tipo de trabalho" (Levantamento, Parametrização, Programação etc.), reutilizável entre frentes.
- **Usuários** — os logins do sistema (distintos dos Recursos — nem todo usuário de login é um recurso alocado em atividades, e vice-versa).
- **Parâmetros** — identidade visual do sistema (logo e nome da empresa exibidos no topo, vistos por todos os usuários).
- **Documentação** — esta e a documentação técnica do sistema, sempre disponíveis para consulta e exportação em PDF.

## 4. Regras de negócio importantes

- **Horas da atividade vs. apontamento individual**: o previsto/realizado de uma atividade no Cronograma é sempre um número único, editável manualmente a qualquer momento — nunca é somado ou recalculado a partir do apontamento diário de cada participante em "Minhas atividades". Uma reunião com 9 participantes continua prevista em, por exemplo, 2 horas no Cronograma, independentemente de cada um dos 9 apontar suas próprias 2 horas individualmente.
- **Reimportação de cronograma é sempre aditiva**: reimportar uma planilha nunca apaga participantes, relatos ou anexos já cadastrados manualmente — só atualiza os campos que vêm da própria planilha (datas, percentual concluído) e cria o que ainda não existe.
- **Controle de horas por recurso**: só recursos com essa marca habilitada podem apontar horas em "Minhas atividades" e aparecem como opção de filtro no Relatório de Horas dos Recursos — mas continuam podendo ser adicionados livremente como participantes de qualquer atividade no Cronograma, marcados ou não.
- **Acesso único**: nesta versão não existe hierarquia de perfil — todo usuário autenticado tem acesso às mesmas telas e pode editar os mesmos cadastros. Times de acesso diferenciado (ex: só leitura para o cliente) não fazem parte do sistema ainda.

## 5. Um sistema em evolução

O Ergon PM está em implantação contínua: novas funcionalidades, campos e validações são adicionadas conforme o projeto avança. Este documento é mantido atualizado a cada mudança relevante — a data e a versão no topo indicam a última revisão.$doc$),
('tecnico', 'Documento Técnico', '1.0', $doc$# Ergon PM — Documento Técnico

## 1. Como usar este documento

Este documento descreve a arquitetura, o banco de dados e as convenções técnicas do **Ergon PM** — a ferramenta de gestão da implantação do sistema Ergon (não confundir com o Ergon em si, o produto de RH/Folha da Techne que está sendo implantado no cliente). Ele é o ponto de partida para qualquer pessoa (ou IA) que vá dar manutenção, corrigir bugs ou adicionar funcionalidades ao Ergon PM, e é mantido atualizado a cada rodada de desenvolvimento.

## 2. Stack tecnológica

| Camada | Tecnologia | Observação |
|---|---|---|
| Backend | Python 3 / Flask | API REST em JSON, servida também como arquivo estático do frontend |
| Banco de dados | PostgreSQL 14+ | Acesso via subprocess `psql` (ver seção 5), não via driver Python |
| Frontend | HTML + JavaScript puro (vanilla), um único arquivo `index.html` | Sem framework (React/Vue) nem build step — SPA por troca de visibilidade de `<section class="view">` |
| Geração de PDF | ReportLab | Relatório Executivo e Relatório de Horas dos Recursos |
| Geração de planilha | openpyxl | Relatório de Horas dos Recursos e exportações |
| Leitura de Word/PDF | python-docx, pypdf | Extração automática de requisitos do Termo de Referência |
| Cálculo de caminho crítico | NetworkX | Grafo de dependências entre atividades |
| Inteligência artificial | API da Anthropic (Claude) | Só no Relatório Executivo — analisa dados reais e escreve o diagnóstico em texto |
| Autenticação | Flask session (cookie assinado) + werkzeug.security | Sem JWT, sem OAuth — sessão de servidor tradicional |
| Deploy | Render (aplicação) + Supabase (Postgres gerenciado) | Também roda localmente via Docker Compose |

## 3. Arquitetura geral

O backend é organizado em módulos dentro de `backend/app/`, cada um com uma responsabilidade:

| Módulo | Responsabilidade |
|---|---|
| `main.py` | Todas as rotas HTTP da API (~65 rotas), validação de payload, orquestração entre módulos |
| `db.py` | Camada de acesso ao banco (ver seção 5) |
| `auth.py` | Autenticação, cadastro, hash de senha, "esqueci a senha" via e-mail |
| `cpm.py` | Cálculo do caminho crítico (CPM) |
| `cronograma_import.py` | Importação de cronograma via Excel/CSV/MS Project |
| `tr_parser.py` | Extração automática de requisitos a partir de documentos do Termo de Referência (.docx/.pdf) |
| `minhas_atividades.py` | Regras da tela "Minhas atividades": geração da grade diária, autorização por recurso, ajuste/confirmação de horas |
| `relatorio_executivo.py` | Coleta de dados do projeto e chamada à IA (Anthropic) para o Relatório Executivo |
| `relatorio_pdf.py` | Montagem do PDF do Relatório Executivo |
| `relatorio_atividades.py` | Coleta de dados e montagem de PDF/planilha do Relatório de Horas dos Recursos |

O frontend é um único arquivo (`frontend/index.html`, ~3000 linhas) com HTML, CSS e JavaScript embutidos — sem framework nem etapa de build. A navegação entre telas é feita alternando a visibilidade de blocos `<section class="view" id="view-...">`; o estado da aplicação vive em variáveis JavaScript globais (`PROJETO`, `ATIVIDADES`, `RECURSOS`, `ETAPAS`, `FRENTES` etc.), recarregadas da API a cada troca de projeto. Chamadas à API passam por uma função utilitária `api(caminho, opções)` que já injeta cabeçalhos e trata erros de forma padronizada. O tema da interface (claro/escuro/automático) é uma preferência salva só no navegador de cada usuário (`localStorage`), não no banco.

## 4. Autenticação e autorização

- Login é feito por e-mail/senha; a senha é validada com `werkzeug.security.check_password_hash` contra o hash salvo em `usuarios.senha_hash` (nunca se guarda senha em texto puro).
- A sessão é um **cookie Flask assinado** com `SECRET_KEY` (variável de ambiente obrigatória em produção — há um valor padrão inseguro só para não quebrar ambientes de desenvolvimento sem configuração, com aviso no log). O cookie guarda `usuario_id`.
- `before_request` (`exigir_login()` em `main.py`) bloqueia qualquer rota `/api/...` sem sessão ativa, exceto as rotas de login/cadastro/esqueci-senha (`AUTH_ROTAS_PUBLICAS`). As rotas do frontend estático (`/`, `/<path>`) nunca são bloqueadas — o próprio JavaScript decide mostrar a tela de login ou o sistema, consultando `GET /api/auth/me`.
- **Não existe hierarquia de perfil**: todo usuário autenticado tem acesso de leitura/escrita às mesmas rotas e telas. Um controle de permissões por papel (admin/consultor/cliente-leitura) ainda não foi implementado.
- "Esqueci a senha" gera uma senha nova, salva o hash e a envia em texto puro por e-mail via `smtplib` (SMTP configurado por variáveis de ambiente `SMTP_*`) — sem SMTP configurado, a funcionalidade fica indisponível com mensagem de erro clara, o resto do sistema funciona normalmente.

## 5. Acesso ao banco de dados

`backend/app/db.py` **não usa um driver Python de Postgres** (nem psycopg2, nem psycopg3, nem um ORM). Em vez disso, chama o cliente de linha de comando `psql` via `subprocess`, passando o SQL pela entrada padrão e recebendo o resultado como texto — cada `SELECT` é embrulhado numa consulta que devolve `json_agg(row_to_json(...))`, e o backend faz `json.loads()` no texto de volta. Essa escolha evita depender de um driver compilado (o que simplifica bastante o Dockerfile/deploy), ao custo de uma latência um pouco maior por chamada e da necessidade do pacote `postgresql-client` estar instalado no ambiente que roda o backend.

A interface pública de `db.py` tem quatro funções: `fetch_all(sql)`, `fetch_one(sql)`, `execute(sql)` e `execute_returning_one(sql, prelude="")` — esta última é usada quando o SQL precisa gravar um `RETURNING *` (ex: criar/editar um registro e devolver a linha resultante ao frontend) e aceita um `prelude` para rodar um `SET LOCAL` na mesma transação (usado para registrar o autor de uma mudança de status antes do `UPDATE` que dispara o trigger de histórico). A função `db.q(valor)` faz o escaping seguro de qualquer valor Python para literal SQL (incluindo dollar-quoting de texto), usada em toda concatenação de SQL do backend.

## 6. Banco de dados — tabelas e relacionamentos

O diagrama conceitual da hierarquia principal:

```
projetos
  └─ etapas
  └─ frentes_trabalho
  └─ atividades (etapa_id, frente_trabalho_id, tipo_atividade_elementar_id, atividade_pai_id)
       ├─ atividade_recurso (N:N com recursos)
       ├─ atividade_dependencia (grafo de precedência, para o CPM)
       ├─ atividade_requisito (N:N com requisitos_tr)
       ├─ atividade_relato (histórico de andamento / pendências)
       ├─ atividade_horas_dia (apontamento diário, por recurso — "Minhas atividades")
       ├─ historico_status_atividade (auditoria automática via trigger)
       └─ ciclos_migracao (execuções semanais de migração de dados)
  └─ requisitos_tr
  └─ marcos
  └─ riscos
  └─ calendario_util (feriados/exceções, usado no CPM)
  └─ relatorios_executivos (histórico dos relatórios de IA)
anexos (FK polimórfica: atividade | requisito | risco | marco | projeto)
recursos (global, sem projeto_id — a mesma pessoa atua em vários projetos)
usuarios (global, login — independente de recursos)
parametros_site (singleton, identidade visual)
documentacao (singleton por tipo — este documento e o Documento Executivo)
```

### 6.1 Tabelas principais

**`projetos`** — uma implantação por linha. Campos-chave: `sigla`, `nome`, `cliente`, os cinco campos de interlocutores (`fiscal_projeto`, `gestor_projeto`, `gerente_projeto_cliente`, `gerente_projeto_techne`, `lider_projeto_techne`), datas (`data_abertura`, `data_inicio`, `data_inicio_real`, `data_fim_prevista`), `prazo_total_meses` e `horas_dia_util` (jornada padrão usada para converter horas em dias úteis no CPM).

**`etapas`** — `projeto_id` (FK, `ON DELETE CASCADE`), `numero`, `nome`. `UNIQUE (projeto_id, numero)`.

**`frentes_trabalho`** — `projeto_id` (FK cascade), `nome`, `cor_hex` (exibição), `ordem`, `ativo` (permite "aposentar" uma frente sem quebrar atividades já lançadas nela). `UNIQUE (projeto_id, nome)`.

**`tipos_atividade_elementar`** — vocabulário global (sem `projeto_id`), `nome` único, `ordem`, `ativo`.

**`recursos`** — global (sem `projeto_id`: a mesma pessoa pode atuar em vários projetos ao mesmo tempo). Campos: `nome`, `tipo_vinculo` (enum: Techne/Cliente/Terceirizado), `empresa`, `cargo`, `email`, `telefone`, `controla_horas` (boolean, default `true` — desde a migração 013, só recursos com esta marca podem apontar horas em "Minhas atividades"), `ativo`. Índice funcional `idx_recursos_email_lower` (`lower(email)`) acelera o casamento usuário-logado → recurso por e-mail.

**`atividades`** — a tabela central. `projeto_id`, `etapa_id`, `frente_trabalho_id` (todas FK obrigatórias), `tipo_atividade_elementar_id` (FK opcional), `atividade_pai_id` (auto-FK, `ON DELETE CASCADE` — hierarquia WBS), `requisito_tr_id` (FK opcional para `requisitos_tr`, criada por `ALTER TABLE` depois que a tabela de requisitos existe, por causa da ordem de criação), `codigo_wbs` (numeração hierárquica mantida pela aplicação), `origem_importacao_id` (id da tarefa na planilha de origem, usado para casar a mesma atividade entre reimportações), `nome`, `descricao`, `prazo_horas`, `horas_realizadas`, quatro datas (`dtini_prev`, `dtfim_prev`, `dtini_real`, `dtfim_real`), `percentual_concluido` (0–100), `status` (enum), `prioridade` (enum), sete colunas de resultado do CPM (`cpm_es_dias`, `cpm_ef_dias`, `cpm_ls_dias`, `cpm_lf_dias`, `cpm_folga_dias`, `cpm_critica`, `cpm_calculado_em`, mais as quatro datas de calendário equivalentes), `observacoes`, `eh_atividade_master` (marca os entregáveis mestres do projeto, usados pelo Relatório Executivo). Não existem mais campos fixos de responsável (`responsavel_techne_id`/`responsavel_cliente_id` foram removidos na migração 012) — quem participa de uma atividade vive só em `atividade_recurso`. Índices em `projeto_id`, `etapa_id`, `frente_trabalho_id`, `atividade_pai_id`, `status`, `dtfim_prev`, `dtini_prev`, `(projeto_id, origem_importacao_id)` e um índice parcial em atividades master.

**`historico_status_atividade`** — auditoria automática (nunca escrita manualmente pela aplicação): um trigger (`trg_atividades_historico`, função `registrar_historico_status_atividade()`) grava uma linha a cada `INSERT` ou a cada vez que `status` muda num `UPDATE`, guardando o status anterior, o novo e quem alterou (lido de `current_setting('app.usuario_atual', true)`).

**`atividade_relato`** — log de andamento, append-only (sem rota de `UPDATE`/`DELETE`). `autor_id` (FK opcional a `recursos`) ou `autor_nome` (texto livre, se o autor não estiver cadastrado). Quando `eh_pendencia = true`, exige (`CHECK`) `pendencia_responsavel_id`, `pendencia_prazo_possivel` e `pendencia_data_limite` preenchidos; guarda também `pendencia_resolvida`/`pendencia_resolvida_em`.

**`atividade_dependencia`** — arestas do grafo de precedência: `atividade_id` (sucessora), `predecessora_id`, `tipo` (enum FS/SS/FF/SF — convenção clássica de CPM), `lag_horas` (pode ser negativo, para antecipação). `CHECK (atividade_id <> predecessora_id)` e `UNIQUE (atividade_id, predecessora_id)` evitam auto-referência e duplicidade.

**`atividade_recurso`** — tabela de junção N:N entre `atividades` e `recursos`, chave primária composta `(atividade_id, recurso_id)`. Também guarda `papel_na_atividade` (texto livre) e `horas_alocadas` (opcional). É a **única** fonte de "quem participa" de uma atividade desde a migração 012, e também a base de quem enxerga a atividade em "Minhas atividades".

**`ciclos_migracao`** — uma linha por rodada semanal de migração de um tema (a atividade "pai" representa o tema, ex: "Migração de Pessoas"). `numero_ciclo`, `data_execucao`, `qtd_registros_extraidos`, `qtd_registros_carregados`, `qtd_rejeicoes`, e uma coluna gerada (`GENERATED ALWAYS AS ... STORED`) `percentual_rejeicao` calculada automaticamente pelo próprio Postgres. `UNIQUE (atividade_id, numero_ciclo)`.

**`requisitos_tr`** — `projeto_id`, `codigo` (único por projeto, ex: "TR-014"), `titulo`, `descricao` (texto literal do edital), `tipo_requisito` (Funcional/Não Funcional), `modulo_origem`, `frente_trabalho_id` (opcional), `classificacao` (enum: Essencial/Imediato, Obrigatório, Desejável, Customizado Curto/Médio/Longo), `atendimento` (enum: A analisar, Nativo, Parcial, Customizado, Não atende), `status` (enum de 8 estados, de "Não iniciado" a "Aprovado"/"Rejeitado"), `responsavel_id` (FK a `recursos`), `prioridade`, `cobranca` (Sim/Não/N-A), `data_levantamento`.

**`atividade_requisito`** — junção N:N entre `atividades` e `requisitos_tr` (chave composta), a rastreabilidade requisito ↔ atividades que o atendem.

**`marcos`** — `projeto_id`, `etapa_id` (opcional), `nome`, `data_prevista` (obrigatória), `data_real` (opcional), `origem_importacao_id` (mesmo propósito do de atividades, para marcos extraídos de tarefas de duração zero na importação de cronograma).

**`riscos`** — `projeto_id`, `descricao`, `categoria`, `probabilidade`/`impacto` (enum Baixo/Médio/Alto), `mitigacao`, `responsavel_id` (FK a `recursos`), `status` (Aberto/Mitigado/Encerrado), `identificado_em`.

**`calendario_util`** — exceções ao calendário padrão (segunda a sexta úteis) por projeto: uma linha por `(projeto_id, data)` marcando se aquele dia é útil ou não (feriados, recessos). Usada para converter os deslocamentos em dias úteis do CPM em datas de calendário reais, e para a distribuição diária de horas em "Minhas atividades".

**`anexos`** — metadados de arquivo (o conteúdo fica em disco, em `backend/uploads/`; aqui só o caminho). FK **polimórfica** validada na aplicação (não no banco): `entidade_tipo` (enum: atividade/requisito/risco/marco/projeto) + `entidade_id` (uuid solto, sem `REFERENCES` de banco, porque aponta para tabelas diferentes conforme o tipo).

**`relatorios_executivos`** — histórico dos relatórios gerados por IA no Dashboard: `conteudo_md` (o texto markdown devolvido pela IA), `dados_enviados` (jsonb — um retrato fiel dos dados/números que foram enviados no prompt, para auditoria: todo diagnóstico apresentado ao cliente pode ser rastreado até a origem), `modelo_ia`, `gerado_por`.

**`usuarios`** — login do sistema, **independente** de `recursos` (nem todo usuário de login é um recurso alocado em atividades, e vice-versa — o vínculo entre os dois é resolvido em tempo de consulta comparando e-mails, nunca por uma FK). `email` (único, case-insensitive via índice funcional), `nome`, `telefone`, `empresa`, `cargo`, `senha_hash`, `recebe_relatorio_executivo`/`recebe_notificacao_whatsapp` (reservados para uso futuro — nenhum envio automático existe ainda), `ativo`, `ultimo_login_em`.

**`parametros_site`** — tabela "singleton": sem constraint de banco forçando uma linha só, mas a aplicação sempre lê/edita a primeira linha e cria uma linha padrão automaticamente na primeira leitura, se ainda não existir nenhuma. Guarda `nome_empresa` e `logo_arquivo` (nome do arquivo em `backend/uploads/`).

**`atividade_horas_dia`** — a tabela por trás de "Minhas atividades": a quebra diária das horas previstas/confirmadas de uma atividade, **por recurso** (não por atividade sozinha — desde a migração 012, a granularidade é `(atividade_id, recurso_id, data)`, com `UNIQUE` composta, corrigindo um bug latente em que dois participantes lançando no mesmo dia se sobrescreviam). Gerada automaticamente (função `garantir_dias()` em `minhas_atividades.py`) na primeira vez que a grade de uma atividade é aberta por um participante específico: `prazo_horas` da atividade é dividido igualmente pelos dias úteis entre `dtini_prev` e `dtfim_prev` (respeitando `calendario_util`); a partir daí a grade não é regenerada automaticamente, mesmo que a atividade seja editada depois (limitação conhecida — mudanças grandes de planejamento após a geração exigem ajuste manual dia a dia). Colunas: `horas_previstas`, `horas_realizadas` (preenchida na confirmação), `confirmado`, `confirmado_em`, `confirmado_por` (FK a `usuarios`).

**`documentacao`** — guarda o conteúdo (markdown) deste Documento Técnico e do Documento Executivo, cada um identificado por `tipo` (`'executivo'` ou `'tecnico'`), com `titulo`, `versao` e `atualizado_em`. Exibida em Configurações → Documentação, com exportação em PDF via impressão do navegador (`window.print()`, sem geração de PDF no backend). Ver migração 014.

### 6.2 Tipos enumerados (vocabulário fechado)

`prioridade_enum` (Urgente/Alta/Média/Baixa) · `status_atividade_enum` (Não iniciada/Em andamento/Bloqueada/Concluída/Cancelada) · `tipo_dependencia_enum` (FS/SS/FF/SF) · `classificacao_tr_enum` · `atendimento_tr_enum` · `status_requisito_enum` · `cobranca_enum` (Sim/Não/N-A) · `tipo_requisito_enum` (Funcional/Não Funcional) · `tipo_vinculo_enum` (Techne/Cliente/Terceirizado) · `nivel_risco_enum` (Baixo/Médio/Alto) · `status_risco_enum` (Aberto/Mitigado/Encerrado) · `entidade_anexo_enum` (atividade/requisito/risco/marco/projeto).

### 6.3 Views

- **`vw_atividades_atrasadas`** — atividades com `dtfim_prev` no passado e status diferente de Concluída/Cancelada, já com `responsaveis_nomes` (agregação dos participantes via `string_agg`) e `dias_atraso` calculado.
- **`vw_caminho_critico`** — a última fotografia do caminho crítico calculado (`cpm_critica = true`), ordenada por `cpm_es_dias`.
- **`vw_resumo_frente`** — contagem de atividades por status, agrupada por frente de trabalho.

### 6.4 Triggers

- `set_atualizado_em()` — função genérica reaproveitada por várias tabelas (`projetos`, `atividades`, `requisitos_tr`, `riscos`, `atividade_horas_dia`) para atualizar `atualizado_em = now()` a cada `UPDATE`.
- `registrar_historico_status_atividade()` — grava o histórico de mudança de status de atividades (seção 6.1).

## 7. Fluxos técnicos principais

**Caminho crítico (CPM)** — `backend/app/cpm.py` monta um grafo dirigido (NetworkX) a partir de `atividade_dependencia`, converte a duração de cada atividade de horas para dias úteis (`prazo_horas / horas_dia_util`, arredondado para cima, mínimo 1 dia) e calcula início/fim mais cedo e mais tarde por atividade, marcando como crítica toda atividade com folga zero. Suporta integralmente dependências Fim-Início (FS, o caso predominante); SS/FF/SF são calculadas por aproximação da mesma fórmula. O resultado é persistido nas colunas `cpm_*` de `atividades` a cada recálculo (`POST /api/cpm/recalcular`).

**Importação de cronograma** — `backend/app/cronograma_import.py` lê planilhas Excel/CSV ou exportações de MS Project, casando cada linha com uma atividade já existente pelo `origem_importacao_id` (ou, na falta dele, pelo código WBS) — reimportar sempre atualiza em vez de duplicar, e nunca sobrescreve campos preenchidos manualmente (recurso, tipo, status Bloqueada/Cancelada, observações, item do TR). Tarefas de duração zero na planilha viram `marcos` em vez de `atividades`.

**Extração de requisitos do TR** — `backend/app/tr_parser.py` lê arquivos `.docx` (python-docx) ou `.pdf` (pypdf) e reconhece itens de requisito por padrões de texto (regras/regex, sem IA nesta etapa), devolvendo uma prévia para conferência humana antes de qualquer gravação (`/api/requisitos/importar-documento/preview` → `/confirmar`).

**Relatório Executivo (IA)** — `backend/app/relatorio_executivo.py` monta um retrato em JSON do estado atual do projeto (atividades, prazos, riscos, pendências, ritmo de execução) e envia como prompt para a API da Anthropic (variável `ANTHROPIC_API_KEY`); o texto de resposta (markdown) e o retrato de dados enviado são persistidos em `relatorios_executivos`, para que qualquer afirmação do relatório possa ser auditada até a origem. Sem a chave configurada, a rota devolve um erro explicando o que falta, sem quebrar o resto do sistema. `relatorio_pdf.py` converte o texto em PDF (ReportLab) para download.

**Relatório de Horas dos Recursos** — `backend/app/relatorio_atividades.py` é 100% determinístico (nenhuma IA): lê `atividade_horas_dia` filtrando por período e, opcionalmente, por recurso, agrega em memória por recurso → atividade → dia com subtotais, e formata o mesmo dicionário em PDF (ReportLab, paisagem A4) ou planilha (openpyxl, abas "Resumo" e "Detalhe"). Nada é persistido — os filtros mudam a cada geração.

**"Minhas atividades"** — `backend/app/minhas_atividades.py` resolve o vínculo "usuário logado → recurso" comparando e-mails (case-insensitive), sem nenhuma FK entre `usuarios` e `recursos`. `recursos_do_usuario(email, apenas_com_controle_horas=True)` filtra por `controla_horas = true` por padrão; quando a grade dá "não vinculado", a mesma função (chamada de novo sem esse filtro) permite distinguir "nenhum recurso com este e-mail" de "recurso existe, mas sem controle de horas habilitado", para uma mensagem mais precisa ao usuário. `garantir_dias()` gera a quebra diária uma única vez por par (atividade, recurso); `ajustar_dia`/`confirmar_dia`/`desconfirmar_dia` são sempre autorizados pelo `recurso_id` do usuário logado, nunca por quem originalmente criou a linha.

## 8. API — rotas por módulo

Todas as rotas ficam sob o prefixo `/api/`, respondem e recebem JSON (exceto downloads de arquivo), e — com exceção de `/api/auth/login`, `/api/auth/registrar` e `/api/auth/esqueci-senha` — exigem sessão ativa.

- **Autenticação**: `POST /auth/registrar`, `POST /auth/login`, `POST /auth/logout`, `GET /auth/me`, `POST /auth/esqueci-senha`, `POST /auth/trocar-senha`.
- **Usuários**: `GET/GET·id/PUT /usuarios`.
- **Projetos**: `GET/POST/PUT /projetos`.
- **Parâmetros do site**: `GET/PUT /parametros`, `POST/GET /parametros/<id>/logo`.
- **Configurações base**: `GET/POST/PUT/DELETE` para `/etapas`, `/frentes`, `/tipos-atividade`, `/recursos`.
- **Atividades**: `GET/POST /atividades`, `GET/PUT/DELETE /atividades/<id>`, `/atividades/<id>/historico`, `/atividades/<id>/relatos` (+ `PATCH /relatos/<id>/resolver`), `/atividades/<id>/dependencias` (+ `DELETE /dependencias/<id>`), `/atividades/<id>/recursos` (+ `DELETE .../recursos/<recurso_id>`), `/atividades/<id>/requisitos` (+ `DELETE .../requisitos/<id>`).
- **Minhas atividades**: `GET /minhas-atividades`, `PUT /minhas-atividades/dia/<id>`, `POST /minhas-atividades/dia/<id>/confirmar`, `POST .../desconfirmar`.
- **Requisitos TR**: `GET/POST/PUT/DELETE /requisitos`, `POST /requisitos/importar-csv`, `POST /requisitos/importar-documento/preview` e `/confirmar`.
- **Ciclos de migração**: `GET/POST /ciclos-migracao`.
- **Marcos**: `GET/POST/PUT /marcos`.
- **Importação de cronograma**: `POST /cronograma/importar/preview` e `/confirmar`, `GET /cronograma/resumo-remocao`, `POST /cronograma/remover-tudo`.
- **Riscos**: `GET/POST/PUT /riscos`.
- **Anexos**: `POST/GET /anexos`, `GET /anexos/<id>/download`, `DELETE /anexos/<id>`.
- **Relatórios**: `GET /relatorios/periodo`, `/atrasadas`, `/resumo-frentes`; Relatório Executivo (`GET/POST /relatorios/executivo...`, `GET .../pdf`); Relatório de Horas dos Recursos (`GET /relatorios/minhas-atividades/pdf` e `/planilha`).
- **Caminho crítico**: `POST /cpm/recalcular`, `GET /cpm/caminho-critico`.
- **Documentação**: `GET /documentacao`, `GET /documentacao/<tipo>`, `PUT /documentacao/<tipo>`.
- **Frontend estático**: `GET /` e `GET /<path:path>` servem os arquivos de `frontend/`.

## 9. Convenções do projeto

- **Migrações**: `db/schema.sql` é sempre o retrato completo e atual do banco; cada `db/migration_0NN_*.sql` é um script incremental, seguro para produção (`BEGIN;`/`COMMIT;`), aplicado uma vez e mantido para o histórico — nunca editado depois de já ter sido aplicado em produção. Toda mudança de schema atualiza os dois: a migração incremental e o `schema.sql` consolidado.
- **Nomenclatura**: tabelas, colunas, funções e nomes de variável no backend são em português (refletindo o domínio do negócio); só nomes de arquivos/módulos e algumas convenções técnicas genéricas ficam em inglês.
- **Sem ORM**: todo SQL é escrito à mão nos módulos do backend, usando `db.q()` para escaping seguro — não há migrations automáticas nem um mapeamento objeto-relacional.
- **Renomeações de rótulo vs. identificador**: quando um termo do domínio muda (ex: "Responsável" → "Recurso", 19ª rodada), a convenção adotada é renomear rótulos visíveis ao usuário e comentários de código, mas preservar identificadores internos já em uso (nomes de coluna do banco, ids de elemento HTML, chaves de campo JSON) — trocar um identificador interno amplamente usado é um risco de quebra desproporcional ao ganho cosmético, e pode ser feito à parte, deliberadamente, se um dia for necessário.

## 10. Deploy e ambientes

- **Local/self-hosted**: Docker Compose (`docker-compose.yml` para Postgres local; `docker-compose.supabase.yml` para apontar para um Supabase remoto durante o desenvolvimento).
- **Produção**: aplicação hospedada no Render (serviço web, deploy automático a cada push na branch `main`) e banco Postgres gerenciado no Supabase.
- **Variáveis de ambiente** (ver `.env.example`): credenciais do Postgres (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`), `SECRET_KEY` (sessão), `ANTHROPIC_API_KEY` (Relatório Executivo), `SMTP_*` (envio de e-mail do "esqueci a senha").
- **Sem dependência de driver nativo de banco** — só precisa de Python, das bibliotecas em `requirements.txt` e do binário `psql` disponível no `PATH` (já incluído no Dockerfile).

## 11. Um sistema em evolução

Este documento técnico é atualizado a cada rodada de desenvolvimento que altere o banco de dados, a arquitetura ou uma convenção do projeto — a versão e a data no topo indicam a última revisão. Para o histórico detalhado, rodada a rodada, de cada decisão técnica tomada, consulte a documentação de gestão técnica do projeto (mantida à parte, fora do próprio sistema).$doc$)
ON CONFLICT (tipo) DO NOTHING;

COMMIT;
