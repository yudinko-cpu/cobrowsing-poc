/**
 * Клиент к token-server backend'у.
 *
 * NEXT_PUBLIC_API_URL инжектится Next.js на этапе сборки — если он не задан,
 * process.env.NEXT_PUBLIC_API_URL === undefined и все fetch'и уходят в
 * "undefined/session/list" → относительно текущей страницы → на порт web-agent'а.
 * Отсюда классический баг «стучится не туда».
 *
 * Тут ловим этот случай явно: возвращаем dev-дефолт и пишем warning.
 */

const DEV_DEFAULT_API_URL = 'http://127.0.0.1:4000';

function warnDefault(reason: string): string {
  // eslint-disable-next-line no-console
  console.error(
    `[api] NEXT_PUBLIC_API_URL ${reason}. Использую dev-дефолт ${DEV_DEFAULT_API_URL}. ` +
      `Проверьте web-agent/.env.local: URL должен быть "http://host:port" ` +
      `(например, http://127.0.0.1:4000) — без лишних двоеточий, слэшей и пробелов. ` +
      `После правки — рестарт \`npm run dev\` (hot reload NEXT_PUBLIC_* не подхватывает).`
  );
  return DEV_DEFAULT_API_URL;
}

function resolveApiUrl(): string {
  const envUrl = (process.env.NEXT_PUBLIC_API_URL ?? '').trim();

  // Случай 1: не задано.
  if (envUrl.length === 0) {
    return warnDefault('не задан');
  }

  // Случай 2: не парсится URL constructor'ом.
  // Типичные опечатки: "http://localhost::3000" (лишнее двоеточие).
  let parsed: URL;
  try {
    parsed = new URL(envUrl);
  } catch {
    return warnDefault(`= "${envUrl}" — не парсится`);
  }

  // Случай 3: парсится, но невалиден семантически.
  // Node's URL слишком либерален: "localhost:3000" считает валидным (localhost — схема),
  // "http:/localhost:3000" тоже проходит. Явно требуем http/https + непустой hostname.
  if (!/^https?:$/.test(parsed.protocol)) {
    return warnDefault(
      `= "${envUrl}" — нужна схема http:// или https:// (получено "${parsed.protocol}")`
    );
  }
  if (!parsed.hostname) {
    return warnDefault(`= "${envUrl}" — пустой hostname`);
  }

  // Нормализованная база: только протокол + host (host включает порт если есть).
  // Отбрасывает случайные пути, query, fragment, trailing slashes.
  return `${parsed.protocol}//${parsed.host}`;
}

export const API_URL = resolveApiUrl();

/**
 * Тонкая обёртка над fetch — префиксует API_URL и парсит JSON-ошибки в throw.
 * По умолчанию Content-Type: application/json (можно переопределить через init.headers).
 */
export async function apiFetch<T = unknown>(
  path: string,
  init?: RequestInit
): Promise<T> {
  const url = `${API_URL}${path.startsWith('/') ? path : `/${path}`}`;
  const r = await fetch(url, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(init?.headers || {}),
    },
  });
  if (!r.ok) {
    const body = (await r.json().catch(() => ({}))) as { error?: string };
    throw new Error(body.error || `HTTP ${r.status}`);
  }
  return (await r.json()) as T;
}
