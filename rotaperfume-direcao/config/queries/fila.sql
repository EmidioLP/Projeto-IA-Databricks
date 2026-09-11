-- @param vendedor STRING = Todos
-- Os 200 contatos da semana, com o retorno mais recente de cada cliente
-- (se houver). 'Todos' não filtra por vendedor.
WITH retorno_recente AS (
  SELECT cliente_id, status, comentario, registrado_em
  FROM lakehouse_rotaperfume.gold.retorno_ligacao
  QUALIFY ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY registrado_em DESC) = 1
)
SELECT
  f.vendedor,
  f.ordem,
  f.cliente_id,
  f.razao_social,
  f.cidade,
  f.uf,
  f.score,
  f.faixa,
  f.ticket_medio,
  f.motivo,
  f.sugestao,
  r.status AS status_retorno,
  r.comentario AS comentario_retorno
FROM lakehouse_rotaperfume.gold.fila_semanal f
LEFT JOIN retorno_recente r ON r.cliente_id = f.cliente_id
WHERE (:vendedor = 'Todos' OR f.vendedor = :vendedor)
ORDER BY f.vendedor, f.ordem;
