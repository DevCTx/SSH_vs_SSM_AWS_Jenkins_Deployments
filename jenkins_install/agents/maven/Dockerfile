FROM jenkins-base-agent

USER root

RUN apt-get update && apt-get install -y \
    openjdk-21-jdk \
    maven && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

USER jenkins