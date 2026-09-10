# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository overview

This repo has two parts:

- `datasets/` — static raw source CSVs for a fictional perfume distributor, split into two source systems (`erp/`, `crm/`). This is the "raw" data the rest of the project ingests.
- `rotaperfume/` — a Databricks Asset Bundle (DAB) project that will ingest, validate, and transform those CSVs on Databricks. It was scaffolded from Databricks' `default-python` bundle template and is currently a bare skeleton: `src/` and `resources/` are empty, `fixtures/` only has a `.gitkeep`. It gets built out incrementally — see "Planned pipeline" below.

`.llm/prompt01.md` is a lesson script (in Portuguese) for a course this repo supports, describing the first of six planned deliveries for the `rotaperfume` bundle. Treat it as a design reference for where the project is headed, not as ground truth for the current state of `rotaperfume/databricks.yml` (see Discrepancies below) — names/paths there sometimes differ from what's actually in this repo.

## Commands

Run from `rotaperfume/` (the bundle root):

```bash
uv sync --dev                                                        # install deps (Python 3.12 pinned via requires-python)
uv run pytest                                                        # run tests (spins up a DatabricksSession via Databricks Connect — needs auth)
uv run ruff check .                                                  # lint (line-length = 120)

databricks bundle validate --target dev --profile <profile>
databricks bundle deploy   --target dev --profile <profile>          # target dev is the default
databricks bundle run <resource-name> --target dev --profile <profile>
```

Configured CLI profiles (in `.databrickscfg`): `DEFAULT`, `Lolpes`, `jornadaaovivo`, `jornada`. **Always pass `--profile` explicitly** on Databricks CLI/bundle commands in this repo — never rely on the implicit default profile.

For any Databricks CLI/bundle/auth work, load the `databricks-core` skill first (both `rotaperfume/AGENTS.md`, which `rotaperfume/CLAUDE.md` imports, and the `.databricks/aitools` install say the same thing) — it drives profile selection and the deploy workflow for this project.

## Datasets

Two source systems, all CSV, under `datasets/<system>/`:

**erp/** — `produtos`, `pedidos` (FK `cliente_id`, `vendedor_id`), `itens_pedido` (FK `pedido_id`, `sku` — the largest file, ~197k rows), `pagamentos` (FK `pedido_id`), `estoque` (FK `sku`).

**crm/** — `clientes`, `vendedores`, `carteira` (cliente↔vendedor assignment over time, FK `cliente_id`, `vendedor_id`), `oportunidades` (sales pipeline, FK `cliente_id`, `vendedor_id`), `visitas` (FK `cliente_id`, `vendedor_id` — second largest file, ~38k rows).

`sku` and `pedido_id`/`cliente_id`/`vendedor_id` are the join keys tying the two systems together.

## Planned pipeline (from `.llm/prompt01.md`)

The bundle builds a medallion-style Unity Catalog layout, entirely as code:

- **Catalog** (`lakehouse_rotaperfume` per current `databricks.yml`, `variables.catalog`) with schemas `bronze`, `silver`, `gold`, defined as a bundle resource (`resources/catalogo.yml`) — *except catalog creation itself*, which must go through a raw SQL script (`scripts/criar-catalogo.sh`, via `databricks experimental aitools tools query`), not a bundle resource. Reason: on Free Edition with Default Storage enabled, the Unity Catalog API refuses `CREATE CATALOG` without a managed location (`Metastore storage root URL does not exist`), but the SQL path works.
- **Raw layer**: the 10 CSVs get uploaded to a managed Volume (`bronze.raw`) via `databricks fs cp --recursive --overwrite` (destination needs the `dbfs:` scheme even though it's a UC Volume, e.g. `dbfs:/Volumes/<catalog>/bronze/raw/erp`). Raw ≠ bronze: raw is the untouched file in the Volume, bronze is the first table.
- **Arrival check**: a serverless notebook (`src/raw/conferencia.py`) validates all 10 expected files landed and are non-empty, then records byte/row counts into a `bronze._raw_arquivos` control table. This runs as the first task (`raw_conferencia`) of a scheduled job `rotaperfume_pipeline` (`resources/pipeline.job.yml`), meant to grow one task per subsequent delivery.
- **Gotcha**: don't set `mode: development` on the `dev` target for this project — it prefixes Unity Catalog schema names (`dev_<user>_bronze`), which breaks all the SQL written against `bronze`/`silver`/`gold`. Pause scheduling explicitly instead via `presets: { trigger_pause_status: PAUSED }`.

### Discrepancies vs. the current scaffold

- `.llm/prompt01.md` refers to a `projeto-dados-ia` profile and a `dados/erp` / `dados/crm` source path — this repo instead has the configured profiles above and puts the source CSVs at `datasets/erp` / `datasets/crm`. Adapt names accordingly when implementing.
- The current `rotaperfume/databricks.yml` (freshly scaffolded, unmodified) still has `mode: development` on the `dev` target — that needs to change to the `trigger_pause_status: PAUSED` approach described above before the catalog/schema resources are added, per the gotcha.
