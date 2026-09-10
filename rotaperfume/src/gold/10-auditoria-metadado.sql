-- Gold: auditoria de metadado
--
-- Metadado faltando é BUG, não pendência de documentação: a partir desta
-- entrega tem um agente (Genie) lendo o COMMENT para decidir qual coluna
-- usar. Os dois primeiros SELECTs quebram o job via raise_error() se
-- faltar comment; o terceiro só imprime o relatório de cobertura, sem quebrar.

-- Teste A: toda tabela/view da gold tem COMMENT de tabela.
SELECT
  'auditoria_1_objetos_sem_comment' AS teste,
  n AS valor_calculado,
  0 AS valor_esperado,
  CASE WHEN n = 0 THEN 'PASSOU'
       ELSE raise_error('objetos da gold sem COMMENT: ' || lista)
  END AS resultado
FROM (
  SELECT COUNT(*) AS n, array_join(collect_list(table_name), ', ') AS lista
  FROM lakehouse_rotaperfume.information_schema.tables
  WHERE table_schema = 'gold' AND (comment IS NULL OR comment = '')
);

-- Teste B: toda coluna de fato_vendas e das 6 views de negócio tem COMMENT.
SELECT
  'auditoria_2_colunas_sem_comment' AS teste,
  n AS valor_calculado,
  0 AS valor_esperado,
  CASE WHEN n = 0 THEN 'PASSOU'
       ELSE raise_error('colunas sem COMMENT em fato_vendas/views de negócio: ' || lista)
  END AS resultado
FROM (
  SELECT COUNT(*) AS n, array_join(collect_list(table_name || '.' || column_name), ', ') AS lista
  FROM lakehouse_rotaperfume.information_schema.columns
  WHERE table_schema = 'gold'
    AND table_name IN (
      'fato_vendas', 'receita_mensal', 'ranking_marcas', 'margem_por_categoria',
      'clientes_em_risco', 'efeito_lancamento', 'ruptura_por_marca'
    )
    AND (comment IS NULL OR comment = '')
);

-- Relatório de cobertura por objeto - não quebra, é para a conversa com
-- quem vai consumir a gold.
SELECT
  c.table_name,
  COUNT(*) AS colunas,
  COUNT(*) FILTER (WHERE c.comment IS NOT NULL AND c.comment <> '') AS comentadas,
  ROUND(100.0 * COUNT(*) FILTER (WHERE c.comment IS NOT NULL AND c.comment <> '') / COUNT(*), 1) AS cobertura_pct
FROM lakehouse_rotaperfume.information_schema.columns c
WHERE c.table_schema = 'gold'
GROUP BY c.table_name
ORDER BY cobertura_pct, c.table_name;
