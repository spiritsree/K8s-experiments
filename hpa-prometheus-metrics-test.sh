#!/bin/bash

# This is to test custom metrics api with prometheus server with a sample deployment.

RED='\033[0;31m'      # Red
GREEN='\033[0;32m'    # Green
NC='\033[0m'          # Color Reset

kubectl_bin=$(which kubectl)
helm_bin=$(which helm)
if [[ -z ${kubectl_bin} ]]; then
    echo 'Needs kubectl...'
    echo 'Install using "brew install kubectl"'
    exit 1
elif [[ -z ${helm_bin} ]]; then
    echo 'Needs helm...'
    echo 'Install using "brew install helm"'
    exit 1
fi

context=$(kubectl config current-context)
resp='N'
echo -e "\n${GREEN}Current kube-context is ${RED}${context}${GREEN} Do you want to continue(Y/N) ?${NC}\n"
read -t 10 resp
if [ "${resp}" != "Y" ]; then
  exit 1
fi

# Creating core namespace
kubectl create namespace core

# Creating prod namespace
kubectl create namesapce prod

# Deploying prometheus
helm install --name prometheus stable/prometheus --set alertmanager.enabled=false --set kubeStateMetrics.enabled=false --set nodeExporter.enabled=false --set pushgateway.enabled=false --set server.persistentVolume.enabled=false --namespace core

cat > /tmp/rule.yaml <<EOF
rules:
  custom:
    - seriesQuery: '{__name__=~"^traefik_.*",kubernetes_namespace!="",kubernetes_pod_name!=""}'
      seriesFilters: []
      resources:
        overrides:
          kubernetes_namespace:
            resource: namespace
          kubernetes_pod_name:
            resource: pod
      name:
        matches: ^traefik_(.*)_total$
        as: ""
      metricsQuery: sum(rate(<<.Series>>{<<.LabelMatchers>>}[5m]))
        by (<<.GroupBy>>)
EOF

# Deploying prometheus adapter and custom.metrics.k8s.io
helm install --name prometheus-adapter --set prometheus.url='http://prometheus-server.core' --set prometheus.port=80 --set rules.default=false --set logLevel=1 stable/prometheus-adapter --namespace core -f /tmp/rules.yaml

# Check custom metrics api
kubectl api-versions | grep custom.metrics.k8s.io

# Check custom.metrics.k8s.io status
kubectl get apiservice v1beta1.custom.metrics.k8s.io -n core -ojson | jq .status.conditions

# Check api endpoint
kubectl get --raw /apis/custom.metrics.k8s.io/v1beta1 | jq .

# Deploy traefik with prometheus enabled
helm install --name traefik stable/traefik --set serviceType=NodePort --set metrics.prometheus.enabled=true --set deployment.podAnnotations."prometheus\.io\/scrape"=true --set deployment.podAnnotations."prometheus\.io\/port"=8080 --namespace prod

# Expose service
# sudo kubectl port-forward svc/traefik 80:80 -n prod

# Create HPA with custom metric
cat > /tmp/hpa.yaml <<EOF
apiVersion: autoscaling/v2beta1
kind: HorizontalPodAutoscaler
metadata:
  name: traefik-hpa
  namespace: prod
spec:
  scaleTargetRef:
    apiVersion: apps/v1beta1
    kind: Deployment
    name: traefik
  minReplicas: 1
  maxReplicas: 3
  metrics:
  - type: Pods
    pods:
      metricName: entrypoint_requests
      targetAverageValue: 20
EOF

kubectl create -f /tmp/hpa.yaml -n prod
