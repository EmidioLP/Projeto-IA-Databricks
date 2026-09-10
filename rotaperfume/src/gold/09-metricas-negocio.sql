-- Gold: métricas de negócio (views com nome de negócio, não de engenheiro)
--
-- Cada COMMENT descreve a PERGUNTA que a view responde, não a implementação -
-- é o que o Genie (prompt 6) lê para escolher onde procurar. Sintaxe
-- compacta CREATE OR REPLACE VIEW nome (col COMMENT '...', ...) COMMENT '...'
-- AS SELECT ... comenta toda coluna sem precisar de um ALTER por coluna.

CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.receita_mensal (
  ano COMMENT 'Ano do pedido',
  mes COMMENT 'Mês do pedido (1-12)',
  receita COMMENT 'Soma da receita líquida do mês (inclui devolução, exclui pedido cancelado)',
  margem COMMENT 'Soma da margem do mês',
  pedidos COMMENT 'Número de pedidos distintos no mês',
  mes_pico_setor COMMENT 'true quando o mês é pico de vendas do setor (abril, junho, outubro) - vem de dim_calendario, não é recalculado aqui'
)
COMMENT 'Como estão as vendas mês a mês, e se cada mês é de pico ou de vale para o setor.'
AS
WITH calendario_mensal AS (
  SELECT DISTINCT ano, mes, mes_pico_setor FROM lakehouse_rotaperfume.gold.dim_calendario
)
SELECT
  f.ano,
  f.mes,
  SUM(f.receita) AS receita,
  SUM(f.margem) AS margem,
  COUNT(DISTINCT f.pedido_id) AS pedidos,
  c.mes_pico_setor
FROM lakehouse_rotaperfume.gold.fato_vendas f
JOIN calendario_mensal c ON c.ano = f.ano AND c.mes = f.mes
GROUP BY f.ano, f.mes, c.mes_pico_setor;

CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.ranking_marcas (
  marca COMMENT 'Marca do produto',
  receita COMMENT 'Soma da receita líquida da marca',
  margem_pct COMMENT 'Margem da marca como percentual da própria receita (0-100)',
  participacao_pct COMMENT 'Participação da marca na receita total da empresa (0-100)'
)
COMMENT 'Quais marcas estão vendendo, com que margem, e que fatia da receita total cada uma representa.'
AS
SELECT
  marca,
  SUM(receita) AS receita,
  100.0 * SUM(margem) / NULLIF(SUM(receita), 0) AS margem_pct,
  100.0 * SUM(receita) / NULLIF(SUM(SUM(receita)) OVER (), 0) AS participacao_pct
FROM lakehouse_rotaperfume.gold.fato_vendas
GROUP BY marca;

CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.margem_por_categoria (
  categoria COMMENT 'Categoria do produto',
  receita COMMENT 'Soma da receita líquida da categoria',
  margem COMMENT 'Soma da margem da categoria',
  margem_pct COMMENT 'Margem da categoria como percentual da própria receita (0-100)'
)
COMMENT 'Qual categoria dá mais lucro, e onde a margem está apertada.'
AS
SELECT
  categoria,
  SUM(receita) AS receita,
  SUM(margem) AS margem,
  100.0 * SUM(margem) / NULLIF(SUM(receita), 0) AS margem_pct
FROM lakehouse_rotaperfume.gold.fato_vendas
GROUP BY categoria;

CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.clientes_em_risco (
  cliente_id COMMENT 'Cliente',
  razao_social COMMENT 'Nome do cliente',
  segmento COMMENT 'Segmento de mercado do cliente',
  cidade COMMENT 'Cidade do cliente',
  data_ultimo_pedido COMMENT 'Data do último pedido do cliente',
  dias_sem_comprar COMMENT 'Dias corridos desde o último pedido até hoje - o filtro de risco é maior que 90',
  receita_mensal_media_antes_de_sumir COMMENT 'Receita acumulada do cliente dividida pelos meses em que ele esteve ativo (do primeiro ao último pedido) - quanto ele comprava por mês antes de parar'
)
COMMENT 'Quais clientes pararam de comprar (mais de 90 dias sem pedido), e quanta receita por mês a empresa está deixando de receber por causa disso.'
AS
SELECT
  cliente_id,
  razao_social,
  segmento,
  cidade,
  data_ultimo_pedido,
  dias_sem_comprar,
  receita_acumulada / GREATEST(1, MONTHS_BETWEEN(data_ultimo_pedido, data_primeiro_pedido)) AS receita_mensal_media_antes_de_sumir
FROM lakehouse_rotaperfume.gold.dim_cliente
WHERE dias_sem_comprar > 90;

CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.efeito_lancamento (
  sku COMMENT 'Produto',
  marca COMMENT 'Marca do produto',
  data_lancamento COMMENT 'Data de lançamento do produto',
  receita_primeiros_120_dias COMMENT 'Receita do produto nos primeiros 120 dias após o lançamento',
  receita_resto_periodo COMMENT 'Receita do produto depois dos primeiros 120 dias de vida',
  dias_desde_lancamento_ate_hoje COMMENT 'Dias corridos desde o lançamento até hoje - contexto para julgar se o produto já teve tempo de maturar'
)
COMMENT 'Se o lançamento de um produto fez efeito, e quais produtos mantiveram força de venda depois do hype inicial. Só cobre os SKUs com data de lançamento registrada.'
AS
SELECT
  pr.sku,
  pr.marca,
  pr.data_lancamento,
  SUM(f.receita) FILTER (WHERE f.data_pedido < date_add(pr.data_lancamento, 120)) AS receita_primeiros_120_dias,
  SUM(f.receita) FILTER (WHERE f.data_pedido >= date_add(pr.data_lancamento, 120)) AS receita_resto_periodo,
  datediff(current_date(), pr.data_lancamento) AS dias_desde_lancamento_ate_hoje
FROM lakehouse_rotaperfume.gold.dim_produto pr
LEFT JOIN lakehouse_rotaperfume.gold.fato_vendas f ON f.sku = pr.sku
WHERE pr.data_lancamento IS NOT NULL
GROUP BY pr.sku, pr.marca, pr.data_lancamento;

CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.ruptura_por_marca (
  marca COMMENT 'Marca do produto',
  snapshots COMMENT 'Número de snapshots de estoque observados para a marca',
  snapshots_em_ruptura COMMENT 'Número desses snapshots em que o saldo estava zerado (ruptura)',
  ruptura_pct COMMENT 'Percentual de snapshots em ruptura (0-100) - quanto maior, mais a marca fica sem estoque'
)
COMMENT 'Quais marcas mais ficam em ruptura de estoque, e onde o risco de perder venda por falta de produto é maior.'
AS
SELECT
  pr.marca,
  COUNT(*) AS snapshots,
  COUNT(*) FILTER (WHERE e.ruptura) AS snapshots_em_ruptura,
  100.0 * COUNT(*) FILTER (WHERE e.ruptura) / NULLIF(COUNT(*), 0) AS ruptura_pct
FROM lakehouse_rotaperfume.silver.estoque e
JOIN lakehouse_rotaperfume.gold.dim_produto pr ON pr.sku = e.sku
GROUP BY pr.marca;
