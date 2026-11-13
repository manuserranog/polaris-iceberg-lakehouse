"""Simula la migración de una tabla Hive actual a Iceberg SIN reescribir datos.

1. Escribe Parquet con layout Hive (dt=YYYY-MM-DD/) en s3a:// -> como las tablas actuales en Scality.
2. Crea la tabla Iceberg en Polaris con el mismo esquema y particionado.
3. add_files: registra los Parquet existentes en manifests Iceberg (solo metadatos).
4. Importación incremental de una partición nueva (convivencia con el job legacy).
"""
from pyspark.sql import functions as F

from lakehouse_session import banner, get_spark

spark = get_spark("migrate-hive-parquet")
LEGACY = "s3a://warehouse/legacy/ventas_hive"
T = "lake.ventas.pedidos_migrados"
SOURCE = f"`parquet`.`{LEGACY}`"

def legacy_rows(dt, n):
    return (spark.range(n)
            .withColumn("cliente", F.concat(F.lit("cli_"), (F.col("id") % 7).cast("string")))
            .withColumn("importe", (F.col("id") * 1.5).cast("decimal(12,2)"))
            .withColumn("dt", F.lit(dt)))

banner("1. Datos legacy estilo Hive (dos particiones)")
(legacy_rows("2026-10-14", 1000).unionByName(legacy_rows("2026-10-15", 500))
 .write.mode("overwrite").partitionBy("dt").parquet(LEGACY))
legacy = spark.read.parquet(LEGACY)
legacy.groupBy("dt").count().orderBy("dt").show()

banner("2. Tabla Iceberg destino en Polaris")
spark.sql("CREATE NAMESPACE IF NOT EXISTS lake.ventas")
spark.sql(f"DROP TABLE IF EXISTS {T}")  # sin PURGE: los Parquet legacy no se tocan
spark.sql(f"""
    CREATE TABLE {T} (id BIGINT, cliente STRING, importe DECIMAL(12,2), dt STRING)
    USING iceberg PARTITIONED BY (dt)
""")

banner("3. add_files: carga inicial (solo metadatos, los ficheros se quedan donde están)")
spark.sql(f"CALL lake.system.add_files(table => 'ventas.pedidos_migrados', source_table => '{SOURCE}')").show()

banner("4. El job legacy escribe una partición nueva -> importación incremental")
legacy_rows("2026-10-16", 250).write.mode("append").partitionBy("dt").parquet(LEGACY)
spark.sql(f"""
    CALL lake.system.add_files(
      table => 'ventas.pedidos_migrados', source_table => '{SOURCE}',
      partition_filter => map('dt', '2026-10-16'))
""").show()

banner("Validación: conteos por partición legacy vs Iceberg")
# Spark infiere dt como DATE al descubrir particiones; normalizamos a string
legacy_counts = {str(r.dt): r["count"] for r in spark.read.parquet(LEGACY).groupBy("dt").count().collect()}
ice_counts = {str(r.dt): r["count"] for r in spark.table(T).groupBy("dt").count().collect()}
print("legacy :", dict(sorted(legacy_counts.items())))
print("iceberg:", dict(sorted(ice_counts.items())))
spark.sql(f"SELECT file_path, partition, record_count FROM {T}.files").show(truncate=False)
assert legacy_counts == ice_counts, "los conteos por partición no coinciden"
banner(f"MIGRATE OK: {sum(ice_counts.values())} filas en {len(ice_counts)} particiones, sin reescribir datos")
spark.stop()
