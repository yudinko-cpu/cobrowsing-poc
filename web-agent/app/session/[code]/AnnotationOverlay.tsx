'use client';

/**
 * AnnotationOverlay — слой операторских аннотаций поверх видео клиента.
 *
 * ANNO-3: приём и рендер входящих. ANNO-4: тулбар, ввод и отправка.
 *
 * Единый AnnoState держит и СВОИ (оптимистично), и чужие аннотации: LiveKit не
 * возвращает отправителю его же data-сообщения, поэтому свои штрихи применяем
 * локально сразу, а по сети шлём параллельно. Чужие приходят через DataReceived.
 *
 * Координаты нормализованы [0..1] по контент-боксу видео (letterbox учтён,
 * пересчёт на ресайз/смену dims трека). Толщина линии и кегль — доля короткой
 * стороны контента, чтобы совпадать с рендером на iOS.
 *
 * Надёжность: add/end/remove/clear — reliable; append/pointer — lossy. Финальную
 * геометрию штриха/фигуры дублируем в end (reliable), поэтому потеря lossy-
 * апдейтов не искажает результат.
 *
 * См. docs/annotations-plan.md (§4 координаты, §5 протокол, §7 типы, §9 web).
 */

import type * as React from 'react';
import { useEffect, useRef, useState, type RefObject, type JSX } from 'react';
import { RoomEvent, ConnectionState, type RemoteParticipant, type DataPacket_Kind } from 'livekit-client';
import { useRoomContext } from '@livekit/components-react';
import {
  ANNO_TOPIC,
  ANNO_VERSION,
  MAX_TEXT_LEN,
  decode,
  encode,
  isReliable,
  newState,
  apply,
  removeAuthor,
  expirePointers,
  expireClicks,
  clickProgress,
  contentRect,
  fromNormalized,
  colorForIdentity,
  pointerOpacity,
  quantize,
  simplifyPath,
  MAX_PACKET_BYTES,
  type AnnoMsg,
  type Annotation,
  type Click,
  type Op,
  type Pointer,
  type Point,
  type ContentRect,
} from '../../../lib/anno';

type Tool = 'off' | 'pointer' | 'draw' | 'arrow' | 'rect' | 'ellipse' | 'text';

const STROKE_W = 0.006; // нормализованная толщина линии
const TEXT_SIZE = 0.035; // нормализованный кегль

const TOOLS: { tool: Tool; icon: string; title: string }[] = [
  { tool: 'off', icon: '🖱', title: 'Курсор (не рисовать)' },
  { tool: 'pointer', icon: '🔦', title: 'Лазерная указка' },
  { tool: 'draw', icon: '✏️', title: 'Рисование' },
  { tool: 'arrow', icon: '↗', title: 'Стрелка' },
  { tool: 'rect', icon: '▭', title: 'Прямоугольник' },
  { tool: 'ellipse', icon: '◯', title: 'Овал' },
  { tool: 'text', icon: 'T', title: 'Текст' },
];

const clamp01 = (v: number) => (v < 0 ? 0 : v > 1 ? 1 : v);

function fmtBytes(b: number): string {
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(1)} KB`;
  return `${(b / 1024 / 1024).toFixed(2)} MB`;
}

export function AnnotationOverlay({ containerRef }: { containerRef: RefObject<HTMLDivElement | null> }) {
  const room = useRoomContext();

  // AnnoState живёт в ref (мутируется вне React); ререндер форсим счётчиком.
  const stateRef = useRef(newState());
  const [, setTick] = useState(0);
  const bump = () => setTick((t) => t + 1);

  const [box, setBox] = useState<{ w: number; h: number }>({ w: 0, h: 0 });
  const [rect, setRect] = useState<ContentRect>({ x: 0, y: 0, w: 0, h: 0 });
  const [tool, setTool] = useState<Tool>('off');

  const myId = room?.localParticipant?.identity || 'agent-local';
  const myColor = colorForIdentity(myId);

  // Сессия рисования, счётчик id, стек своих id (для undo), троттлы.
  const counterRef = useRef(0);
  const ownIdsRef = useRef<string[]>([]);
  const drawingRef = useRef<{
    id: string;
    kind: 'path' | 'arrow' | 'shape';
    from?: Point;
    pts?: Point[];
    pending?: Point[];
  } | null>(null);
  const lastAppendRef = useRef(0);
  const lastPointerRef = useRef(0);

  // Метрики data-канала — для приёмки ANNO-7 (размеры пакетов, объём трафика).
  const statsRef = useRef({ sent: 0, recv: 0, bytesSent: 0, bytesRecv: 0, maxMsg: 0, failed: 0, dropped: 0 });

  // Инлайн-редактор текста.
  const [textDraft, setTextDraft] = useState<{ at: Point; x: number; y: number } | null>(null);
  const textValueRef = useRef('');

  const nextId = () => `${myId}:${(counterRef.current += 1)}`;

  // ── Отслеживание контент-бокса (ресайз + смена dims трека) ──────────────────
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    let video: HTMLVideoElement | null = null;

    const recompute = () => {
      const cw = container.clientWidth;
      const ch = container.clientHeight;
      const v = container.querySelector('video');
      const vidW = v?.videoWidth || 16;
      const vidH = v?.videoHeight || 9;
      setBox({ w: cw, h: ch });
      setRect(contentRect({ left: 0, top: 0, width: cw, height: ch }, vidW, vidH));
    };

    const onVideoChange = () => recompute();

    const attachVideo = (v: HTMLVideoElement) => {
      if (v === video) return;
      video?.removeEventListener('loadedmetadata', onVideoChange);
      video?.removeEventListener('resize', onVideoChange);
      video = v;
      v.addEventListener('loadedmetadata', onVideoChange);
      v.addEventListener('resize', onVideoChange);
      recompute();
    };

    const ro = new ResizeObserver(recompute);
    ro.observe(container);

    const mo = new MutationObserver(() => {
      const v = container.querySelector('video');
      if (v) attachVideo(v);
    });
    mo.observe(container, { childList: true, subtree: true });

    const existing = container.querySelector('video');
    if (existing) attachVideo(existing);
    recompute();

    return () => {
      ro.disconnect();
      mo.disconnect();
      video?.removeEventListener('loadedmetadata', onVideoChange);
      video?.removeEventListener('resize', onVideoChange);
    };
  }, [containerRef]);

  // ── Приём аннотаций с data-канала ──────────────────────────────────────────
  useEffect(() => {
    if (!room) return;
    const onData = (
      payload: Uint8Array,
      participant?: RemoteParticipant,
      _kind?: DataPacket_Kind,
      topic?: string,
    ) => {
      if (topic !== ANNO_TOPIC) return;
      statsRef.current.recv += 1;
      statsRef.current.bytesRecv += payload.length;
      const msg = decode(payload);
      if (!msg) return;

      // Гейт прав (§6.4). Клиент («Customer» в JWT-имени) не может быть автором
      // аннотаций; и наоборот — снапшот sync-state принимаем ТОЛЬКО от него,
      // потому что канонический стор живёт на клиенте.
      const isCustomer = participant?.name === 'Customer';
      if (msg.op === 'sync-state' ? !isCustomer : isCustomer) {
        // Отбрасывания логируем: иначе «аннотации не доходят» неотличимо от
        // сбоя сети. name берётся из JWT (backend: 'Agent' / 'Customer').
        statsRef.current.dropped += 1;
        console.warn('[anno] сообщение отброшено гейтом прав', {
          op: msg.op,
          from: participant?.identity,
          name: participant?.name,
        });
        return;
      }

      if (participant?.identity) msg.author = participant.identity; // анти-спуфинг
      apply(stateRef.current, msg);
      bump();
    };
    room.on(RoomEvent.DataReceived, onData);
    return () => {
      room.off(RoomEvent.DataReceived, onData);
    };
  }, [room]);

  // ── Уход оператора → снять его аннотации (ANNO-5) ────────────────────────────
  useEffect(() => {
    if (!room) return;
    const onLeft = (participant: RemoteParticipant) => {
      removeAuthor(stateRef.current, participant.identity);
      bump();
    };
    room.on(RoomEvent.ParticipantDisconnected, onLeft);
    return () => {
      room.off(RoomEvent.ParticipantDisconnected, onLeft);
    };
  }, [room]);

  // ── Ресинк: просим у клиента текущее состояние (ANNO-6) ─────────────────────
  // Нужен при позднем подключении оператора и после F5. Клиент отвечает
  // адресным sync-state; мёрж идёт по id, поэтому дубликатов не возникает.
  useEffect(() => {
    if (!room) return;

    const requestSync = () => {
      const lp = room.localParticipant;
      if (!lp) return;
      // Публиковать data до установления соединения нельзя — publishData
      // отклонится. Раньше здесь этой проверки не было, и первый вызов
      // (синхронно на монтировании) мог уходить в никуда.
      if (room.state !== ConnectionState.Connected) return;
      const msg: AnnoMsg = {
        v: ANNO_VERSION,
        op: 'sync-req',
        author: lp.identity || 'agent',
        ts: Date.now(),
      };
      void lp
        .publishData(encode(msg), { reliable: true, topic: ANNO_TOPIC })
        .catch((e: unknown) => console.error('[anno] sync-req не отправлен', e));
    };

    requestSync(); // если уже подключены — спросим сразу
    room.on(RoomEvent.Connected, requestSync);
    room.on(RoomEvent.ParticipantConnected, requestSync); // клиент мог зайти позже нас

    // Одна отложенная попытка: сразу после connect data-канал мог быть не готов.
    const retry = setTimeout(() => {
      if (stateRef.current.items.size === 0) requestSync();
    }, 1000);

    return () => {
      room.off(RoomEvent.Connected, requestSync);
      room.off(RoomEvent.ParticipantConnected, requestSync);
      clearTimeout(retry);
    };
  }, [room]);

  // ── Тикер угасания указок и кликов ──────────────────────────────────────────
  useEffect(() => {
    const id = setInterval(() => {
      const s = stateRef.current;
      if (s.pointers.size === 0 && s.clicks.size === 0) return;
      const t = Date.now();
      expirePointers(s, t);
      expireClicks(s, t);
      bump();
    }, 33);
    return () => clearInterval(id);
  }, []);

  // ── Отправка / оптимистичное применение ─────────────────────────────────────
  const makeMsg = (partial: Partial<AnnoMsg> & { op: Op }): AnnoMsg => ({
    v: ANNO_VERSION,
    ts: Date.now(),
    author: myId,
    ...partial,
  });

  const applyLocal = (msg: AnnoMsg) => {
    apply(stateRef.current, msg);
    bump();
  };

  const send = (msg: AnnoMsg) => {
    const lp = room?.localParticipant;
    if (!lp) return;
    const bytes = encode(msg);

    const s = statsRef.current;
    s.sent += 1;
    s.bytesSent += bytes.length;
    if (bytes.length > s.maxMsg) s.maxMsg = bytes.length;
    if (bytes.length > MAX_PACKET_BYTES) {
      // Не должно случаться: финальная геометрия упрощается перед отправкой.
      console.warn(`[anno] пакет ${bytes.length}B > лимита ${MAX_PACKET_BYTES}B (op=${msg.op})`);
    }

    // publishData асинхронный. Ошибку НЕ глушим: молчаливый сбой отправки
    // выглядит как «аннотации не доходят», и найти его без лога невозможно.
    try {
      void lp
        .publishData(bytes, { reliable: isReliable(msg.op), topic: ANNO_TOPIC })
        .catch((e: unknown) => {
          s.failed += 1;
          console.error('[anno] publishData отклонён', { op: msg.op, bytes: bytes.length, error: e });
        });
    } catch (e) {
      // Синхронный бросок (например, транспорт не готов) — тоже фиксируем.
      s.failed += 1;
      console.error('[anno] publishData бросил синхронно', { op: msg.op, error: e });
    }
  };

  const emit = (msg: AnnoMsg) => {
    applyLocal(msg);
    send(msg);
  };

  // ── Координата события внутри контент-бокса ─────────────────────────────────
  // Input-слой позиционирован ровно в контент-боксе, поэтому offsetX/Y относительно
  // него = пиксели контента; нормализуем делением на размер бокса.
  const pointFromEvent = (e: React.PointerEvent): Point => {
    const w = rect.w || 1;
    const h = rect.h || 1;
    // Квантуем сразу на входе — все исходящие сообщения становятся компактнее.
    return quantize([clamp01(e.nativeEvent.offsetX / w), clamp01(e.nativeEvent.offsetY / h)]);
  };

  // ── Указатель: down / move / up ─────────────────────────────────────────────
  const onPointerDown = (e: React.PointerEvent) => {
    if (tool === 'off') return;

    if (tool === 'pointer') {
      // Клик указкой — эфемерная «волна» в точке нажатия, видна всем участникам.
      // Reliable: это разовое событие-акцент, потерять его нельзя.
      emit(makeMsg({ op: 'click', color: myColor, at: pointFromEvent(e) }));
      return;
    }

    const p = pointFromEvent(e);

    if (tool === 'text') {
      // Клик в новое место при открытом поле — сначала фиксируем предыдущий ввод,
      // иначе набранный текст потерялся бы.
      if (textDraft) confirmText();
      setTextDraft({ at: p, x: rect.x + p[0] * rect.w, y: rect.y + p[1] * rect.h });
      textValueRef.current = '';
      return;
    }

    (e.target as Element).setPointerCapture?.(e.pointerId);
    const id = nextId();
    ownIdsRef.current.push(id);
    lastAppendRef.current = Date.now();

    if (tool === 'draw') {
      drawingRef.current = { id, kind: 'path', pts: [p], pending: [] };
      emit(makeMsg({ op: 'add', id, kind: 'path', color: myColor, w: STROKE_W, pts: [p] }));
    } else if (tool === 'arrow') {
      drawingRef.current = { id, kind: 'arrow', from: p };
      emit(makeMsg({ op: 'add', id, kind: 'arrow', color: myColor, w: STROKE_W, from: p, to: p }));
    } else {
      const shape = tool === 'rect' ? 'rect' : 'ellipse';
      drawingRef.current = { id, kind: 'shape', from: p };
      emit(makeMsg({ op: 'add', id, kind: 'shape', color: myColor, w: STROKE_W, shape, from: p, to: p, fill: false }));
    }
  };

  const onPointerMove = (e: React.PointerEvent) => {
    const now = Date.now();

    if (tool === 'pointer') {
      if (now - lastPointerRef.current < 33) return; // ~30 Гц
      lastPointerRef.current = now;
      emit(makeMsg({ op: 'pointer', color: myColor, at: pointFromEvent(e) }));
      return;
    }

    const d = drawingRef.current;
    if (!d) return;
    const p = pointFromEvent(e);

    if (d.kind === 'path') {
      d.pts!.push(p);
      d.pending!.push(p);
      applyLocal(makeMsg({ op: 'append', id: d.id, pts: [p] })); // плавно локально
      // Флашим по времени ИЛИ по объёму — батч не должен раздуваться на быстром вводе.
      if (now - lastAppendRef.current > 50 || d.pending!.length >= 32) {
        send(makeMsg({ op: 'append', id: d.id, pts: d.pending! })); // батч по сети
        d.pending = [];
        lastAppendRef.current = now;
      }
    } else {
      applyLocal(makeMsg({ op: 'append', id: d.id, to: p }));
      if (now - lastAppendRef.current > 40) {
        send(makeMsg({ op: 'append', id: d.id, to: p }));
        lastAppendRef.current = now;
      }
    }
  };

  const onPointerUp = (e: React.PointerEvent) => {
    const d = drawingRef.current;
    if (!d) return;
    const p = pointFromEvent(e);

    if (d.kind === 'path') {
      if (d.pending && d.pending.length) send(makeMsg({ op: 'append', id: d.id, pts: d.pending }));
      // end несёт полную геометрию (reliable) — гарантия при потере lossy-апдейтов.
      // Упрощаем (RDP + кап), чтобы длинный штрих гарантированно влезал в пакет;
      // локально применяем ту же упрощённую версию, чтобы картинка совпадала с чужой.
      emit(makeMsg({ op: 'end', id: d.id, pts: simplifyPath(d.pts ?? []) }));
    } else {
      emit(makeMsg({ op: 'end', id: d.id, from: d.from, to: p }));
    }
    drawingRef.current = null;
  };

  // ── Текст ────────────────────────────────────────────────────────────────────
  const confirmText = () => {
    const t = textValueRef.current.trim();
    if (textDraft && t) {
      const id = nextId();
      ownIdsRef.current.push(id);
      emit(makeMsg({ op: 'add', id, kind: 'text', color: myColor, at: textDraft.at, text: t, size: TEXT_SIZE }));
    }
    setTextDraft(null);
    textValueRef.current = '';
  };
  const cancelText = () => {
    setTextDraft(null);
    textValueRef.current = '';
  };

  // ── Undo / Clear ──────────────────────────────────────────────────────────────
  const undo = () => {
    const id = ownIdsRef.current.pop();
    if (id) emit(makeMsg({ op: 'remove', id })); // remove гейтится по author — чужое не тронет
  };
  const clearOwn = () => {
    ownIdsRef.current = [];
    emit(makeMsg({ op: 'clear', scope: 'own' }));
  };
  const clearAll = () => {
    // Стирает аннотации ВСЕХ операторов у всех участников — сильное действие,
    // на PoC разрешено любому оператору, но с подтверждением и логом автора (§6.4).
    if (!window.confirm('Стереть аннотации ВСЕХ операторов? Это увидят все.')) return;
    ownIdsRef.current = [];
    console.info(`[anno] clear-all by ${myId}`);
    emit(makeMsg({ op: 'clear', scope: 'all' }));
  };

  // ── Рендер ───────────────────────────────────────────────────────────────────
  const st = stateRef.current;
  const shortSide = Math.min(rect.w, rect.h) || 1;
  const now = Date.now();
  const interactive = tool !== 'off' && rect.w > 0;

  return (
    <>
      <svg
        width={box.w}
        height={box.h}
        style={{ position: 'absolute', inset: 0, pointerEvents: 'none', zIndex: 4 }}
        aria-hidden
      >
        {[...st.items.values()].map((a) => renderAnnotation(a, rect, shortSide))}
        {[...st.pointers.values()].map((p) => renderPointer(p, rect, shortSide, now))}
        {[...st.clicks.values()].map((c) => renderClick(c, rect, shortSide, now))}
      </svg>

      {/* Слой ввода — ровно контент-бокс видео. Ловит события только когда выбран
          инструмент; иначе pointerEvents:none и ничего не блокирует. */}
      {interactive && (
        <div
          onPointerDown={onPointerDown}
          onPointerMove={onPointerMove}
          onPointerUp={onPointerUp}
          // Гасим дефолт mousedown: иначе браузер уводит фокус на <body>
          // (этот div не фокусируемый), инлайн-поле текста мгновенно получает
          // blur и закрывается — поле просто не успевало показаться.
          onMouseDown={(e) => e.preventDefault()}
          style={{
            position: 'absolute',
            left: rect.x,
            top: rect.y,
            width: rect.w,
            height: rect.h,
            zIndex: 6,
            cursor: tool === 'text' ? 'text' : 'crosshair',
            touchAction: 'none',
            pointerEvents: 'auto',
          }}
        />
      )}

      {/* Инлайн-редактор текста. */}
      {textDraft && (
        <input
          autoFocus
          defaultValue=""
          maxLength={MAX_TEXT_LEN}
          placeholder="Текст…"
          onChange={(e) => {
            textValueRef.current = e.target.value;
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              confirmText();
            } else if (e.key === 'Escape') {
              cancelText();
            }
          }}
          onBlur={confirmText}
          style={{
            position: 'absolute',
            left: textDraft.x,
            top: textDraft.y,
            zIndex: 25,
            font: '600 14px system-ui, sans-serif',
            color: myColor,
            background: 'rgba(0,0,0,0.6)',
            border: `1px solid ${myColor}`,
            borderRadius: 4,
            padding: '2px 6px',
            outline: 'none',
            pointerEvents: 'auto',
          }}
        />
      )}

      {/* Метрики data-канала — для приёмки ANNO-7 (размеры пакетов, объём). */}
      <div
        style={{
          position: 'absolute',
          right: 12,
          bottom: 12,
          zIndex: 15,
          padding: '6px 8px',
          background: 'rgba(0,0,0,0.7)',
          color: '#9ca3af',
          fontFamily: 'ui-monospace, SFMono-Regular, monospace',
          fontSize: 11,
          lineHeight: 1.5,
          borderRadius: 6,
          pointerEvents: 'none',
          whiteSpace: 'pre',
        }}
      >
        {[
          `anno tx: ${statsRef.current.sent} (${fmtBytes(statsRef.current.bytesSent)})`,
          `anno rx: ${statsRef.current.recv} (${fmtBytes(statsRef.current.bytesRecv)})`,
          `max msg: ${statsRef.current.maxMsg} B / ${MAX_PACKET_BYTES}`,
          `fail/drop: ${statsRef.current.failed} / ${statsRef.current.dropped}`,
          `items:   ${st.items.size}   ptr: ${st.pointers.size}`,
          `me: ${myId}`,
        ].join('\n')}
      </div>

      {/* Тулбар. */}
      <div
        style={{
          position: 'absolute',
          bottom: 16,
          left: '50%',
          transform: 'translateX(-50%)',
          zIndex: 20,
          display: 'flex',
          alignItems: 'center',
          gap: 4,
          padding: '6px 8px',
          background: 'rgba(17,24,39,0.92)',
          border: '1px solid #374151',
          borderRadius: 10,
          boxShadow: '0 8px 24px rgba(0,0,0,0.4)',
          pointerEvents: 'auto',
        }}
      >
        {TOOLS.map((t) => (
          <ToolButton key={t.tool} active={tool === t.tool} title={t.title} onClick={() => setTool(t.tool)}>
            {t.icon}
          </ToolButton>
        ))}
        <span style={{ width: 1, height: 22, background: '#374151', margin: '0 4px' }} />
        <ToolButton title="Отменить последнее (своё)" onClick={undo}>
          ↶
        </ToolButton>
        <ToolButton title="Стереть все свои" onClick={clearOwn}>
          🗑
        </ToolButton>
        <ToolButton title="Стереть у всех операторов" onClick={clearAll}>
          🧹
        </ToolButton>
        <span
          title={`Ваш цвет (${myId})`}
          style={{
            width: 16,
            height: 16,
            borderRadius: '50%',
            background: myColor,
            marginLeft: 4,
            border: '2px solid rgba(255,255,255,0.6)',
          }}
        />
      </div>
    </>
  );
}

// ── Кнопка тулбара ──────────────────────────────────────────────────────────────

function ToolButton({
  children,
  title,
  active,
  onClick,
}: {
  children: React.ReactNode;
  title: string;
  active?: boolean;
  onClick: () => void;
}) {
  return (
    <button
      title={title}
      onClick={onClick}
      style={{
        width: 32,
        height: 32,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        fontSize: 15,
        lineHeight: 1,
        color: 'white',
        background: active ? '#2563eb' : 'transparent',
        border: 'none',
        borderRadius: 7,
        cursor: 'pointer',
      }}
    >
      {children}
    </button>
  );
}

// ── Рендереры типов ────────────────────────────────────────────────────────────

function renderAnnotation(a: Annotation, rect: ContentRect, shortSide: number): JSX.Element | null {
  const color = a.color || colorForIdentity(a.author);
  const lineW = Math.max(1, (a.w ?? 0.006) * shortSide);

  switch (a.kind) {
    case 'path': {
      if (!a.pts || a.pts.length === 0) return null;
      const points = a.pts
        .map((p) => {
          const q = fromNormalized(p[0], p[1], rect);
          return `${q.x},${q.y}`;
        })
        .join(' ');
      return (
        <polyline
          key={a.id}
          points={points}
          fill="none"
          stroke={color}
          strokeWidth={lineW}
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      );
    }

    case 'arrow': {
      if (!a.from || !a.to) return null;
      const p0 = fromNormalized(a.from[0], a.from[1], rect);
      const p1 = fromNormalized(a.to[0], a.to[1], rect);
      const size = Math.max(10, lineW * 3.5);
      const angle = Math.atan2(p1.y - p0.y, p1.x - p0.x);
      const a1 = angle + (Math.PI * 5) / 6;
      const a2 = angle - (Math.PI * 5) / 6;
      const head = `M ${p1.x} ${p1.y} L ${p1.x + Math.cos(a1) * size} ${p1.y + Math.sin(a1) * size} M ${p1.x} ${p1.y} L ${p1.x + Math.cos(a2) * size} ${p1.y + Math.sin(a2) * size}`;
      return (
        <g key={a.id} stroke={color} strokeWidth={lineW} strokeLinecap="round" strokeLinejoin="round" fill="none">
          <line x1={p0.x} y1={p0.y} x2={p1.x} y2={p1.y} />
          <path d={head} />
        </g>
      );
    }

    case 'shape': {
      if (!a.from || !a.to) return null;
      const p0 = fromNormalized(a.from[0], a.from[1], rect);
      const p1 = fromNormalized(a.to[0], a.to[1], rect);
      const x = Math.min(p0.x, p1.x);
      const y = Math.min(p0.y, p1.y);
      const w = Math.abs(p1.x - p0.x);
      const h = Math.abs(p1.y - p0.y);
      const fill = a.fill ? color : 'none';
      const fillOpacity = a.fill ? 0.2 : undefined;
      if (a.shape === 'ellipse') {
        return (
          <ellipse
            key={a.id}
            cx={x + w / 2}
            cy={y + h / 2}
            rx={w / 2}
            ry={h / 2}
            fill={fill}
            fillOpacity={fillOpacity}
            stroke={color}
            strokeWidth={lineW}
          />
        );
      }
      return (
        <rect
          key={a.id}
          x={x}
          y={y}
          width={w}
          height={h}
          rx={3}
          fill={fill}
          fillOpacity={fillOpacity}
          stroke={color}
          strokeWidth={lineW}
        />
      );
    }

    case 'text': {
      if (!a.at || !a.text) return null;
      const q = fromNormalized(a.at[0], a.at[1], rect);
      const fontSize = Math.max(11, (a.size ?? 0.035) * shortSide);
      return (
        <text
          key={a.id}
          x={q.x}
          y={q.y}
          fill={color}
          fontSize={fontSize}
          fontWeight={600}
          dominantBaseline="text-before-edge"
          style={{ fontFamily: 'system-ui, sans-serif', paintOrder: 'stroke' }}
          stroke="rgba(0,0,0,0.35)"
          strokeWidth={fontSize * 0.06}
        >
          {a.text}
        </text>
      );
    }

    default:
      return null;
  }
}

/** Клик указкой: кольцо расходится наружу и гаснет, ядро сжимается. */
function renderClick(c: Click, rect: ContentRect, shortSide: number, now: number): JSX.Element | null {
  const p = clickProgress(now - c.ts);
  if (p >= 1) return null;
  const pos = fromNormalized(c.at[0], c.at[1], rect);
  const color = c.color || colorForIdentity(c.author);
  const r0 = Math.max(4, shortSide * 0.012);
  const r1 = Math.max(16, shortSide * 0.06);
  const r = r0 + (r1 - r0) * p;
  const opacity = 1 - p;
  return (
    <g key={`click-${c.author}-${c.ts}`}>
      <circle
        cx={pos.x}
        cy={pos.y}
        r={r}
        fill="none"
        stroke={color}
        strokeWidth={Math.max(2, shortSide * 0.005)}
        opacity={opacity}
      />
      <circle cx={pos.x} cy={pos.y} r={r0 * (1 - p)} fill={color} opacity={opacity * 0.8} />
    </g>
  );
}

function renderPointer(p: Pointer, rect: ContentRect, shortSide: number, now: number): JSX.Element | null {
  const opacity = pointerOpacity(now - p.ts);
  if (opacity <= 0) return null;
  const c = fromNormalized(p.at[0], p.at[1], rect);
  const color = p.color || colorForIdentity(p.author);
  const r = Math.max(6, shortSide * 0.018);
  return (
    <g key={`ptr-${p.author}`}>
      <circle cx={c.x} cy={c.y} r={r} fill={color} opacity={0.25 * opacity} />
      <circle cx={c.x} cy={c.y} r={r * 0.5} fill={color} opacity={opacity} />
    </g>
  );
}
