#!/usr/bin/env bash
# Cria o catálogo via SQL, fora do bundle.
#
# POR QUE NÃO ESTÁ NO BUNDLE: neste workspace (Free Edition, Default Storage
# habilitado) a API do Unity Catalog RECUSA criar catálogo pelo endpoint REST
# (o que o resource `catalogs` do bundle usa por baixo) - ela exige uma
# MANAGED LOCATION que a conta gratuita não tem:
#   Error: Metastore storage root URL does not exist. Default Storage is
#   enabled in your account. (400 INVALID_STATE)
# O comando SQL `CREATE CATALOG` funciona porque passa por um caminho
# diferente (o SQL warehouse, não a REST API de catálogos). Rode este script
# uma vez, antes do primeiro `databricks bundle deploy`.
set -euo pipefail

PROFILE="${1:?uso: criar-catalogo.sh <profile> [catalog]}"
CATALOG="${2:-lakehouse_rotaperfume}"

databricks experimental aitools tools query \
  "CREATE CATALOG IF NOT EXISTS ${CATALOG} COMMENT 'Catálogo do projeto rotaperfume - dados de ERP e CRM de um distribuidor de perfumes.'" \
  --profile "${PROFILE}"
