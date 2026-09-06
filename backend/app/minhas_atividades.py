"""
"Minhas atividades" — grade semanal do consultor logado.

Cada usuário logado (tabela `usuarios`) enxerga aqui as atividades do
cronograma em que o profissional vinculado a ele (tabela `recursos`) aparece
como Responsável Techne OU Responsável cliente. O vínculo entre as duas
tabelas não é uma coluna nova: é resolvido em tempo de consulta comparando
o e-mail de login com o e-mail cadastrado no Responsável (ambos
case-insensitive) — ver `recursos_do_usuario()`. Um usuário cujo e-mail não
bate com nenhum Responsável cadastrado simplesmente não tem nada pra ver
aqui (a rota devolve `vinculado: False`, e o front-end explica o que fazer).

Desde a 16ª rodada, a grade traz atividades de TODOS os projetos em que o
profissional está delegado, não só do projeto selecionado no cabeçalho —
"Minhas atividades" é o apontamento pessoal de horas do consultor na
empresa, e `recursos` sempre foi uma tabela global (sem `projeto_id`), então
não faz sentido restringir a um projeto só quando a mesma pessoa pode
atender vários clientes ao mesmo tempo, inclusive na mesma semana. Ver
`montar_grade()`.

Para cada atividade, a grade mostra os dias úteis da semana escolhida (por
padrão, a semana atual) com a hora prevista de cada dia. Essa quebra diária
é gerada automaticamente, uma única vez por atividade (`garantir_dias()`),
dividindo `atividades.prazo_horas` igualmente pelos dias úteis entre
`dtini_prev` e `dtfim_prev` — dali em diante a tabela `atividade_horas_dia`
passa a ser a fonte de verdade daquela atividade, dia a dia (editar o total
geral ou as datas da atividade depois não regenera a grade — ver comentário
em db/schema.sql, seção 18).

Cabe ao consultor, em cada dia: (a) ajustar o número de horas previstas
daquele dia (`ajustar_dia`), ou (b) simplesmente confirmar a execução
(`confirmar_dia`, que grava `horas_realizadas` = o valor informado, ou o
previsto atual se nada for informado). Editar o previsto de um dia já
confirmado desfaz a confirmação (força reconfirmar), pra nunca deixar uma
hora "confirmada" que não corresponde mais ao número exibido.

Até a 16ª rodada, nenhuma ação aqui tocava `atividades.horas_realizadas` (o
total agregado, editável manualmente no modal da atividade desde a 4ª
rodada) — de propósito, para não sobrescrever silenciosamente um valor
lançado por outro caminho. A partir da 16ª rodada (parte 3), a pedido
explícito do usuário, isso mudou: uma vez que uma atividade tem quebra
diária (ou seja, já apareceu em "Minhas atividades" de alguém),
`atividades.horas_realizadas` passa a ser a SOMA dos dias já confirmados
aqui, recalculada a cada ajuste/confirmação/desconfirmação — ver
`_sincronizar_horas_realizadas()`. O campo manual do modal de atividade
(`backend/app/main.py:update_atividade`) passa a ser ignorado nesse caso
(e o front-end trava o campo), evitando os dois números divergirem.
Atividades que nunca tiveram quebra diária gerada continuam com o campo
100% manual, como sempre foi.
"""
import uuid
from datetime import date, timedelta

from . import db


class MinhasAtividadesError(Exception):
    """Erro esperado (autorização, validação) — sempre devolvido como 400/404
    pela rota, nunca um 500 genérico."""
    pass


def _parse_data(v):
    if v is None:
        return None
    return date.fromisoformat(v) if isinstance(v, str) else v


def recursos_do_usuario(email):
    """Ids de todos os Responsáveis (recursos) cujo e-mail cadastrado bate
    (case-insensitive) com o e-mail de login do usuário. Normalmente 0 ou 1,
    mas nada impede mais de um cadastro de Responsável com o mesmo e-mail —
    nesse caso, atividades delegadas a qualquer um deles aparecem juntas."""
    email = (email or "").strip().lower()
    if not email:
        return []
    linhas = db.fetch_all(f"SELECT id, nome FROM recursos WHERE lower(email) = {db.q(email)}")
    return linhas


def semana_de(data_ref: date):
    """Segunda a sexta (5 datas) da semana que contém data_ref."""
    segunda = data_ref - timedelta(days=data_ref.weekday())
    return [segunda + timedelta(days=i) for i in range(5)]


def _non_working(projeto_id):
    """Exceções ao calendário padrão (feriados/recessos) cadastradas para o
    projeto — mesma fonte usada pelo CPM (ver backend/app/cpm.py)."""
    excecoes = db.fetch_all(
        f"SELECT data FROM calendario_util WHERE projeto_id = {db.q(projeto_id)} AND util = FALSE"
    )
    return {_parse_data(e["data"]) for e in excecoes}


def _dias_uteis_periodo(data_ini, data_fim, non_working):
    """Lista de dias úteis (seg-sex, exceto exceções em calendario_util)
    entre data_ini e data_fim, inclusive. Se não sobrar nenhum (ex: janela
    cai inteira num fim de semana/feriado, ou datas invertidas), cai para
    [data_ini] como piso de segurança — sempre precisa de ao menos 1 dia
    para distribuir as horas previstas."""
    if data_fim < data_ini:
        data_ini, data_fim = data_fim, data_ini
    dias = []
    d = data_ini
    while d <= data_fim:
        if d.weekday() < 5 and d not in non_working:
            dias.append(d)
        d += timedelta(days=1)
    return dias or [data_ini]


def _sincronizar_horas_realizadas(atividade_id):
    """16ª rodada (parte 3): grava em `atividades.horas_realizadas` a soma
    das `horas_realizadas` dos dias já CONFIRMADOS desta atividade em
    `atividade_horas_dia`. Chamada (a) quando a quebra diária é gerada pela
    primeira vez (o total nasce em 0 — nada foi confirmado ainda) e (b) a
    cada ajustar/confirmar/desconfirmar um dia. A partir do momento em que
    isso roda pela primeira vez para uma atividade, o campo manual do modal
    de atividade deixa de valer (ver `tem_apontamento_diario` em
    `backend/app/main.py:ATIVIDADE_SELECT` e o bloqueio em
    `update_atividade`) — este total, não mais uma digitação manual, é a
    fonte de verdade dali em diante."""
    linha = db.fetch_one(f"""
        SELECT COALESCE(SUM(horas_realizadas), 0) AS total
        FROM atividade_horas_dia
        WHERE atividade_id = {db.q(atividade_id)} AND confirmado = TRUE
    """)
    total = linha["total"] if linha else 0
    db.execute(f"UPDATE atividades SET horas_realizadas = {db.q(total)} WHERE id = {db.q(atividade_id)}")


def garantir_dias(atividade, non_working):
    """Gera a quebra diária (atividade_horas_dia) da atividade inteira, uma
    única vez. Idempotente: se já existir qualquer linha para esta
    atividade, não faz nada (ver docstring do módulo — a grade diária, uma
    vez criada, é a fonte de verdade). Não gera nada se a atividade não tiver
    data de início/fim previstas ou horas previstas cadastradas (não há como
    distribuir)."""
    ja_existe = db.fetch_one(
        f"SELECT 1 AS x FROM atividade_horas_dia WHERE atividade_id = {db.q(atividade['id'])} LIMIT 1"
    )
    if ja_existe:
        return
    dtini, dtfim, prazo = atividade.get("dtini_prev"), atividade.get("dtfim_prev"), atividade.get("prazo_horas")
    if not dtini or not dtfim or not prazo:
        return
    dtini, dtfim = _parse_data(dtini), _parse_data(dtfim)
    dias = _dias_uteis_periodo(dtini, dtfim, non_working)
    prazo = float(prazo)
    horas_por_dia = round(prazo / len(dias), 2)
    acumulado = 0.0
    valores = []
    for i, d in enumerate(dias):
        # o último dia absorve a diferença de arredondamento, pra soma bater exatamente com prazo_horas
        h = round(prazo - acumulado, 2) if i == len(dias) - 1 else horas_por_dia
        acumulado += h
        valores.append(
            f"({db.q(str(uuid.uuid4()))}, {db.q(atividade['id'])}, {db.q(d.isoformat())}, {db.q(h)})"
        )
    sql = "INSERT INTO atividade_horas_dia (id, atividade_id, data, horas_previstas) VALUES " + ", ".join(valores)
    db.execute(sql)
    # A partir de agora esta atividade tem quebra diária — sincroniza
    # atividades.horas_realizadas (nasce em 0, já que nada foi confirmado
    # ainda) e, a partir daqui, o campo manual do modal fica travado.
    _sincronizar_horas_realizadas(atividade["id"])


def montar_grade(usuario, data_ref: date):
    """Monta a resposta completa de GET /api/minhas-atividades: a semana
    (seg-sex) ao redor de data_ref, e cada atividade delegada ao(s)
    profissional(is) vinculado(s) ao usuário logado, com os 5 dias da grade.

    16ª rodada: deixou de receber `projeto_id` e de filtrar por ele. "Minhas
    atividades" é um apontamento pessoal de horas trabalhadas na empresa —
    o mesmo profissional pode estar delegado em atividades de vários
    projetos (clientes) ao mesmo tempo, inclusive na mesma semana, já que
    `recursos` sempre foi uma tabela global (sem `projeto_id`), sem nenhuma
    trava impedindo isso no banco. Antes disso a tela só olhava para o
    projeto selecionado no seletor do cabeçalho, escondendo atividades de
    outros projetos na mesma semana. Cada atividade retornada agora traz
    `projeto_id`/`projeto_sigla`/`projeto_nome` para o front-end identificar
    de qual projeto ela é."""
    recursos = recursos_do_usuario(usuario.get("email") if usuario else None)
    dias_semana = semana_de(data_ref)
    inicio, fim = dias_semana[0], dias_semana[-1]
    semana_info = {
        "inicio": inicio.isoformat(), "fim": fim.isoformat(),
        "dias": [d.isoformat() for d in dias_semana],
    }
    if not recursos:
        return {"vinculado": False, "recurso_nomes": [], "atividades": [], "semana": semana_info}

    recurso_ids = [r["id"] for r in recursos]
    placeholders = ", ".join(db.q(rid) for rid in recurso_ids)
    atividades = db.fetch_all(f"""
        SELECT a.id, a.nome, a.codigo_wbs, a.status, a.prazo_horas, a.dtini_prev, a.dtfim_prev,
               a.projeto_id, p.sigla AS projeto_sigla, p.nome AS projeto_nome,
               e.numero AS etapa_numero, e.nome AS etapa_nome, f.nome AS frente_nome,
               rt.nome AS responsavel_techne_nome, rc.nome AS responsavel_cliente_nome
        FROM atividades a
        JOIN projetos p ON p.id = a.projeto_id
        JOIN etapas e ON e.id = a.etapa_id
        JOIN frentes_trabalho f ON f.id = a.frente_trabalho_id
        LEFT JOIN recursos rt ON rt.id = a.responsavel_techne_id
        LEFT JOIN recursos rc ON rc.id = a.responsavel_cliente_id
        WHERE (a.responsavel_techne_id IN ({placeholders}) OR a.responsavel_cliente_id IN ({placeholders}))
          AND a.dtini_prev IS NOT NULL AND a.dtfim_prev IS NOT NULL AND a.prazo_horas IS NOT NULL
          AND a.dtini_prev <= {db.q(fim.isoformat())} AND a.dtfim_prev >= {db.q(inicio.isoformat())}
        ORDER BY p.sigla NULLS LAST, p.nome, e.numero, a.codigo_wbs NULLS LAST, a.nome
    """)

    # Calendário de feriados/recessos é por projeto (calendario_util) — com
    # atividades de vários projetos na mesma resposta agora, cada uma usa o
    # calendário do SEU projeto, não de um só; cache simples por projeto_id
    # pra não repetir a consulta a cada atividade do mesmo projeto.
    non_working_por_projeto = {}
    for a in atividades:
        pid = a["projeto_id"]
        if pid not in non_working_por_projeto:
            non_working_por_projeto[pid] = _non_working(pid)
        garantir_dias(a, non_working_por_projeto[pid])

    por_atividade = {}
    if atividades:
        id_list = ", ".join(db.q(a["id"]) for a in atividades)
        linhas = db.fetch_all(f"""
            SELECT * FROM atividade_horas_dia
            WHERE atividade_id IN ({id_list}) AND data BETWEEN {db.q(inicio.isoformat())} AND {db.q(fim.isoformat())}
        """)
        for l in linhas:
            por_atividade.setdefault(l["atividade_id"], {})[_parse_data(l["data"]).isoformat()] = l

    resultado = []
    for a in atividades:
        dtini, dtfim = _parse_data(a["dtini_prev"]), _parse_data(a["dtfim_prev"])
        non_working = non_working_por_projeto[a["projeto_id"]]
        dias_resp = []
        for d in dias_semana:
            linha = por_atividade.get(a["id"], {}).get(d.isoformat())
            dias_resp.append({
                "data": d.isoformat(),
                "dentro_periodo": dtini <= d <= dtfim,
                "feriado": d in non_working,
                "id": linha["id"] if linha else None,
                "horas_previstas": linha["horas_previstas"] if linha else None,
                "horas_realizadas": linha["horas_realizadas"] if linha else None,
                "confirmado": bool(linha["confirmado"]) if linha else False,
            })
        resultado.append({**a, "dias": dias_resp})

    return {
        "vinculado": True,
        "recurso_nomes": [r["nome"] for r in recursos],
        "atividades": resultado,
        "semana": semana_info,
    }


def _linha_autorizada(horas_dia_id, recurso_ids):
    """Confirma que a linha existe E que a atividade dona dela está mesmo
    delegada a um dos profissionais vinculados ao usuário logado — sem isso,
    qualquer usuário logado poderia editar as horas de qualquer atividade só
    sabendo o id da linha."""
    if not recurso_ids:
        return None
    placeholders = ", ".join(db.q(rid) for rid in recurso_ids)
    return db.fetch_one(f"""
        SELECT hd.* FROM atividade_horas_dia hd
        JOIN atividades a ON a.id = hd.atividade_id
        WHERE hd.id = {db.q(horas_dia_id)}
          AND (a.responsavel_techne_id IN ({placeholders}) OR a.responsavel_cliente_id IN ({placeholders}))
    """)


def _validar_horas(valor):
    try:
        valor = float(valor)
    except (TypeError, ValueError):
        raise MinhasAtividadesError("Informe um número de horas válido.")
    if valor < 0:
        raise MinhasAtividadesError("As horas não podem ser negativas.")
    return round(valor, 2)


def ajustar_dia(horas_dia_id, usuario, horas_previstas):
    """Ajusta a hora prevista de um dia específico. Se o dia já estava
    confirmado, a confirmação é desfeita automaticamente — o valor exibido
    mudou, então uma confirmação anterior não vale mais para esse número."""
    recurso_ids = [r["id"] for r in recursos_do_usuario(usuario.get("email") if usuario else None)]
    linha = _linha_autorizada(horas_dia_id, recurso_ids)
    if not linha:
        raise MinhasAtividadesError("Dia não encontrado ou a atividade não está delegada a você.")
    valor = _validar_horas(horas_previstas)
    resultado = db.execute_returning_one(f"""
        UPDATE atividade_horas_dia
        SET horas_previstas = {db.q(valor)}, confirmado = FALSE, confirmado_em = NULL, confirmado_por = NULL
        WHERE id = {db.q(horas_dia_id)}
        RETURNING *
    """)
    _sincronizar_horas_realizadas(linha["atividade_id"])
    return resultado


def confirmar_dia(horas_dia_id, usuario, horas=None):
    """Confirma a execução de um dia: grava horas_realizadas com o valor
    informado, ou com a hora prevista atual se nada for informado (o caso de
    'apenas confirmar', sem digitar nada de novo)."""
    recurso_ids = [r["id"] for r in recursos_do_usuario(usuario.get("email") if usuario else None)]
    linha = _linha_autorizada(horas_dia_id, recurso_ids)
    if not linha:
        raise MinhasAtividadesError("Dia não encontrado ou a atividade não está delegada a você.")
    valor = _validar_horas(horas) if horas is not None else _validar_horas(linha["horas_previstas"])
    resultado = db.execute_returning_one(f"""
        UPDATE atividade_horas_dia
        SET horas_realizadas = {db.q(valor)}, confirmado = TRUE,
            confirmado_em = now(), confirmado_por = {db.q(usuario["id"])}
        WHERE id = {db.q(horas_dia_id)}
        RETURNING *
    """)
    _sincronizar_horas_realizadas(linha["atividade_id"])
    return resultado


def desconfirmar_dia(horas_dia_id, usuario):
    """Desfaz a confirmação de um dia, liberando pra editar de novo."""
    recurso_ids = [r["id"] for r in recursos_do_usuario(usuario.get("email") if usuario else None)]
    linha = _linha_autorizada(horas_dia_id, recurso_ids)
    if not linha:
        raise MinhasAtividadesError("Dia não encontrado ou a atividade não está delegada a você.")
    resultado = db.execute_returning_one(f"""
        UPDATE atividade_horas_dia
        SET confirmado = FALSE, confirmado_em = NULL, confirmado_por = NULL
        WHERE id = {db.q(horas_dia_id)}
        RETURNING *
    """)
    _sincronizar_horas_realizadas(linha["atividade_id"])
    return resultado
