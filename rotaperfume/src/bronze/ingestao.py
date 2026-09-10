# Databricks notebook source
# MAGIC %md
# MAGIC # Ingestão bronze
# MAGIC
# MAGIC Lê os 10 CSVs do Volume `bronze.raw` e grava cada um como tabela Delta em
# MAGIC `bronze`, sem nenhuma limpeza ou conversão de tipo - tudo entra como
# MAGIC `STRING`. A bronze existe para preservar a sujeira da origem exatamente
# MAGIC como ela chegou; decidir o que fazer com ela é trabalho da silver.

# COMMAND ----------

from pyspark.sql.functions import current_timestamp, lit

dbutils.widgets.text("catalog", "lakehouse_rotaperfume")
catalog = dbutils.widgets.get("catalog")

TABELAS = {
    "erp": ["produtos", "pedidos", "itens_pedido", "pagamentos", "estoque"],
    "crm": ["clientes", "vendedores", "carteira", "oportunidades", "visitas"],
}

# COMMAND ----------


def ingerir_tabela(catalog, sistema, tabela):
    """Lê um CSV do raw como texto puro e grava como tabela Delta na bronze."""
    caminho = f"/Volumes/{catalog}/bronze/raw/{sistema}/{tabela}.csv"

    # inferColumnTypes => false: converter tipo é trabalho da silver, feito
    # sabendo o que se faz. read_files cria uma coluna _rescued_data sozinho -
    # descartamos explicitamente em vez de tentar desligar via rescuedDataColumn
    # (isso quebra o CREATE TABLE com uma coluna de nome vazio).
    df = spark.sql(
        f"""
        SELECT * EXCEPT (_rescued_data)
        FROM read_files('{caminho}', format => 'csv', header => true, inferColumnTypes => false)
        """
    )
    df = df.withColumn("_ingerido_em", current_timestamp()).withColumn(
        "_arquivo_origem", lit(f"{tabela}.csv")
    )

    destino = f"{catalog}.bronze.{tabela}"
    df.write.format("delta").mode("overwrite").option("overwriteSchema", "true").saveAsTable(destino)
    spark.sql(
        f"COMMENT ON TABLE {destino} IS "
        f"'Bronze - {tabela}, ingerida sem transformação do sistema {sistema}.'"
    )
    return df.count()


resultados = []
for sistema, tabelas in TABELAS.items():
    for tabela in tabelas:
        linhas = ingerir_tabela(catalog, sistema, tabela)
        resultados.append({"sistema": sistema, "tabela": tabela, "linhas": linhas})

# COMMAND ----------

linhas_no_arquivo = {
    row["arquivo"]: row["linhas"]
    for row in spark.table(f"{catalog}.bronze._raw_arquivos").collect()
}

problemas = []
print(f"{'sistema':<8} {'tabela':<16} {'na_tabela':>10} {'no_arquivo':>10}")
for r in resultados:
    esperado = linhas_no_arquivo.get(f"{r['tabela']}.csv")
    print(f"{r['sistema']:<8} {r['tabela']:<16} {r['linhas']:>10} {esperado if esperado is not None else '?':>10}")
    if esperado is None:
        problemas.append(f"{r['tabela']}: não achei {r['tabela']}.csv em bronze._raw_arquivos")
    elif esperado != r["linhas"]:
        problemas.append(f"{r['tabela']}: {r['linhas']} linhas na tabela, {esperado} no arquivo")

print(f"\n{len(resultados)}/{sum(len(v) for v in TABELAS.values())} tabelas ingeridas")

if problemas:
    raise Exception("Ingestão bronze com contagem divergente:\n" + "\n".join(f"- {p}" for p in problemas))
