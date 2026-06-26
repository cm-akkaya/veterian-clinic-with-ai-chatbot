#!/bin/bash
# Terminalden yap, yoksa varsayilanlari alir:  export TAG="v.1.0.0"   export PROJECT="ngn"   export HARBOR_FQDN="172.31.0.26" 
# IMAGES: "SOURCE[:TAG]|DEST_REPO_NAME" formatinda,  mysql yok sadece.

set -e

# Harbor ayarlarini buraya gir
HARBOR_FQDN="${HARBOR_FQDN:-185.32.14.7}"  # Environment'dan al, yoksa varsayilan
PROJECT="${PROJECT:-ngn}"              # Harbor projesi
TAG="${TAG:-latest}"                         # imaj tag'i

# Push edilecek imaj listesi
IMAGES=(
"springcommunity/spring-petclinic-api-gateway:latest|spring-petclinic-api-gateway"
"springcommunity/spring-petclinic-discovery-server:latest|spring-petclinic-discovery-server"
"springcommunity/spring-petclinic-config-server:latest|spring-petclinic-config-server"
"springcommunity/spring-petclinic-genai-service:latest|spring-petclinic-genai-service"
"springcommunity/spring-petclinic-visits-service:latest|spring-petclinic-visits-service"
"springcommunity/spring-petclinic-vets-service:latest|spring-petclinic-vets-service"
"springcommunity/spring-petclinic-customers-service:latest|spring-petclinic-customers-service"
"springcommunity/spring-petclinic-admin-server:latest|spring-petclinic-admin-server"
"veterian-clinic-ai-chatbot-prometheus-server:latest|veterian-clinic-ai-chatbot-prometheus-server"
"veterian-clinic-ai-chatbot-grafana-server:latest|veterian-clinic-ai-chatbot-grafana-server"
"openzipkin/zipkin:latest|openzipkin/zipkin"
)

# Her imaji Harbor'a tag + push yap
for entry in "${IMAGES[@]}"; do
  SRC="${entry%%|*}"        # Orijinal imaj
  DEST="${entry#*|}"        # Harbor reposu
  TARGET="$HARBOR_FQDN/$PROJECT/$DEST:$TAG"

  echo "==> Tagging: $SRC --> $TARGET"
  docker tag "$SRC" "$TARGET"

  echo "==> Pushing: $TARGET"
  docker push "$TARGET"

  echo "---------------------------------------------"
done

echo "✅All images were pushed successfully."
