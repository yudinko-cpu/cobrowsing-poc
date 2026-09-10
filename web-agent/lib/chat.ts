/**
 * Чат поддержки — модель сообщения, «печатает» и хелперы поверх протокола аннотаций.
 *
 * Едет тем же LiveKit data-топиком (`ANNO_TOPIC`) и тем же конвертом `AnnoMsg`,
 * что клики/штрихи/стрелки:
 *   • `op: 'chat'`   — сообщение: `id` + `text`;
 *   • `op: 'typing'` — «печатает»: `typing: true` (heartbeat) | `false` (перестал).
 * Оба — не состояние аннотаций (в `apply()` — no-op) и не входят в
 * `sync-state`: истории нет by design, всё живёт в памяти одной сессии.
 *
 * Зеркало iOS-стороны — `ios/CobrowseTestApp/sdk/ChatStore.swift`
 * (санитизация, ключ дедупа, троттлинг и TTL «печатает» обязаны совпадать).
 */

import { ANNO_VERSION, clampChatText, type AnnoMsg, type Op } from './anno';

/** Ops чата — не аннотации; AnnotationOverlay пропускает их до гейта прав. */
const CHAT_OPS: ReadonlySet<Op> = new Set<Op>(['chat', 'typing']);

export function isChatOp(op: Op): boolean {
  return CHAT_OPS.has(op);
}

// ── Сообщения ────────────────────────────────────────────────────────────────

/** Сообщение чата в сторе (уже провалидированное). */
export interface ChatMessage {
  /**
   * Ключ дедупа `${author}|${id}`. author — аутентифицированная identity
   * отправителя, id — из payload. Голый `id` не годится: у телефона id вида
   * `client:N`, и подделанный `id` не должен глушить чужое сообщение.
   */
  key: string;
  author: string;
  text: string;
  ts: number;
}

/**
 * Валидатор входящего `chat`. null — не chat / пустой текст после trim.
 * Автор берётся из identity отправителя (анти-спуфинг, как у аннотаций);
 * `payload.author` — только fallback, когда транспорт identity не дал.
 */
export function chatFromMsg(msg: AnnoMsg, senderIdentity?: string): ChatMessage | null {
  if (msg.op !== 'chat') return null;
  const text = clampChatText(typeof msg.text === 'string' ? msg.text : '');
  if (!text) return null;
  const author = senderIdentity || msg.author;
  const id = msg.id ?? String(msg.ts);
  return { key: `${author}|${id}`, author, text, ts: msg.ts };
}

/** Собрать исходящее сообщение. null — после trim пусто (нечего слать). */
export function makeChatMsg(author: string, id: string, raw: string, ts = Date.now()): AnnoMsg | null {
  const text = clampChatText(raw);
  if (!text) return null;
  return { v: ANNO_VERSION, op: 'chat', author, ts, id, text };
}

// ── «Печатает» ───────────────────────────────────────────────────────────────

/** Отправитель: heartbeat `typing: true` не чаще этого интервала (мс). */
export const TYPING_HEARTBEAT_MS = 2000;

/**
 * Получатель: без нового heartbeat индикатор гаснет через это время (мс).
 * Считается по ЛОКАЛЬНЫМ часам получателя (момент приёма), а не по `ts`
 * отправителя — рассинхрон часов телефона и браузера не должен ломать TTL.
 */
export const TYPING_TTL_MS = 5000;

export interface TypingEvent {
  author: string;
  typing: boolean;
  ts: number;
}

/** Валидатор входящего `typing`. Автор — из identity отправителя (анти-спуфинг). */
export function typingFromMsg(msg: AnnoMsg, senderIdentity?: string): TypingEvent | null {
  if (msg.op !== 'typing') return null;
  return { author: senderIdentity || msg.author, typing: msg.typing === true, ts: msg.ts };
}

export function makeTypingMsg(author: string, typing: boolean, ts = Date.now()): AnnoMsg {
  return { v: ANNO_VERSION, op: 'typing', author, ts, typing };
}

/**
 * Отправитель «печатает»: решает, что слать при изменении черновика.
 *   • черновик непустой: `true` сразу при первом символе, дальше — не чаще
 *     TYPING_HEARTBEAT_MS (если heartbeat'ы кончились, получатель гасит по TTL);
 *   • черновик опустел: один `false`;
 *   • после отправки сообщения — reset(): получатели снимут индикатор по самому
 *     `chat`, отдельный `false` не нужен.
 * Зеркало Swift `TypingTracker` в ChatStore.swift.
 */
export class TypingTracker {
  private announced = false;
  private lastSent = 0;
  private readonly heartbeatMs: number;

  constructor(heartbeatMs = TYPING_HEARTBEAT_MS) {
    this.heartbeatMs = heartbeatMs;
  }

  /** true — слать heartbeat, false — слать «перестал», null — слать нечего. */
  onDraftChange(nonEmpty: boolean, now = Date.now()): boolean | null {
    if (nonEmpty) {
      if (!this.announced || now - this.lastSent >= this.heartbeatMs) {
        this.announced = true;
        this.lastSent = now;
        return true;
      }
      return null;
    }
    if (!this.announced) return null;
    this.announced = false;
    this.lastSent = 0;
    return false;
  }

  reset(): void {
    this.announced = false;
    this.lastSent = 0;
  }
}
