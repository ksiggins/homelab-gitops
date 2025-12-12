# This file defines Helm chart metadata for render_helm_chart.sh.
# Not applied to Kubernetes.
name: kube-prometheus-stack
repo: https://prometheus-community.github.io/helm-charts
namespace: monitoring-staging
version: 80.2.1
includeCRDs: true
valuesFile: values.yaml
