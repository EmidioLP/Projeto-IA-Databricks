-- Gold: os 9 testes de qualidade que interrompem o job
--
-- Cada teste é um SELECT independente. raise_error() retorna o tipo NOTHING,
-- então só funciona dentro de CASE WHEN <condição> THEN 'PASSOU' ELSE
-- raise_error(...) END - nunca sozinho. Se um teste falhar, a tarefa quebra
-- e nenhuma tarefa depois dela roda. Corrija a transformação, nunca o teste.

-- Teste 1 (o que mais importa): a receita da gold é exatamente a da silver.
SELECT
  'teste_1_receita_gold_igual_silver' AS teste,
  gold AS valor_calculado,
  silver AS valor_esperado,
  CASE WHEN ABS(gold - silver) <= 0.01 THEN 'PASSOU'
       ELSE raise_error('teste_1 falhou: gold=' || gold || ' silver=' || silver)
  END AS resultado
FROM (
  SELECT
    (SELECT ROUND(SUM(receita), 2) FROM lakehouse_rotaperfume.gold.fato_vendas) AS gold,
    (SELECT ROUND(SUM(valor_liquido), 2) FROM lakehouse_rotaperfume.silver.pedidos) AS silver
);

-- Teste 2: CNPJ único em silver.clientes (a dedup do prompt 3 não regrediu).
SELECT
  'teste_2_cnpj_unico_em_clientes' AS teste,
  duplicados AS valor_calculado,
  0 AS valor_esperado,
  CASE WHEN duplicados = 0 THEN 'PASSOU'
       ELSE raise_error('teste_2 falhou: ' || duplicados || ' CNPJ duplicados em silver.clientes')
  END AS resultado
FROM (SELECT COUNT(*) - COUNT(DISTINCT cnpj) AS duplicados FROM lakehouse_rotaperfume.silver.clientes);

-- Teste 3: nenhuma data_pedido nula na silver.
SELECT
  'teste_3_data_pedido_nao_nula' AS teste,
  nulos AS valor_calculado,
  0 AS valor_esperado,
  CASE WHEN nulos = 0 THEN 'PASSOU'
       ELSE raise_error('teste_3 falhou: ' || nulos || ' pedidos com data_pedido nula')
  END AS resultado
FROM (SELECT COUNT(*) AS nulos FROM lakehouse_rotaperfume.silver.pedidos WHERE data_pedido IS NULL);

-- Teste 4: receita negativa só existe onde devolucao = true.
SELECT
  'teste_4_receita_negativa_so_em_devolucao' AS teste,
  invalidas AS valor_calculado,
  0 AS valor_esperado,
  CASE WHEN invalidas = 0 THEN 'PASSOU'
       ELSE raise_error('teste_4 falhou: ' || invalidas || ' linhas com receita negativa sem devolucao=true')
  END AS resultado
FROM (SELECT COUNT(*) AS invalidas FROM lakehouse_rotaperfume.gold.fato_vendas WHERE receita < 0 AND NOT devolucao);

-- Teste 5: volume da fato_vendas dentro do esperado (detecta join que dobrou linha).
SELECT
  'teste_5_volume_fato_vendas' AS teste,
  linhas AS valor_calculado,
  '140000 a 250000' AS valor_esperado,
  CASE WHEN linhas BETWEEN 140000 AND 250000 THEN 'PASSOU'
       ELSE raise_error('teste_5 falhou: fato_vendas tem ' || linhas || ' linhas, fora de 140000-250000')
  END AS resultado
FROM (SELECT COUNT(*) AS linhas FROM lakehouse_rotaperfume.gold.fato_vendas);

-- Teste 6: todo pedido_id da gold existe na silver.
SELECT
  'teste_6_pedido_id_existe_na_silver' AS teste,
  orfaos AS valor_calculado,
  0 AS valor_esperado,
  CASE WHEN orfaos = 0 THEN 'PASSOU'
       ELSE raise_error('teste_6 falhou: ' || orfaos || ' pedido_id em fato_vendas ausentes em silver.pedidos')
  END AS resultado
FROM (
  SELECT COUNT(*) AS orfaos
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  LEFT JOIN lakehouse_rotaperfume.silver.pedidos p ON p.pedido_id = f.pedido_id
  WHERE p.pedido_id IS NULL
);

-- Teste 7: todo cliente_id da gold existe na silver (prova de que o crosswalk
-- de cliente_id duplicado em 06-fato-vendas.sql funcionou).
SELECT
  'teste_7_cliente_id_existe_na_silver' AS teste,
  orfaos AS valor_calculado,
  0 AS valor_esperado,
  CASE WHEN orfaos = 0 THEN 'PASSOU'
       ELSE raise_error('teste_7 falhou: ' || orfaos || ' cliente_id em fato_vendas ausentes em silver.clientes')
  END AS resultado
FROM (
  SELECT COUNT(*) AS orfaos
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  LEFT JOIN lakehouse_rotaperfume.silver.clientes c ON c.cliente_id = f.cliente_id
  WHERE c.cliente_id IS NULL
);

-- Teste 8: mart_produto_performance soma o mesmo que fato_vendas (conformidade).
SELECT
  'teste_8_mart_produto_conforma_com_fato' AS teste,
  mart AS valor_calculado,
  fato AS valor_esperado,
  CASE WHEN ABS(mart - fato) <= 0.01 THEN 'PASSOU'
       ELSE raise_error('teste_8 falhou: mart_produto_performance=' || mart || ' fato_vendas=' || fato)
  END AS resultado
FROM (
  SELECT
    (SELECT ROUND(SUM(receita), 2) FROM lakehouse_rotaperfume.gold.mart_produto_performance) AS mart,
    (SELECT ROUND(SUM(receita), 2) FROM lakehouse_rotaperfume.gold.fato_vendas) AS fato
);

-- Teste 9: todo CNPJ na silver tem exatamente 14 dígitos.
SELECT
  'teste_9_cnpj_14_digitos' AS teste,
  invalidos AS valor_calculado,
  0 AS valor_esperado,
  CASE WHEN invalidos = 0 THEN 'PASSOU'
       ELSE raise_error('teste_9 falhou: ' || invalidos || ' CNPJ sem 14 dígitos em silver.clientes')
  END AS resultado
FROM (SELECT COUNT(*) AS invalidos FROM lakehouse_rotaperfume.silver.clientes WHERE length(cnpj) <> 14);
