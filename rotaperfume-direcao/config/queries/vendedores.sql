-- Alimenta o Select de filtro por vendedor na tela "A semana".
SELECT vendedor, COUNT(*) AS contatos
FROM lakehouse_rotaperfume.gold.fila_semanal
GROUP BY vendedor
ORDER BY vendedor;
