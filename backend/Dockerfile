FROM python:3.11-slim

# psql client — usado por app/db.py para falar com o Postgres (ver comentário lá)
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY run.py .

ENV FRONTEND_DIR=/frontend
RUN mkdir -p /app/uploads

EXPOSE 8000
# --timeout 240: margem extra para a importação de cronograma em lotes
# (app/cronograma_import.py) — cada lote já é rápido (uma única conexão por
# lote, não uma por linha), mas contra um Postgres remoto lento/congestionado
# é melhor sobrar tempo do que o worker matar a requisição no meio da carga.
CMD ["gunicorn", "-w", "4", "-b", "0.0.0.0:8000", "--timeout", "240", "run:app"]
