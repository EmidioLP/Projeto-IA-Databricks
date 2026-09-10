-- Silver: clientes
--
-- Normaliza CNPJ (nunca vira número, para não perder zero à esquerda),
-- padroniza razao_social, converte data_cadastro (ISO e dd/MM/yyyy
-- misturados) e deduplica por CNPJ mantendo o cadastro MAIS ANTIGO. Os
-- cliente_id descartados na dedup ficam rastreáveis em
-- cliente_ids_duplicados, porque pedidos antigos ainda apontam para eles.

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.clientes AS
WITH normalizado AS (
  SELECT
    cliente_id,
    lpad(regexp_replace(trim(cnpj), '[^0-9]', ''), 14, '0') AS cnpj,
    initcap(regexp_replace(trim(razao_social), '\\s+', ' ')) AS razao_social,
    segmento,
    cidade,
    uf,
    bairro,
    coalesce(try_to_date(data_cadastro), try_to_date(data_cadastro, 'dd/MM/yyyy')) AS data_cadastro,
    ativo = 'S' AS ativo
  FROM lakehouse_rotaperfume.bronze.clientes
),
agrupado AS (
  SELECT
    *,
    row_number() OVER (PARTITION BY cnpj ORDER BY data_cadastro ASC, cliente_id ASC) AS rn,
    collect_list(cliente_id) OVER (PARTITION BY cnpj) AS ids_do_cnpj
  FROM normalizado
)
SELECT
  cliente_id,
  cnpj,
  razao_social,
  segmento,
  cidade,
  uf,
  bairro,
  data_cadastro,
  ativo,
  CASE WHEN size(ids_do_cnpj) > 1 THEN array_remove(ids_do_cnpj, cliente_id) END AS cliente_ids_duplicados,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.clientes) AS _linhas_origem
FROM agrupado
WHERE rn = 1;

COMMENT ON TABLE lakehouse_rotaperfume.silver.clientes IS
  'Clientes limpos e deduplicados por CNPJ - mantém o cadastro mais antigo de cada CNPJ; os demais cliente_id ficam em cliente_ids_duplicados para rastreabilidade de pedidos antigos.';

ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN cnpj COMMENT
  'Normalizado para 14 dígitos (trim + regexp_replace + lpad). Nunca convertido para número, para não perder zero à esquerda.';
ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN razao_social COMMENT
  'Caixa e espaçamento padronizados (initcap, espaço duplo colapsado).';
ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN data_cadastro COMMENT
  'Convertida de ISO ou dd/MM/yyyy (try_to_date duplo) - a bronze trazia os dois formatos misturados.';
ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN cliente_ids_duplicados COMMENT
  'cliente_id dos cadastros duplicados do mesmo CNPJ, descartados nesta deduplicação (NULL quando não há duplicata).';

ALTER TABLE lakehouse_rotaperfume.silver.clientes
  ADD CONSTRAINT cnpj_14_digitos CHECK (length(cnpj) = 14);

ALTER TABLE lakehouse_rotaperfume.silver.clientes
  ADD CONSTRAINT data_cadastro_obrigatoria CHECK (data_cadastro IS NOT NULL);
