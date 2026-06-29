#!/bin/bash
# =============================================================================
# deploy-to-k8s.sh — Petclinic tam otomatik Kubernetes deploy scripti
#
# Kullanım:
#   bash deploy-to-k8s.sh <IMAGE_TAG> [HARBOR_ROBOT_PASSWORD]
#
# Örnekler:
#   bash deploy-to-k8s.sh 26
#   bash deploy-to-k8s.sh 26 'MyRobotPass123'
#
# Ortam değişkeni ile şifre vermek de mümkün:
#   export HARBOR_PASS='MyRobotPass123'
#   bash deploy-to-k8s.sh 26
#
# Script sırasıyla şunları yapar:
#   1. Worker node taint'lerini kaldırır
#   2. EBS GP3 StorageClass oluşturur (yoksa)
#   3. Harbor TLS sertifikasını tüm node'lara DaemonSet ile dağıtır
#   4. containerd config_path'i ayarlar ve containerd'yi restart eder
#   5. Namespace ve imagePullSecret oluşturur
#   6. Tüm manifest'leri sırayla uygular
# =============================================================================

set -e

# ── Renkli çıktı ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}==>${NC} ${BOLD}$*${NC}"; }
success() { echo -e "${GREEN}✅${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠️ ${NC} $*"; }
die()     { echo -e "${RED}❌ HATA:${NC} $*" >&2; exit 1; }

# ── Parametreler ──────────────────────────────────────────────────────────────
IMAGE_TAG="${1:-}"
HARBOR_PASS="${2:-${HARBOR_PASS:-}}"

NAMESPACE="petclinic"
HARBOR_FQDN="185.32.14.7"
HARBOR_USER='robot$ngn+ngn-list-robot'
HARBOR_PROJECT="ngn"
PUBLIC_IP="185.32.14.38"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# ── Parametre kontrolleri ─────────────────────────────────────────────────────
[[ -z "$IMAGE_TAG" ]] && die "IMAGE_TAG gerekli.\n  Kullanım: bash deploy-to-k8s.sh <IMAGE_TAG>"
[[ -z "$HARBOR_PASS" ]] && die "Harbor robot şifresi gerekli.\n  Ya parametre olarak ver: bash deploy-to-k8s.sh $IMAGE_TAG 'SIFRE'\n  Ya da: export HARBOR_PASS='SIFRE'"

echo ""
echo -e "${BOLD}================================================${NC}"
echo -e "${BOLD}  Petclinic → Kubernetes Tam Otomatik Deploy${NC}"
echo -e "${BOLD}================================================${NC}"
echo "  Image Tag  : ${IMAGE_TAG}"
echo "  Namespace  : ${NAMESPACE}"
echo "  Harbor     : ${HARBOR_FQDN}"
echo "  Public IP  : ${PUBLIC_IP}"
echo "  Temp dir   : ${TMPDIR_WORK}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# ADIM 1 — Worker node taint'lerini kaldır
# ══════════════════════════════════════════════════════════════════════════════
info "[1/9] Worker node taint'leri kontrol ediliyor..."

WORKER_NODES=$(kubectl get nodes --no-headers -l '!node-role.kubernetes.io/control-plane,!node-role/frontend' \
  -o custom-columns=NAME:.metadata.name | grep worker || true)

if [[ -z "$WORKER_NODES" ]]; then
  warn "Worker node bulunamadı, taint kaldırma adımı atlanıyor."
else
  for node in $WORKER_NODES; do
    TAINTS=$(kubectl get node "$node" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null || true)
    if echo "$TAINTS" | grep -q "owner"; then
      kubectl taint node "$node" owner:NoSchedule- 2>/dev/null || true
      success "Taint kaldırıldı: $node"
    else
      echo "    Taint yok, atlanıyor: $node"
    fi
  done
fi

# ══════════════════════════════════════════════════════════════════════════════
# ADIM 2 — StorageClass oluştur (yoksa)
# ══════════════════════════════════════════════════════════════════════════════
info "[2/9] StorageClass kontrol ediliyor..."

if kubectl get storageclass ebs-gp3 &>/dev/null; then
  success "StorageClass 'ebs-gp3' zaten mevcut."
else
  info "StorageClass oluşturuluyor..."
  kubectl apply -f - << 'SCEOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ebs-gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
allowVolumeExpansion: true
parameters:
  type: gp3
  fsType: ext4
SCEOF
  success "StorageClass 'ebs-gp3' oluşturuldu."
fi

# ══════════════════════════════════════════════════════════════════════════════
# ADIM 3 — Harbor TLS sertifikasını tüm node'lara dağıt
# ══════════════════════════════════════════════════════════════════════════════
info "[3/9] Harbor TLS sertifikası alınıyor ve node'lara dağıtılıyor..."

# Sertifikayı çek
openssl s_client -connect "${HARBOR_FQDN}:443" -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > "${TMPDIR_WORK}/harbor-ca.crt"

if [[ ! -s "${TMPDIR_WORK}/harbor-ca.crt" ]]; then
  die "Harbor sertifikası alınamadı. Harbor erişilebilir mi? (${HARBOR_FQDN}:443)"
fi
success "Sertifika alındı."

# ConfigMap oluştur
kubectl create configmap harbor-ca-cert \
  --from-file=harbor-ca.crt="${TMPDIR_WORK}/harbor-ca.crt" \
  -n kube-system --dry-run=client -o yaml | kubectl apply -f -

# DaemonSet ile sertifikayı ve config_path'i tüm node'lara uygula
python3 - << PYEOF
content = """apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: harbor-cert-installer
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: harbor-cert-installer
  template:
    metadata:
      labels:
        app: harbor-cert-installer
    spec:
      tolerations:
        - operator: Exists
      hostPID: true
      initContainers:
        - name: install-cert
          image: alpine:latest
          securityContext:
            privileged: true
          command:
            - sh
            - -c
            - |
              CERT_DIR="/host/etc/containerd/certs.d/${HARBOR_FQDN}"
              mkdir -p "\$CERT_DIR"
              cp /tmp/ca/harbor-ca.crt "\$CERT_DIR/harbor-ca.crt"
              printf 'server = "https://${HARBOR_FQDN}"\\\\n[host."https://${HARBOR_FQDN}"]\\\\n  ca = "/etc/containerd/certs.d/${HARBOR_FQDN}/harbor-ca.crt"\\\\n' > "\$CERT_DIR/hosts.toml"
              CONFIG="/host/etc/containerd/config.toml"
              if grep -q 'config_path = ""' "\$CONFIG"; then
                sed -i 's|config_path = ""|config_path = "/etc/containerd/certs.d"|g' "\$CONFIG"
                echo "  config_path guncellendi: \$(hostname)"
              fi
              nsenter -t 1 -m -u -i -n -p -- systemctl restart containerd
              sleep 3
              echo "OK \$(hostname)"
          volumeMounts:
            - name: host-etc
              mountPath: /host/etc
            - name: harbor-ca
              mountPath: /tmp/ca
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: "1m"
              memory: "8Mi"
      volumes:
        - name: host-etc
          hostPath:
            path: /etc
        - name: harbor-ca
          configMap:
            name: harbor-ca-cert
"""
with open('${TMPDIR_WORK}/harbor-cert-ds.yaml', 'w') as f:
    f.write(content)
PYEOF

kubectl apply -f "${TMPDIR_WORK}/harbor-cert-ds.yaml"

# Tüm node'larda tamamlanmasını bekle
info "    Sertifika dağıtımı bekleniyor (max 2 dakika)..."
TIMEOUT=120
ELAPSED=0
while true; do
  TOTAL=$(kubectl get pods -n kube-system -l app=harbor-cert-installer --no-headers 2>/dev/null | wc -l)
  DONE=$(kubectl logs -n kube-system -l app=harbor-cert-installer -c install-cert 2>/dev/null | grep -c "^OK" || true)
  echo "    Tamamlanan: ${DONE}/${TOTAL} node"
  [[ "$DONE" -ge "$TOTAL" && "$TOTAL" -gt 0 ]] && break
  [[ "$ELAPSED" -ge "$TIMEOUT" ]] && die "Sertifika dağıtımı timeout! DaemonSet loglarını kontrol et."
  sleep 5
  ELAPSED=$((ELAPSED + 5))
done

success "Sertifika tüm node'lara dağıtıldı."

# Temizlik
kubectl delete daemonset harbor-cert-installer -n kube-system --ignore-not-found
kubectl delete configmap harbor-ca-cert -n kube-system --ignore-not-found

# ══════════════════════════════════════════════════════════════════════════════
# ADIM 4 — Namespace ve imagePullSecret
# ══════════════════════════════════════════════════════════════════════════════
info "[4/9] Namespace ve imagePullSecret oluşturuluyor..."

kubectl apply -f "${SCRIPT_DIR}/00-namespace-and-secret.yaml"

kubectl create secret docker-registry harbor-pull-secret \
  --namespace="${NAMESPACE}" \
  --docker-server="${HARBOR_FQDN}" \
  --docker-username="${HARBOR_USER}" \
  --docker-password="${HARBOR_PASS}" \
  --docker-email=admin@petclinic.local \
  --dry-run=client -o yaml | kubectl apply -f -

success "Namespace ve imagePullSecret hazır."

# ══════════════════════════════════════════════════════════════════════════════
# ADIM 5 — YAML'ları hazırla (IMAGE_TAG yerleştir)
# ══════════════════════════════════════════════════════════════════════════════
info "[5/9] YAML dosyaları hazırlanıyor (IMAGE_TAG=${IMAGE_TAG})..."

for f in "${SCRIPT_DIR}"/0[1-9]*.yaml; do
  fname=$(basename "$f")
  sed "s/IMAGE_TAG/${IMAGE_TAG}/g" "$f" > "${TMPDIR_WORK}/${fname}"
  echo "    ✔ ${fname}"
done

# ══════════════════════════════════════════════════════════════════════════════
# ADIM 6 — Secret, PVC
# ══════════════════════════════════════════════════════════════════════════════
info "[6/9] Secret ve PVC'ler uygulanıyor..."
kubectl apply -f "${TMPDIR_WORK}/01-configmap-and-secrets.yaml"
kubectl apply -f "${TMPDIR_WORK}/02-persistentvolumeclaims.yaml"
success "Secret ve PVC'ler oluşturuldu."

# ══════════════════════════════════════════════════════════════════════════════
# ADIM 7 — MySQL
# ══════════════════════════════════════════════════════════════════════════════
info "[7/9] MySQL başlatılıyor..."
kubectl apply -f "${TMPDIR_WORK}/03-mysql.yaml"

echo "    MySQL hazır olması bekleniyor (max 4 dakika)..."
kubectl rollout status statefulset/mysql-server -n "${NAMESPACE}" --timeout=240s
success "MySQL hazır."

# ══════════════════════════════════════════════════════════════════════════════
# ADIM 8 — Infrastructure (config-server, discovery-server)
# ══════════════════════════════════════════════════════════════════════════════
info "[8/9] Infrastructure servisleri başlatılıyor..."
kubectl apply -f "${TMPDIR_WORK}/04-infrastructure-services.yaml"

echo "    Config-server bekleniyor (max 4 dakika)..."
kubectl rollout status deployment/config-server -n "${NAMESPACE}" --timeout=240s

echo "    Discovery-server bekleniyor (max 4 dakika)..."
kubectl rollout status deployment/discovery-server -n "${NAMESPACE}" --timeout=240s
success "Infrastructure servisleri hazır."

# ══════════════════════════════════════════════════════════════════════════════
# ADIM 9 — Uygulama servisleri, monitoring, ingress
# ══════════════════════════════════════════════════════════════════════════════
info "[9/9] Uygulama servisleri, monitoring ve ingress uygulanıyor..."
kubectl apply -f "${TMPDIR_WORK}/05-app-services.yaml"
kubectl apply -f "${TMPDIR_WORK}/06-gateway-and-support-services.yaml"
kubectl apply -f "${TMPDIR_WORK}/07-monitoring.yaml"
kubectl apply -f "${TMPDIR_WORK}/08-ingress.yaml"
success "Tüm servisler uygulandı."

# ── Özet ──────────────────────────────────────────────────────────────────────
echo ""
info "Servisler ayağa kalkıyor, 60 saniye bekleniyor..."
sleep 60

echo ""
echo -e "${BOLD}================================================${NC}"
echo -e "${BOLD}  Pod Durumu${NC}"
echo -e "${BOLD}================================================${NC}"
kubectl get pods -n "${NAMESPACE}" -o wide

echo ""
echo -e "${BOLD}================================================${NC}"
echo -e "${BOLD}  Erişim URL'leri${NC}"
echo -e "${BOLD}------------------------------------------------${NC}"
echo "  Ana Uygulama : http://${PUBLIC_IP}/"
echo "  Eureka       : http://${PUBLIC_IP}/eureka/"
echo "  Admin        : http://${PUBLIC_IP}/admin/"
echo "  Grafana      : http://${PUBLIC_IP}/grafana/"
echo "  Prometheus   : http://${PUBLIC_IP}/prometheus/"
echo "  Zipkin       : http://${PUBLIC_IP}/zipkin/"
echo -e "${BOLD}================================================${NC}"
echo ""
warn "genai-service dummy key ile çalışıyor (0/1 normal)."
echo "  Kapatmak için: kubectl scale deployment genai-service --replicas=0 -n petclinic"
echo "  Gerçek key:    kubectl create secret generic genai-secret -n petclinic \\"
echo "                   --from-literal=SPRING_AI_OPENAI_API_KEY='sk-...' \\"
echo "                   --from-literal=OPENAI_API_KEY='sk-...' \\"
echo "                   --dry-run=client -o yaml | kubectl apply -f -"
echo "                 kubectl rollout restart deployment/genai-service -n petclinic"
