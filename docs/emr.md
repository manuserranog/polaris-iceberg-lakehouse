# EMR → Polaris + Scality

Mismo bloque que [`spark/conf/polaris-catalog.properties`](../spark/conf/polaris-catalog.properties); solo cambian los DNS y la gestión de secretos.

## Requisitos
- EMR 7.x (Spark 3.5). Probado en la PoC con Iceberg 1.10.1; el protocolo REST es compatible entre versiones de cliente, pero conviene alinear la versión con la que trae vuestra release de EMR.
- Conectividad de red de EMR hacia Polaris (HTTPS) y Scality (S3 endpoint), p. ej. Direct Connect / VPN.
- TLS en Polaris y Scality en entornos reales (`https://...`).

## Configuración del cluster (clasificaciones)
```json
[
  { "Classification": "iceberg-defaults",
    "Properties": { "iceberg.enabled": "true" } },
  { "Classification": "spark-defaults",
    "Properties": {
      "spark.sql.extensions": "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions",
      "spark.sql.catalog.lake": "org.apache.iceberg.spark.SparkCatalog",
      "spark.sql.catalog.lake.type": "rest",
      "spark.sql.catalog.lake.uri": "https://polaris.midominio.local/api/catalog",
      "spark.sql.catalog.lake.warehouse": "lakehouse",
      "spark.sql.catalog.lake.scope": "PRINCIPAL_ROLE:ALL",
      "spark.sql.catalog.lake.token-refresh-enabled": "true",
      "spark.sql.catalog.lake.io-impl": "org.apache.iceberg.aws.s3.S3FileIO",
      "spark.sql.catalog.lake.s3.endpoint": "https://scality.midominio.local",
      "spark.sql.catalog.lake.s3.path-style-access": "true",
      "spark.sql.catalog.lake.client.region": "us-east-1",

      "spark.hadoop.fs.s3a.bucket.warehouse.endpoint": "https://scality.midominio.local",
      "spark.hadoop.fs.s3a.bucket.warehouse.path.style.access": "true"
    } }
]
```

## Secretos (no ponerlos en las clasificaciones)
- `spark.sql.catalog.lake.credential=<client_id>:<client_secret>`: pásalo por job (`--conf`) leyéndolo de AWS Secrets Manager en el step, o con un bootstrap action que escriba un `spark-defaults` local con permisos restringidos.
- Las claves S3 de Scality: `spark.sql.catalog.lake.s3.access-key-id` / `s3.secret-access-key` (para S3FileIO) y `fs.s3a.bucket.warehouse.access.key` / `secret.key` (para s3a), por el mismo mecanismo.

## Ojo con `s3://` en EMR
En EMR, `s3://` es **EMRFS y apunta a AWS S3**, no a Scality.
- La lectura/escritura de tablas Iceberg va por `S3FileIO` con el endpoint de Scality → sin problema.
- Procedures que usan Hadoop FS sobre rutas de la tabla (`add_files`, `remove_orphan_files`, etc.) necesitan, **solo en ese job**:
  `--conf spark.hadoop.fs.s3.impl=org.apache.hadoop.fs.s3a.S3AFileSystem` (+ el endpoint por bucket de arriba).
  No lo pongas a nivel de cluster si el cluster también usa EMRFS contra AWS S3 (logs, otros buckets).
- Para leer las tablas Hive actuales en Scality usa rutas `s3a://`.

## Prueba rápida
```bash
spark-sql --conf spark.sql.catalog.lake.credential="$POLARIS_CREDENTIAL" \
  -e "SELECT * FROM lake.ventas.pedidos ORDER BY id"
```
