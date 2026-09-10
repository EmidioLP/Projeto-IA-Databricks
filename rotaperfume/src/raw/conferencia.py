# Databricks notebook source
# MAGIC %md
# MAGIC # Conferência de chegada - raw
# MAGIC
# MAGIC Confere que os 10 arquivos esperados chegaram ao Volume `bronze.raw`,
# MAGIC registra tamanho e contagem de linhas em `bronze._raw_arquivos`, e
# MAGIC interrompe o job se algum arquivo faltar ou vier vazio. Arquivo que não
# MAGIC chega não dá erro sozinho - dá número menor, com cara de número certo.
# MAGIC Esta tarefa existe para pegar isso antes do dashboard.

# COMMAND ----------

from datetime import datetime, timezone

dbutils.widgets.text("catalog", "lakehouse_rotaperfume")
catalog = dbutils.widgets.get("catalog")

ARQUIVOS_ESPERADOS = {
    "erp": ["produtos", "pedidos", "itens_pedido", "pagamentos", "estoque"],
    "crm": ["clientes", "vendedores", "carteira", "oportunidades", "visitas"],
}

# COMMAND ----------

resultados = []
problemas = []

for sistema, arquivos in ARQUIVOS_ESPERADOS.items():
    for arquivo in arquivos:
        caminho = f"/Volumes/{catalog}/bronze/raw/{sistema}/{arquivo}.csv"

        try:
            info = dbutils.fs.ls(caminho)[0]
        except Exception:
            problemas.append(f"{sistema}/{arquivo}.csv não encontrado em {caminho}")
            continue

        linhas = spark.read.option("header", True).csv(caminho).count()
        if linhas == 0:
            problemas.append(f"{sistema}/{arquivo}.csv chegou vazio (0 linhas de dado)")
            continue

        resultados.append(
            {
                "sistema": sistema,
                "arquivo": f"{arquivo}.csv",
                "bytes": info.size,
                "linhas": linhas,
                "conferido_em": datetime.now(timezone.utc),
            }
        )

# COMMAND ----------

spark.sql(
    f"""
    CREATE TABLE IF NOT EXISTS {catalog}.bronze._raw_arquivos (
        sistema STRING,
        arquivo STRING,
        bytes BIGINT,
        linhas BIGINT,
        conferido_em TIMESTAMP
    )
    COMMENT 'Conferência de chegada do raw: prova que cada arquivo esperado chegou ao Volume, com tamanho e contagem de linhas na última execução.'
    """
)

if resultados:
    schema = "sistema STRING, arquivo STRING, bytes BIGINT, linhas BIGINT, conferido_em TIMESTAMP"
    resultados_df = spark.createDataFrame(resultados, schema=schema)
    resultados_df.write.mode("overwrite").insertInto(f"{catalog}.bronze._raw_arquivos")

# COMMAND ----------

print(f"{'sistema':<8} {'arquivo':<20} {'bytes':>10} {'linhas':>10}")
for r in sorted(resultados, key=lambda r: (r["sistema"], r["arquivo"])):
    print(f"{r['sistema']:<8} {r['arquivo']:<20} {r['bytes']:>10} {r['linhas']:>10}")
print(f"\n{len(resultados)}/{sum(len(v) for v in ARQUIVOS_ESPERADOS.values())} arquivos conferidos")

if problemas:
    raise Exception("Conferência de chegada falhou:\n" + "\n".join(f"- {p}" for p in problemas))
