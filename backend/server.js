/**
 * Cobrowse POC — token & session API.
 *
 * Endpoints:
 *   POST /session/create        — клиент (iOS) создаёт сессию, получает код и publisher-токен
 *   POST /agent/join            — агент входит по коду, получает subscriber-токен
 *   POST /session/end           — закрытие сессии (любой стороной)
 *   GET  /session/list          — список активных сессий (для dashboard агентов)
 *   GET  /health                — health check
 *
 * Хранилище: Redis. Ключи:
 *   code:{code}                 — { roomName, customerIdentity, createdAt } TTL 10 мин
 *   session:{roomName}          — { code, status, startedAt, endedAt } TTL 1 час
 *   sessions:active             — Set активных roomName
 */

import express from 'express';
import cors from 'cors';
import rateLimit from 'express-rate-limit';
import { AccessToken, RoomServiceClient } from 'livekit-server-sdk';
import Redis from 'ioredis';
import pino from 'pino';
import pinoHttp from 'pino-http';
import crypto from 'node:crypto';
import 'dotenv/config';

// ---- config ----
const PORT = process.env.PORT || 4000;

// LIVEKIT_URL — URL, который отдаётся клиентам (iOS/web) в ответе.
// Прод: wss://livekit.example.com. Dev: ws://127.0.0.1:7880.
const LIVEKIT_URL = required('LIVEKIT_URL');

// LIVEKIT_INTERNAL_URL — куда сам backend ходит за RoomServiceClient
// (deleteRoom и т.п.). В проде совпадает с LIVEKIT_URL, в dev — другой,
// потому что backend в контейнере, а клиенты на хосте.
// Если не задан — используем LIVEKIT_URL с автоматической конвертацией схемы.
const LIVEKIT_INTERNAL_URL = process.env.LIVEKIT_INTERNAL_URL || toHttpScheme(LIVEKIT_URL);

const API_KEY = required('LIVEKIT_API_KEY');
const API_SECRET = required('LIVEKIT_API_SECRET');
const REDIS_URL = process.env.REDIS_URL || 'redis://127.0.0.1:6379';
const CORS_ORIGIN = process.env.CORS_ORIGIN || '*';

const CODE_TTL_SECONDS = 10 * 60;       // 10 минут на ввод кода агентом
const SESSION_TTL_SECONDS = 60 * 60;    // 1 час максимальная длительность

function required(name) {
  const v = process.env[name];
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}

/**
 * Конвертирует WebSocket URL LiveKit в HTTP URL для RoomServiceClient.
 * wss://foo → https://foo
 * ws://foo  → http://foo
 * https://foo и http://foo остаются как есть.
 */
function toHttpScheme(url) {
  return url.replace(/^wss:/i, 'https:').replace(/^ws:/i, 'http:');
}

/**
 * Строит origin-matcher для cors middleware.
 *
 * Поддерживаемые форматы CORS_ORIGIN:
 *   '*'                       — разрешить всем (не для прода)
 *   'dev'                     — разрешить любой http://localhost:* и http://127.0.0.1:*
 *                               (полезно, потому что Next.js мигрирует по портам)
 *   'https://a.com'           — один origin
 *   'https://a.com,https://b' — несколько через запятую
 *
 * Возвращает функцию, которую передаём в cors({ origin: fn }).
 */
function buildOriginMatcher(spec) {
  if (spec === '*') {
    return (_origin, cb) => cb(null, true);
  }

  const devLocalhost = /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

  const list = spec
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  return (origin, cb) => {
    // Запросы без Origin (curl, iOS URLSession, server-to-server) — пропускаем.
    // CORS вообще не про них — политика применяется только в браузерах.
    if (!origin) return cb(null, true);

    if (list.includes('dev') && devLocalhost.test(origin)) return cb(null, true);
    if (list.includes(origin)) return cb(null, true);

    logger.warn({ origin, allowed: list }, 'CORS: origin rejected');
    cb(new Error(`Origin ${origin} not allowed by CORS`));
  };
}

// ---- deps ----
const logger = pino({ level: process.env.LOG_LEVEL || 'info' });
const redis = new Redis(REDIS_URL);
const roomService = new RoomServiceClient(LIVEKIT_INTERNAL_URL, API_KEY, API_SECRET);

// ---- app ----
const app = express();

// CORS должен идти РАНЬШЕ json-парсера и rate-limit'а,
// чтобы preflight OPTIONS уходил обратно с корректными заголовками
// даже если тело запроса невалидное или лимит превышен.
const corsOptions = {
  origin: buildOriginMatcher(CORS_ORIGIN),
  methods: ['GET', 'POST', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization'],
  credentials: false,
  maxAge: 86400, // кэш preflight на сутки, чтобы не спамить OPTIONS
};
app.use(cors(corsOptions));
// Явный обработчик preflight — некоторые версии express/cors требуют этого,
// когда используется функциональный origin-matcher.
app.options('*', cors(corsOptions));

app.use(express.json({ limit: '32kb' }));
app.use(pinoHttp({ logger }));

// Rate limiting: 30 запросов / минуту с IP. Чтобы код не подбирали брутфорсом.
// skip для OPTIONS — иначе preflight может улететь в 429 и браузер откажет запросу.
const limiter = rateLimit({
  windowMs: 60_000,
  max: 30,
  standardHeaders: true,
  skip: (req) => req.method === 'OPTIONS',
});
app.use(limiter);

// ---- routes ----

app.get('/health', (req, res) => res.json({ ok: true }));

/**
 * Клиент (iOS) создаёт новую cobrowse-сессию.
 * Request: { customerId?: string }   — необязательный ID для аудита
 * Response: { code, roomName, livekitUrl, token, expiresIn }
 */
app.post('/session/create', async (req, res) => {
  try {
    const customerId = req.body.customerId || `anon-${crypto.randomUUID().slice(0, 8)}`;
    const roomName = `cobrowse-${crypto.randomUUID()}`;
    const code = generateCode();

    // Сохраняем mapping code → room в Redis с TTL
    await redis.setex(
      `code:${code}`,
      CODE_TTL_SECONDS,
      JSON.stringify({ roomName, customerId, createdAt: Date.now() })
    );

    // Сохраняем сессию для dashboard
    await redis.setex(
      `session:${roomName}`,
      SESSION_TTL_SECONDS,
      JSON.stringify({ code, customerId, status: 'waiting', startedAt: Date.now() })
    );
    await redis.sadd('sessions:active', roomName);

    // JWT для клиента: publish-only
    const token = new AccessToken(API_KEY, API_SECRET, {
      identity: customerId,
      name: 'Customer',
      ttl: SESSION_TTL_SECONDS,
    });
    token.addGrant({
      room: roomName,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,  // нужен для приёма аудио агента + data-канала
      canPublishData: true,
    });

    logger.info({ roomName, code, customerId }, 'session created');

    res.json({
      code: formatCode(code),
      roomName,
      livekitUrl: LIVEKIT_URL,
      token: await token.toJwt(),
      expiresIn: CODE_TTL_SECONDS,
    });
  } catch (err) {
    logger.error({ err }, 'session/create failed');
    res.status(500).json({ error: 'internal' });
  }
});

/**
 * Агент входит в сессию по 6-значному коду.
 * Request:  { code: string, agentId: string }
 * Response: { roomName, livekitUrl, token, customerId }
 */
app.post('/agent/join', async (req, res) => {
  try {
    const code = String(req.body.code || '').replace(/[^0-9]/g, '');
    const agentId = String(req.body.agentId || '').slice(0, 64);
    if (code.length !== 6 || !agentId) return res.status(400).json({ error: 'invalid params' });

    const raw = await redis.get(`code:${code}`);
    if (!raw) return res.status(404).json({ error: 'code not found or expired' });

    const { roomName, customerId } = JSON.parse(raw);

    // Код одноразовый — удаляем сразу, чтобы повторный ввод не работал
    await redis.del(`code:${code}`);

    // Обновляем статус сессии
    const sessionRaw = await redis.get(`session:${roomName}`);
    if (sessionRaw) {
      const session = JSON.parse(sessionRaw);
      session.status = 'active';
      session.agentId = agentId;
      session.agentJoinedAt = Date.now();
      await redis.setex(`session:${roomName}`, SESSION_TTL_SECONDS, JSON.stringify(session));
    }

    const token = new AccessToken(API_KEY, API_SECRET, {
      identity: agentId,
      name: 'Agent',
      ttl: SESSION_TTL_SECONDS,
    });
    token.addGrant({
      room: roomName,
      roomJoin: true,
      canPublish: true,   // голос + data-канал для аннотаций
      canSubscribe: true,
      canPublishData: true,
    });

    logger.info({ roomName, agentId, customerId }, 'agent joined');

    res.json({
      roomName,
      livekitUrl: LIVEKIT_URL,
      token: await token.toJwt(),
      customerId,
    });
  } catch (err) {
    logger.error({ err }, 'agent/join failed');
    res.status(500).json({ error: 'internal' });
  }
});

/**
 * Завершить сессию.
 * Request: { roomName: string }
 */
app.post('/session/end', async (req, res) => {
  try {
    const roomName = String(req.body.roomName || '');
    if (!roomName.startsWith('cobrowse-')) return res.status(400).json({ error: 'invalid roomName' });

    // Закрыть на LiveKit (выкинет всех участников)
    await roomService.deleteRoom(roomName).catch((err) => {
      logger.warn({ err, roomName }, 'deleteRoom failed (room may already be gone)');
    });

    // Обновить статус в Redis
    const sessionRaw = await redis.get(`session:${roomName}`);
    if (sessionRaw) {
      const session = JSON.parse(sessionRaw);
      session.status = 'ended';
      session.endedAt = Date.now();
      await redis.setex(`session:${roomName}`, SESSION_TTL_SECONDS, JSON.stringify(session));
    }
    await redis.srem('sessions:active', roomName);

    logger.info({ roomName }, 'session ended');
    res.json({ ok: true });
  } catch (err) {
    logger.error({ err }, 'session/end failed');
    res.status(500).json({ error: 'internal' });
  }
});

/**
 * Список активных сессий (для агентского dashboard).
 */
app.get('/session/list', async (req, res) => {
  try {
    const roomNames = await redis.smembers('sessions:active');
    const sessions = await Promise.all(
      roomNames.map(async (roomName) => {
        const raw = await redis.get(`session:${roomName}`);
        return raw ? { roomName, ...JSON.parse(raw) } : null;
      })
    );
    res.json({ sessions: sessions.filter(Boolean) });
  } catch (err) {
    logger.error({ err }, 'session/list failed');
    res.status(500).json({ error: 'internal' });
  }
});

// ---- utils ----

/** Генерирует 6-значный код. Использует crypto, без modulo bias. */
function generateCode() {
  const n = crypto.randomInt(0, 1_000_000);
  return String(n).padStart(6, '0');
}

/** Форматирует код в "123-456" для UX. */
function formatCode(code) {
  return `${code.slice(0, 3)}-${code.slice(3)}`;
}

// ---- start ----
app.listen(PORT, () => {
  logger.info(
    { port: PORT, livekitUrl: LIVEKIT_URL, livekitInternalUrl: LIVEKIT_INTERNAL_URL },
    'token server started'
  );
});
