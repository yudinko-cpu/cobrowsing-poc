/**
 * Cobrowse annotations — общий протокол (web-сторона).
 *
 * Зеркало Swift-модуля `ios/CobrowseTestApp/sdk/Annotation.swift`. Формат на
 * проводе (JSON) обязан совпадать байт-в-байт по ключам, иначе iOS и web не
 * поймут друг друга. Любая правка схемы здесь → синхронная правка в Swift.
 *
 * Слои:
 *   • AnnoMsg   — сообщение на data-канале (topic = ANNO_TOPIC).
 *   • Annotation — сохранённая аннотация в сторе (мёрж входящих ops).
 *   • координаты — нормализованные [0..1] по контент-боксу видео (object-fit:contain).
 *   • цвета     — детерминированы по identity (FNV-1a), палитра идентична Swift.
 *
 * См. docs/annotations-plan.md (§4 координаты, §5 протокол, §6 мульти-юзер).
 */

// ── Константы протокола ──────────────────────────────────────────────────────

/** LiveKit data topic для всех аннотационных сообщений. */
export const ANNO_TOPIC = 'cobrowse.anno';

/** Версия протокола. Ломающие изменения инкрементят это число. */
export const ANNO_VERSION = 1;

/** Максимальная длина текстовой аннотации (символов). Санитизация на приёме. */
export const MAX_TEXT_LEN = 200;

// ── Типы ─────────────────────────────────────────────────────────────────────

export type Op =
  | 'add' // старт аннотации (+ начальная геометрия)
  | 'append' // докинуть геометрию (точки штриха / новый `to` / новый текст)
  | 'end' // финализация (надёжная финальная геометрия)
  | 'remove' // удалить аннотацию по id (в т.ч. реализация Undo)
  | 'clear' // снять все (scope: own | all)
  | 'pointer' // эфемерная лазерная указка
  | 'sync-req' // запрос полного состояния (позднее подключение / реконнект)
  | 'sync-state'; // ответ с полным снапшотом

export type Kind = 'path' | 'arrow' | 'text' | 'shape';
export type ShapeKind = 'rect' | 'ellipse';
export type ClearScope = 'own' | 'all';

/** Нормализованная точка [nx, ny], каждая координата в [0..1]. */
export type Point = [number, number];

/**
 * Сообщение на проводе. Все геометрические поля — в нормализованных координатах.
 * Поля опциональны и присутствуют в зависимости от `op`/`kind`.
 */
export interface AnnoMsg {
  v: number;
  op: Op;
  author: string; // participant identity (дубль к LiveKit sender для устойчивости)
  ts: number;
  id?: string; // "author:counter" — для add/append/end/remove
  kind?: Kind; // для add
  color?: string; // hex, напр. "#ff375f"
  w?: number; // нормализованная толщина линии (доля короткой стороны контента)
  pts?: Point[]; // path: точки (add — начальные, append — новый батч)
  from?: Point; // arrow/shape: первый угол
  to?: Point; // arrow/shape: второй угол
  at?: Point; // text/pointer: точка
  text?: string; // text
  size?: number; // text: нормализованный кегль
  shape?: ShapeKind; // shape: rect | ellipse
  fill?: boolean; // shape: полупрозрачная заливка
  scope?: ClearScope; // clear
  items?: Annotation[]; // sync-state: полный снапшот
}

/** Сохранённая аннотация в сторе (персистентная, без эфемерных указок). */
export interface Annotation {
  id: string;
  author: string;
  kind: Kind;
  color: string;
  ts: number;
  w?: number;
  pts?: Point[];
  from?: Point;
  to?: Point;
  at?: Point;
  text?: string;
  size?: number;
  shape?: ShapeKind;
  fill?: boolean;
}

/** Эфемерная указка одного оператора. */
export interface Pointer {
  author: string;
  color: string;
  at: Point;
  ts: number;
}

// ── Кодек ────────────────────────────────────────────────────────────────────

const _enc = new TextEncoder();
const _dec = new TextDecoder();

/** Сериализовать сообщение в байты для publishData. */
export function encode(msg: AnnoMsg): Uint8Array {
  return _enc.encode(JSON.stringify(msg));
}

/**
 * Разобрать байты в сообщение. Возвращает null на битом JSON или
 * несовпадении версии — вызывающий молча игнорирует такие пакеты.
 */
export function decode(bytes: Uint8Array): AnnoMsg | null {
  try {
    const obj = JSON.parse(_dec.decode(bytes)) as AnnoMsg;
    if (!obj || typeof obj !== 'object') return null;
    if (obj.v !== ANNO_VERSION) return null;
    if (typeof obj.op !== 'string' || typeof obj.author !== 'string') return null;
    return obj;
  } catch {
    return null;
  }
}

// ── Координаты (letterbox object-fit: contain) ───────────────────────────────

export interface Rect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface ContentRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/**
 * Контент-бокс видео внутри элемента при object-fit: contain.
 * `vidW/vidH` — интринсик-размеры видео (dimensions трека или videoWidth/Height).
 * Возвращает прямоугольник реального контента (без letterbox-полос).
 */
export function contentRect(elem: Rect, vidW: number, vidH: number): ContentRect {
  if (vidW <= 0 || vidH <= 0 || elem.width <= 0 || elem.height <= 0) {
    return { x: elem.left, y: elem.top, w: elem.width, h: elem.height };
  }
  const scale = Math.min(elem.width / vidW, elem.height / vidH);
  const w = vidW * scale;
  const h = vidH * scale;
  return {
    x: elem.left + (elem.width - w) / 2,
    y: elem.top + (elem.height - h) / 2,
    w,
    h,
  };
}

const clamp01 = (v: number) => (v < 0 ? 0 : v > 1 ? 1 : v);

/**
 * Клиентская координата события (clientX/clientY) → нормализованная точка.
 * Возвращает null, если точка вне контент-бокса (клик по letterbox-полосе).
 */
export function toNormalized(
  clientX: number,
  clientY: number,
  rect: ContentRect,
): Point | null {
  if (rect.w <= 0 || rect.h <= 0) return null;
  const nx = (clientX - rect.x) / rect.w;
  const ny = (clientY - rect.y) / rect.h;
  if (nx < 0 || nx > 1 || ny < 0 || ny > 1) return null;
  return [clamp01(nx), clamp01(ny)];
}

/** Нормализованная точка → пиксельная координата внутри контент-бокса. */
export function fromNormalized(nx: number, ny: number, rect: ContentRect): { x: number; y: number } {
  return { x: rect.x + clamp01(nx) * rect.w, y: rect.y + clamp01(ny) * rect.h };
}

// ── Цвета по автору (детерминированно, паритет со Swift) ──────────────────────

/**
 * Палитра из 8 контрастных цветов (= MAX_AGENTS_PER_SESSION). Порядок обязан
 * совпадать со Swift `AnnoColor.palette`, иначе цвет оператора разъедется между
 * web и iOS.
 */
export const PALETTE: readonly string[] = [
  '#ff375f', // красно-розовый
  '#0a84ff', // синий
  '#30d158', // зелёный
  '#ff9f0a', // оранжевый
  '#bf5af2', // фиолетовый
  '#64d2ff', // голубой
  '#ffd60a', // жёлтый
  '#ff6482', // коралловый
];

/**
 * FNV-1a 32-бит по UTF-8 байтам. Реализация обязана совпадать со Swift
 * (та же константа, тот же порядок операций, uint32-обёртка).
 */
export function fnv1a32(s: string): number {
  let hash = 0x811c9dc5; // 2166136261
  const bytes = _enc.encode(s);
  for (let i = 0; i < bytes.length; i++) {
    hash ^= bytes[i];
    // hash * 16777619 в uint32 через Math.imul
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash >>> 0;
}

/** Детерминированный цвет оператора по его identity. */
export function colorForIdentity(identity: string): string {
  return PALETTE[fnv1a32(identity) % PALETTE.length];
}

// ── Состояние и reducer (мёрж входящих ops) ──────────────────────────────────

export interface AnnoState {
  /** Персистентные аннотации по id. */
  items: Map<string, Annotation>;
  /** Эфемерные указки по автору. */
  pointers: Map<string, Pointer>;
}

export function newState(): AnnoState {
  return { items: new Map(), pointers: new Map() };
}

/**
 * Применить входящее сообщение к состоянию (мутирует).
 *
 * Семантика (обязана совпадать со Swift):
 *   • append-only по (author, id); update по id — last-writer-wins.
 *   • clear own — только аннотации/указка автора; all — всё.
 *   • sync-state — мёрж снапшота по id.
 *   • `isAgent` (опц.) — гейт прав: если задан и вернул false, op игнорируется
 *     (клиент писать не может — §6.4). Также автор не может трогать чужие id.
 */
export function apply(
  state: AnnoState,
  msg: AnnoMsg,
  isAgent?: (author: string) => boolean,
): void {
  if (isAgent && !isAgent(msg.author)) return;

  switch (msg.op) {
    case 'add': {
      if (!msg.id || !msg.kind) return;
      state.items.set(msg.id, {
        id: msg.id,
        author: msg.author,
        kind: msg.kind,
        color: msg.color ?? colorForIdentity(msg.author),
        ts: msg.ts,
        w: msg.w,
        pts: msg.pts ? msg.pts.slice() : undefined,
        from: msg.from,
        to: msg.to,
        at: msg.at,
        text: msg.text != null ? clampText(msg.text) : undefined,
        size: msg.size,
        shape: msg.shape,
        fill: msg.fill,
      });
      return;
    }
    case 'append': {
      if (!msg.id) return;
      const a = state.items.get(msg.id);
      if (!a || a.author !== msg.author) return; // нельзя дополнять чужое
      if (a.kind === 'path' && msg.pts) {
        a.pts = (a.pts ?? []).concat(msg.pts);
      }
      if (msg.to) a.to = msg.to; // arrow/shape тянут второй угол
      if (msg.text != null) a.text = clampText(msg.text);
      a.ts = msg.ts;
      return;
    }
    case 'end': {
      if (!msg.id) return;
      const a = state.items.get(msg.id);
      if (!a || a.author !== msg.author) return;
      if (msg.pts) a.pts = msg.pts.slice();
      if (msg.from) a.from = msg.from;
      if (msg.to) a.to = msg.to;
      if (msg.at) a.at = msg.at;
      if (msg.text != null) a.text = clampText(msg.text);
      a.ts = msg.ts;
      return;
    }
    case 'remove': {
      if (!msg.id) return;
      const a = state.items.get(msg.id);
      if (a && a.author === msg.author) state.items.delete(msg.id); // только своё
      return;
    }
    case 'clear': {
      if (msg.scope === 'all') {
        state.items.clear();
        state.pointers.clear();
      } else {
        for (const [id, a] of state.items) if (a.author === msg.author) state.items.delete(id);
        state.pointers.delete(msg.author);
      }
      return;
    }
    case 'pointer': {
      if (!msg.at) return;
      state.pointers.set(msg.author, {
        author: msg.author,
        color: msg.color ?? colorForIdentity(msg.author),
        at: msg.at,
        ts: msg.ts,
      });
      return;
    }
    case 'sync-state': {
      if (!msg.items) return;
      for (const it of msg.items) state.items.set(it.id, it);
      return;
    }
    case 'sync-req':
      // Обрабатывается на транспортном слое (клиент отвечает sync-state).
      return;
  }
}

/** Убрать все аннотации ушедшего оператора (по participantDisconnected). */
export function removeAuthor(state: AnnoState, author: string): void {
  for (const [id, a] of state.items) if (a.author === author) state.items.delete(id);
  state.pointers.delete(author);
}

/** Снять протухшие указки (не обновлялись дольше ttlMs). */
export function expirePointers(state: AnnoState, now: number, ttlMs = POINTER_TTL_MS): void {
  for (const [author, p] of state.pointers) if (now - p.ts > ttlMs) state.pointers.delete(author);
}

// ── Угасание указки (единый источник со Swift AnnotationRenderer.PointerFade) ──

/** До этого возраста (мс с последнего апдейта) указка на полной непрозрачности. */
export const POINTER_HOLD_MS = 400;
/** К этому возрасту указка полностью прозрачна и удаляется expirePointers. */
export const POINTER_TTL_MS = 1000;

/** Непрозрачность указки по возрасту: 1 пока свежая, линейно к 0 к TTL. */
export function pointerOpacity(ageMs: number): number {
  if (ageMs <= POINTER_HOLD_MS) return 1;
  if (ageMs >= POINTER_TTL_MS) return 0;
  return 1 - (ageMs - POINTER_HOLD_MS) / (POINTER_TTL_MS - POINTER_HOLD_MS);
}

/** Полный снапшот персистентных аннотаций — тело sync-state. */
export function snapshot(state: AnnoState): Annotation[] {
  return [...state.items.values()];
}

function clampText(t: string): string {
  return t.length > MAX_TEXT_LEN ? t.slice(0, MAX_TEXT_LEN) : t;
}

// ── Хелперы отправителя ──────────────────────────────────────────────────────

/**
 * Генератор стабильных id аннотаций в рамках автора: "agent-ab12:37".
 * Держите один инстанс на сессию оператора.
 */
export class IdGen {
  private n = 0;
  private readonly author: string;
  constructor(author: string) {
    this.author = author;
  }
  next(): string {
    this.n += 1;
    return `${this.author}:${this.n}`;
  }
}

/** true, если op нужно слать надёжно (reliable), false — lossy (best-effort). */
export function isReliable(op: Op): boolean {
  switch (op) {
    case 'pointer':
    case 'append':
      return false; // высокочастотные; потеря отдельного апдейта незаметна
    default:
      return true; // add/end/remove/clear/sync-* — критично не потерять
  }
}
