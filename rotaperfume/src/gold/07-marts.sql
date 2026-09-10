-- Gold: marts por diretoria
--
-- mart_vendas_por_vendedor e mart_produto_performance derivam de
-- gold.fato_vendas - é o que "conformado" significa: os dois têm que somar o
-- mesmo total de receita que o fato. mart_financeiro_recebimento é a exceção
-- consciente: vencimento/recebimento não existe no grão de item de pedido,
-- então lê de silver.pagamentos (nunca da bronze).

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor AS
WITH agregado AS (
  SELECT
    vendedor_id,
    ano,
    mes,
    SUM(receita) AS receita,
    SUM(margem) AS margem,
    COUNT(DISTINCT cliente_id) AS clientes_atendidos,
    SUM(receita) / NULLIF(COUNT(DISTINCT pedido_id), 0) AS ticket_medio
  FROM lakehouse_rotaperfume.gold.fato_vendas
  GROUP BY vendedor_id, ano, mes
)
SELECT
  a.vendedor_id,
  a.ano,
  a.mes,
  a.receita,
  a.margem,
  a.clientes_atendidos,
  a.ticket_medio,
  v.meta_mensal AS meta,
  100 * a.receita / NULLIF(v.meta_mensal, 0) AS atingimento_pct,
  current_timestamp() AS _processado_em
FROM agregado a
LEFT JOIN lakehouse_rotaperfume.silver.vendedores v ON v.vendedor_id = a.vendedor_id;

COMMENT ON TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor IS
  'Grão vendedor x mês, para a diretoria comercial. Deriva de gold.fato_vendas.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor ALTER COLUMN ticket_medio COMMENT 'Receita do mês dividida pelo número de pedidos distintos do vendedor no mês.';
ALTER TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor ALTER COLUMN atingimento_pct COMMENT 'Receita do mês como percentual da meta mensal do vendedor.';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_produto_performance AS
WITH mensal AS (
  SELECT sku, ano, mes,
    SUM(receita) AS receita,
    SUM(margem) AS margem,
    SUM(quantidade) AS quantidade
  FROM lakehouse_rotaperfume.gold.fato_vendas
  GROUP BY sku, ano, mes
),
total_sku AS (
  SELECT sku, SUM(receita) AS receita_total
  FROM lakehouse_rotaperfume.gold.fato_vendas
  GROUP BY sku
),
classificado AS (
  SELECT
    sku,
    CASE
      WHEN SUM(receita_total) OVER (ORDER BY receita_total DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           / SUM(receita_total) OVER () <= 0.8 THEN 'A'
      WHEN SUM(receita_total) OVER (ORDER BY receita_total DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           / SUM(receita_total) OVER () <= 0.95 THEN 'B'
      ELSE 'C'
    END AS curva_abc
  FROM total_sku
)
SELECT
  m.sku,
  m.ano,
  m.mes,
  m.receita,
  m.margem,
  100 * m.margem / NULLIF(m.receita, 0) AS margem_pct,
  m.quantidade,
  c.curva_abc,
  current_timestamp() AS _processado_em
FROM mensal m
JOIN classificado c ON c.sku = m.sku;

COMMENT ON TABLE lakehouse_rotaperfume.gold.mart_produto_performance IS
  'Grão SKU x mês, para a diretoria de produto. Deriva de gold.fato_vendas.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_produto_performance ALTER COLUMN curva_abc COMMENT
  'Classificação ABC por receita acumulada do SKU (todos os meses juntos): A até 80% da receita acumulada, B até 95%, C o restante. Mesma classe em todas as linhas mensais do SKU.';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento AS
SELECT
  year(data_vencimento) AS ano,
  month(data_vencimento) AS mes,
  ROUND(SUM(valor), 2) AS valor_a_receber,
  ROUND(SUM(valor_liquido) FILTER (WHERE status_pagamento IN ('Pago', 'Pago com atraso')), 2) AS recebido,
  ROUND(AVG(datediff(data_pagamento, data_vencimento)) FILTER (WHERE data_pagamento IS NOT NULL), 1) AS atraso_medio_dias,
  ROUND(SUM(valor - valor_liquido), 2) AS custo_taxa,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.pagamentos
GROUP BY year(data_vencimento), month(data_vencimento);

COMMENT ON TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento IS
  'Grão mês de vencimento, para a diretoria financeira. Lê de silver.pagamentos - vencimento e recebimento não existem no grão de item de pedido de gold.fato_vendas.';

ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN valor_a_receber COMMENT 'Soma do valor bruto de todos os pagamentos com vencimento neste mês, pagos ou não.';
ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN recebido COMMENT 'Soma do valor líquido dos pagamentos deste mês já quitados (Pago ou Pago com atraso).';
ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN atraso_medio_dias COMMENT 'Média de dias entre vencimento e pagamento, só entre os pagamentos já quitados.';
ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN custo_taxa COMMENT 'Diferença entre valor bruto e valor líquido - o custo da forma de pagamento (taxa_pct aplicada na origem).';
