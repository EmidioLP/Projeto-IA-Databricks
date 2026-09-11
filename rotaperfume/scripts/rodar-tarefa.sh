#!/usr/bin/env bash
# Roda uma única tarefa do job rotaperfume_pipeline sob demanda, sem esperar
# o schedule nem rodar o pipeline inteiro. Útil para conferir uma tarefa nova
# (ex.: gold_retorno_ligacao) ou para forçar re-teste (ex.: auditoria_de_metadado).
set -euo pipefail

PROFILE="${1:?uso: rodar-tarefa.sh <profile> <task_key> [target]}"
TASK_KEY="${2:?uso: rodar-tarefa.sh <profile> <task_key> [target]}"
TARGET="${3:-dev}"

databricks bundle run rotaperfume_pipeline \
  --only "${TASK_KEY}" \
  --target "${TARGET}" \
  --profile "${PROFILE}"
