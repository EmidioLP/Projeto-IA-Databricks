import { useEffect, useState } from 'react';
import { GenieChat, Badge, Alert, AlertDescription } from '@databricks/appkit-ui/react';

interface QuemSouResponse {
  email: string | null;
}

export function PerguntarPage() {
  const [email, setEmail] = useState<string | null>(null);
  const [erroIdentidade, setErroIdentidade] = useState(false);

  useEffect(() => {
    fetch('/api/quem-sou')
      .then((r) => (r.ok ? (r.json() as Promise<QuemSouResponse>) : Promise.reject(new Error('quem-sou failed'))))
      .then((d) => setEmail(d.email))
      .catch(() => setErroIdentidade(true));
  }, []);

  return (
    <div className="space-y-4 w-full max-w-4xl mx-auto">
      <div className="flex items-center justify-between flex-wrap gap-2">
        <div>
          <h2 className="text-2xl font-bold text-foreground">Perguntar</h2>
          <p className="text-sm text-muted-foreground mt-1">
            Para o que não estava previsto na tela &ldquo;A semana&rdquo;.
          </p>
        </div>
        {email && <Badge variant="secondary">{email}</Badge>}
      </div>

      {erroIdentidade && (
        <Alert variant="destructive">
          <AlertDescription>Não foi possível identificar o usuário logado.</AlertDescription>
        </Alert>
      )}

      <p className="text-xs text-muted-foreground">
        Resposta gerada por IA a partir dos seus dados — revise o SQL gerado antes de confiar no
        número. A consulta roda com as suas próprias permissões (autorização do usuário), não com
        as do app.
      </p>

      <div className="h-[min(600px,70vh)] border rounded-lg overflow-hidden">
        <GenieChat alias="default" />
      </div>
    </div>
  );
}
