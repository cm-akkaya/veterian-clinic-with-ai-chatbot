# Petclinic → Kubernetes Deploy Rehberi

## Dosya Yapısı

```
k8s/
├── 00-namespace-and-secret.yaml     # Namespace + imagePullSecret talimatı
├── 01-configmap-and-secrets.yaml    # MySQL & OpenAI secret'ları
├── 02-persistentvolumeclaims.yaml   # MySQL, Prometheus, Grafana PVC'leri
├── 03-mysql.yaml                    # MySQL StatefulSet + headless Service
├── 04-infrastructure-services.yaml  # config-server + discovery-server
├── 05-app-services.yaml             # customers, visits, vets servisleri
├── 06-gateway-and-support-services.yaml  # api-gateway, genai, admin, zipkin
├── 07-monitoring.yaml               # Prometheus + Grafana
├── 08-ingress.yaml                  # Nginx Ingress (tüm path'ler)
└── deploy-to-k8s.sh                 # Tek komutla deploy scripti
```

---

## Adım Adım Deploy

### 1. Harbor imagePullSecret oluştur

```bash
kubectl apply -f 00-namespace-and-secret.yaml

kubectl create secret docker-registry harbor-pull-secret \
  --namespace=petclinic \
  --docker-server=185.32.14.7 \
  --docker-username='robot$ngn+ngn-list-robot' \
  --docker-password='<ROBOT_ACCOUNT_SIFREN>' \
  --docker-email=admin@petclinic.local
```

> ⚠️ Robot account adındaki `$` işareti nedeniyle tek tırnak (`'`) zorunlu.

### 2. Storage class'ı kontrol et

```bash
kubectl get storageclass
```

Eğer `(default)` annotasyonlu bir SC varsa PVC'ler otomatik bind olur.
Yoksa `02-persistentvolumeclaims.yaml` içindeki `storageClassName` alanını doldur.

### 3. Deploy et

```bash
chmod +x deploy-to-k8s.sh
bash deploy-to-k8s.sh <IMAGE_TAG>
# Örnek:
bash deploy-to-k8s.sh 42
```

### 4. Durumu izle

```bash
# Pod durumu
kubectl get pods -n petclinic -w

# Servis durumu
kubectl get svc -n petclinic

# Ingress
kubectl get ingress -n petclinic

# Belirli bir pod'un logları
kubectl logs -f deployment/api-gateway -n petclinic
kubectl logs -f deployment/config-server -n petclinic
```

---

## Erişim URL'leri

| Servis | URL |
|---|---|
| Ana Uygulama | http://185.32.14.38/ |
| Eureka | http://185.32.14.38/eureka/ |
| Spring Boot Admin | http://185.32.14.38/admin/ |
| Grafana | http://185.32.14.38/grafana/ |
| Prometheus | http://185.32.14.38/prometheus/ |
| Zipkin | http://185.32.14.38/zipkin/ |

---

## GenAI Servisi Notu

genai-service dummy OpenAI key ile deploy edilmiştir.
Crash döngüsüne girerse:

```bash
# Geçici olarak kapat
kubectl scale deployment genai-service --replicas=0 -n petclinic

# Gerçek key ile güncelle
kubectl create secret generic genai-secret \
  --namespace=petclinic \
  --from-literal=SPRING_AI_OPENAI_API_KEY='sk-...' \
  --from-literal=OPENAI_API_KEY='sk-...' \
  --dry-run=client -o yaml | kubectl apply -f -

# Yeniden başlat
kubectl scale deployment genai-service --replicas=1 -n petclinic
```

---

## Sıfırdan Temizleme

```bash
# Tüm namespace'i sil (PVC'ler dahil!)
kubectl delete namespace petclinic

# Sadece pod'ları yeniden başlat
kubectl rollout restart deployment -n petclinic
```

---

## Sık Karşılaşılan Sorunlar

| Sorun | Komut |
|---|---|
| ImagePullBackOff | `kubectl describe pod <pod> -n petclinic` → secret kontrolü |
| CrashLoopBackOff | `kubectl logs <pod> -n petclinic --previous` |
| PVC Pending | `kubectl describe pvc -n petclinic` → storageclass kontrolü |
| Ingress çalışmıyor | `kubectl describe ingress -n petclinic` |
