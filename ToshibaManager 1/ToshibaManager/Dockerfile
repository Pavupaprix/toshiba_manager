FROM python:3.12-slim

# Dépendances Python — couche mise en cache séparément du code applicatif
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Utilisateur non-root (constitution — Principe II, Data Safety & Confidentiality)
RUN useradd --create-home --uid 1000 toshibamanager

# Code applicatif (uploads/ est exclu via .dockerignore — remplacé par un volume au runtime)
# toshiba_template.py n'est pas copié : prototype standalone antérieur à
# app.py, jamais importé par celui-ci, donc sans utilité dans l'image (T022).
COPY app.py addressbook.py ./
COPY modele_xml/ ./modele_xml/
COPY templates/ ./templates/
COPY static/ ./static/
COPY Toshiba+Partage.bat ./
COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

RUN mkdir -p /app/uploads && chown -R toshibamanager:toshibamanager /app

USER toshibamanager

EXPOSE 5000

CMD ["./entrypoint.sh"]
