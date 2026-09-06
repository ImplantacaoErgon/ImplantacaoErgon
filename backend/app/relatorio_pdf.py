"""
Gera o PDF do Relatório Executivo a partir do markdown devolvido pela IA
(ver app/relatorio_executivo.py). Só entende o subconjunto de markdown que o
prompt pede à IA para usar — "## título", parágrafos e listas com "-" (mais
"**negrito**" e "*itálico*" dentro do texto) — não é um parser de markdown
genérico.

Usa reportlab (não weasyprint/wkhtmltopdf) de propósito: é puro Python, não
precisa de bibliotecas de sistema extras na imagem Docker (Pango/Cairo/
Chromium), o que mantém o Dockerfile simples.
"""
import re
from datetime import datetime
from io import BytesIO

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import cm
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, ListFlowable, ListItem, HRFlowable

_INLINE_BOLD = re.compile(r"\*\*(.+?)\*\*")
_INLINE_ITALIC = re.compile(r"(?<!\*)\*([^*]+?)\*(?!\*)")


def _inline_to_reportlab(text):
    """Converte **negrito** e *itálico* para as tags <b>/<i> do reportlab, e escapa
    o resto (&, <, >) para não quebrar o parser de markup interno do Paragraph."""
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    text = _INLINE_BOLD.sub(r"<b>\1</b>", text)
    text = _INLINE_ITALIC.sub(r"<i>\1</i>", text)
    return text


def _estilos():
    base = getSampleStyleSheet()
    estilos = {
        "titulo": ParagraphStyle("titulo", parent=base["Title"], fontSize=18, spaceAfter=4),
        "subtitulo": ParagraphStyle("subtitulo", parent=base["Normal"], fontSize=10.5,
                                     textColor=colors.HexColor("#555555"), alignment=TA_CENTER, spaceAfter=2),
        "h2": ParagraphStyle("h2", parent=base["Heading2"], fontSize=13.5, spaceBefore=16, spaceAfter=6,
                              textColor=colors.HexColor("#1a3d5c")),
        "corpo": ParagraphStyle("corpo", parent=base["Normal"], fontSize=10, leading=14.5, spaceAfter=6,
                                 alignment=4),  # justify
        "item": ParagraphStyle("item", parent=base["Normal"], fontSize=10, leading=14),
        "rodape": ParagraphStyle("rodape", parent=base["Normal"], fontSize=7.5,
                                  textColor=colors.HexColor("#888888")),
    }
    return estilos


def _markdown_para_flowables(conteudo_md, estilos):
    flowables = []
    linhas = conteudo_md.replace("\r\n", "\n").split("\n")
    buffer_lista = []

    def fecha_lista():
        if buffer_lista:
            flowables.append(ListFlowable(
                [ListItem(Paragraph(_inline_to_reportlab(li), estilos["item"]), leftIndent=8) for li in buffer_lista],
                bulletType="bullet", start="•", leftIndent=14, spaceBefore=2, spaceAfter=8,
            ))
            buffer_lista.clear()

    for linha in linhas:
        linha_strip = linha.strip()
        if not linha_strip:
            fecha_lista()
            continue
        if linha_strip.startswith("## "):
            fecha_lista()
            flowables.append(Paragraph(_inline_to_reportlab(linha_strip[3:].strip()), estilos["h2"]))
        elif linha_strip.startswith("# "):
            fecha_lista()
            flowables.append(Paragraph(_inline_to_reportlab(linha_strip[2:].strip()), estilos["h2"]))
        elif linha_strip.startswith(("- ", "* ")):
            buffer_lista.append(linha_strip[2:].strip())
        else:
            fecha_lista()
            flowables.append(Paragraph(_inline_to_reportlab(linha_strip), estilos["corpo"]))
    fecha_lista()
    return flowables


def gerar_pdf_bytes(relatorio_row):
    """relatorio_row: dict com pelo menos conteudo_md, gerado_em, dados_enviados
    (dados_enviados.projeto.{nome,cliente,sigla}) — como vem de relatorios_executivos."""
    estilos = _estilos()
    dados = relatorio_row.get("dados_enviados") or {}
    projeto = dados.get("projeto") or {}
    nome_projeto = projeto.get("nome") or "Projeto"
    cliente = projeto.get("cliente") or ""
    gerado_em = relatorio_row.get("gerado_em")
    if isinstance(gerado_em, str):
        try:
            gerado_em_fmt = datetime.fromisoformat(gerado_em.replace("Z", "+00:00")).strftime("%d/%m/%Y %H:%M")
        except ValueError:
            gerado_em_fmt = gerado_em
    else:
        gerado_em_fmt = str(gerado_em) if gerado_em else ""

    buf = BytesIO()
    doc = SimpleDocTemplate(
        buf, pagesize=A4,
        topMargin=2.2 * cm, bottomMargin=2 * cm, leftMargin=2.2 * cm, rightMargin=2.2 * cm,
        title=f"Relatório Executivo — {nome_projeto}",
    )

    flow = [
        Paragraph("Relatório Executivo do Projeto", estilos["titulo"]),
        Paragraph(f"{nome_projeto}" + (f" — {cliente}" if cliente else ""), estilos["subtitulo"]),
        Paragraph(f"Gerado em {gerado_em_fmt} · conteúdo produzido por IA a partir dos dados do cronograma",
                  estilos["subtitulo"]),
        Spacer(1, 6),
        HRFlowable(width="100%", thickness=0.6, color=colors.HexColor("#cccccc")),
        Spacer(1, 4),
    ]
    flow.extend(_markdown_para_flowables(relatorio_row.get("conteudo_md") or "", estilos))
    flow.append(Spacer(1, 14))
    flow.append(HRFlowable(width="100%", thickness=0.4, color=colors.HexColor("#dddddd")))
    flow.append(Spacer(1, 6))
    flow.append(Paragraph(
        "Este relatório foi redigido por um modelo de inteligência artificial a partir de dados extraídos "
        "automaticamente do cronograma do projeto na data indicada acima. As previsões de prazo são estimativas "
        "calculadas por extrapolação do ritmo de execução observado — não são um compromisso contratual. "
        "Recomenda-se revisão pelo gerente de projeto antes de qualquer uso oficial ou apresentação ao cliente.",
        estilos["rodape"],
    ))

    doc.build(flow)
    return buf.getvalue()
