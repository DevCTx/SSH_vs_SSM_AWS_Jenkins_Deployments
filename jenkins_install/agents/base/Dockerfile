FROM jenkins/inbound-agent

USER root

RUN apt-get update && apt-get install -y \
    git \
    curl \
    ca-certificates \
    openssh-client && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

USER jenkins