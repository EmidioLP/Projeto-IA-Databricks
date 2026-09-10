# Projeto IA Databricks

Repositório de estudos, construído acompanhando a aula de Engenharia de Dados
da [Jornada de Dados](https://github.com/lvgalvao/projeto-dados-ia-databricks.git).
Usado apenas para fins de estudo e portfólio — não é um projeto em produção.

## O que tem aqui

- **`datasets/`** — dados fonte (CSV) de um distribuidor de perfumes fictício,
  separados em dois sistemas de origem: `erp/` (produtos, pedidos, itens de
  pedido, pagamentos, estoque) e `crm/` (clientes, vendedores, carteira,
  oportunidades, visitas).
- **`rotaperfume/`** — o projeto principal: um [Databricks Asset Bundle](https://docs.databricks.com/dev-tools/bundles/index.html)
  que sobe esses CSVs para o Unity Catalog e constrói um pipeline em camadas
  (raw → bronze → silver → gold), tudo como código.
- **`.llm/`** — os roteiros de aula (prompts) que guiaram cada entrega do
  `rotaperfume`.

## Progresso

O pipeline é construído em seis entregas. Feito até agora:

- [x] **Raw** — catálogo, schemas e Volume do Unity Catalog como código; os 10
  CSVs sobem para o Volume; uma tarefa confere que todos chegaram.
- [x] **Bronze** — as 10 tabelas Delta da bronze, ingeridas sem nenhuma
  limpeza ou conversão de tipo (a sujeira da origem é preservada de propósito).
- [ ] **Silver** — modelagem: tipos corretos, chaves conferidas.
- [ ] **Silver (qualidade)** — checagens de qualidade sobre a silver.
- [ ] **Gold** — métricas e agregados de negócio.
- [ ] **Gold (publicação)** — o que fica pronto para dashboard/consumo.

Detalhes de arquitetura e comandos de desenvolvimento estão em
[`CLAUDE.md`](CLAUDE.md) e em [`rotaperfume/README.md`](rotaperfume/README.md).

## Créditos

Aula e roteiro original da Jornada de Dados: [lvgalvao/projeto-dados-ia-databricks](https://github.com/lvgalvao/projeto-dados-ia-databricks.git).
