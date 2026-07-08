import 'dotenv/config';
import express from 'express';
import { router as keyBindingRouter } from './routes/keyBinding.js';
import { router as messagesRouter } from './routes/messages.js';

const app = express();
app.use(express.json());
app.use(keyBindingRouter);
app.use(messagesRouter);

app.get('/', (_req, res) => {
  res.json({ status: 'ok', mode: 'e2ee-relay' });
});

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log(`E2EE inbox relay listening on :${port}`);
  console.log('OpenID4VP vp_token/key-binding-JWT verification is MOCKED — see routes/keyBinding.js');
});
