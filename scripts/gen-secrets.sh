#!/usr/bin/env bash
# Genera credenciales de prueba (solo PoC) en .secrets/ y las carga como Secrets de k8s.
# Si .secrets/ ya existe, reutiliza los valores para que los re-despliegues sean idempotentes.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .secrets
gen() { [ -s ".secrets/$1" ] || openssl rand -hex "${2:-16}" > ".secrets/$1"; cat ".secrets/$1"; }

S3_KEY=$(gen s3_access_key 10)
S3_SECRET=$(gen s3_secret_key 20)
DB_PASS=$(gen db_password)
ROOT_SECRET=$(gen polaris_root_secret)

S3_JSON=$(cat <<EOF
{"identities":[{"name":"lakehouse","credentials":[{"accessKey":"$S3_KEY","secretKey":"$S3_SECRET"}],
  "actions":["Admin","Read","Write","List","Tagging"]}]}
EOF
)

apply_secret() { kubectl create secret generic "$@" --dry-run=client -o yaml | kubectl apply -f - >/dev/null; }

for ns in lakehouse spark-jobs; do
  apply_secret s3-creds -n "$ns" \
    --from-literal=AWS_ACCESS_KEY_ID="$S3_KEY" \
    --from-literal=AWS_SECRET_ACCESS_KEY="$S3_SECRET" \
    --from-literal=AWS_REGION=us-east-1 \
    --from-literal=s3.json="$S3_JSON"
done

apply_secret polaris-db -n lakehouse \
  --from-literal=username=polaris \
  --from-literal=password="$DB_PASS" \
  --from-literal=jdbcUrl="jdbc:postgresql://postgres.lakehouse:5432/polaris"

apply_secret polaris-root -n lakehouse \
  --from-literal=credential="POLARIS,root,$ROOT_SECRET"

echo "Secrets aplicados (valores en .secrets/, no versionar)."
