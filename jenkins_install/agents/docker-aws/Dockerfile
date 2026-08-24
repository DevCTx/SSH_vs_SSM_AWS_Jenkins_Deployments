FROM jenkins-base-agent

USER root

ARG DOCKER_GID=999

# docker.io for build/push; unzip is only needed to install the AWS CLI below.
RUN apt-get update && apt-get install -y \
    docker.io \
    unzip \
    jq && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# If the docker group already exists on this base image, align its GID with
# the host's docker.sock group (passed as a build arg); otherwise create it.
RUN getent group docker \
    && groupmod -g "${DOCKER_GID}" docker \
    || groupadd -g "${DOCKER_GID}" docker \
    &&  usermod -aG docker jenkins

# AWS CLI: needed by every combo where 
# either REGISTRY=ecr ("aws ecr get-login-password") 
# or TRANSPORT=ssm ("aws ssm send-command").
# This single image also runs the deploy stage, so it must have it too.
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws

USER jenkins