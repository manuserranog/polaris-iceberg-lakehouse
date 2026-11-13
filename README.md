# polaris-iceberg-lakehouse

Lakehouse local con Apache Iceberg, Apache Polaris (catálogo REST) y Kubeflow Spark Operator sobre minikube.

Valida en local la arquitectura objetivo: **Iceberg + catálogo Iceberg REST (Polaris) sobre S3 on-prem**, con Spark en Kubernetes como alternativa a Cloudera y la **misma configuración de catálogo** que usarían EMR y Databricks.

```
            minikube
 ┌───────────────────────────────────────────────────────────────┐
 │ ns spark-jobs                    ns lakehouse                 │
 │  SparkApplication ──REST/OAuth──► Polaris 1.8 ──JDBC──► Postgres│
 │  (driver+executors)                  │                         │
 │        └──────── S3FileIO ──────────►└──► SeaweedFS (S3 API)   │
 │ ns spark-operator: Kubeflow Spark Operator 2.5     = "Scality" │
 └───────────────────────────────────────────────────────────────┘
        EMR / Databricks → mismo bloque de config (docs/)
```

| Pieza | Versión | Papel |
|---|---|---|
| Apache Polaris | 1.8.0 (chart oficial) | Catálogo Iceberg REST, RBAC, persistencia Postgres |
| Kubeflow Spark Operator | 2.5.2 | Ejecuta `SparkApplication` |
| Spark | 3.5.9 / Scala 2.12 / Java 17 | Misma línea que EMR 7.x y DBR 14–16 LTS |
| Iceberg | 1.10.1 (`iceberg-spark-runtime-3.5_2.12` + `iceberg-aws-bundle`) | Formato de tabla |
| SeaweedFS | 4.48 | S3-compatible con endpoint propio y path-style (sustituye a Scality; MinIO ya no publica imágenes) |

> 📘 Guía paso a paso con todos los comandos: **[TUTORIAL.md](TUTORIAL.md)**

## Requisitos
Docker Desktop (recomendado ≥ 8 GB de RAM asignados), `kubectl`, `minikube`, `helm` (`brew install minikube helm`).

## Arranque
```bash
make all          # cluster + secrets + S3 + Postgres + Polaris + bootstrap + operator + imagen + demo
```
O paso a paso: `make up` → `make bootstrap` → `make operator` → `make image` → `make demo`.

| Target | Qué hace |
|---|---|
| `make up` | minikube, Secrets (generados en `.secrets/`), SeaweedFS + bucket `warehouse`, Postgres, bootstrap del realm y Polaris |
| `make bootstrap` | Catálogo `lakehouse`, principal `spark`, namespace `ventas`, roles `spark_role`/`ventas_rw` (acceso solo a `ventas`) ([polaris/bootstrap.sh](polaris/bootstrap.sh)) |
| `make operator` | Instala el Spark Operator vigilando `spark-jobs` |
| `make image` | Construye `spark-iceberg:3.5` dentro de minikube |
| `make run-smoke` / `run-reader` / `run-migrate` / `run-access` | Lanza cada `SparkApplication` y muestra su salida |
| `make status` / `make ui` | Estado de pods / port-forward de Polaris (:8181) y S3 (:8333) |
| `make down` / `make destroy` | Borra los recursos / borra minikube |

## Qué demuestra cada job
- **[iceberg_smoke.py](jobs/iceberg_smoke.py)**: tabla con particionado oculto `days(ts)`, `INSERT`, `MERGE`, `DELETE`, `ALTER TABLE ADD COLUMN`, time travel `VERSION AS OF` y `rollback_to_snapshot`.
- **[iceberg_reader.py](jobs/iceberg_reader.py)**: otra aplicación Spark que solo comparte Polaris + S3 ve los mismos datos, esquema y snapshots → interoperabilidad entre motores (EMR / Databricks / k8s).
- **[migrate_hive_parquet.py](jobs/migrate_hive_parquet.py)**: Parquet con layout Hive (`dt=…/`) importado a Iceberg con `add_files` **sin reescribir datos**, más importación incremental de una partición nueva (convivencia con el job legacy).

## Configuración portable
[spark/conf/polaris-catalog.properties](spark/conf/polaris-catalog.properties) es el bloque que se reutiliza tal cual en:
- **EMR** → [docs/emr.md](docs/emr.md)
- **Databricks** → [docs/databricks.md](docs/databricks.md)

En k8s lo carga [jobs/lakehouse_session.py](jobs/lakehouse_session.py) (el operator monta su propio `/opt/spark/conf`) e inyecta `POLARIS_CREDENTIAL` desde el Secret `polaris-spark-creds`.

## Lecciones de la PoC
- Con un S3 no-AWS, el catálogo se crea con `stsUnavailable: true`, y el servidor Polaris necesita las claves como `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (cadena por defecto), no solo `storage.secret`.
- `add_files` escribe manifests temporales con Hadoop FS sobre rutas `s3://` → hace falta `fs.s3.impl=S3AFileSystem`. En EMR/Databricks `s3://` apunta a AWS S3, así que con Scality también hay que mapearlo (por job).
- Polaris 1.8 expone también `/api/openlineage/v1/lineage` y políticas de tabla: base para linaje y mantenimiento gestionado.

## Siguientes pasos
1. Credential vending: probar contra el STS de Scality (si lo tiene) y quitar claves estáticas de los executors.
2. Exponer Polaris por Ingress con TLS y conectar un cluster EMR / Databricks real.
3. Mantenimiento: jobs de `rewrite_data_files`, `expire_snapshots`, `remove_orphan_files` (o Apache Amoro).
4. Autenticación externa (OIDC con vuestro IdP) en lugar de la interna de Polaris.
