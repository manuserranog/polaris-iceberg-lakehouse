"""Smoke test Iceberg + Polaris: DDL, escrituras, MERGE, evolución de esquema, time travel y rollback."""
from lakehouse_session import banner, get_spark

spark = get_spark("iceberg-smoke")
T = "lake.ventas.pedidos"

banner("Namespace y tabla (particionado oculto por days(ts))")
spark.sql("CREATE NAMESPACE IF NOT EXISTS lake.ventas")
spark.sql(f"DROP TABLE IF EXISTS {T} PURGE")
spark.sql(f"""
    CREATE TABLE {T} (
        id BIGINT, cliente STRING, importe DECIMAL(12,2), ts TIMESTAMP)
    USING iceberg
    PARTITIONED BY (days(ts))
    TBLPROPERTIES ('format-version'='2', 'write.merge.mode'='merge-on-read')
""")

banner("INSERT inicial")
spark.sql(f"""
    INSERT INTO {T} VALUES
      (1, 'acme',    100.00, TIMESTAMP '2026-10-14 10:00:00'),
      (2, 'globex',  250.50, TIMESTAMP '2026-10-14 12:30:00'),
      (3, 'initech',  75.25, TIMESTAMP '2026-10-15 09:15:00')
""")
first_snapshot = spark.sql(f"SELECT snapshot_id FROM {T}.snapshots ORDER BY committed_at").first()[0]

banner("MERGE (upsert)")
spark.sql("""
    CREATE OR REPLACE TEMP VIEW cambios AS SELECT * FROM VALUES
      (2L, 'globex', CAST(300.00 AS DECIMAL(12,2)), TIMESTAMP '2026-10-14 12:30:00'),
      (4L, 'umbrella', CAST(990.00 AS DECIMAL(12,2)), TIMESTAMP '2026-10-16 08:00:00')
      AS t(id, cliente, importe, ts)
""")
spark.sql(f"""
    MERGE INTO {T} t USING cambios s ON t.id = s.id
    WHEN MATCHED THEN UPDATE SET importe = s.importe
    WHEN NOT MATCHED THEN INSERT *
""")
spark.sql(f"DELETE FROM {T} WHERE id = 3")

banner("Evolución de esquema (sin reescribir datos)")
spark.sql(f"ALTER TABLE {T} ADD COLUMN canal STRING AFTER cliente")
spark.sql(f"INSERT INTO {T} VALUES (5, 'hooli', 'web', 42.00, TIMESTAMP '2026-10-16 11:00:00')")
spark.table(T).orderBy("id").show(truncate=False)

banner("Snapshots / historial")
spark.sql(f"SELECT committed_at, snapshot_id, operation FROM {T}.snapshots ORDER BY committed_at").show(truncate=False)
spark.sql(f"SELECT partition, record_count, file_count FROM {T}.partitions").show(truncate=False)

banner("Time travel al primer snapshot")
old = spark.sql(f"SELECT * FROM {T} VERSION AS OF {first_snapshot}")
old.orderBy("id").show(truncate=False)
assert old.count() == 3, "el primer snapshot debía tener 3 filas"

banner("Rollback de una carga errónea")
before = spark.table(T).count()
good_snapshot = spark.sql(f"SELECT snapshot_id FROM {T}.snapshots ORDER BY committed_at DESC").first()[0]
spark.sql(f"INSERT INTO {T} SELECT id + 1000, cliente, canal, importe, ts FROM {T}")  # carga "mala"
assert spark.table(T).count() == before * 2
spark.sql(f"CALL lake.system.rollback_to_snapshot('ventas.pedidos', {good_snapshot})")
assert spark.table(T).count() == before, "el rollback debía dejar la tabla como antes"

final = {r.id: float(r.importe) for r in spark.table(T).collect()}
assert final == {1: 100.0, 2: 300.0, 4: 990.0, 5: 42.0}, final
banner(f"SMOKE OK: {len(final)} filas, MERGE/DELETE/ALTER/time travel/rollback verificados")
spark.stop()
