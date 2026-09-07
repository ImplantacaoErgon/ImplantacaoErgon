"""
Manuais do Sistema (Configurações > Manuais do Sistema) e busca por
referência para a tela "Analisar Requisitos".

Escopo desta primeira versão (24ª/25ª rodadas de implantação): busca por
PALAVRA-CHAVE, sem nenhuma chamada de IA — usa só o suporte nativo de busca
textual do Postgres (tsvector/tsquery/ts_rank/ts_headline, configuração
"portuguese"), que já lida com plural/conjugação/acentuação sem precisar de
extensão nenhuma no banco. Nada aqui chama a API da Anthropic (esse é o
único módulo de análise do sistema que NÃO usa IA — comparar com
relatorio_executivo.py).

Fluxo:
  1. Um manual (PDF) é enviado em Configurações > Manuais do Sistema —
     `extrair_paginas_pdf()` quebra o arquivo em texto por página (via
     `pypdf`, mesma biblioteca já usada em tr_parser.py — sem OCR: um
     manual só de imagem escaneada não gera texto pesquisável, mesma
     limitação que o import de TR já tinha).
  2. Cada página vira uma linha em `manual_paginas`, com uma coluna
     `busca` (tsvector) calculada automaticamente pelo próprio Postgres
     via `GENERATED ALWAYS AS (to_tsvector('portuguese', texto)) STORED`
     — não precisa de nenhum código Python pra manter essa coluna
     sincronizada.
  3. Ao "Analisar" um requisito, `montar_tsquery()` extrai os termos
     relevantes do título+descrição do requisito (removendo palavras
     gramaticais comuns) e `buscar_referencias()` roda uma busca OR
     desses termos contra todas as páginas de manuais ativos, ranqueada
     por `ts_rank` — as melhores páginas viram sugestões de referência,
     com o trecho já recortado ao redor dos termos batidos via
     `ts_headline` (também nativo do Postgres, sem lógica extra aqui).

É uma busca por sobreposição de vocabulário, não por significado — pode
não achar uma referência cujo texto use palavras muito diferentes do
requisito, mesmo tratando do mesmo assunto. Por isso o resultado é sempre
tratado como CANDIDATO pra revisão do consultor, nunca como resposta
definitiva — a classificação de atendimento e a "Resposta oficial"
continuam 100% humanas, sem nenhuma automação.
"""
import io
import re

from . import db


class ManualError(Exception):
    pass


TAMANHO_MAXIMO_BYTES = 40 * 1024 * 1024  # 40 MB por manual

# Colunas leves de `manuais` — nunca inclui `arquivo_dados` (o PDF em
# base64, que pode ter dezenas de MB) em listagens genéricas, mesmo
# princípio já usado para o logo (PARAMETROS_COLUNAS_LEVES) e pra
# documentacao. Servir o PDF em si tem rota própria (GET .../pdf).
MANUAL_COLUNAS_LEVES = "id, nome, versao, arquivo_nome, arquivo_mime, tamanho_bytes, paginas_total, ativo, enviado_em"

RELEVANCIA_MINIMA = 0.01  # ts_rank abaixo disso não é mostrado como candidato
MAX_REFERENCIAS_POR_REQUISITO = 3
MAX_TERMOS_BUSCA = 40  # evita tsquery gigante em descrições muito longas

# Palavras gramaticais comuns em português — removidas antes de montar a
# busca (não é uma lista de "palavras proibidas" do domínio: termos como
# "sistema"/"folha"/"servidor" continuam valendo como termo de busca de
# propósito, mesmo sendo frequentes, porque ainda carregam significado).
STOPWORDS_PT = {
    "a", "à", "às", "ao", "aos", "aquela", "aquelas", "aquele", "aqueles", "aquilo",
    "as", "até", "com", "como", "da", "das", "de", "dela", "delas", "dele", "deles",
    "depois", "do", "dos", "e", "ela", "elas", "ele", "eles", "em", "entre", "era",
    "essa", "essas", "esse", "esses", "esta", "estas", "este", "estes", "esta", "eu",
    "isso", "isto", "já", "lhe", "lhes", "mais", "mas", "me", "mesmo", "meu", "meus",
    "minha", "minhas", "muito", "na", "nas", "nem", "no", "nos", "nós", "nossa",
    "nossas", "nosso", "nossos", "num", "numa", "o", "os", "ou", "para", "pela",
    "pelas", "pelo", "pelos", "por", "qual", "quando", "que", "quem", "se", "sem",
    "será", "seu", "seus", "só", "sua", "suas", "também", "te", "teu", "teus", "tu",
    "tua", "tuas", "tudo", "um", "uma", "você", "vocês", "vos", "onde", "cada",
    "outro", "outra", "outros", "outras", "todo", "toda", "todos", "todas", "sob",
    "sobre", "após", "durante", "conforme", "mediante", "acordo", "presente",
}

_PALAVRA_RE = re.compile(r"[A-Za-zÀ-ÖØ-öø-ÿ]{4,}")


def extrair_paginas_pdf(conteudo_bytes):
    """Devolve uma lista [{numero_pagina, texto}, ...], uma por página do
    PDF, na ordem do arquivo. `texto` pode vir vazio numa página só de
    imagem/tabela escaneada (pypdf não faz OCR) — a página ainda é
    gravada (pra numeração ficar certa), só não participa da busca."""
    try:
        import pypdf
    except ImportError:
        raise ManualError("Pacote 'pypdf' não instalado na imagem do backend.")
    try:
        reader = pypdf.PdfReader(io.BytesIO(conteudo_bytes))
    except Exception as e:
        raise ManualError(f"Não foi possível ler o PDF: {e}")
    paginas = []
    for i, page in enumerate(reader.pages, start=1):
        try:
            texto = (page.extract_text() or "").strip()
        except Exception:
            texto = ""
        paginas.append({"numero_pagina": i, "texto": texto})
    return paginas


def montar_tsquery(texto):
    """Extrai os termos relevantes de um texto (título+descrição do
    requisito) e devolve uma string pronta pra virar `to_tsquery('portuguese', ...)`
    no formato "termo1 | termo2 | termo3" (OR entre os termos — queremos
    achar páginas que batam com QUALQUER termo relevante, ranqueadas
    depois por quantos/quão bem bateram, não exigir todos ao mesmo
    tempo). Devolve None se não sobrar nenhum termo útil."""
    palavras = _PALAVRA_RE.findall((texto or "").lower())
    termos = []
    vistos = set()
    for p in palavras:
        if p in STOPWORDS_PT or p in vistos:
            continue
        vistos.add(p)
        termos.append(p)
        if len(termos) >= MAX_TERMOS_BUSCA:
            break
    if not termos:
        return None
    return " | ".join(termos)


def buscar_referencias(texto_requisito, limite=MAX_REFERENCIAS_POR_REQUISITO):
    """Busca as páginas de manuais ativos mais relevantes para o texto de
    um requisito. Devolve uma lista (pode ser vazia) de
    {manual_id, manual_nome, pagina, trecho, relevancia}, já ordenada da
    mais relevante pra menos, limitada a `limite` itens e só com
    pontuação (ts_rank) acima de RELEVANCIA_MINIMA — abaixo disso é
    tratado como "não achou nada confiável" em vez de forçar um
    candidato fraco."""
    termos = montar_tsquery(texto_requisito)
    if not termos:
        return []
    query_sql = db.q(termos)
    sql = f"""
        SELECT mp.manual_id, m.nome AS manual_nome, mp.numero_pagina AS pagina,
               ts_rank(mp.busca, q.tsq) AS relevancia,
               ts_headline('portuguese', mp.texto, q.tsq,
                 'MaxFragments=1, MaxWords=55, MinWords=15, ShortWord=3, HighlightAll=false, StartSel=**, StopSel=**'
               ) AS trecho
        FROM manual_paginas mp
        JOIN manuais m ON m.id = mp.manual_id AND m.ativo
        CROSS JOIN (SELECT to_tsquery('portuguese', {query_sql}) AS tsq) q
        WHERE mp.busca @@ q.tsq
        ORDER BY relevancia DESC
        LIMIT {int(limite)}
    """
    linhas = db.fetch_all(sql)
    return [l for l in linhas if (l.get("relevancia") or 0) >= RELEVANCIA_MINIMA]
