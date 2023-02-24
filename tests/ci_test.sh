#!/bin/bash

set -o pipefail
set -x
check_pod_status(){
    podname=$1
    namespace=$2
    retry=3
    while [ $retry -ne 0 ]
    do
        containerStatuses=$(oc get $podname -n $namespace -o jsonpath='{.status.containerStatuses[*].state}')
        if [[ $containerStatuses == *'waiting'* || -z $containerStatuses ]];
        then

            echo "Output: $containerStatuses"
            echo "Retrying again..."
        else
            echo "Status of $podname is healthy inside $namespace namespace"
            return
        fi
        sleep 30
        ((retry--))
    done
    echo "Retry exhausted!!!!!!!!!!!!"
    teardown
    exit 1
}
crds(){
    oc create -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/master/bundle.yaml
    oc create -f https://raw.githubusercontent.com/grafana/loki/main/operator/config/crd/bases/loki.grafana.com_recordingrules.yaml
    oc create -f https://raw.githubusercontent.com/grafana/loki/main/operator/config/crd/bases/loki.grafana.com_alertingrules.yaml

}
role() {
    oc apply -f observatorium-cluster-role.yaml
    oc apply -f observatorium-cluster-role-binding.yaml
    oc apply --namespace observatorium-metrics -f observatorium-service-account.yaml
}
minio(){
    oc create ns minio || true
    sleep 5
    oc process -f minio-template.yaml -p MINIO_CPU_REQUEST=15m -p MINIO_CPU_LIMITS=30m -p MINIO_MEMORY_REQUEST=100Mi -p MINIO_MEMORY_LIMITS=150Mi --local -o yaml | sed -e 's/"storage": "10Gi"/"storage": "0.25Gi"/g' | oc apply -n minio -f -
    sleep 5
    podname=$(oc get pods -n minio -l app.kubernetes.io/name=minio -o name)
    sleep 30
    check_pod_status $podname minio
}
dex(){
    oc create ns dex || true
    sleep 5
    oc process -f dex-template.yaml -p DEX_CPU_REQUEST=15m -p DEX_CPU_LIMITS=30m -p DEX_MEMORY_REQUEST=25Mi -p DEX_MEMORY_LIMITS=50Mi | sed -e 's/"storage": "1Gi"/"storage": "0.25Gi"/g' | oc apply -n dex -f -
    sleep 5
    podname=$(oc get pods -n dex -l app.kubernetes.io/name=dex -o name)
    sleep 30
    check_pod_status $podname dex
}
destroy(){
    depname=$1
    namespace=$2
    if [ $depname == 'memcached' ];
    then
        return
    fi
    oc delete statefulsets -n $namespace -l app.kubernetes.io/name=$depname
    oc delete deployment -n $namespace -l app.kubernetes.io/name=$depname
    oc delete pvc -n $namespace --all=true
    sleep 30
}
teardown(){
    oc delete ns minio dex observatorium observatorium-metrics telemeter
}
observatorium_metrics(){
    oc create ns observatorium-metrics || true
    sleep 5
    oc process -f observatorium-metrics-thanos-objectstorage-secret-template.yaml | oc apply --namespace observatorium-metrics -f -
    oc process --param-file=observatorium-metrics.ci.env -f ../resources/services/observatorium-metrics-template.yaml -o jsonpath='{.items[?(@.kind=="ConfigMap")]}' | oc apply --namespace observatorium-metrics -f -
    oc apply -f observatorium-alertmanager-config-secret.yaml --namespace observatorium-metrics
    role
    comps=('thanos-compact' 'alertmanager' 'thanos-query' 'thanos-query-frontend' 'thanos-receive' 'thanos-rule' 'thanos-stateless-rule' 'memcached' 'thanos-store' 'thanos-volcano-query')
    for comp in ${comps[*]}
    do
        if [ $comp == 'thanos-receive' ];
        then
            oc process --param-file=observatorium-metrics.ci.env -f ../resources/services/observatorium-metrics-template.yaml -o jsonpath='{.items[?(@.kind=="PodDisruptionBudget")]}' | oc apply --namespace observatorium-metrics -f -
            oc process --param-file=observatorium-metrics.ci.env -f ../resources/services/observatorium-metrics-template.yaml | oc apply --namespace observatorium-metrics --selector=app.kubernetes.io/name=thanos-receive-controller -f -
        fi
        if [ $comp == 'alertmanager' ];
        then
            oc process --param-file=observatorium-metrics.ci.env -f ../resources/services/observatorium-metrics-template.yaml -o jsonpath='{.items[?(@.kind=="PersistentVolumeClaim")]}' | sed -e 's/10Gi/0.25Gi/g' | oc apply --namespace observatorium-metrics -f -
        fi
        oc process --param-file=observatorium-metrics.ci.env -f ../resources/services/observatorium-metrics-template.yaml | oc apply --namespace observatorium-metrics --selector=app.kubernetes.io/name=$comp -f -
        sleep 5
        pods=$(oc get pods -n observatorium-metrics -l app.kubernetes.io/name=$comp -o name)
        sleep 30
        for pod in $pods
        do
            check_pod_status $pod observatorium-metrics
        done
        echo "Sleeping...."
        sleep 30
        destroy $comp observatorium-metrics
    done
}
observatorium(){
    oc create ns observatorium || true
    sleep 5
    oc apply -f observatorium-rules-objstore-secret.yaml --namespace observatorium
    oc apply -f observatorium-rhobs-tenant-secret.yaml --namespace observatorium
    comps=('avalanche-remote-writer' 'gubernator' 'memcached' 'observatorium-api' 'observatorium-up' 'rules-objstore' 'rules-obsctl-reloader')
    for comp in ${comps[*]}
    do
        oc process --param-file=observatorium.test.env -f ../resources/services/observatorium-template.yaml | oc apply --namespace observatorium --selector=app.kubernetes.io/name=$comp -f -
        sleep 5
        pods=$(oc get pods -n observatorium -l app.kubernetes.io/name=$comp -o name)
        sleep 30
        for pod in $pods
        do
            check_pod_status $pod observatorium
        done
        echo "Sleeping...."
        sleep 30
        destroy $comp observatorium
    done

}
telemeter(){
    oc create ns telemeter || true
    sleep 5
    oc apply --namespace telemeter -f telemeter-token-refersher-oidc-secret.yaml
    comps=('memcached' 'nginx' 'memcached' 'token-refresher')
    for comp in ${comps[*]}
    do
        oc process --param-file=telemeter.test.env -f ../resources/services/telemeter-template.yaml | oc apply --namespace telemeter --selector=app.kubernetes.io/name=$comp -f -
        sleep 5
        pods=$(oc get pods -n telemeter -l app.kubernetes.io/name=$comp -o name)
        echo "$pods"
        for pod in $pods
        do
            check_pod_status $pod telemeter
        done
        echo "Sleeping...."
        sleep 30
        destroy $comp telemeter
    done
}
crds
echo "$PWD"
minio
dex
observatorium_metrics
observatorium
telemeter
teardown
set +x
