-- Gold: retorno_ligacao — o caminho de volta da fila de ligação.
--
-- Única tabela do projeto cujo dado não vem do pipeline: vem do time
-- comercial, depois de cada ligação da fila (gold.fila_semanal). Por isso
-- CREATE TABLE IF NOT EXISTS, e não CREATE OR REPLACE — um redeploy não pode
-- apagar o que o time já registrou. Nasce vazia; isso é o estado correto.
--
-- Só o CREATE é guardado por IF NOT EXISTS. Os COMMENTs abaixo rodam em todo
-- deploy/execução do job (não tocam dado, só metadado) para continuarem
-- sincronizados se este arquivo for editado depois.

CREATE TABLE IF NOT EXISTS lakehouse_rotaperfume.gold.retorno_ligacao (
  cliente_id      INT,
  vendedor        STRING,
  status          STRING,
  comentario      STRING,
  registrado_em   TIMESTAMP,
  registrado_por  STRING,
  _referencia     DATE
);

COMMENT ON TABLE lakehouse_rotaperfume.gold.retorno_ligacao IS
  'Retorno registrado pelo time comercial depois de cada ligação da fila semanal (gold.fila_semanal) - a única tabela do projeto cujo dado não vem do pipeline. Nasce vazia; CREATE TABLE IF NOT EXISTS para um redeploy nunca apagar o que o time já registrou.';

ALTER TABLE lakehouse_rotaperfume.gold.retorno_ligacao ALTER COLUMN cliente_id COMMENT
  'Cliente que recebeu a ligação. INT, alinhado a gold.score_propensao e gold.fila_semanal.';
ALTER TABLE lakehouse_rotaperfume.gold.retorno_ligacao ALTER COLUMN vendedor COMMENT
  'Nome do vendedor que fez a ligação, mesmo padrão de nome usado em gold.fila_semanal.vendedor.';
ALTER TABLE lakehouse_rotaperfume.gold.retorno_ligacao ALTER COLUMN status COMMENT
  'Resultado da ligação: vendeu | vai_pensar | sem_interesse | nao_atendeu.';
ALTER TABLE lakehouse_rotaperfume.gold.retorno_ligacao ALTER COLUMN comentario COMMENT
  'Texto livre do vendedor sobre a ligação - contexto que não cabe no status.';
ALTER TABLE lakehouse_rotaperfume.gold.retorno_ligacao ALTER COLUMN registrado_em COMMENT
  'Data e hora em que o retorno foi registrado - não é a data/hora da ligação em si.';
ALTER TABLE lakehouse_rotaperfume.gold.retorno_ligacao ALTER COLUMN registrado_por COMMENT
  'E-mail de quem estava logado ao registrar o retorno.';
ALTER TABLE lakehouse_rotaperfume.gold.retorno_ligacao ALTER COLUMN _referencia COMMENT
  'Semana da fila (gold.fila_semanal) a que este retorno se refere.';
