#!/bin/bash

set -o pipefail

INFO="INFO"
ERROR="ERROR"
log_info(){
    echo "$(date "+%Y-%m-%d %H:%M:%S") [$INFO] $1"
}
log_error(){
    echo "$(date "+%Y-%m-%d %H:%M:%S") [$ERROR] $1"
}
check_status(){
    resname=$1
    namespace=$2
    echo "oc rollout status $resname -n $namespace --timeout=5m"
    oc rollout status $resname -n $namespace --timeout=5m
    if [ $? -ne 0 ];
    then
        exit 1
    fi
}
crds(){
    log_info "Deploying CRD's on cluster"
    oc create -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/master/bundle.yaml 1> /dev/null
    oc create -f https://raw.githubusercontent.com/grafana/loki/main/operator/config/crd/bases/loki.grafana.com_recordingrules.yaml 1> /dev/null
    oc create -f https://raw.githubusercontent.com/grafana/loki/main/operator/config/crd/bases/loki.grafana.com_alertingrules.yaml 1> /dev/null

}
role() {
    oc apply -f observatorium-cluster-role.yaml 1> /dev/null
    oc apply -f observatorium-cluster-role-binding.yaml 1> /dev/null
    oc apply --namespace observatorium-metrics -f observatorium-service-account.yaml 1> /dev/null
}
minio(){
    log_info "Deploying resources inside minio namespace"
    oc create ns minio 1> /dev/null
    sleep 5
    oc process -f minio-template.yaml -p MINIO_CPU_REQUEST=30m -p MINIO_CPU_LIMITS=50m -p MINIO_MEMORY_REQUEST=50Mi -p MINIO_MEMORY_LIMITS=100Mi --local -o yaml | sed -e 's/storage: [0-9].Gi/storage: 0.25Gi/g' | oc apply -n minio -f -
    sleep 5 
    check_status deployment/minio minio
}
dex(){
    log_info "Deploying resources inside dex namespace"
    oc create ns dex 1> /dev/null
    sleep 5
    oc process -f dex-template.yaml -p DEX_CPU_REQUEST=30m -p DEX_CPU_LIMITS=50m -p DEX_MEMORY_REQUEST=50Mi -p DEX_MEMORY_LIMITS=100Mi --local -o yaml | sed -e 's/storage: [0-9].Gi/storage: 0.25Gi/g' | oc apply -n dex -f -
    sleep 5
    check_status deployment/dex dex
}
teardown(){
    log_info "Teardown started"
    oc delete ns minio dex observatorium observatorium-metrics telemeter 1> /dev/null
}
observatorium_metrics(){
    log_info "Deploying resources inside observatorium-metrics namespace"
    oc create ns observatorium-metrics 1> /dev/null
    sleep 5
    oc process -f observatorium-metrics-thanos-objectstorage-secret-template.yaml | oc apply --namespace observatorium-metrics -f - 1> /dev/null
    oc apply -f observatorium-alertmanager-config-secret.yaml --namespace observatorium-metrics 1> /dev/null
    role
    oc process --param-file=observatorium-metrics.ci.env -f ../resources/services/observatorium-metrics-template.yaml | oc apply --namespace observatorium-metrics -f - 
    sleep 5
    ress=$(oc get statefulsets -o name -n observatorium-metrics ; oc get deployments -o name -n observatorium-metrics)
    for res in $ress
    do
        check_status $res observatorium-metrics
    done
}
observatorium(){
    log_info "Deploying resources inside observatorium namespace"
    oc create ns observatorium 1> /dev/null
    sleep 5
    oc apply -f observatorium-rules-objstore-secret.yaml --namespace observatorium 1> /dev/null
    oc apply -f observatorium-rhobs-tenant-secret.yaml --namespace observatorium 1> /dev/null
    oc process --param-file=observatorium.test.ci.env -f ../resources/services/observatorium-template.yaml | oc apply --namespace observatorium -f -
    sleep 5
    ress=$(oc get statefulsets -o name -n observatorium ; oc get deployments -o name -n observatorium)
    for res in $ress
    do
        check_status $res observatorium
    done

}
telemeter(){
    log_info "Deploying resources inside telemeter namespace"
    oc create ns telemeter 1> /dev/null
    sleep 5
    oc apply --namespace telemeter -f telemeter-token-refersher-oidc-secret.yaml 1> /dev/null
    oc process --param-file=telemeter.ci.env -f ../resources/services/telemeter-template.yaml | oc apply --namespace telemeter  -f - 
    sleep 5
    ress=$(oc get statefulsets -o name -n telemeter ; oc get deployments -o name -n telemeter)
    for res in $ress
    do
        check_status $res telemeter
    done
}
deploy_job(){
    oc apply -n observatorium -f secret.yaml
    oc apply -n observatorium -f tenant.yaml
    oc rollout restart deployment/observatorium-observatorium-api -n observatorium
    check_status deployment/observatorium-observatorium-api observatorium
    oc apply -n observatorium -f job.yaml
    oc wait --for=condition=complete --timeout=5m -n observatorium job/observatorium-up-metrics
}
crds
minio
dex
observatorium_metrics
observatorium
deploy_job
telemeter
teardown
