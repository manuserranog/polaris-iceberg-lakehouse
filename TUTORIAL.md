# Tutorial: Lakehouse con Spark Operator + Polaris + Iceberg en minikube

Guía paso a paso con **los comandos reales** que hay detrás de cada `make`. Si solo quieres levantarlo: `make all`.
Todos los comandos se ejecutan desde la carpeta `poc-lakehouse/`.

---

## 0. Prerrequisitos (una sola vez)

```bash
brew install minikube helm
```
Docker Desktop arrancado, con ≥ 8 GB de RAM en *Settings → Resources*. `kubectl` ya instalado.

---

## 1. Arrancar el cluster

```bash
minikube start --driver=docker --cpus=6 --memory=7000
kubectl get nodes
```

> **Retomar otro día:** `minikube start` (sin más) recupera todo lo desplegado: catálogo, tablas, imagen. Salta al paso 9 (y `make ui` para las interfaces web).
> **Parar sin perder nada:** `minikube stop`.

---

## 2. Namespaces y credenciales

```bash
kubectl apply -f k8s/namespaces.yaml   # lakehouse (infra) y spark-jobs (jobs)
./scripts/gen-secrets.sh               # genera credenciales de prueba en .secrets/ y crea los Secrets
kubectl get secrets -n lakehouse
```
Secrets que se crean:

| Secret | Namespace | Contenido |
|---|---|---|
| `s3-creds` | lakehouse, spark-jobs | Claves S3 + `s3.json` de SeaweedFS |
| `polaris-db` | lakehouse | Usuario, password y JDBC URL de Postgres |
| `polaris-root` | lakehouse | `POLARIS,root,<secret>` (principal root) |

---

## 3. Almacenamiento S3 ("Scality") y Postgres

```bash
kubectl apply -f k8s/s3.yaml -f k8s/postgres.yaml
kubectl -n lakehouse rollout status statefulset/seaweedfs
kubectl -n lakehouse rollout status statefulset/postgres
kubectl -n lakehouse wait --for=condition=complete job/create-bucket
kubectl -n lakehouse logs job/create-bucket        # debe listar el bucket "warehouse"
```

---

## 4. Polaris

**4.1 Inicializar el esquema en Postgres y el realm** (una vez):
```bash
kubectl apply -f k8s/polaris-bootstrap-job.yaml
kubectl -n lakehouse wait --for=condition=complete job/polaris-bootstrap
kubectl -n lakehouse logs job/polaris-bootstrap | tail -2   # "Bootstrap completed successfully."
```

**4.2 Instalar el servidor con Helm:**
```bash
helm repo add polaris https://downloads.apache.org/polaris/helm-chart
helm repo update
helm upgrade --install polaris polaris/polaris --version 1.8.0 \
  -n lakehouse -f helm/polaris-values.yaml --wait
kubectl -n lakehouse get pods
```

---

## 5. Crear catálogo, principal y permisos

```bash
./polaris/bootstrap.sh
```
Qué hace por dentro (API de gestión de Polaris):
1. Token OAuth del `root` → `POST /api/catalog/v1/oauth/tokens`
2. Catálogo `lakehouse` sobre `s3://warehouse/` con endpoint propio, `pathStyleAccess` y `stsUnavailable` → `POST /api/management/v1/catalogs`
3. Principal `spark` (devuelve client_id/secret) → `POST /api/management/v1/principals`
4. Namespace `ventas`, creado por **root** (gobierno: el admin crea los namespaces, los jobs trabajan dentro)
5. Principal role `spark_role` + catalog role `ventas_rw` con privilegios **solo sobre el namespace `ventas`** (ver [Control de acceso](#control-de-acceso-en-polaris))
6. Guarda `POLARIS_CREDENTIAL=client_id:secret` en el Secret `spark-jobs/polaris-spark-creds`

**Probarlo a mano:**
```bash
kubectl -n lakehouse port-forward svc/polaris 8181:8181
```
En otra terminal:
```bash
CRED=$(cat .secrets/polaris_spark_credential)
TOKEN=$(curl -s -X POST localhost:8181/api/catalog/v1/oauth/tokens \
  -d grant_type=client_credentials -d client_id=${CRED%%:*} -d client_secret=${CRED#*:} \
  -d scope=PRINCIPAL_ROLE:ALL | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -s "localhost:8181/api/catalog/v1/config?warehouse=lakehouse" -H "Authorization: Bearer $TOKEN"
curl -s "localhost:8181/api/catalog/v1/lakehouse/namespaces" -H "Authorization: Bearer $TOKEN"
```

---

## 6. Spark Operator (Kubeflow)

```bash
helm repo add spark-operator https://kubeflow.github.io/spark-operator
helm repo update
helm upgrade --install spark-operator spark-operator/spark-operator --version 2.5.2 \
  -n spark-operator --create-namespace -f helm/spark-operator-values.yaml --wait
kubectl -n spark-operator get pods
kubectl get crd | grep sparkoperator
```

---

## 7. Imagen Spark + Iceberg

```bash
minikube image build -t spark-iceberg:3.5 spark/
minikube image ls | grep spark-iceberg
```
La imagen = `apache/spark:3.5.9` + `iceberg-spark-runtime-3.5_2.12` + `iceberg-aws-bundle` (1.10.1) + `hadoop-aws`.
La config del catálogo ([spark/conf/polaris-catalog.properties](spark/conf/polaris-catalog.properties)) va dentro de la imagen; **es el mismo bloque que usarías en EMR y Databricks**.

> Si cambias ese fichero o el Dockerfile, vuelve a ejecutar este paso.

---

## 8. Subir los scripts de los jobs

```bash
kubectl -n spark-jobs create configmap lakehouse-jobs --from-file=jobs/ \
  --dry-run=client -o yaml | kubectl apply -f -
```
> Si editas algo en `jobs/`, repite este comando (no hace falta reconstruir la imagen).

---

## 9. Ejecutar los jobs

Cada job es un `SparkApplication` ([k8s/sparkapps/](k8s/sparkapps/)). Para lanzarlo hay que borrar la ejecución anterior y volver a aplicarlo:

```bash
kubectl -n spark-jobs delete sparkapplication iceberg-smoke --ignore-not-found
kubectl apply -f k8s/sparkapps/smoke.yaml
kubectl -n spark-jobs get sparkapplication iceberg-smoke -w     # esperar a COMPLETED (Ctrl+C)
kubectl -n spark-jobs logs iceberg-smoke-driver | grep -v -E "WARN|INFO"
```
Igual con `reader.yaml` (`iceberg-reader`), `migrate.yaml` (`iceberg-migrate`) y `access.yaml` (`iceberg-access`).
Atajo: `make run-smoke`, `make run-reader`, `make run-migrate`, `make run-access` o `make demo` (los cuatro).

| Job | Qué demuestra | Línea final esperada |
|---|---|---|
| smoke | Tabla con `days(ts)`, INSERT, MERGE, DELETE, ADD COLUMN, time travel, rollback | `SMOKE OK` |
| reader | Otra app que solo comparte Polaris + S3 ve los mismos datos y snapshots | `READER OK` |
| migrate | Parquet estilo Hive → Iceberg con `add_files` sin reescribir + incremental | `MIGRATE OK` |
| access | `spark` puede todo dentro de `ventas` y recibe 403 fuera (listar namespaces, crear `finanzas`) | `ACCESS OK` |

**Ver la UI de Spark mientras corre un job:**
```bash
kubectl -n spark-jobs port-forward iceberg-smoke-driver 4040:4040    # http://localhost:4040
```

---

## 10. Ver el catálogo y los ficheros (interfaces web)

**10.1 Polaris Console** (UI oficial de `apache/polaris-tools`; no hay imagen publicada, se construye):
```bash
make console-image      # git clone polaris-tools + minikube image build (≈ 2-3 min)
make console            # kubectl apply -f k8s/polaris-console.yaml
```
Requisito ya incluido: **CORS** en [helm/polaris-values.yaml](helm/polaris-values.yaml) para `http://localhost:8080`, porque el navegador llama directamente a la API de Polaris en `localhost:8181`.

**10.2 Abrir todos los accesos** (déjalo corriendo en una terminal):
```bash
make ui
```

| Qué | URL | Notas |
|---|---|---|
| Polaris Console | http://localhost:8080 | Usuario `root`, password en `.secrets/polaris_root_secret`. Catalogs → lakehouse → ventas → tabla: esquema, snapshots, propiedades. Access Control: principals, roles, grants |
| Explorador de ficheros S3 | http://localhost:8888/buckets/warehouse/ | Filer web de SeaweedFS. Dentro de cada tabla: `metadata/` (Iceberg) y `data/` (Parquet). Con Scality real: Cyberduck o la consola de Scality |
| API Polaris | http://localhost:8181 | Para `curl` (paso 5) o clientes externos |
| Endpoint S3 | http://localhost:8333 | Para clientes S3 (aws cli, Cyberduck, DuckDB) |

> Si reinstalas Polaris (`helm upgrade`), el pod cambia y los port-forwards se cortan: vuelve a lanzar `make ui`.

---

## 11. Explorar desde la terminal

**Ficheros Iceberg en el S3** (metadata.json, manifests, datos):
```bash
kubectl -n lakehouse run s3ls --rm -i --restart=Never --image=amazon/aws-cli:2.38.1 \
  --overrides='{"spec":{"containers":[{"name":"s3ls","image":"amazon/aws-cli:2.38.1","args":["--endpoint-url","http://seaweedfs:8333","s3","ls","--recursive","s3://warehouse/"],"envFrom":[{"secretRef":{"name":"s3-creds"}}]}]}}'
```

**Estado general:**
```bash
make status
kubectl logs -n lakehouse -l app.kubernetes.io/name=polaris --tail=50
```

**Escribir tu propio job:** copia `jobs/iceberg_reader.py`, usa `get_spark("mi-job")` de `lakehouse_session.py`, crea un `k8s/sparkapps/mijob.yaml` copiando otro y cambiando `name` y `mainApplicationFile`, y repite los pasos 8 y 9.

---

## 12. Parar y limpiar

```bash
minikube stop                 # parar (conserva todo)
make down                     # borrar Polaris, operator y namespaces (mantiene minikube)
minikube delete               # borrar el cluster entero
```

---

## Control de acceso en Polaris

Cadena de permisos (los principals nunca reciben privilegios directamente):
```
Principal ──► Principal Role ──► Catalog Role ──► Privilegios sobre catálogo / namespace / tabla / vista
spark          spark_role          ventas_rw         namespace ventas: NAMESPACE_FULL_METADATA,
                                                     TABLE_FULL_METADATA, TABLE_WRITE_DATA, VIEW_FULL_METADATA
```
- Los grants sobre un namespace se **heredan** a sus tablas y vistas (también las futuras).
- `*_FULL_METADATA` **no** incluye datos: `TABLE_READ_DATA` / `TABLE_WRITE_DATA` se conceden aparte (WRITE implica READ).
- Perfil de solo lectura sobre una tabla: catalog role con `TABLE_READ_DATA` sobre `ventas.pedidos`.
- Polaris aplica los permisos en el **catálogo**. Con claves S3 estáticas (como esta PoC) quien tenga las claves puede leer el bucket directamente; para aplicarlo también en los datos hace falta *credential vending* (STS en Scality).
- No hay seguridad por columna/fila: se resuelve en el motor (Trino + OPA/Ranger) o con vistas.

**Ver los permisos de `spark`:** Console → *Access Control* → Principals → `spark`, o por API:
```bash
B=http://localhost:8181
T=$(curl -s -X POST $B/api/catalog/v1/oauth/tokens -d grant_type=client_credentials -d client_id=root \
  -d client_secret=$(cat .secrets/polaris_root_secret) -d scope=PRINCIPAL_ROLE:ALL \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -s $B/api/management/v1/principals/spark/principal-roles -H "Authorization: Bearer $T"
curl -s $B/api/management/v1/principal-roles/spark_role/catalog-roles/lakehouse -H "Authorization: Bearer $T"
curl -s $B/api/management/v1/catalogs/lakehouse/catalog-roles/ventas_rw/grants -H "Authorization: Bearer $T"
```

**Comprobarlo:** `make run-access`.

---

## Problemas habituales

| Síntoma | Causa / solución |
|---|---|
| `Unable to load credentials from any of the providers` con `Server error` | Polaris no ve las claves S3 → `envFrom: s3-creds` en [helm/polaris-values.yaml](helm/polaris-values.yaml) |
| `No FileSystem for scheme "s3"` en `add_files` | Falta `spark.hadoop.fs.s3.impl=org.apache.hadoop.fs.s3a.S3AFileSystem` |
| Pod de Polaris con reinicios tras `minikube start` | Normal: arranca antes que Postgres y reintenta; espera a `1/1 Running` |
| `ErrImageNeverPull` en el driver | La imagen no está en minikube → paso 7 |
| El job no ve tus cambios en `jobs/` | Repite el paso 8 (ConfigMap) |
| `ForbiddenException` / 403 en un job | El principal `spark` solo tiene permisos en `lake.ventas`: usa ese namespace o añade grants |
| `not authorized for op ROTATE_CREDENTIALS` | Solo el propio principal puede rotar; el admin usa `POST /principals/<p>/reset` |

---

## Llevarlo a EMR y Databricks
- [docs/emr.md](docs/emr.md)
- [docs/databricks.md](docs/databricks.md)
