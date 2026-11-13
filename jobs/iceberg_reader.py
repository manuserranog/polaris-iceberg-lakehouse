"""'Segundo motor': otra aplicación Spark independiente que solo conoce el catálogo REST.

Simula a EMR/Databricks leyendo lo que escribió otro motor, sin compartir nada salvo Polaris + S3.
"""
from lakehouse_session import banner, get_spark

spark = get_spark("iceberg-reader")
T = "lake.ventas.pedidos"

banner("Tablas visibles en el namespace ventas")
spark.sql("SHOW TABLES IN lake.ventas").show()

banner("Esquema actual (incluye la columna añadida por el otro motor)")
spark.sql(f"DESCRIBE TABLE {T}").show(20, truncate=False)

banner("Datos y snapshots")
df = spark.table(T)
df.orderBy("id").show(truncate=False)
snapshots = spark.sql(f"SELECT snapshot_id, operation FROM {T}.snapshots").count()
spark.sql(f"SELECT made_current_at, snapshot_id, is_current_ancestor FROM {T}.history").show(truncate=False)

assert "canal" in df.columns, "el lector no ve la evolución de esquema"
assert df.count() == 4, f"se esperaban 4 filas, hay {df.count()}"
banner(f"READER OK: {df.count()} filas, {snapshots} snapshots vistos desde otra aplicación")
spark.stop()
