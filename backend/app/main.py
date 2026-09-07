import base64
import csv
import io
import json
import os
import uuid
from datetime import datetime, date, timedelta

from flask import Flask, request, jsonify, send_from_directory, send_file, abort, session

from . import db, cpm, tr_parser, cronograma_import, relatorio_executivo, relatorio_pdf, auth, minhas_atividades, relatorio_atividades

UPLOAD_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "uploads")
FRONTEND_DIR = os.environ.get(
    "FRONTEND_DIR",
    os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(__file__))), "frontend"),
)

# Chave usada para assinar o cookie de sessão (login). Precisa ser FIXA e
# igual em todos os workers do gunicorn (-w 4) — se cada worker sorteasse
# a própria chave, a sessão de um usuário só funcionaria "às vezes"
# (dependendo de qual worker atendesse a requisição seguinte). Por isso o
# fallback abaixo é um valor fixo (não aleatório) só para não quebrar o
# sistema quando SECRET_KEY não estiver configurada — mas é um valor
# PÚBLICO (está neste código-fonte), então NUNCA deve ser usado em
# produção. Configure SECRET_KEY no .env antes de ir para produção (veja
# .env.example e o README, seção "Login e cadastro de usuários").
_SECRET_KEY_FALLBACK_INSEGURO = "ergon-pm-troque-esta-chave-no-.env-antes-de-usar-em-producao"
SECRET_KEY = os.environ.get("SECRET_KEY", "").strip() or _SECRET_KEY_FALLBACK_INSEGURO
if SECRET_KEY == _SECRET_KEY_FALLBACK_INSEGURO:
    print(
        "[SECURITY WARNING] SECRET_KEY não configurada — usando uma chave padrão INSEGURA "
        "(pública neste código-fonte) só para o sistema funcionar. Configure SECRET_KEY no "
        "arquivo .env antes de usar em produção. Veja .env.example.",
        flush=True,
    )

# Rotas de autenticação que continuam acessíveis sem sessão ativa (login,
# cadastro, "esqueci a senha") — todo o resto embaixo de /api/ exige login
# (ver exigir_login() abaixo). O front-end estático (/, /<path>) nunca é
# bloqueado aqui: é só HTML/JS/CSS, sem dado nenhum do projeto — ele mesmo
# decide mostrar a tela de login ou o sistema, com base em /api/auth/me.
AUTH_ROTAS_PUBLICAS = {
    "/api/auth/login", "/api/auth/registrar", "/api/auth/esqueci-senha",
}

PROJETO_FIELDS = [
    "sigla", "nome", "cliente", "descricao", "fiscal_projeto", "gestor_projeto",
    "gerente_projeto_cliente", "gerente_projeto_techne", "lider_projeto_techne",
    "data_abertura", "data_inicio", "data_inicio_real", "data_fim_prevista",
    "prazo_total_meses", "horas_dia_util",
]

# Parâmetros do site (Configurações > Parâmetros): logo + nome da empresa,
# exibidos no topo do sistema. O tema da página (claro/escuro) NÃO é um
# campo aqui — é preferência pessoal salva no navegador de cada usuário
# (localStorage), não um parâmetro do site. Ver migration_010 e a seção
# "17. PARÂMETROS DO SITE" do schema.sql.
PARAMETROS_FIELDS = ["nome_empresa"]
LOGO_EXTENSOES_PERMITIDAS = {".png", ".jpg", ".jpeg", ".svg", ".webp", ".gif"}
LOGO_TAMANHO_MAXIMO_BYTES = 3 * 1024 * 1024  # 3 MB
LOGO_MIME_POR_EXTENSAO = {
    ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
    ".svg": "image/svg+xml", ".webp": "image/webp", ".gif": "image/gif",
}
# Colunas "leves" de parametros_site — tudo, EXCETO logo_dados (o base64 do
# logo, que pode ter alguns MB). Usadas em toda leitura/escrita que não seja
# especificamente para servir a imagem do logo (GET .../logo), para não
# duplicar esses MB em todo carregamento de página (Configurações e o
# carregarParametros() disparado no boot do front-end, ver frontend/index.html).
PARAMETROS_COLUNAS_LEVES = "id, nome_empresa, logo_arquivo, logo_mime, atualizado_em"
CLASSIFICACAO_TR_VALIDAS = {
    "Essencial/Imediato", "Obrigatório", "Desejável",
    "Customizado Curto", "Customizado Médio", "Customizado Longo",
}
ATENDIMENTO_TR_VALIDOS = {"A analisar", "Nativo", "Parcial", "Customizado", "Não atende"}
STATUS_REQUISITO_VALIDOS = {
    "Não iniciado", "Em levantamento", "Especificado", "Em desenvolvimento",
    "Em homologação", "Entregue", "Aprovado", "Rejeitado",
}
PRIORIDADE_VALIDAS = {"Urgente", "Alta", "Média", "Baixa"}
COBRANCA_VALIDAS = {"Sim", "Não", "N/A"}
TIPO_REQUISITO_VALIDOS = {"Funcional", "Não Funcional"}
TIPO_VINCULO_VALIDOS = {"Techne", "Cliente", "Terceirizado"}

ATIVIDADE_FIELDS = [
    "projeto_id", "etapa_id", "frente_trabalho_id", "tipo_atividade_elementar_id", "atividade_pai_id",
    "requisito_tr_id",
    "codigo_wbs", "origem_importacao_id", "nome", "descricao",
    "prazo_horas", "horas_realizadas", "dtini_prev", "dtfim_prev",
    "dtini_real", "dtfim_real", "percentual_concluido", "status", "prioridade", "observacoes",
    "eh_atividade_master",
]
RELATO_FIELDS = [
    "autor_id", "autor_nome", "texto", "eh_pendencia",
    "pendencia_responsavel_id", "pendencia_prazo_possivel", "pendencia_data_limite",
]
# Status que exigem ao menos um relato de andamento registrado (ver create/update_atividade).
# "Não iniciada" e "Concluída" ficam de fora — todo o resto (inclusive "Cancelada", que também
# merece um relato explicando o motivo) precisa de relato.
STATUS_EXIGE_RELATO = {"Em andamento", "Bloqueada", "Cancelada"}
REQUISITO_FIELDS = [
    "projeto_id", "codigo", "titulo", "descricao", "tipo_requisito", "modulo_origem",
    "frente_trabalho_id", "classificacao", "atendimento",
    "status", "responsavel_id", "prioridade", "cobranca", "data_levantamento", "observacoes",
]
# Colunas usadas no upsert em massa (CSV e importação de documento) — sem projeto_id,
# que é sempre passado à parte.
REQUISITO_UPSERT_COLUMNS = [
    "codigo", "titulo", "descricao", "tipo_requisito", "modulo_origem", "frente_trabalho_id",
    "classificacao", "atendimento", "status", "prioridade", "cobranca",
    "data_levantamento", "observacoes",
]
RECURSO_FIELDS = ["nome", "tipo_vinculo", "empresa", "cargo", "email", "telefone", "controla_horas", "ativo"]
ETAPA_FIELDS = ["projeto_id", "numero", "nome", "descricao", "data_inicio_prev", "data_fim_prev"]
FRENTE_FIELDS = ["projeto_id", "nome", "descricao", "cor_hex", "ordem", "ativo"]
TIPO_ATIVIDADE_FIELDS = ["nome", "descricao", "ordem", "ativo"]
MARCO_FIELDS = ["projeto_id", "etapa_id", "nome", "descricao", "data_prevista", "data_real", "origem_importacao_id"]
RISCO_FIELDS = ["projeto_id", "descricao", "categoria", "probabilidade", "impacto", "mitigacao",
                "responsavel_id", "status", "identificado_em"]
CICLO_FIELDS = ["atividade_id", "numero_ciclo", "data_execucao", "qtd_registros_extraidos",
                "qtd_registros_carregados", "qtd_rejeicoes", "observacoes"]

ATIVIDADE_SELECT = """
SELECT a.*, e.numero AS etapa_numero, e.nome AS etapa_nome,
       f.nome AS frente_nome, f.cor_hex AS frente_cor,
       t.nome AS tipo_nome,
       rq.codigo AS requisito_tr_codigo, rq.titulo AS requisito_tr_titulo,
       (a.status NOT IN ('Concluída','Cancelada') AND a.dtfim_prev IS NOT NULL
        AND a.dtfim_prev < CURRENT_DATE) AS atrasada,
       -- Lista completa de recursos/participantes (N, não mais 2 campos fixos —
       -- ver tabela atividade_recurso e migração 012), já pronta pro front-end sem
       -- round-trip extra: cada item {id, nome, tipo_vinculo}.
       COALESCE((
         SELECT json_agg(json_build_object('id', r.id, 'nome', r.nome, 'tipo_vinculo', r.tipo_vinculo)
                          ORDER BY r.tipo_vinculo, r.nome)
         FROM atividade_recurso ar JOIN recursos r ON r.id = ar.recurso_id
         WHERE ar.atividade_id = a.id
       ), '[]') AS responsaveis
FROM atividades a
JOIN etapas e ON e.id = a.etapa_id
JOIN frentes_trabalho f ON f.id = a.frente_trabalho_id
LEFT JOIN tipos_atividade_elementar t ON t.id = a.tipo_atividade_elementar_id
LEFT JOIN requisitos_tr rq ON rq.id = a.requisito_tr_id
"""


def upsert_requisitos(projeto_id, linhas):
    """linhas: lista de dicts com chaves de REQUISITO_UPSERT_COLUMNS (ausentes -> NULL).
    Faz upsert por (projeto_id, codigo) — reimportar atualiza em vez de duplicar.
    Deduplica códigos repetidos dentro do próprio lote (mantém a última ocorrência,
    senão o ON CONFLICT do Postgres quebra com "cannot affect row a second time").
    Retorna (inseridos, atualizados)."""
    por_codigo = {}
    for l in linhas:
        if l.get("codigo"):
            por_codigo[l["codigo"]] = l
    linhas = list(por_codigo.values())
    if not linhas:
        return 0, 0

    existentes = {
        r["codigo"] for r in db.fetch_all(
            f"SELECT codigo FROM requisitos_tr WHERE projeto_id = {db.q(projeto_id)}"
        )
    }
    inseridos = sum(1 for l in linhas if l["codigo"] not in existentes)
    atualizados = len(linhas) - inseridos

    values_sql = ", ".join(
        "(" + db.q(projeto_id) + ", " + ", ".join(db.q(l.get(col)) for col in REQUISITO_UPSERT_COLUMNS) + ")"
        for l in linhas
    )
    set_clause = ", ".join(f"{col} = EXCLUDED.{col}" for col in REQUISITO_UPSERT_COLUMNS if col != "codigo")
    sql = (
        f"INSERT INTO requisitos_tr (projeto_id, {', '.join(REQUISITO_UPSERT_COLUMNS)}) VALUES "
        + values_sql
        + f" ON CONFLICT (projeto_id, codigo) DO UPDATE SET {set_clause}"
    )
    db.execute(sql, timeout=120)
    return inseridos, atualizados


def insert_row(table, data, allowed):
    cols, vals = [], []
    for f in allowed:
        if f in data and data[f] not in (None, ""):
            cols.append(f)
            vals.append(db.q(data[f]))
    if not cols:
        raise ValueError("Nenhum campo válido informado.")
    sql = f"INSERT INTO {table} ({', '.join(cols)}) VALUES ({', '.join(vals)}) RETURNING *"
    return db.execute_returning_one(sql)


def patch_row(table, row_id, data, allowed, prelude=""):
    sets = [f"{f} = {db.q(data[f])}" for f in allowed if f in data]
    if not sets:
        return db.fetch_one(f"SELECT * FROM {table} WHERE id = {db.q(row_id)}")
    sql = f"UPDATE {table} SET {', '.join(sets)} WHERE id = {db.q(row_id)} RETURNING *"
    return db.execute_returning_one(sql, prelude=prelude)


def delete_row(table, row_id):
    """DELETE genérico. Erros de FK (registro em uso por outra tabela) e de
    unicidade são traduzidos em mensagens amigáveis pelo errorhandler global
    (ver handle_db_error), então aqui só dispara o DELETE mesmo."""
    db.execute(f"DELETE FROM {table} WHERE id = {db.q(row_id)}")
    return "", 204


def create_app():
    app = Flask(__name__, static_folder=None)
    os.makedirs(UPLOAD_DIR, exist_ok=True)

    app.config.update(
        SECRET_KEY=SECRET_KEY,
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        # Secure = cookie só é enviado em HTTPS. Precisa ficar DESLIGADO em
        # dev local (docker-compose serve em http://localhost, sem HTTPS —
        # com Secure=True o navegador simplesmente descartaria o cookie e o
        # login pareceria não "colar"). Em produção atrás de HTTPS (Render,
        # ou qualquer proxy com TLS), defina SESSION_COOKIE_SECURE=true nas
        # variáveis de ambiente do serviço.
        SESSION_COOKIE_SECURE=os.environ.get("SESSION_COOKIE_SECURE", "").strip().lower() == "true",
        PERMANENT_SESSION_LIFETIME=timedelta(days=7),
    )

    @app.before_request
    def exigir_login():
        """Todo /api/* exige sessão autenticada, exceto as rotas em
        AUTH_ROTAS_PUBLICAS (login, cadastro, esqueci-senha) e /api/health.
        O front-end estático (servido lá embaixo, fora de /api/) nunca
        passa por aqui — ele carrega sempre e é o próprio JS que decide
        mostrar a tela de login ou o sistema, chamando /api/auth/me."""
        path = request.path
        if not path.startswith("/api/"):
            return None
        if path == "/api/health" or path in AUTH_ROTAS_PUBLICAS:
            return None
        if not session.get("usuario_id"):
            return jsonify({"erro": "Sessão expirada ou não autenticada. Faça login novamente."}), 401
        return None

    # -------------------------------------------------------------- health
    @app.get("/api/health")
    def health():
        try:
            db.fetch_one("SELECT 1 AS ok")
            return jsonify({"status": "ok"})
        except db.DbError as e:
            return jsonify({"status": "error", "detail": str(e)}), 500

    # --------------------------------------------------- autenticação / usuários
    @app.post("/api/auth/registrar")
    def auth_registrar():
        """Autocadastro aberto — 'primeiro acesso'. Qualquer pessoa preenche
        todos os campos (obrigatórios) e já sai logada, com a senha que ela
        mesma digitou (não é gerada pelo sistema)."""
        data = request.get_json(force=True)
        try:
            usuario = auth.registrar_usuario(data)
        except auth.AuthError as e:
            return jsonify({"erro": str(e)}), 400
        session.clear()
        session.permanent = True
        session["usuario_id"] = usuario["id"]
        return jsonify(usuario), 201

    @app.post("/api/auth/login")
    def auth_login():
        data = request.get_json(force=True)
        try:
            usuario = auth.autenticar(data.get("email"), data.get("senha"))
        except auth.AuthError as e:
            return jsonify({"erro": str(e)}), 401
        session.clear()
        session.permanent = True
        session["usuario_id"] = usuario["id"]
        return jsonify(usuario)

    @app.post("/api/auth/logout")
    def auth_logout():
        session.clear()
        return "", 204

    @app.get("/api/auth/me")
    def auth_me():
        usuario_id = session.get("usuario_id")
        if not usuario_id:
            return jsonify({"erro": "Não autenticado."}), 401
        usuario = auth.buscar_usuario_publico(usuario_id)
        if not usuario or not usuario.get("ativo", True):
            session.clear()
            return jsonify({"erro": "Não autenticado."}), 401
        return jsonify(usuario)

    @app.post("/api/auth/esqueci-senha")
    def auth_esqueci_senha():
        email = (request.get_json(force=True) or {}).get("email")
        if not (email or "").strip():
            return jsonify({"erro": "Informe o e-mail cadastrado."}), 400
        try:
            auth.esqueci_a_senha(email)
        except auth.AuthError as e:
            # Only reaches here for a real problem sending the e-mail (SMTP não
            # configurado, credenciais erradas etc.) — precisa aparecer pra quem
            # administra perceber e corrigir. Se o e-mail simplesmente não
            # existir no cadastro, esqueci_a_senha() não levanta nada (ver
            # docstring em auth.py) e cai na mensagem genérica de sucesso abaixo,
            # de propósito, pra não revelar quais e-mails estão cadastrados.
            return jsonify({"erro": str(e)}), 400
        return jsonify({
            "ok": True,
            "mensagem": "Se este e-mail estiver cadastrado, uma nova senha foi enviada para ele.",
        })

    @app.post("/api/auth/trocar-senha")
    def auth_trocar_senha():
        data = request.get_json(force=True)
        try:
            auth.trocar_senha(session["usuario_id"], data.get("senha_atual"), data.get("senha_nova"))
        except auth.AuthError as e:
            return jsonify({"erro": str(e)}), 400
        return jsonify({"ok": True})

    @app.get("/api/usuarios")
    def list_usuarios():
        return jsonify(db.fetch_all(f"SELECT {auth.USUARIO_COLUNAS_PUBLICAS} FROM usuarios ORDER BY nome"))

    @app.get("/api/usuarios/<id>")
    def get_usuario(id):
        row = auth.buscar_usuario_publico(id)
        if not row:
            abort(404)
        return jsonify(row)

    @app.put("/api/usuarios/<id>")
    def update_usuario(id):
        """Edição pela tela Configurações > Usuários. Propositalmente não
        aceita e-mail nem senha aqui (ver auth.USUARIO_EDIT_FIELDS) — trocar
        de e-mail não é suportado nesta rodada, e senha só muda por
        'Alterar senha' (logado) ou 'Esqueci a senha' (por e-mail)."""
        row = patch_row("usuarios", id, request.get_json(force=True), auth.USUARIO_EDIT_FIELDS)
        if not row:
            abort(404)
        row.pop("senha_hash", None)
        return jsonify(row)

    # ------------------------------------------------------------ projetos
    @app.get("/api/projetos")
    def list_projetos():
        return jsonify(db.fetch_all("SELECT * FROM projetos ORDER BY criado_em"))

    @app.post("/api/projetos")
    def create_projeto():
        data = request.get_json(force=True)
        if not (data.get("nome") and data.get("cliente")):
            return jsonify({"erro": "Nome do projeto e Instituição são obrigatórios."}), 400
        return jsonify(insert_row("projetos", data, PROJETO_FIELDS)), 201

    @app.put("/api/projetos/<id>")
    def update_projeto(id):
        row = patch_row("projetos", id, request.get_json(force=True), PROJETO_FIELDS)
        if not row:
            abort(404)
        return jsonify(row)

    # ------------------------------------------------- parâmetros do site
    @app.get("/api/parametros")
    def get_parametros():
        """Singleton (mesma convenção de /api/projetos): lê a primeira
        linha e cria uma linha padrão automaticamente se ainda não existir
        nenhuma — assim o front-end nunca precisa lidar com "ainda não
        tem parâmetros cadastrados"."""
        row = db.fetch_one(f"SELECT {PARAMETROS_COLUNAS_LEVES} FROM parametros_site ORDER BY atualizado_em LIMIT 1")
        if not row:
            row = db.execute_returning_one(
                f"INSERT INTO parametros_site DEFAULT VALUES RETURNING {PARAMETROS_COLUNAS_LEVES}"
            )
        return jsonify(row)

    @app.put("/api/parametros/<id>")
    def update_parametros(id):
        data = request.get_json(force=True)
        sets = [f"{f} = {db.q(data[f])}" for f in PARAMETROS_FIELDS if f in data]
        sets.append("atualizado_em = now()")
        sql = (
            f"UPDATE parametros_site SET {', '.join(sets)} WHERE id = {db.q(id)} "
            f"RETURNING {PARAMETROS_COLUNAS_LEVES}"
        )
        row = db.execute_returning_one(sql)
        if not row:
            abort(404)
        return jsonify(row)

    @app.post("/api/parametros/<id>/logo")
    def upload_logo_parametros(id):
        """O conteúdo do logo é gravado em base64 direto no banco (coluna
        logo_dados), não em disco. Disco local não é confiável nos deploys
        deste sistema (ex: Render sem disco persistente) — é apagado a cada
        redeploy e reiniciado, então um logo salvo lá "some" pouco depois de
        enviado, mesmo continuando a existir a referência no banco. Ver
        comentário da coluna em db/schema.sql (seção 17)."""
        existe = db.fetch_one(f"SELECT id FROM parametros_site WHERE id = {db.q(id)}")
        if not existe:
            abort(404)
        file = request.files.get("file")
        if not file or not file.filename:
            return jsonify({"erro": "Selecione um arquivo de imagem."}), 400
        ext = os.path.splitext(file.filename)[1].lower()
        if ext not in LOGO_EXTENSOES_PERMITIDAS:
            return jsonify({"erro": "Formato não suportado. Use PNG, JPG, SVG, WEBP ou GIF."}), 400
        conteudo = file.read()
        if len(conteudo) > LOGO_TAMANHO_MAXIMO_BYTES:
            return jsonify({"erro": "Arquivo muito grande (máximo 3 MB)."}), 400
        stored_name = f"logo_{uuid.uuid4()}{ext}"
        mime = LOGO_MIME_POR_EXTENSAO.get(ext, file.mimetype or "application/octet-stream")
        dados_b64 = base64.b64encode(conteudo).decode("ascii")
        sql = (
            f"UPDATE parametros_site SET logo_arquivo = {db.q(stored_name)}, "
            f"logo_dados = {db.q(dados_b64)}, logo_mime = {db.q(mime)}, atualizado_em = now() "
            f"WHERE id = {db.q(id)} RETURNING {PARAMETROS_COLUNAS_LEVES}"
        )
        novo = db.execute_returning_one(sql)
        return jsonify(novo)

    @app.get("/api/parametros/<id>/logo")
    def get_logo_parametros(id):
        """Serve o logo a partir do base64 gravado no banco (logo_dados) —
        ver comentário em upload_logo_parametros sobre por que não fica em
        disco. O nome do arquivo nunca vem da URL (só o id dos parâmetros
        e, opcionalmente, um "?f=" cosmético só para cache-busting no
        front-end — o valor de "f" nunca é lido aqui)."""
        row = db.fetch_one(f"SELECT logo_dados, logo_mime FROM parametros_site WHERE id = {db.q(id)}")
        if not row or not row.get("logo_dados"):
            abort(404)
        conteudo = base64.b64decode(row["logo_dados"])
        return send_file(io.BytesIO(conteudo), mimetype=row.get("logo_mime") or "application/octet-stream")

    # -------------------------------------------------------------- etapas
    @app.get("/api/etapas")
    def list_etapas():
        pid = request.args.get("projeto_id")
        sql = "SELECT * FROM etapas"
        if pid:
            sql += f" WHERE projeto_id = {db.q(pid)}"
        sql += " ORDER BY numero"
        return jsonify(db.fetch_all(sql))

    @app.post("/api/etapas")
    def create_etapa():
        data = request.get_json(force=True)
        if not (data.get("numero") and data.get("nome")):
            return jsonify({"erro": "Número e nome da etapa são obrigatórios."}), 400
        return jsonify(insert_row("etapas", data, ETAPA_FIELDS)), 201

    @app.put("/api/etapas/<id>")
    def update_etapa(id):
        row = patch_row("etapas", id, request.get_json(force=True), ETAPA_FIELDS)
        if not row:
            abort(404)
        return jsonify(row)

    @app.delete("/api/etapas/<id>")
    def delete_etapa(id):
        return delete_row("etapas", id)

    # -------------------------------------------------------------- frentes
    @app.get("/api/frentes")
    def list_frentes():
        pid = request.args.get("projeto_id")
        sql = "SELECT * FROM frentes_trabalho"
        if pid:
            sql += f" WHERE projeto_id = {db.q(pid)}"
        sql += " ORDER BY ordem"
        return jsonify(db.fetch_all(sql))

    @app.post("/api/frentes")
    def create_frente():
        data = request.get_json(force=True)
        if not data.get("nome"):
            return jsonify({"erro": "Nome da frente de trabalho é obrigatório."}), 400
        return jsonify(insert_row("frentes_trabalho", data, FRENTE_FIELDS)), 201

    @app.put("/api/frentes/<id>")
    def update_frente(id):
        row = patch_row("frentes_trabalho", id, request.get_json(force=True), FRENTE_FIELDS)
        if not row:
            abort(404)
        return jsonify(row)

    @app.delete("/api/frentes/<id>")
    def delete_frente(id):
        return delete_row("frentes_trabalho", id)

    # -------------------------------------------------------- tipos atividade
    @app.get("/api/tipos-atividade")
    def list_tipos_atividade():
        return jsonify(db.fetch_all("SELECT * FROM tipos_atividade_elementar ORDER BY ordem"))

    @app.post("/api/tipos-atividade")
    def create_tipo_atividade():
        data = request.get_json(force=True)
        if not data.get("nome"):
            return jsonify({"erro": "Nome do tipo de atividade elementar é obrigatório."}), 400
        return jsonify(insert_row("tipos_atividade_elementar", data, TIPO_ATIVIDADE_FIELDS)), 201

    @app.put("/api/tipos-atividade/<id>")
    def update_tipo_atividade(id):
        row = patch_row("tipos_atividade_elementar", id, request.get_json(force=True), TIPO_ATIVIDADE_FIELDS)
        if not row:
            abort(404)
        return jsonify(row)

    @app.delete("/api/tipos-atividade/<id>")
    def delete_tipo_atividade(id):
        return delete_row("tipos_atividade_elementar", id)

    # ------------------------------------------------------------- recursos
    @app.get("/api/recursos")
    def list_recursos():
        return jsonify(db.fetch_all("SELECT * FROM recursos ORDER BY nome"))

    @app.post("/api/recursos")
    def create_recurso():
        data = request.get_json(force=True)
        if not data.get("nome"):
            return jsonify({"erro": "Nome do recurso é obrigatório."}), 400
        if data.get("tipo_vinculo") and data["tipo_vinculo"] not in TIPO_VINCULO_VALIDOS:
            return jsonify({"erro": "Vínculo inválido — use Techne, Cliente ou Terceirizado."}), 400
        return jsonify(insert_row("recursos", data, RECURSO_FIELDS)), 201

    @app.put("/api/recursos/<id>")
    def update_recurso(id):
        data = request.get_json(force=True)
        if data.get("tipo_vinculo") and data["tipo_vinculo"] not in TIPO_VINCULO_VALIDOS:
            return jsonify({"erro": "Vínculo inválido — use Techne, Cliente ou Terceirizado."}), 400
        row = patch_row("recursos", id, data, RECURSO_FIELDS)
        if not row:
            abort(404)
        return jsonify(row)

    @app.delete("/api/recursos/<id>")
    def delete_recurso(id):
        return delete_row("recursos", id)

    # ----------------------------------------------------------- atividades
    @app.get("/api/atividades")
    def list_atividades():
        args = request.args
        where = []
        if args.get("projeto_id"):
            where.append(f"a.projeto_id = {db.q(args['projeto_id'])}")
        if args.get("etapa_id"):
            where.append(f"a.etapa_id = {db.q(args['etapa_id'])}")
        if args.get("frente_trabalho_id"):
            where.append(f"a.frente_trabalho_id = {db.q(args['frente_trabalho_id'])}")
        if args.get("status"):
            where.append(f"a.status = {db.q(args['status'])}")
        if args.get("responsavel_id"):
            where.append(
                f"EXISTS(SELECT 1 FROM atividade_recurso ar WHERE ar.atividade_id = a.id "
                f"AND ar.recurso_id = {db.q(args['responsavel_id'])})"
            )
        if args.get("atividade_pai_id"):
            where.append(f"a.atividade_pai_id = {db.q(args['atividade_pai_id'])}")
        if args.get("search"):
            termo = args["search"].replace("'", "''")
            where.append(
                f"(a.nome ILIKE '%{termo}%' OR a.descricao ILIKE '%{termo}%' OR a.codigo_wbs ILIKE '%{termo}%')"
            )
        if args.get("periodo_inicio") and args.get("periodo_fim"):
            where.append(
                f"a.dtini_prev <= {db.q(args['periodo_fim'])} AND a.dtfim_prev >= {db.q(args['periodo_inicio'])}"
            )
        if args.get("atrasadas") == "true":
            where.append(
                "a.status NOT IN ('Concluída','Cancelada') AND a.dtfim_prev IS NOT NULL AND a.dtfim_prev < CURRENT_DATE"
            )
        if args.get("criticas") == "true":
            where.append("a.cpm_critica = TRUE")
        sql = ATIVIDADE_SELECT
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY a.dtini_prev NULLS LAST, a.codigo_wbs"
        return jsonify(db.fetch_all(sql))

    @app.post("/api/atividades")
    def create_atividade():
        data = request.get_json(force=True)
        # Herança nativa do item do TR: se a atividade tem pai e não veio com
        # requisito_tr_id explícito, copia do pai (permanece editável depois).
        if not data.get("requisito_tr_id") and data.get("atividade_pai_id"):
            pai = db.fetch_one(
                f"SELECT requisito_tr_id FROM atividades WHERE id = {db.q(data['atividade_pai_id'])}"
            )
            if pai and pai.get("requisito_tr_id"):
                data["requisito_tr_id"] = pai["requisito_tr_id"]
        status = data.get("status")
        if status in STATUS_EXIGE_RELATO:
            return jsonify({
                "erro": f'Não é possível criar a atividade já como "{status}". '
                        'Crie como "Não iniciada" e, na sequência, registre um relato de andamento ao mudar o status.'
            }), 400
        return jsonify(insert_row("atividades", data, ATIVIDADE_FIELDS)), 201

    @app.get("/api/atividades/<id>")
    def get_atividade(id):
        row = db.fetch_one(ATIVIDADE_SELECT + f" WHERE a.id = {db.q(id)}")
        if not row:
            abort(404)
        return jsonify(row)

    @app.put("/api/atividades/<id>")
    def update_atividade(id):
        data = request.get_json(force=True)
        novo_status = data.get("status")
        if novo_status in STATUS_EXIGE_RELATO:
            tem_relato = db.fetch_one(
                f"SELECT 1 AS x FROM atividade_relato WHERE atividade_id = {db.q(id)} LIMIT 1"
            )
            if not tem_relato:
                return jsonify({
                    "erro": f'Status "{novo_status}" exige ao menos um relato de andamento registrado. '
                            'Adicione um relato na aba Relatos e tente salvar novamente.'
                }), 400
        usuario = request.headers.get("X-Usuario", "")
        prelude = f"SET LOCAL app.usuario_atual = {db.q(usuario)};" if usuario else ""
        row = patch_row("atividades", id, data, ATIVIDADE_FIELDS, prelude=prelude)
        if not row:
            abort(404)
        return jsonify(row)

    @app.delete("/api/atividades/<id>")
    def delete_atividade(id):
        db.execute(f"DELETE FROM atividades WHERE id = {db.q(id)}")
        return "", 204

    @app.get("/api/atividades/<id>/historico")
    def atividade_historico(id):
        return jsonify(db.fetch_all(
            f"SELECT * FROM historico_status_atividade WHERE atividade_id = {db.q(id)} ORDER BY alterado_em"
        ))

    # ---------------------------------------------------------------- relatos
    @app.get("/api/atividades/<id>/relatos")
    def list_relatos(id):
        sql = (
            "SELECT r.*, au.nome AS autor_cadastro_nome, pr.nome AS pendencia_responsavel_nome "
            "FROM atividade_relato r "
            "LEFT JOIN recursos au ON au.id = r.autor_id "
            "LEFT JOIN recursos pr ON pr.id = r.pendencia_responsavel_id "
            f"WHERE r.atividade_id = {db.q(id)} ORDER BY r.criado_em DESC"
        )
        return jsonify(db.fetch_all(sql))

    @app.post("/api/atividades/<id>/relatos")
    def create_relato(id):
        data = request.get_json(force=True)
        if not (data.get("texto") or "").strip():
            return jsonify({"erro": "Informe o texto do relato."}), 400
        if data.get("eh_pendencia"):
            faltando = [
                campo for campo in ("pendencia_responsavel_id", "pendencia_prazo_possivel", "pendencia_data_limite")
                if not data.get(campo)
            ]
            if faltando:
                return jsonify({
                    "erro": "Pendência exige recurso responsável, prazo possível e data limite."
                }), 400
        data = dict(data)
        data["atividade_id"] = id
        row = insert_row("atividade_relato", data, ["atividade_id"] + RELATO_FIELDS)
        return jsonify(row), 201

    @app.patch("/api/relatos/<relato_id>/resolver")
    def resolver_pendencia(relato_id):
        sql = (
            "UPDATE atividade_relato SET pendencia_resolvida = TRUE, pendencia_resolvida_em = now() "
            f"WHERE id = {db.q(relato_id)} AND eh_pendencia RETURNING *"
        )
        row = db.execute_returning_one(sql)
        if not row:
            abort(404)
        return jsonify(row)

    # ------------------------------------------------------------ dependências
    @app.get("/api/atividades/<id>/dependencias")
    def list_dependencias(id):
        sql = (
            "SELECT ad.*, p.nome AS predecessora_nome, p.status AS predecessora_status "
            "FROM atividade_dependencia ad JOIN atividades p ON p.id = ad.predecessora_id "
            f"WHERE ad.atividade_id = {db.q(id)}"
        )
        return jsonify(db.fetch_all(sql))

    @app.post("/api/atividades/<id>/dependencias")
    def create_dependencia(id):
        data = request.get_json(force=True)
        data["atividade_id"] = id
        row = insert_row("atividade_dependencia", data, ["atividade_id", "predecessora_id", "tipo", "lag_horas"])
        return jsonify(row), 201

    @app.delete("/api/dependencias/<dep_id>")
    def delete_dependencia(dep_id):
        db.execute(f"DELETE FROM atividade_dependencia WHERE id = {db.q(dep_id)}")
        return "", 204

    # -------------------------------------------------------- recursos ativ.
    @app.get("/api/atividades/<id>/recursos")
    def list_atividade_recursos(id):
        sql = (
            "SELECT ar.*, r.nome AS recurso_nome, r.empresa, r.cargo, r.tipo_vinculo "
            f"FROM atividade_recurso ar JOIN recursos r ON r.id = ar.recurso_id WHERE ar.atividade_id = {db.q(id)}"
        )
        return jsonify(db.fetch_all(sql))

    @app.post("/api/atividades/<id>/recursos")
    def add_atividade_recurso(id):
        data = request.get_json(force=True)
        sql = (
            "INSERT INTO atividade_recurso (atividade_id, recurso_id, papel_na_atividade, horas_alocadas) "
            f"VALUES ({db.q(id)}, {db.q(data.get('recurso_id'))}, {db.q(data.get('papel_na_atividade'))}, "
            f"{db.q(data.get('horas_alocadas'))}) RETURNING *"
        )
        return jsonify(db.execute_returning_one(sql)), 201

    @app.delete("/api/atividades/<id>/recursos/<recurso_id>")
    def remove_atividade_recurso(id, recurso_id):
        db.execute(
            f"DELETE FROM atividade_recurso WHERE atividade_id = {db.q(id)} AND recurso_id = {db.q(recurso_id)}"
        )
        return "", 204

    # -------------------------------------------------- minhas atividades
    # Grade semanal do consultor logado: dias úteis da semana x atividades em
    # que o profissional vinculado a ele (por e-mail, ver
    # backend/app/minhas_atividades.py) é um dos participantes (atividade_recurso).
    @app.get("/api/minhas-atividades")
    def minhas_atividades_grade():
        # 16ª rodada: não recebe mais projeto_id — a grade sempre traz as
        # atividades de TODOS os projetos em que o usuário está delegado
        # (ver docstring de minhas_atividades.montar_grade).
        usuario = auth.buscar_usuario_publico(session["usuario_id"])
        semana_str = request.args.get("semana")
        try:
            data_ref = date.fromisoformat(semana_str) if semana_str else date.today()
        except ValueError:
            return jsonify({"erro": "Data de referência da semana inválida."}), 400
        return jsonify(minhas_atividades.montar_grade(usuario, data_ref))

    @app.put("/api/minhas-atividades/dia/<id>")
    def minhas_atividades_ajustar(id):
        usuario = auth.buscar_usuario_publico(session["usuario_id"])
        data = request.get_json(force=True)
        try:
            row = minhas_atividades.ajustar_dia(id, usuario, data.get("horas_previstas"))
        except minhas_atividades.MinhasAtividadesError as e:
            return jsonify({"erro": str(e)}), 400
        if not row:
            abort(404)
        return jsonify(row)

    @app.post("/api/minhas-atividades/dia/<id>/confirmar")
    def minhas_atividades_confirmar(id):
        usuario = auth.buscar_usuario_publico(session["usuario_id"])
        data = request.get_json(silent=True) or {}
        try:
            row = minhas_atividades.confirmar_dia(id, usuario, data.get("horas"))
        except minhas_atividades.MinhasAtividadesError as e:
            return jsonify({"erro": str(e)}), 400
        if not row:
            abort(404)
        return jsonify(row)

    @app.post("/api/minhas-atividades/dia/<id>/desconfirmar")
    def minhas_atividades_desconfirmar(id):
        usuario = auth.buscar_usuario_publico(session["usuario_id"])
        try:
            row = minhas_atividades.desconfirmar_dia(id, usuario)
        except minhas_atividades.MinhasAtividadesError as e:
            return jsonify({"erro": str(e)}), 400
        if not row:
            abort(404)
        return jsonify(row)

    # ------------------------------------------------------------- requisitos
    @app.get("/api/requisitos")
    def list_requisitos():
        args = request.args
        where = []
        if args.get("projeto_id"):
            where.append(f"r.projeto_id = {db.q(args['projeto_id'])}")
        if args.get("frente_trabalho_id"):
            where.append(f"r.frente_trabalho_id = {db.q(args['frente_trabalho_id'])}")
        if args.get("classificacao"):
            where.append(f"r.classificacao = {db.q(args['classificacao'])}")
        if args.get("atendimento"):
            where.append(f"r.atendimento = {db.q(args['atendimento'])}")
        if args.get("status"):
            where.append(f"r.status = {db.q(args['status'])}")
        if args.get("search"):
            termo = args["search"].replace("'", "''")
            where.append(f"(r.codigo ILIKE '%{termo}%' OR r.titulo ILIKE '%{termo}%' OR r.descricao ILIKE '%{termo}%')")
        sql = (
            "SELECT r.*, f.nome AS frente_nome, res.nome AS responsavel_nome "
            "FROM requisitos_tr r LEFT JOIN frentes_trabalho f ON f.id = r.frente_trabalho_id "
            "LEFT JOIN recursos res ON res.id = r.responsavel_id"
        )
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY r.codigo"
        return jsonify(db.fetch_all(sql))

    @app.post("/api/requisitos")
    def create_requisito():
        return jsonify(insert_row("requisitos_tr", request.get_json(force=True), REQUISITO_FIELDS)), 201

    @app.put("/api/requisitos/<id>")
    def update_requisito(id):
        row = patch_row("requisitos_tr", id, request.get_json(force=True), REQUISITO_FIELDS)
        if not row:
            abort(404)
        return jsonify(row)

    @app.delete("/api/requisitos/<id>")
    def delete_requisito(id):
        db.execute(f"DELETE FROM requisitos_tr WHERE id = {db.q(id)}")
        return "", 204

    @app.post("/api/requisitos/importar-csv")
    def importar_requisitos_csv():
        """Importa/atualiza requisitos do TR em massa a partir de uma planilha CSV.
        Colunas aceitas (cabeçalho, minúsculas, ; ou , como separador):
        codigo*, titulo*, descricao, frente, classificacao, atendimento, status,
        prioridade, cobranca, data_levantamento, observacoes
        (* obrigatórias). "frente" é o NOME da frente de trabalho já cadastrada
        no projeto — se não bater com nenhuma, o requisito é importado sem frente.
        Requisitos com código já existente no projeto são atualizados (upsert)."""
        projeto_id = request.form.get("projeto_id")
        file = request.files.get("file")
        if not (projeto_id and file):
            return jsonify({"erro": "projeto_id e file são obrigatórios"}), 400

        raw_bytes = file.read()
        try:
            raw = raw_bytes.decode("utf-8-sig")
        except UnicodeDecodeError:
            raw = raw_bytes.decode("latin-1")
        if not raw.strip():
            return jsonify({"erro": "Arquivo CSV vazio."}), 400

        primeira_linha = raw.splitlines()[0]
        delimiter = ";" if primeira_linha.count(";") >= primeira_linha.count(",") else ","
        reader = csv.DictReader(io.StringIO(raw), delimiter=delimiter)
        if not reader.fieldnames:
            return jsonify({"erro": "Não foi possível ler o cabeçalho do CSV."}), 400
        reader.fieldnames = [(f or "").strip().lower() for f in reader.fieldnames]
        if "codigo" not in reader.fieldnames or "titulo" not in reader.fieldnames:
            return jsonify({"erro": "O CSV precisa ter, no mínimo, as colunas 'codigo' e 'titulo'."}), 400

        frentes = {
            f["nome"].strip().lower(): f["id"]
            for f in db.fetch_all(f"SELECT id, nome FROM frentes_trabalho WHERE projeto_id = {db.q(projeto_id)}")
        }
        existentes = {
            r["codigo"] for r in db.fetch_all(f"SELECT codigo FROM requisitos_tr WHERE projeto_id = {db.q(projeto_id)}")
        }

        def campo_validado(valor, permitidos, default):
            valor = (valor or "").strip()
            return valor if valor in permitidos else default

        linhas_por_codigo = {}  # dict, não lista — um código repetido no arquivo sobrescreve o anterior
        erros = []
        for i, row in enumerate(reader, start=2):  # linha 1 = cabeçalho
            codigo = (row.get("codigo") or "").strip()
            titulo = (row.get("titulo") or "").strip()
            if not codigo or not titulo:
                erros.append(f"Linha {i}: código e título são obrigatórios — linha ignorada.")
                continue
            if codigo in linhas_por_codigo:
                erros.append(f"Linha {i}: código '{codigo}' repetido no arquivo — só a última ocorrência foi usada.")
            frente_nome = (row.get("frente") or "").strip().lower()
            frente_id = frentes.get(frente_nome)
            if frente_nome and not frente_id:
                erros.append(f"Linha {i}: frente '{row.get('frente')}' não encontrada — requisito importado sem frente.")
            linhas_por_codigo[codigo] = {
                "codigo": codigo,
                "titulo": titulo,
                "descricao": (row.get("descricao") or "").strip() or None,
                "tipo_requisito": "Funcional",
                "modulo_origem": None,
                "frente_trabalho_id": frente_id,
                "classificacao": campo_validado(row.get("classificacao"), CLASSIFICACAO_TR_VALIDAS, "Obrigatório"),
                "atendimento": campo_validado(row.get("atendimento"), ATENDIMENTO_TR_VALIDOS, "A analisar"),
                "status": campo_validado(row.get("status"), STATUS_REQUISITO_VALIDOS, "Não iniciado"),
                "prioridade": campo_validado(row.get("prioridade"), PRIORIDADE_VALIDAS, "Média"),
                "cobranca": campo_validado(row.get("cobranca"), COBRANCA_VALIDAS, "N/A"),
                "data_levantamento": (row.get("data_levantamento") or "").strip() or None,
                "observacoes": (row.get("observacoes") or "").strip() or None,
            }
        linhas_validas = list(linhas_por_codigo.values())

        if not linhas_validas:
            return jsonify({"inseridos": 0, "atualizados": 0,
                             "erros": erros or ["Nenhuma linha válida encontrada no arquivo."]}), 400

        inseridos, atualizados = upsert_requisitos(projeto_id, linhas_validas)
        return jsonify({"inseridos": inseridos, "atualizados": atualizados, "erros": erros})

    # ---------------------------------------------------- importação a partir do TR
    @app.post("/api/requisitos/importar-documento/preview")
    def importar_documento_preview():
        """Recebe o arquivo do Termo de Referência (HTML, DOCX, PDF ou TXT) e
        devolve uma PRÉVIA dos requisitos que seriam importados — não grava
        nada no banco ainda. Ver app/tr_parser.py para o algoritmo de
        extração (baseado em regras, sem IA em tempo de execução)."""
        projeto_id = request.form.get("projeto_id")
        file = request.files.get("file")
        if not (projeto_id and file):
            return jsonify({"erro": "projeto_id e file são obrigatórios"}), 400
        try:
            resultado = tr_parser.parse_tr_document(file.read(), file.filename or "")
        except tr_parser.TrParseError as e:
            return jsonify({"erro": str(e)}), 400
        except Exception as e:
            return jsonify({"erro": f"Falha ao ler o documento: {e}"}), 400

        frentes = {
            f["nome"].strip().lower(): f["id"]
            for f in db.fetch_all(f"SELECT id, nome FROM frentes_trabalho WHERE projeto_id = {db.q(projeto_id)}")
        }
        existentes = {
            r["codigo"] for r in db.fetch_all(
                f"SELECT codigo FROM requisitos_tr WHERE projeto_id = {db.q(projeto_id)}"
            )
        }
        for it in resultado["itens"]:
            it["ja_existe"] = it["codigo"] in existentes
            it["frente_sugerida_id"] = None
            it["frente_sugerida_nome"] = None
            modulo_norm = (it.get("modulo_origem") or "").lower()
            for nome, fid in frentes.items():
                if nome and nome in modulo_norm:
                    it["frente_sugerida_id"] = fid
                    it["frente_sugerida_nome"] = nome
                    break
        resumo = {
            "total": len(resultado["itens"]),
            "funcionais": sum(1 for it in resultado["itens"] if it["tipo_requisito"] == "Funcional"),
            "nao_funcionais": sum(1 for it in resultado["itens"] if it["tipo_requisito"] == "Não Funcional"),
            "ja_existentes": sum(1 for it in resultado["itens"] if it["ja_existe"]),
            "baixa_confianca": resultado.get("baixa_confianca", False),
        }
        return jsonify({"itens": resultado["itens"], "avisos": resultado["avisos"], "resumo": resumo})

    @app.post("/api/requisitos/importar-documento/confirmar")
    def importar_documento_confirmar():
        """Recebe a lista de itens que o usuário revisou/manteve marcados na
        prévia (mesmo formato devolvido por .../preview) e grava de fato,
        via upsert por código — reimportar/reconfirmar atualiza em vez de
        duplicar."""
        data = request.get_json(force=True)
        projeto_id = data.get("projeto_id")
        itens = data.get("itens") or []
        if not projeto_id or not itens:
            return jsonify({"erro": "projeto_id e itens são obrigatórios"}), 400

        linhas = []
        for it in itens:
            codigo = (it.get("codigo") or "").strip()
            titulo = (it.get("titulo") or "").strip()
            if not codigo or not titulo:
                continue
            tipo = it.get("tipo_requisito")
            linhas.append({
                "codigo": codigo,
                "titulo": titulo,
                "descricao": it.get("descricao") or None,
                "tipo_requisito": tipo if tipo in TIPO_REQUISITO_VALIDOS else "Funcional",
                "modulo_origem": it.get("modulo_origem") or None,
                "frente_trabalho_id": it.get("frente_trabalho_id") or it.get("frente_sugerida_id") or None,
                "classificacao": "Obrigatório",
                "atendimento": "A analisar",
                "status": "Não iniciado",
                "prioridade": "Média",
                "cobranca": "N/A",
                "data_levantamento": None,
                "observacoes": None,
            })
        if not linhas:
            return jsonify({"erro": "Nenhum item válido para importar."}), 400

        inseridos, atualizados = upsert_requisitos(projeto_id, linhas)
        return jsonify({"inseridos": inseridos, "atualizados": atualizados})

    @app.get("/api/atividades/<id>/requisitos")
    def list_atividade_requisitos(id):
        sql = (
            "SELECT r.* FROM atividade_requisito ar JOIN requisitos_tr r ON r.id = ar.requisito_id "
            f"WHERE ar.atividade_id = {db.q(id)}"
        )
        return jsonify(db.fetch_all(sql))

    @app.post("/api/atividades/<id>/requisitos")
    def link_atividade_requisito(id):
        rid = request.get_json(force=True).get("requisito_id")
        db.execute(
            f"INSERT INTO atividade_requisito (atividade_id, requisito_id) VALUES ({db.q(id)}, {db.q(rid)}) "
            "ON CONFLICT DO NOTHING"
        )
        return "", 201

    @app.delete("/api/atividades/<id>/requisitos/<rid>")
    def unlink_atividade_requisito(id, rid):
        db.execute(
            f"DELETE FROM atividade_requisito WHERE atividade_id = {db.q(id)} AND requisito_id = {db.q(rid)}"
        )
        return "", 204

    # ----------------------------------------------------------- ciclos migração
    @app.get("/api/ciclos-migracao")
    def list_ciclos():
        aid = request.args.get("atividade_id")
        sql = "SELECT * FROM ciclos_migracao"
        if aid:
            sql += f" WHERE atividade_id = {db.q(aid)}"
        sql += " ORDER BY numero_ciclo"
        return jsonify(db.fetch_all(sql))

    @app.post("/api/ciclos-migracao")
    def create_ciclo():
        return jsonify(insert_row("ciclos_migracao", request.get_json(force=True), CICLO_FIELDS)), 201

    # ------------------------------------------------------------------ marcos
    @app.get("/api/marcos")
    def list_marcos():
        pid = request.args.get("projeto_id")
        sql = "SELECT * FROM marcos"
        if pid:
            sql += f" WHERE projeto_id = {db.q(pid)}"
        sql += " ORDER BY data_prevista"
        return jsonify(db.fetch_all(sql))

    @app.post("/api/marcos")
    def create_marco():
        return jsonify(insert_row("marcos", request.get_json(force=True), MARCO_FIELDS)), 201

    @app.put("/api/marcos/<id>")
    def update_marco(id):
        row = patch_row("marcos", id, request.get_json(force=True), MARCO_FIELDS)
        if not row:
            abort(404)
        return jsonify(row)

    # -------------------------------------------------- importação de cronograma
    @app.post("/api/cronograma/importar/preview")
    def cronograma_importar_preview():
        """Recebe uma planilha (.xlsx exportado do MS Project, ou .csv com as
        mesmas colunas) e devolve uma PRÉVIA — contagens de atividades/marcos
        novos x a atualizar, avisos, e a lista de grupos de Etapa/Frente
        encontrados no WBS para o usuário conferir/ajustar antes de gravar.
        Não grava nada no banco ainda. Ver app/cronograma_import.py."""
        projeto_id = request.form.get("projeto_id")
        file = request.files.get("file")
        if not (projeto_id and file):
            return jsonify({"erro": "projeto_id e file são obrigatórios"}), 400
        try:
            resultado = cronograma_import.preview(projeto_id, file.read(), file.filename or "")
        except cronograma_import.ImportacaoError as e:
            return jsonify({"erro": str(e)}), 400
        except Exception as e:
            print(f"[cronograma_import] ERRO INESPERADO em /preview: {e}", flush=True)
            import traceback
            traceback.print_exc()
            return jsonify({"erro": f"Falha ao ler a planilha: {e}"}), 400
        return jsonify(resultado)

    @app.post("/api/cronograma/importar/confirmar")
    def cronograma_importar_confirmar():
        """Recebe o token da prévia acima + o mapeamento de Etapa/Frente que o
        usuário revisou (cada grupo do WBS aponta pra uma Etapa/Frente já
        existente, ou pede pra criar uma nova com o nome informado) e grava
        de fato — sempre atualizando o projeto atual (nunca cria um projeto
        novo). Reimportar casa cada linha da planilha com a atividade/marco
        já existente (por Id de origem ou, na falta dele, pelo código WBS) e
        atualiza em vez de duplicar; campos preenchidos manualmente
        (recurso, tipo, status Bloqueada/Cancelada, observações, item do
        TR) não são sobrescritos."""
        data = request.get_json(force=True)
        token = data.get("token")
        projeto_id = data.get("projeto_id")
        if not (token and projeto_id):
            return jsonify({"erro": "token e projeto_id são obrigatórios"}), 400
        try:
            resultado = cronograma_import.confirmar(
                token, projeto_id, data.get("mapeamento_etapas") or [], data.get("mapeamento_frentes") or []
            )
        except cronograma_import.ImportacaoError as e:
            return jsonify({"erro": str(e)}), 400
        except db.DbError:
            # deixa cair no handler global (@app.errorhandler(db.DbError) mais abaixo),
            # que já traduz violação de FK/unicidade em mensagem amigável — aqui só
            # não queremos que um erro de banco no meio da importação vire uma
            # exceção genérica sem chegar nesse handler.
            raise
        except Exception as e:
            # Qualquer outro erro inesperado durante a importação (ex: um valor
            # fora do padrão numa linha da planilha que nenhum parser previu):
            # loga a mensagem completa em `docker compose logs backend` (o "log
            # da carga" pedido depois do incidente do openpyxl/timeout) e devolve
            # o motivo real pro navegador, em vez de deixar o Flask devolver um
            # 500 genérico sem corpo JSON (que aparecia como "Erro de Requisição").
            print(f"[cronograma_import] ERRO INESPERADO em /confirmar: {e}", flush=True)
            import traceback
            traceback.print_exc()
            return jsonify({"erro": f"Falha inesperada durante a importação: {e}"}), 500
        return jsonify(resultado)

    @app.get("/api/cronograma/resumo-remocao")
    def cronograma_resumo_remocao():
        """Contagens do que seria apagado por /remover-tudo, para o front
        mostrar antes de pedir a confirmação — nada é apagado aqui."""
        projeto_id = request.args.get("projeto_id")
        if not projeto_id:
            return jsonify({"erro": "projeto_id é obrigatório"}), 400
        row = db.fetch_one(f"""
            SELECT
              (SELECT count(*) FROM atividades WHERE projeto_id = {db.q(projeto_id)}) AS atividades,
              (SELECT count(*) FROM marcos WHERE projeto_id = {db.q(projeto_id)}) AS marcos,
              (SELECT count(*) FROM atividade_dependencia d
                 JOIN atividades a ON a.id = d.atividade_id
                 WHERE a.projeto_id = {db.q(projeto_id)}) AS dependencias,
              (SELECT count(*) FROM atividade_relato r
                 JOIN atividades a ON a.id = r.atividade_id
                 WHERE a.projeto_id = {db.q(projeto_id)}) AS relatos
        """)
        return jsonify(row or {"atividades": 0, "marcos": 0, "dependencias": 0, "relatos": 0})

    @app.post("/api/cronograma/remover-tudo")
    def cronograma_remover_tudo():
        """Apaga TODAS as atividades e marcos do projeto (e, em cascata, tudo
        que pendura neles: dependências, relatos, histórico de status,
        vínculos com requisitos do TR, ciclos de migração, anexos). NÃO
        apaga Etapas, Frentes, Requisitos do TR nem as configurações do
        projeto — só o cronograma em si. Ação irreversível: por isso exige
        que o cliente reenvie, em `confirmacao`, o nome exato do projeto
        (o mesmo mostrado no topo da tela), conferido aqui no servidor
        contra o nome real — digitar errado ou mandar o campo vazio
        recusa o pedido antes de tocar no banco."""
        data = request.get_json(force=True)
        projeto_id = data.get("projeto_id")
        confirmacao = (data.get("confirmacao") or "").strip()
        if not projeto_id:
            return jsonify({"erro": "projeto_id é obrigatório"}), 400
        projeto = db.fetch_one(f"SELECT nome FROM projetos WHERE id = {db.q(projeto_id)}")
        if not projeto:
            abort(404)
        if not confirmacao or confirmacao != projeto["nome"]:
            return jsonify({"erro": "Confirmação não confere com o nome do projeto. Nada foi apagado."}), 400
        db.execute(f"DELETE FROM atividades WHERE projeto_id = {db.q(projeto_id)}")
        db.execute(f"DELETE FROM marcos WHERE projeto_id = {db.q(projeto_id)}")
        return jsonify({"ok": True})

    # ------------------------------------------------------------------ riscos
    @app.get("/api/riscos")
    def list_riscos():
        pid = request.args.get("projeto_id")
        sql = (
            "SELECT ri.*, re.nome AS responsavel_nome FROM riscos ri "
            "LEFT JOIN recursos re ON re.id = ri.responsavel_id"
        )
        if pid:
            sql += f" WHERE ri.projeto_id = {db.q(pid)}"
        sql += " ORDER BY ri.identificado_em DESC"
        return jsonify(db.fetch_all(sql))

    @app.post("/api/riscos")
    def create_risco():
        return jsonify(insert_row("riscos", request.get_json(force=True), RISCO_FIELDS)), 201

    @app.put("/api/riscos/<id>")
    def update_risco(id):
        row = patch_row("riscos", id, request.get_json(force=True), RISCO_FIELDS)
        if not row:
            abort(404)
        return jsonify(row)

    # ------------------------------------------------------------------ anexos
    @app.post("/api/anexos")
    def upload_anexo():
        entidade_tipo = request.form.get("entidade_tipo")
        entidade_id = request.form.get("entidade_id")
        enviado_por = request.form.get("enviado_por", "")
        file = request.files.get("file")
        if not (entidade_tipo and entidade_id and file):
            return jsonify({"erro": "entidade_tipo, entidade_id e file são obrigatórios"}), 400
        ext = os.path.splitext(file.filename)[1]
        stored_name = f"{uuid.uuid4()}{ext}"
        path = os.path.join(UPLOAD_DIR, stored_name)
        file.save(path)
        sql = (
            "INSERT INTO anexos (entidade_tipo, entidade_id, nome_original, caminho_arquivo, tipo_mime, "
            "tamanho_bytes, enviado_por) VALUES ("
            f"{db.q(entidade_tipo)}, {db.q(entidade_id)}, {db.q(file.filename)}, {db.q(stored_name)}, "
            f"{db.q(file.mimetype)}, {os.path.getsize(path)}, {db.q(enviado_por)}) RETURNING *"
        )
        return jsonify(db.execute_returning_one(sql)), 201

    @app.get("/api/anexos")
    def list_anexos():
        et, eid = request.args.get("entidade_tipo"), request.args.get("entidade_id")
        sql = "SELECT * FROM anexos"
        if et and eid:
            sql += f" WHERE entidade_tipo = {db.q(et)} AND entidade_id = {db.q(eid)}"
        sql += " ORDER BY enviado_em DESC"
        return jsonify(db.fetch_all(sql))

    @app.get("/api/anexos/<id>/download")
    def download_anexo(id):
        row = db.fetch_one(f"SELECT * FROM anexos WHERE id = {db.q(id)}")
        if not row:
            abort(404)
        return send_file(os.path.join(UPLOAD_DIR, row["caminho_arquivo"]), download_name=row["nome_original"], as_attachment=True)

    @app.delete("/api/anexos/<id>")
    def delete_anexo(id):
        row = db.fetch_one(f"SELECT * FROM anexos WHERE id = {db.q(id)}")
        if row:
            try:
                os.remove(os.path.join(UPLOAD_DIR, row["caminho_arquivo"]))
            except OSError:
                pass
        db.execute(f"DELETE FROM anexos WHERE id = {db.q(id)}")
        return "", 204

    # -------------------------------------------------------------- relatórios
    @app.get("/api/relatorios/periodo")
    def relatorio_periodo():
        pid, ini, fim = request.args.get("projeto_id"), request.args.get("inicio"), request.args.get("fim")
        if not (pid and ini and fim):
            return jsonify({"erro": "projeto_id, inicio e fim são obrigatórios"}), 400
        sql = (
            ATIVIDADE_SELECT
            + f" WHERE a.projeto_id = {db.q(pid)} AND a.dtini_prev <= {db.q(fim)} AND a.dtfim_prev >= {db.q(ini)}"
            + " ORDER BY a.dtini_prev"
        )
        return jsonify(db.fetch_all(sql))

    @app.get("/api/relatorios/atrasadas")
    def relatorio_atrasadas():
        pid = request.args.get("projeto_id")
        sql = "SELECT * FROM vw_atividades_atrasadas"
        if pid:
            sql += f" WHERE projeto_id = {db.q(pid)}"
        sql += " ORDER BY dias_atraso DESC"
        return jsonify(db.fetch_all(sql))

    @app.get("/api/relatorios/resumo-frentes")
    def relatorio_resumo_frentes():
        pid = request.args.get("projeto_id")
        sql = "SELECT * FROM vw_resumo_frente"
        if pid:
            sql += f" WHERE projeto_id = {db.q(pid)}"
        sql += " ORDER BY frente_nome"
        return jsonify(db.fetch_all(sql))

    # ------------------------------------------------- relatório executivo (IA)
    @app.get("/api/relatorios/executivo")
    def relatorio_executivo_listar():
        """Histórico (sem o conteúdo completo, só o essencial pra montar uma lista
        de 'relatórios anteriores' no Dashboard)."""
        pid = request.args.get("projeto_id")
        if not pid:
            return jsonify({"erro": "projeto_id é obrigatório"}), 400
        sql = (
            f"SELECT id, gerado_em, modelo_ia, gerado_por FROM relatorios_executivos "
            f"WHERE projeto_id = {db.q(pid)} ORDER BY gerado_em DESC LIMIT 20"
        )
        return jsonify(db.fetch_all(sql))

    @app.get("/api/relatorios/executivo/<id>")
    def relatorio_executivo_obter(id):
        row = db.fetch_one(f"SELECT * FROM relatorios_executivos WHERE id = {db.q(id)}")
        if not row:
            abort(404)
        return jsonify(row)

    @app.post("/api/relatorios/executivo/gerar")
    def relatorio_executivo_gerar():
        data = request.get_json(force=True)
        projeto_id = data.get("projeto_id")
        if not projeto_id:
            return jsonify({"erro": "projeto_id é obrigatório"}), 400
        gerado_por = data.get("gerado_por")
        print(f"[relatorio_executivo] iniciando geração para projeto {projeto_id}...", flush=True)
        try:
            row = relatorio_executivo.gerar_relatorio(projeto_id, gerado_por=gerado_por)
        except relatorio_executivo.RelatorioExecutivoError as e:
            print(f"[relatorio_executivo] erro esperado: {e}", flush=True)
            return jsonify({"erro": str(e)}), 400
        except db.DbError:
            raise
        except Exception as e:
            print(f"[relatorio_executivo] ERRO INESPERADO: {e}", flush=True)
            import traceback
            traceback.print_exc()
            return jsonify({"erro": f"Falha inesperada ao gerar o relatório: {e}"}), 500
        print(f"[relatorio_executivo] relatório {row['id']} gerado com sucesso.", flush=True)
        return jsonify(row), 201

    @app.get("/api/relatorios/executivo/<id>/pdf")
    def relatorio_executivo_pdf(id):
        row = db.fetch_one(f"SELECT * FROM relatorios_executivos WHERE id = {db.q(id)}")
        if not row:
            abort(404)
        if isinstance(row.get("dados_enviados"), str):
            row["dados_enviados"] = json.loads(row["dados_enviados"])
        try:
            pdf_bytes = relatorio_pdf.gerar_pdf_bytes(row)
        except Exception as e:
            print(f"[relatorio_executivo] erro ao gerar PDF do relatório {id}: {e}", flush=True)
            import traceback
            traceback.print_exc()
            return jsonify({"erro": f"Falha ao gerar o PDF: {e}"}), 500
        nome_arquivo = f"relatorio-executivo-{row['gerado_em'][:10] if isinstance(row['gerado_em'], str) else id}.pdf"
        return send_file(
            io.BytesIO(pdf_bytes), mimetype="application/pdf",
            as_attachment=True, download_name=nome_arquivo,
        )

    # ------------------------------------ relatório de minhas atividades
    # Apontamento de horas (previsto x realizado) lançado em "Minhas
    # atividades", filtrável por consultor e período — gerado na hora
    # (sem persistir nada, ao contrário do Relatório Executivo (IA)), em
    # PDF ou planilha Excel. Ver app/relatorio_atividades.py.
    def _validar_periodo_relatorio_atividades():
        data_ini, data_fim = request.args.get("data_ini"), request.args.get("data_fim")
        if not data_ini or not data_fim:
            return None, None, (jsonify({"erro": "Informe o período (data início e fim, ou mês/ano)."}), 400)
        if data_fim < data_ini:
            return None, None, (jsonify({"erro": "A data fim não pode ser anterior à data início."}), 400)
        return data_ini, data_fim, None

    @app.get("/api/relatorios/minhas-atividades/pdf")
    def relatorio_atividades_pdf():
        data_ini, data_fim, erro = _validar_periodo_relatorio_atividades()
        if erro:
            return erro
        recurso_id = request.args.get("recurso_id") or None
        try:
            dados = relatorio_atividades.coletar_dados(recurso_id, data_ini, data_fim)
            pdf_bytes = relatorio_atividades.gerar_pdf_bytes(dados)
        except Exception as e:
            print(f"[relatorio_atividades] erro ao gerar PDF: {e}", flush=True)
            import traceback
            traceback.print_exc()
            return jsonify({"erro": f"Falha ao gerar o PDF: {e}"}), 500
        nome_arquivo = f"relatorio-atividades-{data_ini}-a-{data_fim}.pdf"
        return send_file(io.BytesIO(pdf_bytes), mimetype="application/pdf",
                          as_attachment=True, download_name=nome_arquivo)

    @app.get("/api/relatorios/minhas-atividades/planilha")
    def relatorio_atividades_planilha():
        data_ini, data_fim, erro = _validar_periodo_relatorio_atividades()
        if erro:
            return erro
        recurso_id = request.args.get("recurso_id") or None
        try:
            dados = relatorio_atividades.coletar_dados(recurso_id, data_ini, data_fim)
            xlsx_bytes = relatorio_atividades.gerar_planilha_bytes(dados)
        except Exception as e:
            print(f"[relatorio_atividades] erro ao gerar planilha: {e}", flush=True)
            import traceback
            traceback.print_exc()
            return jsonify({"erro": f"Falha ao gerar a planilha: {e}"}), 500
        nome_arquivo = f"relatorio-atividades-{data_ini}-a-{data_fim}.xlsx"
        return send_file(
            io.BytesIO(xlsx_bytes),
            mimetype="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            as_attachment=True, download_name=nome_arquivo,
        )

    # -------------------------------------------------------------------- cpm
    @app.post("/api/cpm/recalcular")
    def cpm_recalcular():
        pid = (request.get_json(silent=True) or {}).get("projeto_id") or request.args.get("projeto_id")
        if not pid:
            return jsonify({"erro": "projeto_id é obrigatório"}), 400
        try:
            resultado = cpm.recalcular(pid)
        except ValueError as e:
            return jsonify({"erro": str(e)}), 400
        return jsonify(resultado)

    @app.get("/api/cpm/caminho-critico")
    def cpm_caminho_critico():
        pid = request.args.get("projeto_id")
        sql = "SELECT * FROM vw_caminho_critico"
        if pid:
            sql += f" WHERE projeto_id = {db.q(pid)}"
        return jsonify(db.fetch_all(sql))

    # -------------------------------------------------------------- documentação
    # Configurações > Documentação: dois documentos vivos do próprio sistema
    # (Documento Executivo e Documento Técnico), guardados no banco (tabela
    # `documentacao`, ver db/migration_014_documentacao.sql) em vez de fixos
    # no frontend, para poderem ser atualizados sem precisar de um novo
    # deploy. O PDF é gerado no navegador (impressão), sem rota de backend
    # dedicada. Sem hierarquia de perfil no sistema (ver seção 4 do Documento
    # Técnico), o PUT abaixo fica acessível a qualquer usuário autenticado,
    # igual a todo o resto das rotas de Configurações.
    DOCUMENTACAO_TIPOS = {"executivo", "tecnico"}

    @app.get("/api/documentacao")
    def listar_documentacao():
        """Lista só os metadados (sem o conteúdo, que pode ser grande) —
        usada pela tela de listagem em Configurações > Documentação."""
        return jsonify(db.fetch_all(
            "SELECT tipo, titulo, versao, atualizado_em FROM documentacao ORDER BY tipo"
        ))

    @app.get("/api/documentacao/<tipo>")
    def obter_documentacao(tipo):
        if tipo not in DOCUMENTACAO_TIPOS:
            abort(404)
        row = db.fetch_one(f"SELECT * FROM documentacao WHERE tipo = {db.q(tipo)}")
        if not row:
            abort(404)
        return jsonify(row)

    @app.put("/api/documentacao/<tipo>")
    def atualizar_documentacao(tipo):
        if tipo not in DOCUMENTACAO_TIPOS:
            abort(404)
        data = request.get_json(force=True)
        sets = []
        if "titulo" in data:
            sets.append(f"titulo = {db.q(data['titulo'])}")
        if "versao" in data:
            sets.append(f"versao = {db.q(data['versao'])}")
        if "conteudo_md" in data:
            sets.append(f"conteudo_md = {db.q(data['conteudo_md'])}")
        if not sets:
            return jsonify({"erro": "Nada para atualizar."}), 400
        sets.append("atualizado_em = now()")
        sql = f"UPDATE documentacao SET {', '.join(sets)} WHERE tipo = {db.q(tipo)} RETURNING *"
        row = db.execute_returning_one(sql)
        if not row:
            abort(404)
        return jsonify(row)

    # -------------------------------------------------------------- error handling
    @app.errorhandler(db.DbError)
    def handle_db_error(e):
        msg = str(e)
        baixo = msg.lower()
        if "violates foreign key constraint" in baixo:
            return jsonify({
                "erro": "Não é possível excluir: existem outros registros vinculados a este item "
                        "(ex: atividades usando esta etapa/frente/tipo/recurso). "
                        "Marque como inativo em vez de excluir, se possível.",
            }), 409
        if "duplicate key value violates unique constraint" in baixo:
            return jsonify({"erro": "Já existe um registro com esses mesmos dados (código/nome duplicado)."}), 409
        return jsonify({"erro": msg}), 500

    # ------------------------------------------------------------ front-end estático
    @app.get("/")
    def index():
        return send_from_directory(FRONTEND_DIR, "index.html")

    @app.get("/<path:path>")
    def static_files(path):
        full = os.path.join(FRONTEND_DIR, path)
        if os.path.isfile(full):
            return send_from_directory(FRONTEND_DIR, path)
        return send_from_directory(FRONTEND_DIR, "index.html")

    return app


if __name__ == "__main__":
    create_app().run(host="0.0.0.0", port=int(os.environ.get("PORT", 8000)), debug=True)
