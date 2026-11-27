// Same checks as .github/workflows/ci.yml, as a Jenkins declarative pipeline.
pipeline {
  agent any
  options {
    timeout(time: 20, unit: 'MINUTES')
    disableConcurrentBuilds()
  }
  environment {
    IMAGE = "snipr:jenkins-${env.BUILD_NUMBER}"
  }
  stages {
    stage('Checkout') {
      steps { checkout scm }
    }
    stage('Install') {
      steps {
        dir('app') {
          sh 'uv venv --python 3.12 .venv && uv pip install --python .venv --require-hashes -r requirements-dev.txt'
        }
      }
    }
    stage('Ruff') {
      steps {
        dir('app') { sh '.venv/bin/ruff check . && .venv/bin/ruff format --check .' }
      }
    }
    stage('Pytest') {
      steps {
        dir('app') { sh '.venv/bin/pytest --junitxml=pytest.xml' }
      }
      post { always { junit 'app/pytest.xml' } }
    }
    stage('Docker build') {
      steps { sh 'docker build -f app/Dockerfile -t "$IMAGE" .' }
    }
    stage('Trivy scan') {
      steps {
        sh 'docker save "$IMAGE" -o image.tar'
        sh 'trivy image --input image.tar --scanners vuln --format json -o trivy-report.json'
        sh 'trivy image --input image.tar --scanners vuln --skip-db-update --severity CRITICAL --exit-code 1'
      }
      post { always { archiveArtifacts artifacts: 'trivy-report.json', allowEmptyArchive: true } }
    }
  }
  post {
    always {
      sh 'docker image rm -f "$IMAGE" >/dev/null 2>&1 || true; rm -f image.tar'
    }
  }
}
