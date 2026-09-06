from dotenv import load_dotenv
load_dotenv()  # lê um .env na raiz do projeto/pasta atual, se existir (não sobrescreve variáveis já exportadas)

from app.main import create_app

app = create_app()

if __name__ == "__main__":
    import os
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8000)), debug=os.environ.get("DEBUG") == "1")
