# Databricks notebook source
# MAGIC %md
# MAGIC # Modelo de propensão de compra em 7 dias
# MAGIC
# MAGIC Treina em `gold.features_treino`, mede contra três baselines de regra
# MAGIC simples e contra a moeda (0,5), registra o modelo no Unity Catalog com
# MAGIC MLflow (alias `@prod`) e pontua `gold.features_cliente` em
# MAGIC `gold.score_propensao`. As métricas também viram tabela
# MAGIC (`gold.modelo_metricas`, `gold.calibragem_holdout`) porque o Genie não lê
# MAGIC MLflow e ninguém reabre a UI de experimento daqui a seis meses.
# MAGIC
# MAGIC Os três testes da célula de gate rodam ANTES do registro no UC: um run
# MAGIC reprovado fica logado no experimento (dá para inspecionar), mas nunca
# MAGIC chega a mover o alias `@prod`.

# COMMAND ----------

import mlflow
import mlflow.sklearn
from databricks.sdk import WorkspaceClient
from mlflow.models import infer_signature
from mlflow.tracking import MlflowClient
from pyspark.sql import functions as F
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.inspection import permutation_importance
from sklearn.metrics import roc_auc_score
from sklearn.model_selection import StratifiedKFold, cross_val_predict, train_test_split

dbutils.widgets.text("catalog", "lakehouse_rotaperfume")
catalog = dbutils.widgets.get("catalog")

NOME_MODELO_UC = f"{catalog}.gold.propensao_compra"

# COMMAND ----------
# MAGIC %md
# MAGIC ## 1. Baseline - antes de treinar qualquer coisa

# COMMAND ----------

df = spark.table(f"{catalog}.gold.features_treino").toPandas()
colunas_features = [c for c in df.columns if c not in ("cliente_id", "_referencia", "comprou_em_7d")]

treino, holdout = train_test_split(
    df, test_size=0.25, random_state=42, stratify=df["comprou_em_7d"]
)  # o mesmo split serve de holdout para o baseline E para avaliar o modelo treinado a seguir

auc_recencia = roc_auc_score(holdout["comprou_em_7d"], -holdout["recencia_dias"])
auc_valor_total = roc_auc_score(holdout["comprou_em_7d"], holdout["valor_total"])

# atraso_relativo é NULL para cliente de um pedido só (sem ritmo para calcular).
# roc_auc_score não aceita NaN em y_score - em vez de inventar um valor de
# preenchimento (que enviesaria o ranking para cima ou para baixo), este
# baseline usa só o subconjunto do holdout onde a feature existe.
holdout_com_atraso = holdout.dropna(subset=["atraso_relativo"])
auc_atraso_relativo = roc_auc_score(holdout_com_atraso["comprou_em_7d"], holdout_com_atraso["atraso_relativo"])

print("baseline                              auc")
print(f"moeda (referência)                    0.5000")
print(f"ligar para quem comprou recentemente  {auc_recencia:.4f}")
print(f"ligar para quem compra mais            {auc_valor_total:.4f}")
print(f"ligar para quem está mais atrasado     {auc_atraso_relativo:.4f}  (n={len(holdout_com_atraso)}/{len(holdout)})")

melhor_baseline_auc = max(auc_recencia, auc_valor_total, auc_atraso_relativo)
print(f"\nmelhor baseline: {melhor_baseline_auc:.4f} - é a régua do gate 1")

# COMMAND ----------
# MAGIC %md
# MAGIC ## 2. Treino
# MAGIC
# MAGIC `HistGradientBoostingClassifier`: trata NaN nativamente via splits que
# MAGIC aprendem para qual lado mandar o valor ausente - os NULLs de ritmo são
# MAGIC sinal ("só pediu uma vez"), não defeito, e não são imputados em lugar
# MAGIC nenhum. NUNCA XGBoost aqui: ele treina e loga no MLflow sem problema, mas
# MAGIC falha ao carregar de volta no serverless por conflito de
# MAGIC `__sklearn_tags__` com o scikit-learn 1.6.1 deste ambiente - e o erro só
# MAGIC aparece depois, na etapa de SCORE, com cara de problema totalmente
# MAGIC diferente.

# COMMAND ----------

X_treino, y_treino = treino[colunas_features], treino["comprou_em_7d"]
X_holdout, y_holdout = holdout[colunas_features], holdout["comprou_em_7d"]

modelo_holdout = HistGradientBoostingClassifier(random_state=42).fit(X_treino, y_treino)

# COMMAND ----------
# MAGIC %md
# MAGIC ## 3. As duas métricas

# COMMAND ----------

auc = roc_auc_score(y_holdout, modelo_holdout.predict_proba(X_holdout)[:, 1])

# lift_top200 NÃO usa modelo_holdout: a fila real é "200 de ~2.800" clientes, e
# um holdout de ~700 já deixaria os 200 primeiros como 28% da amostra,
# inflando o lift de forma otimista. Em vez disso, pontua TODOS os clientes de
# features_treino por validação cruzada out-of-fold - o estimador usado aqui é
# só um molde: cross_val_predict clona e treina um por fold, e nenhum deles é
# guardado, logado ou registrado.
X_completo, y_completo = df[colunas_features], df["comprou_em_7d"]
dobras = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
scores_oof = cross_val_predict(
    HistGradientBoostingClassifier(random_state=42), X_completo, y_completo, cv=dobras, method="predict_proba"
)[:, 1]

ranking_oof = df[["cliente_id", "comprou_em_7d"]].copy()
ranking_oof["score_oof"] = scores_oof
top200 = ranking_oof.sort_values("score_oof", ascending=False).head(200)

taxa_base = float(df["comprou_em_7d"].mean())
acertos_top200 = int(top200["comprou_em_7d"].sum())
lift_top200 = (acertos_top200 / 200) / taxa_base

print(f"auc (holdout):          {auc:.4f}")
print(f"taxa_base:              {taxa_base * 100:.2f}%")
print(f"acertos_top200:         {acertos_top200}/200")
print(f"lift_top200:            {lift_top200:.2f}x")

# COMMAND ----------
# MAGIC %md
# MAGIC ## 4. Importância por permutação (no holdout)

# COMMAND ----------

# scoring="roc_auc" para ranquear as features pelo que de fato importa aqui
# (separar quem compra de quem não compra), não pela acurácia padrão.
importancia = permutation_importance(
    modelo_holdout, X_holdout, y_holdout, n_repeats=5, random_state=42, scoring="roc_auc"
)
ranking_importancia = sorted(zip(colunas_features, importancia.importances_mean), key=lambda t: -t[1])
feature_top1 = ranking_importancia[0][0]

print("top 10 features por importância de permutação:")
for nome, valor in ranking_importancia[:10]:
    print(f"  {nome:<25} {valor:.4f}")

# COMMAND ----------
# MAGIC %md
# MAGIC ## 5. MLflow - loga o run sempre, registra no UC só se os gates passarem

# COMMAND ----------

w = WorkspaceClient()
usuario = w.current_user.me().user_name

pasta_experimentos = f"/Users/{usuario}/rotaperfume"
caminho_experimento = f"{pasta_experimentos}/propensao_compra"

# Sem criar a pasta pai antes, mlflow.set_experiment falha com
# "BAD_REQUEST: For input string: 'None'" - mensagem que não menciona pasta
# nenhuma.
w.workspace.mkdirs(pasta_experimentos)

mlflow.set_registry_uri("databricks-uc")  # antes de logar, senão o modelo cai no registry legado do workspace
mlflow.set_experiment(caminho_experimento)

with mlflow.start_run(run_name="propensao_compra") as run:
    mlflow.log_param("modelo", "HistGradientBoostingClassifier")
    mlflow.log_param("random_state", 42)
    mlflow.log_metric("auc", auc)
    mlflow.log_metric("lift_top200", lift_top200)
    mlflow.log_metric("acertos_top200", acertos_top200)
    mlflow.log_metric("taxa_base", taxa_base)
    # o Unity Catalog exige assinatura (schema de entrada/saída) para
    # registrar um modelo - sem isso o register_model do gate 6 quebra com
    # "Model passed for registration did not contain any signature metadata".
    assinatura = infer_signature(X_treino, modelo_holdout.predict_proba(X_treino))
    # artifact_path, NUNCA name=: name= é sintaxe do MLflow 3, e este ambiente
    # serverless roda MLflow 2.22.
    mlflow.sklearn.log_model(
        sk_model=modelo_holdout, artifact_path="modelo", signature=assinatura, input_example=X_treino.head(5)
    )
    run_id = run.info.run_id

# COMMAND ----------
# MAGIC %md
# MAGIC ## 6. Os três gates - só depois deles o modelo vira @prod

# COMMAND ----------

assert auc - melhor_baseline_auc >= 0.05, (
    f"Gate 1 falhou: auc={auc:.4f} não supera o melhor baseline ({melhor_baseline_auc:.4f}) em pelo menos 0.05"
)
assert auc < 0.99, f"Gate 2 falhou: auc={auc:.4f} >= 0.99 - bom demais é vazamento de dado, não competência"
assert lift_top200 >= 2.5, f"Gate 3 falhou: lift_top200={lift_top200:.2f} abaixo do mínimo 2.5"

versao_registrada = mlflow.register_model(model_uri=f"runs:/{run_id}/modelo", name=NOME_MODELO_UC)
versao = int(versao_registrada.version)
MlflowClient().set_registered_model_alias(name=NOME_MODELO_UC, alias="prod", version=versao)
print(f"{NOME_MODELO_UC} versão {versao} registrada e apontada em @prod")

# COMMAND ----------
# MAGIC %md
# MAGIC ## 7. Score - pontua gold.features_cliente


# COMMAND ----------


def adicionar_faixa(sdf, coluna_score):
    """NTILE(4) sobre coluna_score: 1=Fria (menor score) ... 4=Muito quente (maior score)."""
    sdf.createOrReplaceTempView("_tmp_faixa")
    return spark.sql(f"""
        SELECT *,
          CASE NTILE(4) OVER (ORDER BY {coluna_score})
            WHEN 1 THEN 'Fria' WHEN 2 THEN 'Morna'
            WHEN 3 THEN 'Quente' WHEN 4 THEN 'Muito quente'
          END AS faixa
        FROM _tmp_faixa
    """)


# mlflow.pyfunc.load_model().predict() devolveria a classe (0/1), não a
# probabilidade - carregar como sklearn nativo e usar predict_proba.
# mlflow.pyfunc.spark_udf não roda neste serverless (InvalidVersion:
# '18.x-aarch64-photon-scala2') - features_cliente tem só 2.816 linhas, cabe
# fácil em pandas.
modelo_prod = mlflow.sklearn.load_model(f"models:/{NOME_MODELO_UC}@prod")

df_cliente = spark.table(f"{catalog}.gold.features_cliente").toPandas()

# lê as colunas do próprio modelo, nunca da ordem da tabela - defensivo contra
# uma mudança futura em features_cliente reordenar colunas silenciosamente.
colunas_modelo = list(modelo_prod.feature_names_in_)
scores_cliente = modelo_prod.predict_proba(df_cliente[colunas_modelo])[:, 1]

pdf_score = df_cliente[["cliente_id", "_referencia"]].copy()
pdf_score["score"] = scores_cliente
pdf_score["versao"] = versao

sdf_score = (
    spark.createDataFrame(pdf_score)
    .withColumn("cliente_id", F.col("cliente_id").cast("int"))
    .withColumn("score", F.col("score").cast("double"))
    .withColumn("versao", F.col("versao").cast("int"))
)
sdf_score = adicionar_faixa(sdf_score, "score")

sdf_score.write.format("delta").mode("overwrite").saveAsTable(f"{catalog}.gold.score_propensao")
spark.sql(
    f"""
    COMMENT ON TABLE {catalog}.gold.score_propensao IS
    'Uma linha por cliente de gold.features_cliente (corte 2026-08-31) com o score de propensão de compra em 7 dias (0 a 1), a faixa (NTILE(4): Fria/Morna/Quente/Muito quente) e a versão do modelo (@prod no UC) que gerou o score.'
    """
)

# COMMAND ----------
# MAGIC %md
# MAGIC ## 8. Métricas viram tabela - o Genie não lê MLflow

# COMMAND ----------

linha_metricas = spark.createDataFrame(
    [
        {
            # spark.createDataFrame não infere schema de numpy.float64/int64 -
            # cast explícito para tipo Python nativo em cada valor vindo do
            # sklearn.
            "versao": int(versao),
            "auc": float(auc),
            "lift_top200": float(lift_top200),
            "acertos_top200": int(acertos_top200),
            "taxa_base": float(taxa_base),
            "auc_baseline_recencia": float(auc_recencia),
            "auc_baseline_valor_total": float(auc_valor_total),
            "auc_baseline_atraso_relativo": float(auc_atraso_relativo),
            "feature_top1": str(feature_top1),
        }
    ]
).withColumn("_treinado_em", F.current_timestamp())

# append, não overwrite: uma linha por treino - é histórico, sobrescrever
# apagaria o próprio propósito da tabela.
linha_metricas.write.format("delta").mode("append").saveAsTable(f"{catalog}.gold.modelo_metricas")
spark.sql(
    f"""
    COMMENT ON TABLE {catalog}.gold.modelo_metricas IS
    'Uma linha por treino do modelo de propensão: versão registrada no UC, auc e lift_top200 no holdout, o auc de cada baseline de regra simples, a feature nº 1 por importância de permutação e quando foi treinado. Histórico - nunca sobrescrita.'
    """
)

# COMMAND ----------

scores_holdout = modelo_holdout.predict_proba(X_holdout)[:, 1]
pdf_calibragem = holdout[["cliente_id", "comprou_em_7d"]].copy()
pdf_calibragem["score"] = scores_holdout

sdf_calibragem = adicionar_faixa(spark.createDataFrame(pdf_calibragem), "score")
calibragem = sdf_calibragem.groupBy("faixa").agg(
    F.count(F.lit(1)).alias("clientes"),
    F.sum("comprou_em_7d").alias("compraram"),
    F.avg("score").alias("score_medio"),
).withColumn("taxa_de_compra", F.col("compraram") / F.col("clientes"))

# overwrite: sempre a calibração do modelo @prod atual no holdout, não é
# histórico (ao contrário de modelo_metricas).
calibragem.write.format("delta").mode("overwrite").saveAsTable(f"{catalog}.gold.calibragem_holdout")
spark.sql(
    f"""
    COMMENT ON TABLE {catalog}.gold.calibragem_holdout IS
    'Taxa de compra real por faixa de score (Fria/Morna/Quente/Muito quente), calculada no holdout do modelo atual - a prova de que o score ordena a fila, sem precisar saber o que é AUC.'
    """
)

# COMMAND ----------

print(f"modelo {NOME_MODELO_UC}@prod, versão {versao}")
print(f"auc={auc:.4f}  lift_top200={lift_top200:.2f}x  acertos_top200={acertos_top200}/200")
print(f"gold.score_propensao: {sdf_score.count()} linhas")
print(f"gold.calibragem_holdout: {calibragem.count()} faixas")
