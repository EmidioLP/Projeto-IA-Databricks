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
  `rotaperfume`, em três trilhas: `engenharia-de-dados/` (as seis entregas
  abaixo), `ciencia-de-dados/` (features, modelo e fila) e `app-e-genie/`
  (em andamento, fechando o loop entre a fila e o time comercial).

## Progresso

O pipeline foi construído em seis entregas incrementais, uma por aula — está completo:

- [x] **Raw** — catálogo, schemas e Volume do Unity Catalog como código; os 10
  CSVs sobem para o Volume; uma tarefa confere que todos chegaram.
- [x] **Bronze** — as 10 tabelas Delta da bronze, ingeridas sem nenhuma
  limpeza ou conversão de tipo (a sujeira da origem é preservada de propósito).
- [x] **Silver** — as 10 tabelas limpas e tipadas: CNPJ normalizado e
  deduplicado, datas convertidas, devolução/cancelamento/vendedor-desligado
  como colunas explícitas (nada é descartado) e regras de qualidade viradas
  `CHECK CONSTRAINT` na própria tabela.
- [x] **Gold** — dimensões conformadas, `fato_vendas` no grão de item de
  pedido (devolução dentro, cancelamento fora), três data marts por
  diretoria e 9 testes de qualidade que derrubam o job (`raise_error`) se a
  receita da gold não bater com a da silver, centavo a centavo.
- [x] **Dashboard** — o dashboard AI/BI comercial (KPIs, receita por mês,
  marcas, margem por categoria, canal, top clientes) versionado como
  `.lvdash.json` e declarado como recurso do bundle, subindo junto com o
  deploy — sem clicar na UI.
- [x] **Agentes de IA** — seis views com nome de negócio (`ranking_marcas`,
  `clientes_em_risco`, etc.) com `COMMENT` respondendo à pergunta que cada
  uma resolve, uma auditoria que derruba o job se faltar metadado, e um
  Genie space como código (instruções de negócio, glossário e a regra de
  sazonalidade do setor) apontando para a gold — não mais para a bronze.

Uma segunda trilha, de ciência de dados, começou a ser construída em cima
dessa gold:

- [x] **Features** — `gold.features_treino` e `gold.features_cliente`,
  geradas pela mesma função `montar_features(referencia)` com datas de corte
  diferentes: 20 features de RFM, ritmo de compra, CRM e mix de produto, cada
  fonte filtrada por `< referencia` para nunca vazar dado do futuro para o
  treino. `gold.dim_cliente` nunca entra aqui, porque agrega o histórico
  inteiro sem corte.
- [x] **Modelo** — um `HistGradientBoostingClassifier` treinado em cima das
  features acima, medido contra três baselines de regra simples (o melhor
  vira o gate 1) e três testes que derrubam a tarefa (o modelo tem que bater
  o melhor baseline por 0,05 de AUC, AUC abaixo de 0,99 — bom demais é
  vazamento — e lift acima de 2,5 nos 200 primeiros da fila). Registrado no
  Unity Catalog (`gold.propensao_compra`, alias `@prod`) só depois de passar
  nos três testes, e usado para gravar `gold.score_propensao` (score e faixa
  por cliente), `gold.modelo_metricas` (histórico de treinos) e
  `gold.calibragem_holdout` (prova de que a taxa de compra sobe da faixa fria
  para a quente, sem precisar entender o que é AUC).
- [x] **Fila e agente** — `gold.fila_semanal`: os 200 clientes elegíveis
  (carteira vigente, vendedor ativo) com maior score, priorizados
  globalmente e numerados por vendedor — nunca por cota igual —, com motivo
  e sugestão de produto em português. Mais quatro funções SQL no Unity
  Catalog (`priorizar_carteira`, `contexto_cliente`, `sugerir_produtos`,
  `checar_disponibilidade`) que um agente consulta, uma página nova no
  dashboard e o Genie Space atualizado para nunca inventar número, nome de
  cliente ou quantidade de estoque.

Uma terceira trilha, app e genie, começou a fechar o loop entre a fila e o
time comercial:

- [x] **Retorno da ligação** — `gold.retorno_ligacao`: a única tabela do
  projeto cujo dado vem do time comercial, não do pipeline
  (`CREATE TABLE IF NOT EXISTS`, nunca `CREATE OR REPLACE` — um redeploy não
  pode apagar o que já foi registrado). E um segundo Genie space, "Rota do
  Perfume - Direção", com só 7 fontes e instruções escritas para UMA decisão
  (ligar ou não): nunca cita AUC (a métrica é `lift_top200`), e sempre avisa
  quando a fila ainda não tem retorno registrado em vez de inventar número.

Detalhes de arquitetura e comandos de desenvolvimento estão em
[`CLAUDE.md`](CLAUDE.md) e em [`rotaperfume/README.md`](rotaperfume/README.md).

## Créditos

Aula ao vivo do canal [Jornada de Dados](https://www.youtube.com/@JornadaDeDados),
com roteiro original em [lvgalvao/projeto-dados-ia-databricks](https://github.com/lvgalvao/projeto-dados-ia-databricks.git).
