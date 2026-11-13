"""Comprueba el control de acceso de Polaris para el principal spark.

Esperado: acceso total dentro de lake.ventas y 403 Forbidden fuera de ese namespace.
"""
from lakehouse_session import banner, get_spark

spark = get_spark("iceberg-access-check")
results = []


def check(desc, sql, should_work):
    try:
        spark.sql(sql).collect()
        ok, detail = should_work, "permitido"
    except Exception as e:  # Polaris responde 403 -> ForbiddenException
        msg = str(e)
        forbidden = "Forbidden" in msg or "not authorized" in msg.lower()
        ok = (not should_work) and forbidden
        detail = "DENEGADO (403)" if forbidden else f"error inesperado: {msg.splitlines()[0][:150]}"
    expected = "permitido" if should_work else "denegado"
    results.append(ok)
    print(f"[{'OK ' if ok else 'FALLO'}] {desc:<55} -> {detail} (esperado: {expected})", flush=True)


banner("Dentro de lake.ventas (debe funcionar)")
check("Leer lake.ventas.pedidos", "SELECT count(*) FROM lake.ventas.pedidos", True)
check("Crear tabla en ventas", "CREATE TABLE IF NOT EXISTS lake.ventas.tmp_acceso (id INT) USING iceberg", True)
check("Escribir en ventas", "INSERT INTO lake.ventas.tmp_acceso VALUES (1)", True)
check("Borrar tabla en ventas", "DROP TABLE IF EXISTS lake.ventas.tmp_acceso PURGE", True)

banner("Fuera de lake.ventas (debe dar 403)")
check("Listar namespaces del catálogo", "SHOW NAMESPACES IN lake", False)
check("Crear namespace lake.finanzas", "CREATE NAMESPACE lake.finanzas", False)

assert all(results), "el control de acceso no se comporta como se esperaba"
banner(f"ACCESS OK: {len(results)} comprobaciones, spark solo opera dentro de lake.ventas")
spark.stop()
