# Databricks → Polaris + Scality

Mismo bloque que [`spark/conf/polaris-catalog.properties`](../spark/conf/polaris-catalog.properties). Databricks actúa como **cliente Iceberg REST** con el jar OSS de Iceberg; Unity Catalog no puede gobernar almacenamiento S3-compatible on-prem.

## Requisitos y limitaciones (validar en vuestro workspace)
- **Access mode**: *Dedicated* (single user) o clusters sin UC. En *Standard/Shared* los jars y catálogos Spark custom están restringidos (allowlist de UC).
- **Runtime**: DBR 14.3 / 15.4 / 16.4 LTS (Spark 3.5, Scala 2.12) → `iceberg-spark-runtime-3.5_2.12`. DBR 17+ (Spark 4) → `iceberg-spark-runtime-4.0_2.13`.
- **Photon** no acelera Iceberg vía jar OSS (sí Delta).
- **S3-compatible**: configurar `fs.s3a` con endpoint propio funciona en clusters clásicos, pero no es un escenario soportado oficialmente por Databricks.
- **Red**: el plano de datos del workspace (vuestra VPC) debe llegar a Polaris y Scality on-prem (VPN / Direct Connect, TLS).

## Librerías del cluster
- Maven: `org.apache.iceberg:iceberg-spark-runtime-3.5_2.12:1.10.1`
- Maven: `org.apache.iceberg:iceberg-aws-bundle:1.10.1`

## Spark config del cluster
```
spark.sql.extensions org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions
spark.sql.catalog.lake org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.lake.type rest
spark.sql.catalog.lake.uri https://polaris.midominio.local/api/catalog
spark.sql.catalog.lake.warehouse lakehouse
spark.sql.catalog.lake.scope PRINCIPAL_ROLE:ALL
spark.sql.catalog.lake.token-refresh-enabled true
spark.sql.catalog.lake.credential {{secrets/lakehouse/polaris_credential}}
spark.sql.catalog.lake.io-impl org.apache.iceberg.aws.s3.S3FileIO
spark.sql.catalog.lake.s3.endpoint https://scality.midominio.local
spark.sql.catalog.lake.s3.path-style-access true
spark.sql.catalog.lake.client.region us-east-1
spark.sql.catalog.lake.s3.access-key-id {{secrets/lakehouse/scality_access_key}}
spark.sql.catalog.lake.s3.secret-access-key {{secrets/lakehouse/scality_secret_key}}

spark.hadoop.fs.s3a.bucket.warehouse.endpoint https://scality.midominio.local
spark.hadoop.fs.s3a.bucket.warehouse.path.style.access true
spark.hadoop.fs.s3a.bucket.warehouse.access.key {{secrets/lakehouse/scality_access_key}}
spark.hadoop.fs.s3a.bucket.warehouse.secret.key {{secrets/lakehouse/scality_secret_key}}
```
Los `{{secrets/<scope>/<key>}}` salen de un *Databricks secret scope* (`databricks secrets create-scope lakehouse`).

## Uso
```sql
SELECT * FROM lake.ventas.pedidos ORDER BY id;          -- tabla escrita desde Spark on k8s / EMR
SELECT * FROM lake.ventas.pedidos VERSION AS OF <snapshot_id>;
```
Para `add_files` / `remove_orphan_files` añade en el job `spark.hadoop.fs.s3.impl org.apache.hadoop.fs.s3a.S3AFileSystem` (en Databricks `s3://` resuelve contra AWS S3).
