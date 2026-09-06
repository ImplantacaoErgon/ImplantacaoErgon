"""
Cálculo do Caminho Crítico (CPM — Critical Path Method).

Suporta integralmente dependências Fim-Início (FS), que é o caso de uso
predominante em cronogramas de implantação. SS/FF/SF são calculadas por
aproximação (mesma fórmula geral adaptada) — para redes com muitas
dependências desses tipos, revise os resultados manualmente.

A duração de cada atividade é convertida de horas para dias úteis usando
`projetos.horas_dia_util`. Os deslocamentos (ES/EF/LS/LF) são inteiros em
dias úteis a partir do início do projeto; datas de calendário são obtidas
pulando fins de semana e as exceções cadastradas em `calendario_util`.
"""
from datetime import timedelta

import networkx as nx

from . import db


def _dur_dias(prazo_horas, horas_dia_util):
    if not prazo_horas or prazo_horas <= 0:
        return 1
    return max(1, round(float(prazo_horas) / float(horas_dia_util)))


def _business_day_offset(base_date, non_working, n):
    """Data que fica n dias úteis após base_date (n=0 -> primeiro dia útil >= base_date)."""
    d = base_date
    count = 0
    while True:
        if d.weekday() < 5 and d not in non_working:
            if count == n:
                return d
            count += 1
        d += timedelta(days=1)


def dias_uteis_entre(data_inicio, data_fim, non_working=frozenset()):
    """Quantidade de dias úteis entre duas datas (>= 0; se data_fim < data_inicio,
    retorna a diferença negativa — quem chama decide o que fazer com atraso).
    Usada pelo relatório executivo (app/relatorio_executivo.py) para medir ritmo
    de execução (% concluído por dia útil decorrido) e reprojetar prazos."""
    if data_fim == data_inicio:
        return 0
    sinal = 1 if data_fim > data_inicio else -1
    d1, d2 = (data_inicio, data_fim) if sinal > 0 else (data_fim, data_inicio)
    count = 0
    d = d1
    while d < d2:
        if d.weekday() < 5 and d not in non_working:
            count += 1
        d += timedelta(days=1)
    return sinal * count


def recalcular(projeto_id: str) -> dict:
    projeto = db.fetch_one(f"SELECT * FROM projetos WHERE id = {db.q(projeto_id)}")
    if not projeto:
        raise ValueError("Projeto não encontrado")
    horas_dia_util = float(projeto.get("horas_dia_util") or 8.0)

    atividades = db.fetch_all(
        f"SELECT id, prazo_horas, dtini_prev FROM atividades WHERE projeto_id = {db.q(projeto_id)}"
    )
    if not atividades:
        return {"atividades_calculadas": 0, "caminho_critico": []}

    deps = db.fetch_all(
        "SELECT ad.atividade_id, ad.predecessora_id, ad.tipo, ad.lag_horas "
        "FROM atividade_dependencia ad "
        f"JOIN atividades a ON a.id = ad.atividade_id AND a.projeto_id = {db.q(projeto_id)}"
    )

    dur = {a["id"]: _dur_dias(a["prazo_horas"], horas_dia_util) for a in atividades}
    ids = list(dur.keys())

    g = nx.DiGraph()
    g.add_nodes_from(ids)
    for d in deps:
        g.add_edge(d["predecessora_id"], d["atividade_id"], tipo=d["tipo"], lag=_dur_dias(d["lag_horas"], horas_dia_util) if d["lag_horas"] else 0)

    try:
        ordem = list(nx.topological_sort(g))
    except nx.NetworkXUnfeasible:
        raise ValueError("Existe um ciclo de dependências entre atividades — corrija antes de recalcular.")

    ES, EF = {}, {}
    for n in ordem:
        candidatos = [0]
        for pred, _, edata in g.in_edges(n, data=True):
            tipo, lag = edata["tipo"], edata["lag"]
            if tipo == "FS":
                candidatos.append(EF[pred] + lag)
            elif tipo == "SS":
                candidatos.append(ES[pred] + lag)
            elif tipo == "FF":
                candidatos.append(EF[pred] + lag - dur[n])
            elif tipo == "SF":
                candidatos.append(ES[pred] + lag - dur[n])
        ES[n] = max(candidatos)
        EF[n] = ES[n] + dur[n]

    fim_projeto = max(EF.values()) if EF else 0

    LS, LF = {}, {}
    for n in reversed(ordem):
        sucessores = list(g.out_edges(n, data=True))
        if not sucessores:
            LF[n] = fim_projeto
        else:
            candidatos = []
            for _, succ, edata in sucessores:
                tipo, lag = edata["tipo"], edata["lag"]
                if tipo == "FS":
                    candidatos.append(LS[succ] - lag)
                elif tipo == "SS":
                    candidatos.append((LS[succ] - lag) + dur[n])
                elif tipo == "FF":
                    candidatos.append(LF[succ] - lag)
                elif tipo == "SF":
                    candidatos.append((LF[succ] - lag) + dur[n])
            LF[n] = min(candidatos) if candidatos else fim_projeto
        LS[n] = LF[n] - dur[n]

    # calendário: data de início do projeto + exceções não-úteis
    data_inicio = projeto.get("data_inicio")
    if not data_inicio:
        datas_ini = [a["dtini_prev"] for a in atividades if a.get("dtini_prev")]
        data_inicio = min(datas_ini) if datas_ini else None
    if isinstance(data_inicio, str):
        from datetime import date
        data_inicio = date.fromisoformat(data_inicio)

    excecoes = db.fetch_all(
        f"SELECT data FROM calendario_util WHERE projeto_id = {db.q(projeto_id)} AND util = FALSE"
    )
    from datetime import date
    non_working = {date.fromisoformat(e["data"]) if isinstance(e["data"], str) else e["data"] for e in excecoes}

    def offset_to_date(offset):
        if data_inicio is None:
            return None
        return _business_day_offset(data_inicio, non_working, int(round(offset)))

    stmts = ["BEGIN;"]
    caminho_critico = []
    for n in ids:
        folga = LS[n] - ES[n]
        critica = folga <= 0
        es_data, ef_data, ls_data, lf_data = (offset_to_date(ES[n]), offset_to_date(EF[n]),
                                               offset_to_date(LS[n]), offset_to_date(LF[n]))
        stmts.append(
            "UPDATE atividades SET "
            f"cpm_es_dias={ES[n]}, cpm_ef_dias={EF[n]}, cpm_ls_dias={LS[n]}, cpm_lf_dias={LF[n]}, "
            f"cpm_folga_dias={folga}, cpm_critica={'TRUE' if critica else 'FALSE'}, "
            f"cpm_es_data={db.q(es_data.isoformat()) if es_data else 'NULL'}, "
            f"cpm_ef_data={db.q(ef_data.isoformat()) if ef_data else 'NULL'}, "
            f"cpm_ls_data={db.q(ls_data.isoformat()) if ls_data else 'NULL'}, "
            f"cpm_lf_data={db.q(lf_data.isoformat()) if lf_data else 'NULL'}, "
            f"cpm_calculado_em=now() WHERE id={db.q(n)};"
        )
        if critica:
            caminho_critico.append(n)
    stmts.append("COMMIT;")
    db.execute("\n".join(stmts))

    return {"atividades_calculadas": len(ids), "duracao_projeto_dias_uteis": fim_projeto,
            "caminho_critico": caminho_critico}
