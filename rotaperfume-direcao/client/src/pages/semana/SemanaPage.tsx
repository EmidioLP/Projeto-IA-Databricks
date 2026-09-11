import { useMemo, useState } from 'react';
import {
  useAnalyticsQuery,
  DataTable,
  Card,
  CardContent,
  CardHeader,
  CardTitle,
  Skeleton,
  Alert,
  AlertDescription,
  Label,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@databricks/appkit-ui/react';
import { sql } from '@databricks/appkit-ui/js';
import type { QueryRegistry } from '@databricks/appkit-ui/react';
import { formatBRL, formatPercentInteiro, formatPercent1Casa } from '../../lib/formatters';

type FilaRow = QueryRegistry['fila']['result'][number];

const EMPTY_PARAMS = {};
const TODOS = 'todos';

export function SemanaPage() {
  const kpis = useAnalyticsQuery('kpis_semana', EMPTY_PARAMS);
  const vendedoresQuery = useAnalyticsQuery('vendedores', EMPTY_PARAMS);
  const [vendedorSelecionado, setVendedorSelecionado] = useState<string>(TODOS);

  const vendedorParam = vendedorSelecionado === TODOS ? 'Todos' : vendedorSelecionado;
  const filaParams = useMemo(() => ({ vendedor: sql.string(vendedorParam) }), [vendedorParam]);

  return (
    <div className="space-y-6 w-full max-w-6xl mx-auto">
      <div>
        <h2 className="text-2xl font-bold text-foreground">A semana</h2>
        <p className="text-sm text-muted-foreground mt-1">
          Os 200 contatos priorizados desta semana, com o retorno já registrado pelo time.
        </p>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <Card>
          <CardHeader>
            <CardTitle className="text-sm text-muted-foreground font-medium">Contatos da semana</CardTitle>
          </CardHeader>
          <CardContent>
            {kpis.loading && <Skeleton className="h-8 w-2/3" />}
            {kpis.error && (
              <Alert variant="destructive">
                <AlertDescription>Não foi possível carregar.</AlertDescription>
              </Alert>
            )}
            {kpis.data?.[0] && (
              <>
                <div className="text-3xl font-bold text-foreground">{Number(kpis.data[0].contatos)}</div>
                <p className="text-xs text-muted-foreground mt-1">
                  {Number(kpis.data[0].vendedores)} vendedores
                </p>
              </>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-sm text-muted-foreground font-medium">Receita esperada</CardTitle>
          </CardHeader>
          <CardContent>
            {kpis.loading && <Skeleton className="h-8 w-2/3" />}
            {kpis.error && (
              <Alert variant="destructive">
                <AlertDescription>Não foi possível carregar.</AlertDescription>
              </Alert>
            )}
            {kpis.data?.[0] && (
              <>
                <div className="text-3xl font-bold text-foreground">
                  {formatBRL(kpis.data[0].receita_esperada)}
                </div>
                <p className="text-xs text-muted-foreground mt-1">
                  Estimativa (score × ticket médio) — não é receita realizada
                </p>
              </>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-sm text-muted-foreground font-medium">Conversão prevista</CardTitle>
          </CardHeader>
          <CardContent>
            {kpis.loading && <Skeleton className="h-8 w-2/3" />}
            {kpis.error && (
              <Alert variant="destructive">
                <AlertDescription>Não foi possível carregar.</AlertDescription>
              </Alert>
            )}
            {kpis.data?.[0] && (
              <>
                <div className="text-3xl font-bold text-foreground">
                  {formatPercentInteiro(Number(kpis.data[0].acertos_top200) / Number(kpis.data[0].contatos))}
                </div>
                <p className="text-xs text-muted-foreground mt-1">
                  contra {formatPercent1Casa(kpis.data[0].taxa_base)} às cegas (lift {Number(kpis.data[0].lift_top200).toFixed(2)}×)
                </p>
              </>
            )}
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="text-sm text-muted-foreground font-medium">Já trabalhados</CardTitle>
          </CardHeader>
          <CardContent>
            {kpis.loading && <Skeleton className="h-8 w-2/3" />}
            {kpis.error && (
              <Alert variant="destructive">
                <AlertDescription>Não foi possível carregar.</AlertDescription>
              </Alert>
            )}
            {kpis.data?.[0] && (
              <>
                <div className="text-3xl font-bold text-foreground">{Number(kpis.data[0].ja_trabalhados)}</div>
                <p className="text-xs text-muted-foreground mt-1">
                  {Number(kpis.data[0].viraram_pedido)} viraram pedido
                </p>
              </>
            )}
          </CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <CardTitle>Fila de ligação</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <div className="max-w-xs space-y-2">
            <Label htmlFor="vendedor">Vendedor</Label>
            <Select value={vendedorSelecionado} onValueChange={setVendedorSelecionado}>
              <SelectTrigger id="vendedor">
                <SelectValue placeholder="Todos os vendedores" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={TODOS}>Todos os vendedores</SelectItem>
                {vendedoresQuery.data?.map((v) => (
                  <SelectItem key={v.vendedor} value={v.vendedor}>
                    {v.vendedor} ({Number(v.contatos)})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <DataTable
            queryKey="fila"
            parameters={filaParams}
            pageSize={25}
            pageSizeOptions={[25, 50, 100]}
            labels={{
              noResults:
                'A fila é global, não por cota: nenhum contato deste vendedor entrou no top 200 desta semana.',
            }}
            transform={(data: FilaRow[]) =>
              data.map((row) => ({
                ordem: row.ordem,
                cliente: `${row.razao_social} — ${row.cidade}/${row.uf} — ${formatBRL(row.ticket_medio)}`,
                vendedor: row.vendedor,
                chance: formatPercentInteiro(row.score),
                motivo: row.motivo,
                sugestao: row.sugestao ?? '—',
              }))
            }
          />
        </CardContent>
      </Card>
    </div>
  );
}
