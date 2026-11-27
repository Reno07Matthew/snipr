# Local Jenkins for the snipr CI demo: controller plus the tools the Jenkinsfile needs.
FROM jenkins/jenkins:2.580.3-lts-jdk21@sha256:161ec15b027ea80911256552191034bf2aaede1aa39dd06ca1fef60d9b585be5
COPY --from=docker:29-cli@sha256:4e60c31615e83523afbb59773b25d055c0da9edcd5f80a4c6a6eebad49de1a25 /usr/local/bin/docker /usr/local/bin/docker
COPY --from=aquasec/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb /usr/local/bin/trivy /usr/local/bin/trivy
COPY --from=ghcr.io/astral-sh/uv:0.13.9@sha256:d3b601f0c7b118bc1753febf7c41cc80981df678445e0254284eecf84db79a7d /uv /usr/local/bin/uv
RUN jenkins-plugin-cli --plugins workflow-aggregator git junit configuration-as-code job-dsl matrix-auth
COPY casc.yaml /usr/share/jenkins/ref/casc.yaml
ENV CASC_JENKINS_CONFIG=/usr/share/jenkins/ref/casc.yaml \
    JAVA_OPTS=-Djenkins.install.runSetupWizard=false
