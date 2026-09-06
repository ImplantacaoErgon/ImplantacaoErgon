# Build context deste Dockerfile é a RAIZ do repositório (não a pasta
# backend/) — por isso os caminhos abaixo começam com "backend/" ou
# "frontend/". Isso é necessário porque a imagem final também precisa do
# frontend/ copiado para dentro dela (ver comentário perto de FRONTEND_DIR
# mais abaixo). Ao rodar manualmente: `docker build -f backend/Dockerfile .`
# a partir da raiz do projeto. Com docker-compose (docker-compose.yml e
# docker-compose.supabase.yml) isso já está configurado corretamente.
FROM python:3.11-slim

# psql client — usado por app/db.py para falar com o Postgres (ver comentário lá)
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY backend/app ./app
COPY backend/run.py .

# Em desenvolvimento local (docker-compose.yml / docker-compose.supabase.yml)
# o volume "./frontend:/frontend:ro" sobrepõe esta cópia, então editar
# frontend/index.html reflete na hora, sem rebuild. Já em produção (Render,
# ou qualquer deploy que rode só esta imagem sem docker-compose) não existe
# esse volume, então o frontend PRECISA estar copiado dentro da imagem —
# é para isso que esta linha serve.
COPY frontend /frontend

ENV FRONTEND_DIR=/frontend
RUN mkdir -p /app/uploads

EXPOSE 8000
# --timeout 240: margem extra para a importação de cronograma em lotes
# (app/cronograma_import.py) — cada lote já é rápido (uma única conexão por
# lote, não uma por linha), mas contra um Postgres remoto lento/congestionado
# é melhor sobrar tempo do que o worker matar a requisição no meio da carga.
#
# 0.0.0.0:${PORT:-8000} (em vez de 8000 fixo): plataformas como o Render
# escolhem a porta e a informam pela variável de ambiente PORT (normalmente
# 10000) — o servidor precisa escutar nela. Localmente (docker-compose), PORT
# não é definida, então cai no padrão 8000, que é o que o compose já expõe.
# Forma "shell" do CMD (sem colchetes) porque só ela expande variáveis de
# ambiente; com a forma "exec" ("${PORT}" ficaria literal).
CMD gunicorn -w 4 -b 0.0.0.0:${PORT:-8000} --timeout 240 run:app
