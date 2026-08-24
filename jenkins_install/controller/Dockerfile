FROM jenkins/jenkins:lts

USER root

# runSetupWizard=false to unable Jenkins preconfiguration and only install the required plugins
# Dhudson.model.DirectoryBrowserSupport.CSP : to enforce Content Security Policy (CSP) 
# (recommanded by Jenkins - cf Jenkins docs)
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false \
-Dhudson.model.DirectoryBrowserSupport.CSP=\"default-src 'self'; \
script-src 'self'; \
style-src 'self' 'unsafe-inline'; \
img-src 'self' data:\""

# Core plugins only. No pipeline definition lives in this image
# Jobs are created/removed at runtime from jenkins-config.yaml (mounted as a volume)  
# via reload_jenkins_config.sh, so if a config change, it never requires to rebuild this image.
RUN jenkins-plugin-cli --plugins \
    workflow-aggregator \
    git \
    github \
    pipeline-stage-view \
    credentials-binding \
    ssh-credentials \
    ssh-slaves \
    ssh-agent \
    ws-cleanup \
    docker-plugin \
    configuration-as-code \
    job-dsl \
    matrix-auth \
    aws-credentials

ENV CASC_JENKINS_CONFIG=/var/jenkins_home/casc/jenkins-config.yaml

USER jenkins