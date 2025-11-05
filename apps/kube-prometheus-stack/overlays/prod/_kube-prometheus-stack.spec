# This file defines Helm chart metadata for render_helm_chart.sh.
# Not applied to Kubernetes.
name: kube-prometheus-stack
repo: https://prometheus-community.github.io/helm-charts
namespace: monitoring-prod
version: 79.1.0
includeCRDs: true
valuesFile: values.yaml
