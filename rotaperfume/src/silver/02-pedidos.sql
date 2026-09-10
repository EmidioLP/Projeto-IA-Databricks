-- Silver: pedidos
--
-- Converte data_pedido (ISO e dd/MM/yyyy) e valor_total (texto -> decimal),
-- e transforma o cancelamento em coluna explícita em vez de sumir com a
-- linha: valor_liquido é zero quando cancelado, valor_total nos demais casos.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.pedidos AS
WITH convertido AS (
  SELECT
    pedido_id,
    cliente_id,
    vendedor_id,
    coalesce(try_to_date(data_pedido), try_to_date(data_pedido, 'dd/MM/yyyy')) AS data_pedido,
    canal,
    status,
    status = 'Cancelado' AS cancelado,
    try_cast(valor_total AS DECIMAL(18, 2)) AS valor_total
  FROM lakehouse_rotaperfume.bronze.pedidos
)
SELECT
  pedido_id,
  cliente_id,
  vendedor_id,
  data_pedido,
  year(data_pedido) AS ano,
  month(data_pedido) AS mes,
  canal,
  status,
  cancelado,
  valor_total,
  CASE WHEN cancelado THEN CAST(0.00 AS DECIMAL(18, 2)) ELSE valor_total END AS valor_liquido,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.pedidos) AS _linhas_origem
FROM convertido;

COMMENT ON TABLE lakehouse_rotaperfume.silver.pedidos IS
  'Pedidos tipados. Cancelamento fica como coluna explícita (cancelado/valor_liquido), nenhuma linha é descartada.';

ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN data_pedido COMMENT
  'Convertida de ISO ou dd/MM/yyyy (try_to_date duplo) - a bronze trazia os dois formatos misturados.';
ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN valor_total COMMENT
  'CAST de texto para DECIMAL(18,2) - a bronze guardava como STRING.';
ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN cancelado COMMENT
  'true quando status = ''Cancelado''. Criada porque a bronze zera o valor_total de pedidos cancelados sem nenhuma flag.';
ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN valor_liquido COMMENT
  'Zero quando cancelado, valor_total nos demais casos - use esta coluna para somar faturamento.';

ALTER TABLE lakehouse_rotaperfume.silver.pedidos
  ADD CONSTRAINT data_pedido_obrigatoria CHECK (data_pedido IS NOT NULL);

-- NÃO usar "valor_liquido >= 0": 135 pedidos têm item de devolução e ficam
-- com saldo negativo de forma legítima. A regra real é sobre o cancelamento.
ALTER TABLE lakehouse_rotaperfume.silver.pedidos
  ADD CONSTRAINT pedido_cancelado_zerado CHECK (NOT cancelado OR valor_liquido = 0);
