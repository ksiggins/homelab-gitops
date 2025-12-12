# This file defines Helm chart metadata for render_helm_chart.sh.
# Not applied to Kubernetes.
name: trivy-operator
repo: https://aquasecurity.github.io/helm-charts/
namespace: trivy-operator-staging
version: 0.31.0
includeCRDs: true
valuesFile: values.yaml
