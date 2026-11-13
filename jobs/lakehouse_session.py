"""SparkSession contra el catálogo Polaris con la configuración portable.

En EMR/Databricks no hace falta este helper: el mismo bloque de propiedades va en la
config del cluster. Aquí lo cargamos del fichero de la imagen e inyectamos el secreto.
"""
import os

from pyspark.sql import SparkSession

CONF_FILE = os.environ.get("LAKEHOUSE_CONF", "/opt/lakehouse/conf/polaris-catalog.properties")


def _read_properties(path):
    props = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition(" ")
            props[key] = value.strip()
    return props


def get_spark(app_name):
    builder = SparkSession.builder.appName(app_name)
    for key, value in _read_properties(CONF_FILE).items():
        builder = builder.config(key, value)
    builder = builder.config("spark.sql.catalog.lake.credential", os.environ["POLARIS_CREDENTIAL"])
    spark = builder.getOrCreate()
    spark.sparkContext.setLogLevel("WARN")
    return spark


def banner(msg):
    print(f"\n========== {msg} ==========", flush=True)
