#!/usr/bin/env bash
# Sobe os CSVs de datasets/erp e datasets/crm (na raiz do repositório, um nível
# acima deste bundle) para o Volume bronze.raw do catálogo.
#
# `databricks fs cp` exige o esquema `dbfs:` no destino mesmo sendo um Volume
# do Unity Catalog - é isso que trava esse comando na prática.
set -euo pipefail

PROFILE="${1:?uso: subir-raw.sh <profile> [catalog]}"
CATALOG="${2:-lakehouse_rotaperfume}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATASETS_DIR="$(cd "${SCRIPT_DIR}/../../datasets" && pwd)"

for sistema in erp crm; do
  origem="${DATASETS_DIR}/${sistema}"
  destino="dbfs:/Volumes/${CATALOG}/bronze/raw/${sistema}"
  echo "==> ${origem} -> ${destino}"
  databricks fs cp --recursive --overwrite "${origem}" "${destino}" --profile "${PROFILE}"
done
