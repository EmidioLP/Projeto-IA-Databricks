// O warehouse devolve DECIMAL/BIGINT como string no JSON mesmo quando o tipo
// gerado diz "number" - Number() aqui é obrigatório antes de formatar ou somar.
export const formatBRL = (value: number | string): string =>
  Number(value).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });

export const formatPercentInteiro = (value: number | string): string =>
  `${Math.round(Number(value) * 100)}%`;

export const formatPercent1Casa = (value: number | string): string =>
  `${(Number(value) * 100).toLocaleString('pt-BR', { minimumFractionDigits: 1, maximumFractionDigits: 1 })}%`;
