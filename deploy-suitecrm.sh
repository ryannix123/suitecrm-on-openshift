#!/bin/bash

##############################################################################
# SuiteCRM on OpenShift - Deployment Script
# 
# This script deploys SuiteCRM 7.15 with MariaDB and Redis on OpenShift
# Based on the Nextcloud/OpenEMR deployment pattern
#
# Author: Ryan Nixon
# Version: 1.0
##############################################################################

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SUITECRM_IMAGE="quay.io/ryan_nix/suitecrm-openshift:7.15.0"
MARIADB_IMAGE="registry.redhat.io/rhel9/mariadb-1011:latest"
REDIS_IMAGE="docker.io/bitnami/redis:7.4"

# Storage configuration
DB_STORAGE_SIZE="10Gi"
SUITECRM_STORAGE_SIZE="20Gi"
REDIS_STORAGE_SIZE="1Gi"

# Database configuration
DB_NAME="suitecrm"
DB_USER="suitecrm"
DB_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"
DB_ROOT_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)"

##############################################################################
# Helper Functions
##############################################################################

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
}

check_command() {
    if ! command -v $1 &> /dev/null; then
        print_error "$1 command not found. Please install it first."
        exit 1
    fi
}

wait_for_pod() {
    local label=$1
    local timeout=${2:-300}
    
    print_info "Waiting for pod with label $label to be ready..."
    oc wait --for=condition=ready pod \
        -l "$label" \
        --timeout="${timeout}s" 2>/dev/null || true
}

##############################################################################
# Preflight Checks
##############################################################################

preflight_checks() {
    print_header "Preflight Checks"
    
    check_command oc
    
    if ! oc whoami &> /dev/null; then
        print_error "Not logged into OpenShift. Please run 'oc login' first."
        exit 1
    fi
    
    print_success "Logged in as: $(oc whoami)"
    print_success "Using cluster: $(oc whoami --show-server)"
}

##############################################################################
# Detect Current Project
##############################################################################

detect_project() {
    print_header "Detecting Current Project"
    
    PROJECT_NAME=$(oc project -q 2>/dev/null)
    
    if [ -z "$PROJECT_NAME" ]; then
        print_error "No project selected. Please switch to a project first with: oc project <project-name>"
        exit 1
    fi
    
    print_success "Using current project: $PROJECT_NAME"
    
    # Get the apps domain for route
    APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "apps.example.com")
    SUITECRM_ROUTE="suitecrm-${PROJECT_NAME}.${APPS_DOMAIN}"
    SITE_URL="https://${SUITECRM_ROUTE}"
    
    print_info "Route will be: ${SUITECRM_ROUTE}"
}

##############################################################################
# Deploy Redis
##############################################################################

deploy_redis() {
    print_header "Deploying Redis"
    
    print_info "Creating Redis PVC..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: redis-data
  labels:
    app: suitecrm
    component: cache
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${REDIS_STORAGE_SIZE}
EOF

    print_info "Creating Redis Deployment..."
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  labels:
    app: suitecrm
    component: cache
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: suitecrm
      component: cache
  template:
    metadata:
      labels:
        app: suitecrm
        component: cache
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: redis
          image: ${REDIS_IMAGE}
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          ports:
            - name: redis
              containerPort: 6379
              protocol: TCP
          env:
            - name: ALLOW_EMPTY_PASSWORD
              value: "yes"
          args:
            - redis-server
            - --appendonly
            - "yes"
            - --maxmemory
            - "256mb"
            - --maxmemory-policy
            - "allkeys-lru"
          volumeMounts:
            - name: redis-data
              mountPath: /data
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 10
            periodSeconds: 10
          livenessProbe:
            exec:
              command: ["redis-cli", "ping"]
            initialDelaySeconds: 30
            periodSeconds: 20
      volumes:
        - name: redis-data
          persistentVolumeClaim:
            claimName: redis-data
EOF

    print_info "Creating Redis Service..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: redis
  labels:
    app: suitecrm
    component: cache
spec:
  type: ClusterIP
  ports:
    - name: redis
      port: 6379
      targetPort: redis
  selector:
    app: suitecrm
    component: cache
EOF

    print_success "Redis deployed!"
}

##############################################################################
# Deploy MariaDB
##############################################################################

deploy_mariadb() {
    print_header "Deploying MariaDB"
    
    print_info "Creating database credentials secret..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: suitecrm-db-credentials
  labels:
    app: suitecrm
    component: database
type: Opaque
stringData:
  MYSQL_ROOT_PASSWORD: "${DB_ROOT_PASSWORD}"
  MYSQL_DATABASE: "${DB_NAME}"
  MYSQL_USER: "${DB_USER}"
  MYSQL_PASSWORD: "${DB_PASSWORD}"
EOF

    print_info "Creating MariaDB PVC..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mariadb-data
  labels:
    app: suitecrm
    component: database
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${DB_STORAGE_SIZE}
EOF

    print_info "Creating MariaDB ConfigMap..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: mariadb-config
  labels:
    app: suitecrm
    component: database
data:
  my.cnf: |
    [mysqld]
    innodb_buffer_pool_size = 256M
    innodb_log_file_size = 64M
    innodb_flush_log_at_trx_commit = 2
    max_connections = 100
    max_allowed_packet = 64M
    character-set-server = utf8mb4
    collation-server = utf8mb4_unicode_ci
    
    [client]
    default-character-set = utf8mb4
EOF

    print_info "Creating MariaDB Deployment..."
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mariadb
  labels:
    app: suitecrm
    component: database
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: suitecrm
      component: database
  template:
    metadata:
      labels:
        app: suitecrm
        component: database
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: mariadb
          image: ${MARIADB_IMAGE}
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          ports:
            - name: mysql
              containerPort: 3306
          env:
            - name: MYSQL_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: suitecrm-db-credentials
                  key: MYSQL_ROOT_PASSWORD
            - name: MYSQL_DATABASE
              valueFrom:
                secretKeyRef:
                  name: suitecrm-db-credentials
                  key: MYSQL_DATABASE
            - name: MYSQL_USER
              valueFrom:
                secretKeyRef:
                  name: suitecrm-db-credentials
                  key: MYSQL_USER
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: suitecrm-db-credentials
                  key: MYSQL_PASSWORD
          volumeMounts:
            - name: mariadb-data
              mountPath: /var/lib/mysql/data
            - name: mariadb-config
              mountPath: /etc/my.cnf.d/suitecrm.cnf
              subPath: my.cnf
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "1"
              memory: 1Gi
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - 'mysqladmin ping -h localhost -u root -p"\${MYSQL_ROOT_PASSWORD}"'
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - 'mysqladmin ping -h localhost -u root -p"\${MYSQL_ROOT_PASSWORD}"'
            initialDelaySeconds: 60
            periodSeconds: 20
      volumes:
        - name: mariadb-data
          persistentVolumeClaim:
            claimName: mariadb-data
        - name: mariadb-config
          configMap:
            name: mariadb-config
EOF

    print_info "Creating MariaDB Service..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: mariadb
  labels:
    app: suitecrm
    component: database
spec:
  type: ClusterIP
  ports:
    - name: mysql
      port: 3306
      targetPort: mysql
  selector:
    app: suitecrm
    component: database
EOF

    print_success "MariaDB deployed!"
    wait_for_pod "app=suitecrm,component=database" 300
}

##############################################################################
# Deploy SuiteCRM
##############################################################################

deploy_suitecrm() {
    print_header "Deploying SuiteCRM"
    
    print_info "Creating SuiteCRM PVC..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: suitecrm-data
  labels:
    app: suitecrm
    component: application
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: ${SUITECRM_STORAGE_SIZE}
EOF

    print_info "Creating SuiteCRM Deployment..."
    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: suitecrm
  labels:
    app: suitecrm
    component: application
spec:
  replicas: 1
  strategy:
    type: RollingUpdate
  selector:
    matchLabels:
      app: suitecrm
      component: application
  template:
    metadata:
      labels:
        app: suitecrm
        component: application
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      initContainers:
        - name: wait-for-db
          image: ${MARIADB_IMAGE}
          imagePullPolicy: IfNotPresent
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          command:
            - /bin/sh
            - -c
            - |
              echo "Waiting for MariaDB..."
              until mysqladmin ping -h mariadb -u \$MYSQL_USER -p"\$MYSQL_PASSWORD" --silent; do
                echo "MariaDB unavailable - sleeping"
                sleep 3
              done
              echo "MariaDB is up!"
          env:
            - name: MYSQL_USER
              valueFrom:
                secretKeyRef:
                  name: suitecrm-db-credentials
                  key: MYSQL_USER
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: suitecrm-db-credentials
                  key: MYSQL_PASSWORD
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
      containers:
        - name: suitecrm
          image: ${SUITECRM_IMAGE}
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: DB_HOST
              value: "mariadb"
            - name: DB_PORT
              value: "3306"
            - name: DB_NAME
              valueFrom:
                secretKeyRef:
                  name: suitecrm-db-credentials
                  key: MYSQL_DATABASE
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: suitecrm-db-credentials
                  key: MYSQL_USER
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: suitecrm-db-credentials
                  key: MYSQL_PASSWORD
            - name: REDIS_HOST
              value: "redis"
            - name: REDIS_PORT
              value: "6379"
            - name: SITE_URL
              value: "${SITE_URL}"
          volumeMounts:
            - name: suitecrm-data
              mountPath: /var/www/html/upload
              subPath: upload
            - name: suitecrm-data
              mountPath: /var/www/html/cache
              subPath: cache
            - name: suitecrm-data
              mountPath: /var/www/html/custom
              subPath: custom
          resources:
            requests:
              cpu: 250m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 2Gi
          readinessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 60
            periodSeconds: 30
      volumes:
        - name: suitecrm-data
          persistentVolumeClaim:
            claimName: suitecrm-data
EOF

    print_info "Creating SuiteCRM Service..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: suitecrm
  labels:
    app: suitecrm
    component: application
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8080
      targetPort: http
  selector:
    app: suitecrm
    component: application
EOF

    print_info "Creating SuiteCRM Route..."
    cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: suitecrm
  labels:
    app: suitecrm
    component: application
  annotations:
    haproxy.router.openshift.io/timeout: 300s
spec:
  host: ${SUITECRM_ROUTE}
  to:
    kind: Service
    name: suitecrm
    weight: 100
  port:
    targetPort: http
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
EOF

    print_success "SuiteCRM deployed!"
    wait_for_pod "app=suitecrm,component=application" 300
}

##############################################################################
# Deploy Scheduler CronJob
##############################################################################

deploy_scheduler() {
    print_header "Deploying Scheduler CronJob"
    
    cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: suitecrm-scheduler
  labels:
    app: suitecrm
    component: scheduler
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        metadata:
          labels:
            app: suitecrm
            component: scheduler
        spec:
          securityContext:
            runAsNonRoot: true
            seccompProfile:
              type: RuntimeDefault
          restartPolicy: OnFailure
          containers:
            - name: scheduler
              image: ${SUITECRM_IMAGE}
              imagePullPolicy: IfNotPresent
              securityContext:
                allowPrivilegeEscalation: false
                capabilities:
                  drop:
                    - ALL
              command:
                - /bin/bash
                - -c
                - |
                  cd /var/www/html
                  php -f cron.php > /dev/null 2>&1
              env:
                - name: DB_HOST
                  value: "mariadb"
                - name: DB_PORT
                  value: "3306"
                - name: DB_NAME
                  valueFrom:
                    secretKeyRef:
                      name: suitecrm-db-credentials
                      key: MYSQL_DATABASE
                - name: DB_USER
                  valueFrom:
                    secretKeyRef:
                      name: suitecrm-db-credentials
                      key: MYSQL_USER
                - name: DB_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: suitecrm-db-credentials
                      key: MYSQL_PASSWORD
                - name: REDIS_HOST
                  value: "redis"
                - name: REDIS_PORT
                  value: "6379"
              volumeMounts:
                - name: suitecrm-data
                  mountPath: /var/www/html/upload
                  subPath: upload
                - name: suitecrm-data
                  mountPath: /var/www/html/cache
                  subPath: cache
                - name: suitecrm-data
                  mountPath: /var/www/html/custom
                  subPath: custom
              resources:
                requests:
                  cpu: 50m
                  memory: 128Mi
                limits:
                  cpu: 500m
                  memory: 512Mi
          volumes:
            - name: suitecrm-data
              persistentVolumeClaim:
                claimName: suitecrm-data
EOF

    print_success "Scheduler CronJob deployed!"
}

##############################################################################
# Display Summary
##############################################################################

display_summary() {
    print_header "Deployment Summary"
    
    ROUTE_URL=$(oc get route suitecrm -o jsonpath='{.spec.host}' 2>/dev/null || echo "${SUITECRM_ROUTE}")
    
    echo ""
    echo "SuiteCRM has been deployed successfully!"
    echo ""
    echo "Access URL: https://${ROUTE_URL}"
    echo ""
    echo "Database Credentials:"
    echo "  Host:     mariadb.${PROJECT_NAME}.svc.cluster.local"
    echo "  Port:     3306"
    echo "  Database: ${DB_NAME}"
    echo "  Username: ${DB_USER}"
    echo "  Password: ${DB_PASSWORD}"
    echo ""
    echo "Next Steps:"
    echo "  1. Navigate to: https://${ROUTE_URL}/install.php"
    echo "  2. Complete the SuiteCRM setup wizard"
    echo "  3. Use the database credentials above when prompted"
    echo ""
    echo "Useful Commands:"
    echo "  View pods:     oc get pods -l app=suitecrm"
    echo "  View logs:     oc logs -f deployment/suitecrm"
    echo "  View DB logs:  oc logs -f deployment/mariadb"
    echo "  Scale:         oc scale deployment/suitecrm --replicas=3"
    echo ""
    
    # Save credentials to file
    CREDS_FILE="suitecrm-credentials.txt"
    cat > "$CREDS_FILE" <<EOF
SuiteCRM Deployment Credentials
===============================
Date: $(date)

Access URL: https://${ROUTE_URL}

Database Information:
  Host: mariadb.${PROJECT_NAME}.svc.cluster.local
  Port: 3306
  Database: ${DB_NAME}
  Username: ${DB_USER}
  Password: ${DB_PASSWORD}
  Root Password: ${DB_ROOT_PASSWORD}

Redis Information:
  Host: redis.${PROJECT_NAME}.svc.cluster.local
  Port: 6379

OpenShift Project: ${PROJECT_NAME}
EOF
    
    print_success "Credentials saved to: ${CREDS_FILE}"
    print_warning "Keep this file secure! It contains sensitive passwords."
}

##############################################################################
# Cleanup Function
##############################################################################

cleanup() {
    print_header "Cleaning Up SuiteCRM Deployment"
    
    print_warning "This will delete all SuiteCRM resources!"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deleting resources..."
        oc delete cronjob suitecrm-scheduler 2>/dev/null || true
        oc delete deployment suitecrm mariadb redis 2>/dev/null || true
        oc delete service suitecrm mariadb redis 2>/dev/null || true
        oc delete route suitecrm 2>/dev/null || true
        oc delete pvc suitecrm-data mariadb-data redis-data 2>/dev/null || true
        oc delete secret suitecrm-db-credentials 2>/dev/null || true
        oc delete configmap mariadb-config 2>/dev/null || true
        print_success "Cleanup complete!"
    else
        print_info "Cleanup cancelled."
    fi
}

##############################################################################
# Usage
##############################################################################

usage() {
    echo "Usage: $0 [COMMAND]"
    echo ""
    echo "Commands:"
    echo "  deploy    Deploy SuiteCRM to OpenShift (default)"
    echo "  cleanup   Remove all SuiteCRM resources"
    echo "  status    Show deployment status"
    echo "  help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0              # Deploy SuiteCRM"
    echo "  $0 deploy       # Deploy SuiteCRM"
    echo "  $0 cleanup      # Remove deployment"
    echo "  $0 status       # Check status"
    echo ""
}

##############################################################################
# Status Function
##############################################################################

status() {
    print_header "SuiteCRM Deployment Status"
    
    echo ""
    echo "=== Pods ==="
    oc get pods -l app=suitecrm
    
    echo ""
    echo "=== Services ==="
    oc get svc -l app=suitecrm
    
    echo ""
    echo "=== Routes ==="
    oc get routes -l app=suitecrm
    
    echo ""
    echo "=== PVCs ==="
    oc get pvc -l app=suitecrm
    
    echo ""
    echo "=== CronJobs ==="
    oc get cronjobs -l app=suitecrm
}

##############################################################################
# Main Execution
##############################################################################

main() {
    print_header "SuiteCRM on OpenShift - Deployment Script"
    
    preflight_checks
    detect_project
    deploy_redis
    deploy_mariadb
    deploy_suitecrm
    deploy_scheduler
    display_summary
    
    print_success "Deployment complete!"
}

# Parse command line arguments
case "${1:-deploy}" in
    deploy)
        main
        ;;
    cleanup)
        preflight_checks
        detect_project
        cleanup
        ;;
    status)
        preflight_checks
        detect_project
        status
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        print_error "Unknown command: $1"
        usage
        exit 1
        ;;
esac
