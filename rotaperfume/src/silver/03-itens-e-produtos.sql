-- Silver: produtos e itens_pedido
--
-- produtos é criada primeiro porque itens_pedido faz join com ela para
-- marcar sku_descontinuado. quantidade negativa em itens_pedido é DEVOLUÇÃO,
-- não erro - a linha fica, com devolucao=true e quantidade_abs positivo.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.produtos AS
SELECT
  sku,
  descricao,
  categoria,
  marca,
  nota_olfativa,
  try_cast(preco_tabela AS DECIMAL(18, 2)) AS preco_tabela,
  try_cast(custo_unitario AS DECIMAL(18, 2)) AS custo_unitario,
  unidade,
  ativo = 'S' AS ativo,
  coalesce(try_to_date(data_lancamento), try_to_date(data_lancamento, 'dd/MM/yyyy')) AS data_lancamento,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.produtos) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.produtos;

COMMENT ON TABLE lakehouse_rotaperfume.silver.produtos IS
  'Catálogo de produtos tipado - preço e custo em decimal, ativo em boolean, data_lancamento convertida.';

ALTER TABLE lakehouse_rotaperfume.silver.produtos ALTER COLUMN ativo COMMENT
  'Convertida de S/N (bronze) para boolean.';
ALTER TABLE lakehouse_rotaperfume.silver.produtos ALTER COLUMN data_lancamento COMMENT
  'Convertida de ISO ou dd/MM/yyyy (try_to_date duplo).';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.itens_pedido AS
WITH convertido AS (
  SELECT
    i.item_id,
    i.pedido_id,
    i.sku,
    try_cast(i.quantidade AS INT) AS quantidade,
    try_cast(i.preco_praticado AS DECIMAL(18, 2)) AS preco_praticado,
    try_cast(i.desconto_pct AS DECIMAL(9, 4)) AS desconto_pct,
    try_cast(i.valor_bruto AS DECIMAL(18, 2)) AS valor_bruto,
    p.ativo AS produto_ativo
  FROM lakehouse_rotaperfume.bronze.itens_pedido i
  LEFT JOIN lakehouse_rotaperfume.silver.produtos p ON p.sku = i.sku
)
SELECT
  item_id,
  pedido_id,
  sku,
  quantidade < 0 AS devolucao,
  abs(quantidade) AS quantidade_abs,
  preco_praticado,
  desconto_pct,
  valor_bruto,
  coalesce(NOT produto_ativo, false) AS sku_descontinuado,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.itens_pedido) AS _linhas_origem
FROM convertido;

COMMENT ON TABLE lakehouse_rotaperfume.silver.itens_pedido IS
  'Itens de pedido tipados. Devolução (quantidade negativa na origem) NÃO é descartada - fica marcada em devolucao, com quantidade_abs sempre positivo.';

ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido ALTER COLUMN devolucao COMMENT
  'true quando a quantidade na bronze era negativa - é devolução, não erro. A linha nunca é descartada.';
ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido ALTER COLUMN quantidade_abs COMMENT
  'abs(quantidade) - use junto com devolucao para separar venda de devolução em qualquer soma.';
ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido ALTER COLUMN sku_descontinuado COMMENT
  'true quando o produto existe em silver.produtos e está com ativo=false.';

ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido
  ADD CONSTRAINT quantidade_abs_positiva CHECK (quantidade_abs > 0);
