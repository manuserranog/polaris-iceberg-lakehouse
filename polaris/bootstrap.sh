#!/usr/bin/env bash
# Crea en Polaris: catálogo "lakehouse" sobre el S3 local, principal "spark" y sus roles/grants.
# Guarda las credenciales OAuth del principal en el Secret polaris-spark-creds (ns spark-jobs).
# Idempotente: los 409 (ya existe) se ignoran y, si el principal existe, se rotan sus credenciales.
set -euo pipefail
cd "$(dirname "$0")/.."

S3_ENDPOINT=${S3_ENDPOINT:-http://seaweedfs.lakehouse:8333}
ROOT_SECRET=$(cat .secrets/polaris_root_secret)

# Port-forward temporal al API REST de Polaris
kubectl -n lakehouse port-forward svc/polaris 18181:8181 >/dev/null 2>&1 &
PF=$!; trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 30); do curl -s -o /dev/null localhost:18181 && break; sleep 1; done
BASE=http://localhost:18181

TOKEN=$(curl -sf -X POST "$BASE/api/catalog/v1/oauth/tokens" \
  -d grant_type=client_credentials -d client_id=root -d client_secret="$ROOT_SECRET" \
  -d scope=PRINCIPAL_ROLE:ALL | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')

# api METHOD PATH [JSON] -> imprime el cuerpo; tolera 409 (ya existe) y 404 en DELETE (ya no existe)
# PATH relativo a /api/management/v1, o absoluto si empieza por /api/
api() {
  local out code url
  out=$(mktemp)
  [[ $2 == /api/* ]] && url="$BASE$2" || url="$BASE/api/management/v1$2"
  code=$(curl -s -o "$out" -w '%{http_code}' -X "$1" "$url" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' ${3:+-d "$3"})
  [[ $1 == DELETE && $code -eq 404 ]] && code=204
  if [[ $code -ge 400 && $code -ne 409 ]]; then echo "ERROR $code en $1 $2: $(cat "$out")" >&2; exit 1; fi
  [[ $code -eq 409 ]] && echo "  (ya existe) $1 $2" >&2
  cat "$out"; rm -f "$out"
  return 0
}

echo "== Catálogo lakehouse"
api POST /catalogs "$(cat <<EOF
{"catalog":{"name":"lakehouse","type":"INTERNAL",
  "properties":{"default-base-location":"s3://warehouse/lakehouse"},
  "storageConfigInfo":{"storageType":"S3","allowedLocations":["s3://warehouse/"],
    "region":"us-east-1","endpoint":"$S3_ENDPOINT","pathStyleAccess":true,"stsUnavailable":true}}}
EOF
)" >/dev/null

echo "== Principal spark"
CREDS=$(api POST /principals '{"principal":{"name":"spark"},"credentialRotationRequired":false}')
if grep -q clientSecret <<<"$CREDS"; then
  CLIENT_ID=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["credentials"]["clientId"])' <<<"$CREDS")
  CLIENT_SECRET=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["credentials"]["clientSecret"])' <<<"$CREDS")
elif [[ -s .secrets/polaris_spark_credential ]]; then
  # Ya existía: reutilizamos las credenciales guardadas (rotate solo lo puede hacer el propio principal)
  IFS=: read -r CLIENT_ID CLIENT_SECRET < .secrets/polaris_spark_credential || true
else
  # Existe pero hemos perdido el secreto: reset como administrador
  CREDS=$(api POST /principals/spark/reset '{}')
  CLIENT_ID=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["credentials"]["clientId"])' <<<"$CREDS")
  CLIENT_SECRET=$(python3 -c 'import sys,json;print(json.load(sys.stdin)["credentials"]["clientSecret"])' <<<"$CREDS")
fi

# Gobierno: el admin crea los namespaces; cada principal solo trabaja dentro de los suyos.
echo "== Namespace ventas (lo crea root, no los jobs)"
api POST /api/catalog/v1/lakehouse/namespaces '{"namespace":["ventas"],"properties":{"owner":"equipo-ventas"}}' >/dev/null

echo "== Roles y grants: spark solo dentro del namespace ventas"
api POST /principal-roles '{"principalRole":{"name":"spark_role"}}' >/dev/null
api PUT /principals/spark/principal-roles '{"principalRole":{"name":"spark_role"}}' >/dev/null
api POST /catalogs/lakehouse/catalog-roles '{"catalogRole":{"name":"ventas_rw"}}' >/dev/null
# FULL_METADATA no incluye leer/escribir datos: TABLE_WRITE_DATA se concede aparte (implica READ_DATA).
# Concedido sobre el namespace -> se hereda a todas sus tablas y vistas, también las futuras.
for priv in NAMESPACE_FULL_METADATA TABLE_FULL_METADATA TABLE_WRITE_DATA VIEW_FULL_METADATA; do
  api PUT /catalogs/lakehouse/catalog-roles/ventas_rw/grants \
    "{\"grant\":{\"type\":\"namespace\",\"namespace\":[\"ventas\"],\"privilege\":\"$priv\"}}" >/dev/null
done
api PUT /principal-roles/spark_role/catalog-roles/lakehouse '{"catalogRole":{"name":"ventas_rw"}}' >/dev/null
# Versiones anteriores de la PoC daban CATALOG_MANAGE_CONTENT (todo el catálogo): se retira.
api DELETE /principal-roles/spark_role/catalog-roles/lakehouse/content_admin >/dev/null
api DELETE /catalogs/lakehouse/catalog-roles/content_admin >/dev/null

kubectl create secret generic polaris-spark-creds -n spark-jobs \
  --from-literal=POLARIS_CREDENTIAL="$CLIENT_ID:$CLIENT_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
printf '%s:%s' "$CLIENT_ID" "$CLIENT_SECRET" > .secrets/polaris_spark_credential

echo "== Comprobación: config del warehouse vista por el principal spark"
SPARK_TOKEN=$(curl -sf -X POST "$BASE/api/catalog/v1/oauth/tokens" \
  -d grant_type=client_credentials -d client_id="$CLIENT_ID" -d client_secret="$CLIENT_SECRET" \
  -d scope=PRINCIPAL_ROLE:ALL | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -sf "$BASE/api/catalog/v1/config?warehouse=lakehouse" -H "Authorization: Bearer $SPARK_TOKEN"; echo
echo "OK: credenciales del principal spark guardadas en Secret spark-jobs/polaris-spark-creds"
