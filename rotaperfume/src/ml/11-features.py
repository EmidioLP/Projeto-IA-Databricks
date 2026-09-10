# Databricks notebook source
# MAGIC %md
# MAGIC # Features de cliente - RFM, ritmo, CRM e mix
# MAGIC
# MAGIC Uma função, `montar_features(referencia)`, devolve uma linha por cliente com
# MAGIC tudo que se sabia dele ATÉ a data de corte `referencia`. Cada fonte é
# MAGIC filtrada pela própria data na primeira linha da leitura (`< referencia`, sem
# MAGIC exceção) - é assinatura de função, não disciplina pessoal.
# MAGIC
# MAGIC `gold.dim_cliente` nunca é lida aqui: `dias_sem_comprar`, `receita_acumulada`
# MAGIC e `total_pedidos` agregam a base inteira sem corte - usar qualquer uma seria
# MAGIC vazamento de dado do futuro para o treino.
# MAGIC
# MAGIC A mesma função gera `gold.features_treino` (com o rótulo `comprou_em_7d`) e
# MAGIC `gold.features_cliente` (sem rótulo, é o que será pontuado) - é o que evita
# MAGIC o desencontro entre o dado de treino e o de produção (training/serving skew).

# COMMAND ----------

from pyspark.sql import functions as F
from pyspark.sql.window import Window

dbutils.widgets.text("catalog", "lakehouse_rotaperfume")
catalog = dbutils.widgets.get("catalog")

# COMMAND ----------


def montar_features(referencia):
    """Uma linha por cliente com o que se sabia dele até `referencia` (string 'YYYY-MM-DD')."""
    ref = F.to_date(F.lit(referencia))

    fato_pre = spark.table(f"{catalog}.gold.fato_vendas").filter(F.col("data_pedido") < ref)
    oport_pre = spark.table(f"{catalog}.silver.oportunidades").filter(F.col("data_abertura") < ref)
    visitas_pre = spark.table(f"{catalog}.silver.visitas").filter(F.col("data_visita") < ref)

    base = fato_pre.select("cliente_id").distinct()

    # ---- RFM ----
    rfm = (
        fato_pre.groupBy("cliente_id")
        .agg(
            F.max("data_pedido").alias("_ultimo_pedido"),
            F.countDistinct("pedido_id").alias("frequencia_pedidos"),
            F.sum("receita").alias("valor_total"),
            F.sum("margem").alias("margem_total"),
        )
        .withColumn("recencia_dias", F.datediff(ref, F.col("_ultimo_pedido")))
        .withColumn("ticket_medio", F.col("valor_total") / F.col("frequencia_pedidos"))
        .withColumn(
            "margem_percentual",
            F.when(F.col("valor_total") != 0, F.col("margem_total") / F.col("valor_total")).otherwise(F.lit(None)),
        )
        .drop("_ultimo_pedido")
    )

    # ---- Ritmo: gaps entre pedidos calculados uma única vez ----
    datas_distintas = fato_pre.select("cliente_id", "data_pedido").distinct()
    janela_datas = Window.partitionBy("cliente_id").orderBy("data_pedido")
    gaps = datas_distintas.withColumn(
        "gap_dias", F.datediff(F.col("data_pedido"), F.lag("data_pedido").over(janela_datas))
    )
    ritmo = gaps.groupBy("cliente_id").agg(
        F.mean("gap_dias").alias("intervalo_medio_dias"),
        F.stddev("gap_dias").alias("desvio_intervalo_dias"),
    )

    pedidos_90d = (
        fato_pre.filter(F.col("data_pedido") >= F.date_sub(ref, 90))
        .groupBy("cliente_id")
        .agg(F.countDistinct("pedido_id").alias("pedidos_ultimos_90d"))
    )

    # ---- CRM ----
    crm_oportunidades = (
        oport_pre.groupBy("cliente_id")
        .agg(
            F.sum(F.when(~F.col("ganha") & ~F.col("perdida"), 1).otherwise(0)).alias("oportunidades_abertas"),
            F.sum(F.when(F.col("ganha"), 1).otherwise(0)).alias("oportunidades_ganhas"),
            F.count(F.lit(1)).alias("_total_oportunidades"),
        )
        .withColumn(
            "taxa_ganho",
            F.when(
                F.col("_total_oportunidades") > 0, F.col("oportunidades_ganhas") / F.col("_total_oportunidades")
            ).otherwise(F.lit(None)),
        )
        .drop("_total_oportunidades")
    )

    visitas_90d = (
        visitas_pre.filter(F.col("data_visita") >= F.date_sub(ref, 90))
        .groupBy("cliente_id")
        .agg(F.countDistinct("visita_id").alias("visitas_90d"))
    )

    # silver.visitas não tem coluna gerou_pedido - o equivalente é
    # resultado = 'Pedido realizado', calculado aqui em vez de alterar a silver.
    conversao_visita = (
        visitas_pre.groupBy("cliente_id")
        .agg(
            F.count(F.when(F.col("resultado") == "Pedido realizado", 1)).alias("_visitas_com_pedido"),
            F.count(F.lit(1)).alias("_visitas_total"),
        )
        .withColumn(
            "conversao_visita",
            F.when(F.col("_visitas_total") > 0, F.col("_visitas_com_pedido") / F.col("_visitas_total")).otherwise(
                F.lit(None)
            ),
        )
        .select("cliente_id", "conversao_visita")
    )

    # ---- Mix ----
    mix = fato_pre.groupBy("cliente_id").agg(
        F.countDistinct("sku").alias("skus_distintos"),
        F.countDistinct("categoria").alias("categorias_distintas"),
        F.countDistinct("marca").alias("marcas_distintas"),
    )

    receita_por_marca = fato_pre.groupBy("cliente_id", "marca").agg(F.sum("receita").alias("_receita_marca"))
    top_marca = receita_por_marca.groupBy("cliente_id").agg(F.max("_receita_marca").alias("_receita_marca_top"))
    concentracao_marca = (
        top_marca.join(rfm.select("cliente_id", "valor_total"), "cliente_id")
        .withColumn(
            "concentracao_marca_top",
            F.when(F.col("valor_total") != 0, F.col("_receita_marca_top") / F.col("valor_total")).otherwise(
                F.lit(None)
            ),
        )
        .select("cliente_id", "concentracao_marca_top")
    )

    # comprou_lancamento é o único join da função.
    lancamentos_recentes = (
        spark.table(f"{catalog}.gold.dim_produto")
        .filter(
            F.col("data_lancamento").isNotNull()
            & (F.col("data_lancamento") >= F.date_sub(ref, 120))
            & (F.col("data_lancamento") < ref)
        )
        .select("sku")
        .distinct()
    )
    comprou_lancamento = (
        fato_pre.join(lancamentos_recentes, "sku")
        .select("cliente_id")
        .distinct()
        .withColumn("comprou_lancamento", F.lit(1))
    )

    # ---- monta tudo em cima da base (clientes com pedido antes do corte) ----
    df = (
        base.join(rfm, "cliente_id", "left")
        .join(ritmo, "cliente_id", "left")
        .join(pedidos_90d, "cliente_id", "left")
        .join(crm_oportunidades, "cliente_id", "left")
        .join(visitas_90d, "cliente_id", "left")
        .join(conversao_visita, "cliente_id", "left")
        .join(mix, "cliente_id", "left")
        .join(concentracao_marca, "cliente_id", "left")
        .join(comprou_lancamento, "cliente_id", "left")
    )

    # cliente sem oportunidade/visita/mix/lançamento fica com 0, nunca NULL.
    # RFM e ritmo nunca entram aqui - ritmo pode ficar NULL de propósito, para
    # cliente com um pedido só (sem gap entre pedidos para calcular).
    colunas_zero = [
        "oportunidades_abertas",
        "oportunidades_ganhas",
        "taxa_ganho",
        "visitas_90d",
        "conversao_visita",
        "pedidos_ultimos_90d",
        "skus_distintos",
        "categorias_distintas",
        "marcas_distintas",
        "comprou_lancamento",
    ]
    for coluna in colunas_zero:
        df = df.withColumn(coluna, F.coalesce(F.col(coluna), F.lit(0)))

    # F.least() ignora nulo e devolve o outro valor: sem o when() em volta, os
    # clientes de um pedido só (intervalo_medio_dias NULL) iriam para o topo
    # da fila com atraso_relativo = 10.
    df = df.withColumn(
        "atraso_relativo",
        F.when(
            F.col("intervalo_medio_dias").isNotNull() & (F.col("intervalo_medio_dias") > 0),
            F.least(F.col("recencia_dias") / F.col("intervalo_medio_dias"), F.lit(10.0)),
        ).otherwise(F.lit(None).cast("double")),
    )

    return df.withColumn("_referencia", ref)


def cast_decimais_para_double(df):
    """Converte toda coluna DECIMAL para double - o registro do modelo quebra depois
    com "Object of type Decimal is not JSON serializable" se alguma escapar."""
    for campo in df.schema.fields:
        if str(campo.dataType).startswith("DecimalType"):
            df = df.withColumn(campo.name, F.col(campo.name).cast("double"))
    return df


# COMMAND ----------

REFERENCIA_TREINO = "2026-08-01"

features_treino = montar_features(REFERENCIA_TREINO)

# janela para a FRENTE de propósito - isto constrói o rótulo, não uma feature.
# 7 dias corridos, dos dois lados inclusive: 2026-08-01 até 2026-08-07.
pedidos_futuro = (
    spark.table(f"{catalog}.gold.fato_vendas")
    .filter(F.col("data_pedido").between(F.lit(REFERENCIA_TREINO), F.date_add(F.lit(REFERENCIA_TREINO), 6)))
    .select("cliente_id")
    .distinct()
    .withColumn("comprou_em_7d", F.lit(1))
)

df_treino = features_treino.join(pedidos_futuro, "cliente_id", "left").withColumn(
    "comprou_em_7d", F.coalesce(F.col("comprou_em_7d"), F.lit(0)).cast("int")
)
df_treino = cast_decimais_para_double(df_treino)

df_treino.write.format("delta").mode("overwrite").saveAsTable(f"{catalog}.gold.features_treino")
spark.sql(
    f"""
    COMMENT ON TABLE {catalog}.gold.features_treino IS
    'Uma linha por cliente com pedido antes de 2026-08-01: 20 features de RFM, ritmo, CRM e mix, mais o rótulo comprou_em_7d (1 se o cliente fez pedido entre 2026-08-01 e 2026-08-07). Usada para treinar o modelo, nunca para pontuação.'
    """
)

# COMMAND ----------

REFERENCIA_CLIENTE = "2026-08-31"

features_cliente = montar_features(REFERENCIA_CLIENTE)
df_cliente = cast_decimais_para_double(features_cliente)

df_cliente.write.format("delta").mode("overwrite").saveAsTable(f"{catalog}.gold.features_cliente")
spark.sql(
    f"""
    COMMENT ON TABLE {catalog}.gold.features_cliente IS
    'Uma linha por cliente com pedido antes de 2026-08-31: as mesmas 20 features de gold.features_treino, sem rótulo. Base pontuada pelo modelo treinado em features_treino.'
    """
)

# COMMAND ----------

n_treino = spark.table(f"{catalog}.gold.features_treino").count()
n_cliente = spark.table(f"{catalog}.gold.features_cliente").count()
taxa_base_pct = spark.table(f"{catalog}.gold.features_treino").agg(F.avg("comprou_em_7d")).first()[0] * 100
recencia_negativa = (
    spark.table(f"{catalog}.gold.features_treino").filter(F.col("recencia_dias") < 0).count()
    + spark.table(f"{catalog}.gold.features_cliente").filter(F.col("recencia_dias") < 0).count()
)

print(f"features_treino:  {n_treino} clientes, taxa_base_pct={taxa_base_pct:.2f}%")
print(f"features_cliente: {n_cliente} clientes")

problemas = []
if n_treino == 0 or n_cliente == 0:
    problemas.append("uma das tabelas de features saiu vazia")
if not (0 <= taxa_base_pct <= 100):
    problemas.append(f"taxa_base_pct fora do intervalo [0, 100]: {taxa_base_pct}")
if recencia_negativa > 0:
    problemas.append(f"{recencia_negativa} linhas com recencia_dias negativa - alguma fonte vazou dado do futuro")

if problemas:
    raise Exception("Geração de features com problema:\n" + "\n".join(f"- {p}" for p in problemas))
