-- Silver: vendedores, carteira, oportunidades, visitas, pagamentos, estoque
--
-- vendedores é criada primeiro porque carteira faz join com ela para
-- detectar vendedor desligado. Nenhum dado é consertado: onde a origem
-- expõe um problema (carteira vigente de vendedor desligado), a silver cria
-- uma coluna para o gestor ver, em vez de esconder ou corrigir sozinha.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.vendedores AS
SELECT
  vendedor_id,
  nome,
  regiao,
  uf,
  coalesce(try_to_date(data_admissao), try_to_date(data_admissao, 'dd/MM/yyyy')) AS data_admissao,
  coalesce(try_to_date(data_desligamento), try_to_date(data_desligamento, 'dd/MM/yyyy')) AS data_desligamento,
  try_cast(meta_mensal AS DECIMAL(18, 2)) AS meta_mensal,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.vendedores) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.vendedores;

COMMENT ON TABLE lakehouse_rotaperfume.silver.vendedores IS
  'Vendedores tipados. data_desligamento NULL significa vendedor ativo.';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.carteira AS
WITH convertido AS (
  SELECT
    c.carteira_id,
    c.cliente_id,
    c.vendedor_id,
    coalesce(try_to_date(c.data_inicio), try_to_date(c.data_inicio, 'dd/MM/yyyy')) AS data_inicio,
    coalesce(try_to_date(c.data_fim), try_to_date(c.data_fim, 'dd/MM/yyyy')) AS data_fim,
    v.data_desligamento AS vendedor_desligado_em
  FROM lakehouse_rotaperfume.bronze.carteira c
  LEFT JOIN lakehouse_rotaperfume.silver.vendedores v ON v.vendedor_id = c.vendedor_id
)
SELECT
  carteira_id,
  cliente_id,
  vendedor_id,
  data_inicio,
  data_fim,
  (data_fim IS NULL OR data_fim >= current_date())
    AND (vendedor_desligado_em IS NULL OR vendedor_desligado_em >= current_date()) AS vigente,
  (data_fim IS NULL OR data_fim >= current_date())
    AND vendedor_desligado_em IS NOT NULL AND vendedor_desligado_em < current_date() AS orfao_vendedor_desligado,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.carteira) AS _linhas_origem
FROM convertido;

COMMENT ON TABLE lakehouse_rotaperfume.silver.carteira IS
  'Carteira de clientes por vendedor. Vendedor desligado com carteira ainda vigente NÃO é corrigido aqui - fica exposto em orfao_vendedor_desligado.';

ALTER TABLE lakehouse_rotaperfume.silver.carteira ALTER COLUMN vigente COMMENT
  'Respeita data_fim da carteira E data_desligamento do vendedor - as duas precisam estar em aberto.';
ALTER TABLE lakehouse_rotaperfume.silver.carteira ALTER COLUMN orfao_vendedor_desligado COMMENT
  'true quando a carteira parece vigente pela própria data, mas o vendedor já foi desligado. Não é conserto, é alerta para o gestor.';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.oportunidades AS
SELECT
  oportunidade_id,
  cliente_id,
  vendedor_id,
  origem,
  coalesce(try_to_date(data_abertura), try_to_date(data_abertura, 'dd/MM/yyyy')) AS data_abertura,
  etapa,
  etapa = 'Fechado ganho' AS ganha,
  etapa = 'Fechado perdido' AS perdida,
  try_cast(probabilidade_pct AS INT) AS probabilidade_pct,
  try_cast(valor_estimado AS DECIMAL(18, 2)) AS valor_estimado,
  coalesce(try_to_date(data_fechamento), try_to_date(data_fechamento, 'dd/MM/yyyy')) AS data_fechamento,
  try_cast(ciclo_dias AS INT) AS ciclo_dias,
  motivo_perda,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.oportunidades) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.oportunidades;

COMMENT ON TABLE lakehouse_rotaperfume.silver.oportunidades IS
  'Oportunidades de venda tipadas. As etapas de fechamento na origem são "Fechado ganho"/"Fechado perdido", não "Ganha"/"Perdida" - ganha/perdida checam o texto exato.';

ALTER TABLE lakehouse_rotaperfume.silver.oportunidades ALTER COLUMN ganha COMMENT
  'true quando etapa = ''Fechado ganho'' (texto exato confirmado na origem, não ''Ganha'').';
ALTER TABLE lakehouse_rotaperfume.silver.oportunidades ALTER COLUMN perdida COMMENT
  'true quando etapa = ''Fechado perdido'' (texto exato confirmado na origem, não ''Perdida'').';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.visitas AS
SELECT
  visita_id,
  cliente_id,
  vendedor_id,
  coalesce(try_to_date(data_visita), try_to_date(data_visita, 'dd/MM/yyyy')) AS data_visita,
  resultado,
  try_cast(duracao_min AS INT) AS duracao_min,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.visitas) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.visitas;

COMMENT ON TABLE lakehouse_rotaperfume.silver.visitas IS 'Visitas de vendedores a clientes, tipadas.';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.pagamentos AS
SELECT
  pagamento_id,
  pedido_id,
  forma_pagamento,
  try_cast(parcelas AS INT) AS parcelas,
  try_cast(valor AS DECIMAL(18, 2)) AS valor,
  try_cast(taxa_pct AS DECIMAL(9, 4)) AS taxa_pct,
  try_cast(valor_liquido AS DECIMAL(18, 2)) AS valor_liquido,
  coalesce(try_to_date(data_vencimento), try_to_date(data_vencimento, 'dd/MM/yyyy')) AS data_vencimento,
  coalesce(try_to_date(data_pagamento), try_to_date(data_pagamento, 'dd/MM/yyyy')) AS data_pagamento,
  status_pagamento,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.pagamentos) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.pagamentos;

COMMENT ON TABLE lakehouse_rotaperfume.silver.pagamentos IS
  'Pagamentos tipados. data_pagamento NULL significa pagamento ainda não realizado (em aberto/inadimplente).';

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.estoque AS
SELECT
  coalesce(try_to_date(data_snapshot), try_to_date(data_snapshot, 'dd/MM/yyyy')) AS data_snapshot,
  sku,
  try_cast(saldo AS INT) AS saldo,
  try_cast(saldo AS INT) = 0 AS ruptura,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.estoque) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.estoque;

COMMENT ON TABLE lakehouse_rotaperfume.silver.estoque IS
  'Snapshot de estoque tipado. ruptura é recalculada a partir de saldo = 0, não copiada da bronze.';

ALTER TABLE lakehouse_rotaperfume.silver.estoque ALTER COLUMN ruptura COMMENT
  'Recalculada como saldo = 0, ignorando o texto que veio da bronze.';
