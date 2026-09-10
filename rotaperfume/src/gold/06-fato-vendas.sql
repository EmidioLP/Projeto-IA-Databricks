-- Gold: fato_vendas
--
-- CONTRATO (escrito antes do SQL):
--   Granularidade: uma linha por ITEM de pedido.
--   Filtro: exclui pedidos cancelados. NÃO exclui devolução.
--   Dimensões: data_pedido, ano, mes, canal, cliente_id, razao_social,
--              segmento, cidade, vendedor_id, sku, categoria, marca,
--              nota_olfativa.
--   Métricas: quantidade, preco_praticado, receita, custo, margem, devolucao.
--   custo  = quantidade * custo_unitario do produto.
--   margem = receita - custo.
--   Devolução entra com quantidade e receita NEGATIVAS, com a flag
--   devolucao=true - se ficasse de fora, a gold somaria R$ 1,26 mi a mais que
--   a silver. Quem quiser o bruto vendido pede
--   SUM(receita) FILTER (WHERE NOT devolucao).
--   Particionada por ano e mes.
--
-- cliente_id passa pelo mesmo crosswalk de dim_cliente (05-dimensoes.sql):
-- pedidos antigos podem apontar para um cadastro que a dedup da silver
-- descartou, e o fato nunca pode gravar um cliente_id que não existe mais em
-- silver.clientes.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.fato_vendas
PARTITIONED BY (ano, mes)
AS
WITH crosswalk AS (
  SELECT cliente_id AS atual, cliente_id AS origem FROM lakehouse_rotaperfume.silver.clientes
  UNION ALL
  SELECT cliente_id AS atual, explode(cliente_ids_duplicados) AS origem
  FROM lakehouse_rotaperfume.silver.clientes WHERE cliente_ids_duplicados IS NOT NULL
),
base AS (
  SELECT
    i.item_id,
    p.pedido_id,
    p.data_pedido,
    year(p.data_pedido) AS ano,
    month(p.data_pedido) AS mes,
    p.canal,
    cw.atual AS cliente_id,
    c.razao_social,
    c.segmento,
    c.cidade,
    p.vendedor_id,
    i.sku,
    pr.categoria,
    pr.marca,
    pr.nota_olfativa,
    CASE WHEN i.devolucao THEN -i.quantidade_abs ELSE i.quantidade_abs END AS quantidade,
    i.preco_praticado,
    pr.custo_unitario,
    i.devolucao
  FROM lakehouse_rotaperfume.silver.itens_pedido i
  JOIN lakehouse_rotaperfume.silver.pedidos  p  ON p.pedido_id = i.pedido_id
  JOIN lakehouse_rotaperfume.silver.produtos pr ON pr.sku = i.sku
  JOIN crosswalk cw ON cw.origem = p.cliente_id
  LEFT JOIN lakehouse_rotaperfume.silver.clientes c ON c.cliente_id = cw.atual
  WHERE NOT p.cancelado
)
SELECT
  item_id,
  pedido_id,
  data_pedido,
  ano,
  mes,
  canal,
  cliente_id,
  razao_social,
  segmento,
  cidade,
  vendedor_id,
  sku,
  categoria,
  marca,
  nota_olfativa,
  quantidade,
  preco_praticado,
  quantidade * preco_praticado AS receita,
  quantidade * custo_unitario AS custo,
  quantidade * preco_praticado - quantidade * custo_unitario AS margem,
  devolucao,
  current_timestamp() AS _processado_em
FROM base;

COMMENT ON TABLE lakehouse_rotaperfume.gold.fato_vendas IS
  'Uma linha por item de pedido faturado (pedidos cancelados excluídos, devoluções incluídas). É o único fato de vendas - todo mart comercial deriva dele.';

ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN data_pedido COMMENT 'Data em que o pedido foi feito.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN ano COMMENT 'Ano do pedido - chave de partição.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN mes COMMENT 'Mês do pedido (1-12) - chave de partição.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN canal COMMENT 'Canal pelo qual o pedido foi feito (App, Telefone, Visita, WhatsApp).';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN cliente_id COMMENT 'Cliente que comprou. Já consolidado para o cadastro atual quando havia CNPJ duplicado.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN razao_social COMMENT 'Nome do cliente no momento da consulta.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN segmento COMMENT 'Segmento de mercado do cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN cidade COMMENT 'Cidade do cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN vendedor_id COMMENT 'Vendedor responsável pelo pedido.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN sku COMMENT 'Produto vendido.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN categoria COMMENT 'Categoria do produto.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN marca COMMENT 'Marca do produto.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN nota_olfativa COMMENT 'Nota olfativa do produto.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN quantidade COMMENT 'Unidades vendidas. Negativa quando a linha é uma devolução.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN preco_praticado COMMENT 'Preço por unidade cobrado neste item.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN receita COMMENT 'quantidade * preco_praticado. Negativa em devoluções - para o valor bruto vendido, use SUM(receita) FILTER (WHERE NOT devolucao).';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN custo COMMENT 'quantidade * custo unitário do produto.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN margem COMMENT 'Receita menos custo do produto. Não considera desconto comercial nem frete.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN devolucao COMMENT 'true quando este item é uma devolução (quantidade e receita negativas).';
