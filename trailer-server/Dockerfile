# aurora-trailers : bandes-annonces pour l'app Aurora (Apple TV).
FROM python:3.12-slim

# ffmpeg : remise en forme des fichiers (MP4 classique, sans piste audio).
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Deno : moteur JavaScript dont yt-dlp a besoin pour YouTube.
COPY --from=denoland/deno:bin-2.1.4 /deno /usr/local/bin/deno

# yt-dlp volontairement non figé : YouTube change souvent, une version récente
# est nécessaire. Changer YTDLP_REFRESH (compose.yaml) puis reconstruire ne
# refait que cette étape ; les étapes lourdes au-dessus restent en cache.
ARG YTDLP_REFRESH=initial
RUN echo "mise à jour yt-dlp : ${YTDLP_REFRESH}" \
 && pip install --no-cache-dir --upgrade "yt-dlp[default]"

RUN useradd --uid 1000 --create-home aurora \
 && mkdir -p /cache && chown aurora /cache
COPY server.py /app/server.py

USER aurora
ENV CACHE_DIR=/cache PORT=8787 PYTHONUNBUFFERED=1
EXPOSE 8787
VOLUME ["/cache"]
HEALTHCHECK --interval=5m --timeout=30s CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8787/health', timeout=20)"
CMD ["python", "/app/server.py"]
