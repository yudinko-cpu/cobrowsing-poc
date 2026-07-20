/**
 * Конфиг Next.js для web-agent.
 *
 * output: 'standalone' — ключевая настройка для размера прод-образа и скорости CI.
 * Next трассирует реальные зависимости рантайма и складывает в `.next/standalone`
 * самодостаточный сервер (`server.js` + минимальный node_modules). Прод-образу
 * больше не нужен весь `node_modules` из сборки, куда `npm ci` тянет и
 * devDependencies (typescript, eslint, @types) — они не нужны на рантайме.
 *
 * Эффект: финальный слой образа падает в разы → быстрее `exporting layers`,
 * push в GHCR и экспорт кэша в GitHub Actions.
 *
 * Важно при использовании standalone: `.next/static` и `public/` в него НЕ входят,
 * их копирует Dockerfile отдельно. Порт и хост сервер берёт из env PORT/HOSTNAME.
 */
const nextConfig = {
  output: 'standalone',
};

export default nextConfig;
