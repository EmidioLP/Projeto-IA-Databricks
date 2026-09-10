-- Gold: dimensões conformadas (dim_cliente, dim_produto, dim_vendedor, dim_calendario)
--
-- Lê só da silver. dim_cliente usa um crosswalk cliente_id -> cliente_id
-- atual (via silver.clientes.cliente_ids_duplicados) porque pedidos antigos
-- ainda apontam para o cadastro duplicado que a dedup do prompt 3 descartou -
-- sem isso a receita/pedidos desse cliente ficariam divididos em dois ids.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_cliente AS
WITH crosswalk AS (
  SELECT cliente_id AS atual, cliente_id AS origem FROM lakehouse_rotaperfume.silver.clientes
  UNION ALL
  SELECT cliente_id AS atual, explode(cliente_ids_duplicados) AS origem
  FROM lakehouse_rotaperfume.silver.clientes WHERE cliente_ids_duplicados IS NOT NULL
),
pedidos_do_cliente AS (
  SELECT
    cw.atual AS cliente_id,
    COUNT(*) AS total_pedidos,
    MIN(p.data_pedido) AS data_primeiro_pedido,
    MAX(p.data_pedido) AS data_ultimo_pedido,
    SUM(p.valor_liquido) AS receita_acumulada
  FROM lakehouse_rotaperfume.silver.pedidos p
  JOIN crosswalk cw ON cw.origem = p.cliente_id
  GROUP BY cw.atual
)
SELECT
  c.cliente_id,
  c.razao_social,
  c.segmento,
  c.cidade,
  c.uf,
  c.data_cadastro,
  pc.data_primeiro_pedido,
  pc.data_ultimo_pedido,
  coalesce(pc.total_pedidos, 0) AS total_pedidos,
  coalesce(pc.receita_acumulada, 0) AS receita_acumulada,
  datediff(current_date(), pc.data_ultimo_pedido) AS dias_sem_comprar,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.clientes c
LEFT JOIN pedidos_do_cliente pc ON pc.cliente_id = c.cliente_id;

COMMENT ON TABLE lakehouse_rotaperfume.gold.dim_cliente IS
  'Uma linha por cliente. Receita e pedidos consolidam os dois cadastros quando o cliente tinha CNPJ duplicado na origem.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_cliente ALTER COLUMN receita_acumulada COMMENT
  'Soma do valor líquido de todos os pedidos do cliente, incluindo pedidos feitos sob um cadastro duplicado já consolidado aqui.';
ALTER TABLE lakehouse_rotaperfume.gold.dim_cliente ALTER COLUMN dias_sem_comprar COMMENT
  'Dias corridos desde o último pedido até hoje. NULL quando o cliente nunca comprou.';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_produto AS
SELECT
  sku,
  marca,
  categoria,
  nota_olfativa,
  custo_unitario AS custo,
  preco_tabela,
  data_lancamento,
  NOT ativo AS descontinuado,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.produtos;

COMMENT ON TABLE lakehouse_rotaperfume.gold.dim_produto IS 'Uma linha por SKU do catálogo.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_produto ALTER COLUMN descontinuado COMMENT
  'true quando o produto não está mais ativo no catálogo - vendas antigas continuam válidas, só não se compra mais este SKU.';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_vendedor AS
SELECT
  vendedor_id,
  nome,
  regiao,
  meta_mensal,
  data_desligamento IS NULL AS ativo,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.vendedores;

COMMENT ON TABLE lakehouse_rotaperfume.gold.dim_vendedor IS 'Uma linha por vendedor.';

ALTER TABLE lakehouse_rotaperfume.gold.dim_vendedor ALTER COLUMN ativo COMMENT
  'true quando o vendedor não tem data de desligamento registrada.';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_calendario AS
WITH dias AS (
  SELECT explode(sequence(DATE'2024-09-01', DATE'2026-08-31', INTERVAL 1 DAY)) AS data
)
SELECT
  data,
  year(data) AS ano,
  month(data) AS mes,
  CASE month(data)
    WHEN 1 THEN 'Janeiro' WHEN 2 THEN 'Fevereiro' WHEN 3 THEN 'Março'
    WHEN 4 THEN 'Abril' WHEN 5 THEN 'Maio' WHEN 6 THEN 'Junho'
    WHEN 7 THEN 'Julho' WHEN 8 THEN 'Agosto' WHEN 9 THEN 'Setembro'
    WHEN 10 THEN 'Outubro' WHEN 11 THEN 'Novembro' WHEN 12 THEN 'Dezembro'
  END AS nome_mes,
  quarter(data) AS trimestre,
  CASE dayofweek(data)
    WHEN 1 THEN 'Domingo' WHEN 2 THEN 'Segunda-feira' WHEN 3 THEN 'Terça-feira'
    WHEN 4 THEN 'Quarta-feira' WHEN 5 THEN 'Quinta-feira' WHEN 6 THEN 'Sexta-feira'
    WHEN 7 THEN 'Sábado'
  END AS dia_semana,
  month(data) IN (4, 6, 10) AS mes_pico_setor,
  current_timestamp() AS _processado_em
FROM dias;

COMMENT ON TABLE lakehouse_rotaperfume.gold.dim_calendario IS
  'Uma linha por dia, cobrindo os 24 meses de dados do pipeline (2024-09 a 2026-08).';

ALTER TABLE lakehouse_rotaperfume.gold.dim_calendario ALTER COLUMN mes_pico_setor COMMENT
  'true em abril, junho e outubro - os meses de pico de vendas do setor de perfumaria, usados para explicar variação sazonal sem repetir a lista em toda análise.';
