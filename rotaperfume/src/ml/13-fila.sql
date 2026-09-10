-- Gold ML: fila_semanal — a lista de ligação da semana (200 clientes,
-- priorizados GLOBALMENTE por score, numerados por vendedor) + as quatro
-- ferramentas que um agente de IA consulta.
--
-- ORDEM DAS CTEs NA FILA (não inverter): elegiveis (filtra carteira ANTES de
-- rankear) -> top_200 (LIMIT 200 só depois do filtro) -> numerado
-- (ROW_NUMBER por vendedor só depois do LIMIT). Se o filtro de carteira
-- rodasse DEPOIS do LIMIT 200, a fila sairia com bem menos de 200 linhas
-- (vendedores desligados com carteira "vigente" na aparência levam clientes
-- junto) e o teste 1 quebraria — sem parecer, à primeira vista, um erro de
-- ordenação.
--
-- cliente_id: score_propensao é INT (única tabela assim, decisão do prompt
-- 2); dim_cliente, features_cliente, carteira, fato_vendas são STRING
-- (nunca convertidos na silver — conferido lendo 01-clientes.sql). Esta
-- tabela adota INT, alinhado ao parâmetro p_cliente_id das funções abaixo;
-- todo join contra as tabelas antigas casta explicitamente.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.fila_semanal AS
WITH elegiveis AS (
  -- Só clientes com carteira vigente E vendedor ativo entram na corrida
  -- pelo score. QUALIFY existe porque pelo menos um cliente (conferido no
  -- workspace) tem duas linhas "vigente" ao mesmo tempo — sem isso ele
  -- entraria duas vezes na disputa pelo top-200 e poderia ser ligado por
  -- dois vendedores na mesma semana. Mantém só a atribuição mais recente.
  SELECT
    sp.cliente_id,          -- já INT em score_propensao
    sp.score,
    sp.faixa,
    v.nome AS vendedor
  FROM lakehouse_rotaperfume.gold.score_propensao sp
  JOIN lakehouse_rotaperfume.silver.carteira c
    ON CAST(c.cliente_id AS INT) = sp.cliente_id
   AND c.vigente = true
   AND c.orfao_vendedor_desligado = false
  JOIN lakehouse_rotaperfume.silver.vendedores v
    ON v.vendedor_id = c.vendedor_id
  QUALIFY ROW_NUMBER() OVER (PARTITION BY sp.cliente_id ORDER BY c.data_inicio DESC) = 1
),
top_200 AS (
  -- Ranking GLOBAL, sem cota por vendedor: a fila é sobre quem tem maior
  -- chance de compra, não sobre distribuir 200/N vendedores igualmente.
  -- Cota igual forçaria um vendedor de carteira fria a ligar para cliente
  -- frio, enquanto um vendedor de carteira quente deixaria cliente bom de
  -- fora.
  SELECT * FROM elegiveis
  ORDER BY score DESC
  LIMIT 200
),
numerado AS (
  -- Só AQUI a ordem reinicia por vendedor — é o que permite
  -- priorizar_carteira filtrar "ordem <= p_quantos" em vez de um LIMIT
  -- parametrizado (o UC recusa com INVALID_LIMIT_LIKE_EXPRESSION).
  SELECT *, ROW_NUMBER() OVER (PARTITION BY vendedor ORDER BY score DESC) AS ordem
  FROM top_200
),
com_features AS (
  SELECT
    n.*,
    fc.valor_total,
    fc.ticket_medio,
    fc.atraso_relativo,
    fc.recencia_dias,
    fc.intervalo_medio_dias,
    fc.comprou_lancamento,
    -- calculado só DENTRO dos 200, não da base toda: "cliente grande" aqui
    -- significa grande relativo a quem já está na fila.
    PERCENT_RANK() OVER (ORDER BY fc.valor_total DESC) AS pr_valor_total
  FROM numerado n
  JOIN lakehouse_rotaperfume.gold.features_cliente fc
    ON fc.cliente_id = CAST(n.cliente_id AS STRING)
),
-- ---- sugestao: marca preferida do cliente + SKU mais comprado nela, ainda
-- não recomprado nos últimos 90 dias ----
vendas_dos_200 AS (
  SELECT
    CAST(f.cliente_id AS INT) AS cliente_id,
    f.marca, f.sku, f.pedido_id, f.quantidade, f.receita, f.data_pedido
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  WHERE CAST(f.cliente_id AS INT) IN (SELECT cliente_id FROM numerado)
),
marca_preferida AS (
  -- Recalcula a mesma "marca top" que concentracao_marca_top (prompt 1) já
  -- usa como razão — aqui precisamos do NOME da marca, não só da razão.
  SELECT cliente_id, marca,
    ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY SUM(receita) DESC, marca ASC) AS rn
  FROM vendas_dos_200
  GROUP BY cliente_id, marca
),
candidato_sku AS (
  SELECT
    v.cliente_id, v.sku,
    COUNT(DISTINCT v.pedido_id) AS pedidos_sku,   -- critério de "mais comprado"
    SUM(v.quantidade) AS qtd_sku,                 -- desempate 1
    MAX(v.data_pedido) AS ultima_compra_sku
  FROM vendas_dos_200 v
  JOIN marca_preferida mp ON mp.cliente_id = v.cliente_id AND mp.marca = v.marca AND mp.rn = 1
  GROUP BY v.cliente_id, v.sku
),
sku_elegivel AS (
  -- "hoje" deste dataset é a referência fixa 2026-08-31, nunca
  -- current_date() — mesma convenção dos prompts 1 e 2.
  SELECT * FROM candidato_sku
  WHERE ultima_compra_sku < DATE_SUB(DATE'2026-08-31', 90)
),
sku_escolhido AS (
  SELECT cliente_id, sku,
    ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY pedidos_sku DESC, qtd_sku DESC, sku ASC) AS rn
  FROM sku_elegivel
),
estoque_recente AS (
  SELECT sku, saldo, ruptura FROM (
    SELECT sku, saldo, ruptura,
      ROW_NUMBER() OVER (PARTITION BY sku ORDER BY data_snapshot DESC) AS rn
    FROM lakehouse_rotaperfume.silver.estoque
  ) WHERE rn = 1
),
sugestao_calc AS (
  SELECT se.cliente_id, se.sku, er.saldo, er.ruptura
  FROM sku_escolhido se
  LEFT JOIN estoque_recente er ON er.sku = se.sku
  WHERE se.rn = 1
)
SELECT
  cf.vendedor,
  cf.ordem,
  cf.cliente_id,
  dc.razao_social,
  dc.cidade,
  dc.uf,
  cf.score,
  cf.faixa,
  cf.ticket_medio,
  -- motivo: do sinal mais RARO/específico para o mais COMUM. Conferido
  -- contra o dado real desta fila (não é suposição): comprou_lancamento=1
  -- em 179/200 clientes (90%!) - de longe o sinal mais comum aqui, apesar de
  -- atraso_relativo ter sido a feature nº1 por importância no prompt 2
  -- (importância para o MODELO não é o mesmo que prevalência NESTA fila).
  -- atraso_relativo > 1.5 aparece em só 5/200, e > 3 em 0/200 - são os sinais
  -- realmente raros aqui. Por isso o atraso vem primeiro e o lançamento por
  -- último, antes do ELSE: se lançamento viesse antes, ele capturaria quase
  -- toda a fila e esconderia os sinais mais específicos. Não inverter.
  CASE
    WHEN cf.atraso_relativo > 3
      THEN 'Compra a cada ' || FORMAT_NUMBER(cf.intervalo_medio_dias, 0)
        || ' dias e está há ' || FORMAT_NUMBER(cf.recencia_dias, 0)
        || ' sem pedido. Risco de perder para o concorrente.'
    WHEN cf.atraso_relativo > 1.5
      THEN 'Está ' || FORMAT_NUMBER(cf.atraso_relativo, 1) || ' vezes mais atrasado que o ritmo dele.'
    WHEN cf.pr_valor_total <= 0.1
      THEN 'Cliente grande, R$ ' || FORMAT_NUMBER(cf.valor_total, 2) || ' no ano. Manter próximo.'
    WHEN cf.comprou_lancamento = 1
      THEN 'Comprou lançamento recente. Alta chance de repetir.'
    ELSE 'Dentro do ritmo. Contato de manutenção.'
  END AS motivo,
  CASE
    WHEN sc.sku IS NULL THEN NULL
    WHEN sc.saldo IS NULL THEN sc.sku || ' — estoque não informado'
    WHEN sc.ruptura THEN sc.sku || ' — sem estoque no momento'
    ELSE sc.sku || ' — ' || sc.saldo || ' em estoque'
  END AS sugestao
FROM com_features cf
JOIN lakehouse_rotaperfume.gold.dim_cliente dc ON dc.cliente_id = CAST(cf.cliente_id AS STRING)
LEFT JOIN sugestao_calc sc ON sc.cliente_id = cf.cliente_id;

COMMENT ON TABLE lakehouse_rotaperfume.gold.fila_semanal IS
  'Fila de ligação da semana: os 200 clientes elegíveis (carteira vigente, vendedor ativo) com maior score de propensão, numerados por vendedor. Ranking é global (top 200 de toda a base elegível), não uma cota igual por vendedor.';

ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN vendedor COMMENT
  'Nome do vendedor dono da carteira vigente do cliente (não o vendedor_id).';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN ordem COMMENT
  'Posição do cliente na fila DESTE vendedor - reinicia em 1 por vendedor. Use no lugar de LIMIT parametrizado.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN cliente_id COMMENT
  'Cliente a ligar. INT, alinhado a gold.score_propensao e ao parâmetro p_cliente_id das funções gold.*.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN razao_social COMMENT
  'Nome do cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN cidade COMMENT
  'Cidade do cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN uf COMMENT
  'UF do cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN score COMMENT
  'Score de propensão de compra em 7 dias (0 a 1), de gold.score_propensao.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN faixa COMMENT
  'Faixa do score (Fria/Morna/Quente/Muito quente), de gold.score_propensao.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN ticket_medio COMMENT
  'Ticket médio histórico do cliente, de gold.features_cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN motivo COMMENT
  'Frase em português explicando por que ligar agora, derivada das features do cliente (valor, lançamento, atraso de ritmo). O CASE avalia do sinal mais raro para o mais comum de propósito.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN sugestao COMMENT
  'SKU mais comprado pelo cliente na marca preferida dele, ainda não recomprado nos últimos 90 dias, com o saldo do snapshot mais recente de silver.estoque. NULL quando não há candidato.';

-- Teste 1: a fila tem exatamente 200 linhas.
SELECT
  'teste_fila_1_exatamente_200_linhas' AS teste,
  linhas AS valor_calculado,
  200 AS valor_esperado,
  CASE WHEN linhas = 200 THEN 'PASSOU'
       ELSE raise_error('teste_fila_1 falhou: fila_semanal tem ' || linhas || ' linhas, esperado 200')
  END AS resultado
FROM (SELECT COUNT(*) AS linhas FROM lakehouse_rotaperfume.gold.fila_semanal);

-- Teste 2: nenhuma linha com motivo nulo ou vazio.
SELECT
  'teste_fila_2_motivo_nunca_nulo_ou_vazio' AS teste,
  invalidos AS valor_calculado,
  0 AS valor_esperado,
  CASE WHEN invalidos = 0 THEN 'PASSOU'
       ELSE raise_error('teste_fila_2 falhou: ' || invalidos || ' linhas com motivo nulo/vazio')
  END AS resultado
FROM (SELECT COUNT(*) AS invalidos FROM lakehouse_rotaperfume.gold.fila_semanal WHERE motivo IS NULL OR motivo = '');

-- Teste 3: nenhum score fora do intervalo [0, 1].
SELECT
  'teste_fila_3_score_entre_0_e_1' AS teste,
  invalidos AS valor_calculado,
  0 AS valor_esperado,
  CASE WHEN invalidos = 0 THEN 'PASSOU'
       ELSE raise_error('teste_fila_3 falhou: ' || invalidos || ' linhas com score fora de [0,1]')
  END AS resultado
FROM (SELECT COUNT(*) AS invalidos FROM lakehouse_rotaperfume.gold.fila_semanal WHERE score < 0 OR score > 1);

-- ============================================================================
-- As quatro ferramentas do agente: funções SQL no Unity Catalog. Todo
-- parâmetro prefixado p_ - um parâmetro com o mesmo nome de uma coluna deixa
-- o corpo da função ambíguo e o CREATE falha.
-- ============================================================================

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.priorizar_carteira(p_vendedor STRING, p_quantos INT)
RETURNS TABLE (
  ordem INT, cliente_id INT, razao_social STRING, cidade STRING, uf STRING,
  score DOUBLE, faixa STRING, ticket_medio DOUBLE, motivo STRING, sugestao STRING
)
COMMENT 'Devolve a fila de ligação de UM vendedor, em ordem de prioridade. Use quando precisar saber quem esse vendedor deve ligar hoje/nesta semana, ex.: priorizar_carteira("Ana Souza", 5) para os 5 primeiros.'
RETURN
  SELECT ordem, cliente_id, razao_social, cidade, uf, score, faixa, ticket_medio, motivo, sugestao
  FROM lakehouse_rotaperfume.gold.fila_semanal
  WHERE vendedor = p_vendedor AND ordem <= p_quantos
  ORDER BY ordem;

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.contexto_cliente(p_cliente_id INT)
RETURNS TABLE (
  cliente_id INT, razao_social STRING, cidade STRING, uf STRING, segmento STRING,
  data_primeiro_pedido DATE, data_ultimo_pedido DATE, total_pedidos BIGINT,
  receita_acumulada DECIMAL(18,2), dias_sem_comprar INT,
  ticket_medio DOUBLE, marcas_distintas BIGINT, concentracao_marca_top DOUBLE,
  marca_preferida STRING
)
COMMENT 'Histórico, ticket médio, marcas preferidas e última compra de UM cliente. Use antes de uma ligação para dar contexto ao vendedor sobre quem é o cliente.'
RETURN
  WITH marca_preferida AS (
    SELECT marca
    FROM lakehouse_rotaperfume.gold.fato_vendas
    WHERE CAST(cliente_id AS INT) = p_cliente_id
    GROUP BY marca
    ORDER BY SUM(receita) DESC, marca ASC
    LIMIT 1
  )
  SELECT
    CAST(dc.cliente_id AS INT) AS cliente_id,
    dc.razao_social, dc.cidade, dc.uf, dc.segmento,
    dc.data_primeiro_pedido, dc.data_ultimo_pedido, dc.total_pedidos,
    dc.receita_acumulada, dc.dias_sem_comprar,
    fc.ticket_medio, fc.marcas_distintas, fc.concentracao_marca_top,
    mp.marca AS marca_preferida
  FROM lakehouse_rotaperfume.gold.dim_cliente dc
  LEFT JOIN lakehouse_rotaperfume.gold.features_cliente fc ON fc.cliente_id = dc.cliente_id
  LEFT JOIN marca_preferida mp ON true
  WHERE CAST(dc.cliente_id AS INT) = p_cliente_id;

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.sugerir_produtos(p_cliente_id INT)
RETURNS TABLE (
  sku STRING, marca STRING, categoria STRING,
  pedidos_historicos BIGINT, qtd_historica BIGINT,
  ultima_compra DATE, dias_desde_ultima_compra INT,
  saldo_atual INT, ruptura BOOLEAN
)
COMMENT 'Todo SKU que o cliente já comprou e não compra há mais de 90 dias (mesma regra da coluna sugestao de gold.fila_semanal, sem restringir à marca preferida) - devolve VÁRIOS candidatos. Use quando for explorar opções de recompra para o cliente.'
RETURN
  WITH historico AS (
    SELECT
      f.sku, f.marca, f.categoria,
      COUNT(DISTINCT f.pedido_id) AS pedidos_historicos,
      SUM(f.quantidade) AS qtd_historica,
      MAX(f.data_pedido) AS ultima_compra
    FROM lakehouse_rotaperfume.gold.fato_vendas f
    WHERE CAST(f.cliente_id AS INT) = p_cliente_id
    GROUP BY f.sku, f.marca, f.categoria
  ),
  parou_90d AS (
    SELECT * FROM historico
    WHERE ultima_compra < DATE_SUB(DATE'2026-08-31', 90)
  ),
  estoque_recente AS (
    SELECT sku, saldo, ruptura FROM (
      SELECT sku, saldo, ruptura,
        ROW_NUMBER() OVER (PARTITION BY sku ORDER BY data_snapshot DESC) AS rn
      FROM lakehouse_rotaperfume.silver.estoque
    ) WHERE rn = 1
  )
  SELECT
    p.sku, p.marca, p.categoria, p.pedidos_historicos, p.qtd_historica,
    p.ultima_compra, DATEDIFF(DATE'2026-08-31', p.ultima_compra) AS dias_desde_ultima_compra,
    e.saldo AS saldo_atual, e.ruptura
  FROM parou_90d p
  LEFT JOIN estoque_recente e ON e.sku = p.sku
  ORDER BY p.pedidos_historicos DESC, p.ultima_compra ASC;

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.checar_disponibilidade(p_sku STRING)
RETURNS TABLE (sku STRING, saldo INT, ruptura BOOLEAN, data_snapshot DATE)
COMMENT 'Saldo e ruptura de UM SKU no snapshot mais recente de silver.estoque. Use antes de sugerir um produto para confirmar que ele está disponível.'
RETURN
  SELECT sku, saldo, ruptura, data_snapshot
  FROM lakehouse_rotaperfume.silver.estoque
  WHERE sku = p_sku
    AND data_snapshot = (SELECT MAX(data_snapshot) FROM lakehouse_rotaperfume.silver.estoque WHERE sku = p_sku);
