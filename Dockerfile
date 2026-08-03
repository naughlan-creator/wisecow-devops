FROM ubuntu:24.04

# ENV DEBIAN_FRONTEND=noninteractive
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
	bash \
	netcat-openbsd \
	fortune-mod \
	fortunes-min \
	cowsay \
	&& rm -rf /var/lib/apt/lists/*

ENV PATH="/usr/games:${PATH}"

WORKDIR /app 
	
COPY wisecow.sh .

RUN useradd --create-home appuser
RUN chmod +x /app/wisecow.sh \
	&& chown -R appuser:appuser /app

USER appuser

EXPOSE 4499

CMD ["./wisecow.sh"]
