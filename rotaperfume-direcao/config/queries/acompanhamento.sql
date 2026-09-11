-- Por vendedor: quantos na fila, quantos já trabalhados e a contagem de
-- cada status de retorno.
WITH retorno_recente AS (
  SELECT cliente_id, status
  FROM lakehouse_rotaperfume.gold.retorno_ligacao
  QUALIFY ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY registrado_em DESC) = 1
)
SELECT
  f.vendedor,
  COUNT(*) AS na_fila,
  COUNT(r.status) AS trabalhados,
  COUNT(*) FILTER (WHERE r.status = 'vendeu') AS vendeu,
  COUNT(*) FILTER (WHERE r.status = 'vai_pensar') AS vai_pensar,
  COUNT(*) FILTER (WHERE r.status = 'sem_interesse') AS sem_interesse,
  COUNT(*) FILTER (WHERE r.status = 'nao_atendeu') AS nao_atendeu
FROM lakehouse_rotaperfume.gold.fila_semanal f
LEFT JOIN retorno_recente r ON r.cliente_id = f.cliente_id
GROUP BY f.vendedor
ORDER BY f.vendedor;
