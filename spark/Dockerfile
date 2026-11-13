# Spark 3.5 / Scala 2.12: misma línea que EMR 7.x y Databricks DBR 14-16 LTS
ARG SPARK_IMAGE=apache/spark:3.5.9-java17-python3
FROM ${SPARK_IMAGE}

# Iceberg: mantener la MISMA versión de jar en k8s, EMR y Databricks
ARG ICEBERG_VERSION=1.10.1
# hadoop-aws solo hace falta para leer Parquet "legacy" por s3a:// (simulación de migración Hive)
ARG HADOOP_AWS_VERSION=3.3.4
ARG AWS_SDK_V1_VERSION=1.12.262

USER root
RUN set -eux; cd /opt/spark/jars; M=https://repo1.maven.org/maven2; \
    curl -fsSLO $M/org/apache/iceberg/iceberg-spark-runtime-3.5_2.12/${ICEBERG_VERSION}/iceberg-spark-runtime-3.5_2.12-${ICEBERG_VERSION}.jar; \
    curl -fsSLO $M/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar; \
    curl -fsSLO $M/org/apache/hadoop/hadoop-aws/${HADOOP_AWS_VERSION}/hadoop-aws-${HADOOP_AWS_VERSION}.jar; \
    curl -fsSLO $M/com/amazonaws/aws-java-sdk-bundle/${AWS_SDK_V1_VERSION}/aws-java-sdk-bundle-${AWS_SDK_V1_VERSION}.jar

# Nota: el Spark Operator monta su propio ConfigMap en /opt/spark/conf, así que el bloque portable
# se deja aparte y lo carga jobs/lakehouse_session.py al crear la SparkSession.
COPY conf/polaris-catalog.properties /opt/lakehouse/conf/polaris-catalog.properties
USER spark
