import { createApp, analytics, genie, server } from '@databricks/appkit';

createApp({
  plugins: [analytics(), genie(), server()],
  onPluginsReady(appkit) {
    appkit.server.extend((app) => {
      // Quem está logado, para mostrar na aba "Perguntar". O header
      // x-forwarded-email é injetado pela plataforma Databricks Apps.
      app.get('/api/quem-sou', (req, res) => {
        res.json({ email: req.header('x-forwarded-email') ?? null });
      });
    });
  },
}).catch(console.error);
