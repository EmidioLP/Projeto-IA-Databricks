-- Os quatro números da tela "A semana": uma linha só, juntando a fila,
-- a última versão do modelo e a contagem de retorno_ligacao.
--
-- gold.fila_semanal é CREATE OR REPLACE (sem coluna de data/versão), então
-- CURRENT_DATE() é o stand-in para "a fila de hoje" - não existe uma
-- referência temporal persistida na própria tabela.
WITH fila AS (
  SELECT
    COUNT(*) AS contatos,
    COUNT(DISTINCT vendedor) AS vendedores,
    ROUND(SUM(score * ticket_medio), 2) AS receita_esperada
  FROM lakehouse_rotaperfume.gold.fila_semanal
),
modelo AS (
  SELECT acertos_top200, lift_top200, taxa_base
  FROM lakehouse_rotaperfume.gold.modelo_metricas
  QUALIFY ROW_NUMBER() OVER (ORDER BY versao DESC) = 1
),
retorno AS (
  SELECT
    COUNT(*) AS ja_trabalhados,
    COUNT(*) FILTER (WHERE status = 'vendeu') AS viraram_pedido
  FROM lakehouse_rotaperfume.gold.retorno_ligacao
)
SELECT
  fila.contatos,
  fila.vendedores,
  fila.receita_esperada,
  CURRENT_DATE() AS referencia,
  modelo.acertos_top200,
  modelo.lift_top200,
  modelo.taxa_base,
  retorno.ja_trabalhados,
  retorno.viraram_pedido
FROM fila
CROSS JOIN modelo
CROSS JOIN retorno;
