/**
 * Чат поддержки — модель сообщения и хелперы поверх протокола аннотаций.
 *
 * Едет тем же LiveKit data-топиком (`ANNO_TOPIC`) и тем же конвертом `AnnoMsg`,
 * что клики/штрихи/стрелки: `op: 'chat'`, полезная нагрузка — `id` + `text`.
 * Чат НЕ является состоянием аннотаций (в `apply()` — no-op) и не входит в
 * `sync-state`: истории нет by design, всё живёт в памяти одной сессии.
 *
 * Зеркало iOS-стороны — `ios/CobrowseTestApp/sdk/ChatStore.swift`
 * (санитизация и ключ дедупа обязаны совпадать).
 */

import { ANNO_VERSION, clampChatText, type AnnoMsg } from './anno';

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
