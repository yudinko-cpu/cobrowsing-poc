'use client';

/**
 * ChatPanel — мессенджер оператора с клиентом (правая колонка страницы сессии).
 *
 * Едет тем же data-топиком и конвертом, что аннотации (`op: 'chat'` и
 * `op: 'typing'`, см. lib/chat.ts). Второй независимый слушатель
 * RoomEvent.DataReceived рядом с AnnotationOverlay: Room — TypedEmitter, каждый
 * `on` получает все события, `off(fn)` снимает только свой. AnnotationOverlay на
 * ops чата делает ранний выход (до гейта прав — клиент вправе их слать), сюда
 * доходит всё остальное.
 *
 * Состояние — компонентное: теряется на unmount/F5. Так и задумано: истории
 * нет, всё живёт в рамках одной сессии, в sync-state чат не входит.
 *
 * Свои сообщения применяем оптимистично: LiveKit не эхоит data отправителю.
 * «Печатает»: heartbeat при изменении черновика (троттлинг в TypingTracker),
 * на приёме — TTL по локальным часам, снимается сразу по сообщению автора.
 */

import { useEffect, useMemo, useRef, useState, type CSSProperties, type KeyboardEvent } from 'react';
import { RoomEvent, ConnectionState, type RemoteParticipant, type DataPacket_Kind } from 'livekit-client';
import { useConnectionState, useLocalParticipant, useRoomContext } from '@livekit/components-react';
import { ANNO_TOPIC, MAX_CHAT_LEN, IdGen, colorForIdentity, decode, encode, isReliable, type AnnoMsg } from '../../../lib/anno';
import {
  TYPING_TTL_MS,
  TypingTracker,
  chatFromMsg,
  makeChatMsg,
  makeTypingMsg,
  typingFromMsg,
  type ChatMessage,
} from '../../../lib/chat';

type Entry = ChatMessage & { isMine: boolean; isCustomer: boolean };

/** Кто печатает: identity → момент последнего heartbeat по локальным часам. */
type TypingMap = Record<string, { ts: number; isCustomer: boolean }>;

function omit(t: TypingMap, key: string): TypingMap {
  if (!(key in t)) return t;
  const { [key]: _removed, ...rest } = t;
  return rest;
}

function typingLabel(t: TypingMap): string {
  const names = Object.entries(t).map(([author, e]) => (e.isCustomer ? 'Клиент' : author));
  return names.length === 1 ? `${names[0]} печатает…` : `${names.join(', ')} печатают…`;
}

export function ChatPanel() {
  const room = useRoomContext();
  // Хук, а не room.state: нужен ререндер при смене состояния соединения.
  const connectionState = useConnectionState();
  const { localParticipant } = useLocalParticipant();
  const myId = localParticipant?.identity || 'agent-local';
  // До connect identity ещё 'agent-local', но send заблокирован до Connected,
  // поэтому реальные id всегда несут настоящую identity.
  const idGen = useMemo(() => new IdGen(myId), [myId]);

  const [messages, setMessages] = useState<Entry[]>([]);
  const [draft, setDraft] = useState('');
  const [typing, setTyping] = useState<TypingMap>({});
  // Ключи принятых сообщений: reliable-канал может доставить повтор. В ref,
  // чтобы пережить StrictMode-перемонтирование слушателя.
  const seenRef = useRef(new Set<string>());
  const typingTrackerRef = useRef(new TypingTracker());
  const listRef = useRef<HTMLDivElement>(null);

  // ── Отправка на data-канал ──────────────────────────────────────────────────
  const publish = (msg: AnnoMsg, what: string) => {
    const lp = room?.localParticipant;
    if (!lp) return;
    // Ошибку не глушим: молчаливый сбой неотличим от «сообщения не доходят».
    void lp
      .publishData(encode(msg), { reliable: isReliable(msg.op), topic: ANNO_TOPIC })
      .catch((e: unknown) => console.error(`[chat] ${what}: publishData отклонён`, e));
  };

  // ── Приём ───────────────────────────────────────────────────────────────────
  useEffect(() => {
    if (!room) return;
    const onData = (
      payload: Uint8Array,
      participant?: RemoteParticipant,
      _kind?: DataPacket_Kind,
      topic?: string,
    ) => {
      if (topic !== ANNO_TOPIC) return;
      const msg = decode(payload);
      if (!msg) return;
      // name проставляет backend в JWT: 'Customer' — клиент, 'Agent' — коллега-оператор.
      const isCustomer = participant?.name === 'Customer';

      if (msg.op === 'chat') {
        // author = аутентифицированная identity отправителя (анти-спуфинг).
        const cm = chatFromMsg(msg, participant?.identity);
        if (!cm || seenRef.current.has(cm.key)) return;
        seenRef.current.add(cm.key);
        setMessages((m) => [...m, { ...cm, isMine: false, isCustomer }]);
        // Сообщение пришло — «печатает» этого автора снимаем сразу.
        setTyping((t) => omit(t, cm.author));
        return;
      }

      if (msg.op === 'typing') {
        const ev = typingFromMsg(msg, participant?.identity);
        if (!ev) return;
        setTyping((t) => (ev.typing ? { ...t, [ev.author]: { ts: Date.now(), isCustomer } } : omit(t, ev.author)));
      }
    };
    // Участник ушёл — его «печатает» не должно висеть до TTL.
    const onLeft = (participant: RemoteParticipant) => {
      setTyping((t) => omit(t, participant.identity));
    };
    room.on(RoomEvent.DataReceived, onData);
    room.on(RoomEvent.ParticipantDisconnected, onLeft);
    return () => {
      room.off(RoomEvent.DataReceived, onData);
      room.off(RoomEvent.ParticipantDisconnected, onLeft);
    };
  }, [room]);

  // ── TTL «печатает» ──────────────────────────────────────────────────────────
  const typingCount = Object.keys(typing).length;
  useEffect(() => {
    if (typingCount === 0) return;
    const id = setInterval(() => {
      const now = Date.now();
      setTyping((t) => {
        const fresh = Object.fromEntries(Object.entries(t).filter(([, e]) => now - e.ts <= TYPING_TTL_MS));
        return Object.keys(fresh).length === Object.keys(t).length ? t : fresh;
      });
    }, 500);
    return () => clearInterval(id);
  }, [typingCount]);

  // Автоскролл к последнему сообщению (и к индикатору «печатает»).
  useEffect(() => {
    const el = listRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages, typingCount]);

  // ── Ввод и отправка ─────────────────────────────────────────────────────────
  const canSend = connectionState === ConnectionState.Connected;
  const hasDraft = draft.trim().length > 0;

  const onDraftChange = (value: string) => {
    setDraft(value);
    if (!canSend) return;
    const flag = typingTrackerRef.current.onDraftChange(value.trim().length > 0);
    if (flag !== null) publish(makeTypingMsg(myId, flag), 'typing');
  };

  const send = () => {
    if (!canSend) return;
    const msg = makeChatMsg(myId, idGen.next(), draft);
    if (!msg) return;
    // Получатели снимут «печатает» по самому сообщению — отдельный стоп не нужен.
    typingTrackerRef.current.reset();
    setMessages((m) => [
      ...m,
      { key: `${myId}|${msg.id}`, author: myId, text: msg.text ?? '', ts: msg.ts, isMine: true, isCustomer: false },
    ]);
    setDraft('');
    publish(msg, 'chat');
  };

  const onKeyDown = (e: KeyboardEvent<HTMLTextAreaElement>) => {
    // Enter — отправить, Shift+Enter — перенос строки.
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      send();
    }
  };

  const sendDisabled = !canSend || !hasDraft;

  return (
    <aside style={styles.panel}>
      {/* Единственный способ описать keyframes при инлайн-стилях — как и
          .cobrowse-video в page.tsx. Точки берут цвет из currentColor. */}
      <style>{`
        @keyframes cbTypingDot {
          0%, 80%, 100% { opacity: .25; transform: translateY(0); }
          40% { opacity: 1; transform: translateY(-3px); }
        }
        .cb-typing-dot {
          display: inline-block; width: 5px; height: 5px; border-radius: 50%;
          background: currentColor; margin-right: 3px;
          animation: cbTypingDot 1.2s infinite ease-in-out;
        }
        .cb-typing-dot:nth-child(2) { animation-delay: .2s; }
        .cb-typing-dot:nth-child(3) { animation-delay: .4s; }
      `}</style>

      <div style={styles.header}>Чат с клиентом</div>

      <div ref={listRef} style={styles.list}>
        {messages.length === 0 && typingCount === 0 ? (
          <div style={styles.empty}>Сообщений пока нет</div>
        ) : (
          messages.map((m) => <Bubble key={m.key} entry={m} />)
        )}
      </div>

      {typingCount > 0 && (
        <div style={styles.typingRow} aria-live="polite">
          <span style={styles.typingDots} aria-hidden>
            <span className="cb-typing-dot" />
            <span className="cb-typing-dot" />
            <span className="cb-typing-dot" />
          </span>
          <span>{typingLabel(typing)}</span>
        </div>
      )}

      <div style={styles.composer}>
        {!canSend && <div style={styles.hint}>Нет соединения с комнатой</div>}
        <textarea
          rows={2}
          maxLength={MAX_CHAT_LEN}
          placeholder="Сообщение клиенту…"
          value={draft}
          onChange={(e) => onDraftChange(e.target.value)}
          onKeyDown={onKeyDown}
          disabled={!canSend}
          style={styles.textarea}
        />
        <button
          type="button"
          onClick={send}
          disabled={sendDisabled}
          style={{ ...styles.sendBtn, opacity: sendDisabled ? 0.5 : 1, cursor: sendDisabled ? 'default' : 'pointer' }}
        >
          Отправить
        </button>
      </div>
    </aside>
  );
}

// ── Пузырь сообщения ──────────────────────────────────────────────────────────

function Bubble({ entry }: { entry: Entry }) {
  const isColleague = !entry.isMine && !entry.isCustomer;
  const label = entry.isMine ? 'Вы' : entry.isCustomer ? 'Клиент' : entry.author;
  const time = new Date(entry.ts).toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
  return (
    <div
      style={{
        ...styles.bubble,
        alignSelf: entry.isMine ? 'flex-end' : 'flex-start',
        background: entry.isMine ? '#2563eb' : entry.isCustomer ? '#374151' : '#1f2937',
      }}
    >
      <div style={{ ...styles.meta, color: entry.isMine ? 'rgba(255,255,255,0.8)' : '#9ca3af' }}>
        {/* Коллега-оператор — та же цветовая метка, что в ростере и у его аннотаций. */}
        {isColleague && <span style={{ ...styles.dot, background: colorForIdentity(entry.author) }} />}
        <span style={{ ...styles.author, fontFamily: isColleague ? 'ui-monospace, SFMono-Regular, monospace' : undefined }}>
          {label}
        </span>
        <span style={styles.time}>{time}</span>
      </div>
      <div style={styles.text}>{entry.text}</div>
    </div>
  );
}

const styles: Record<string, CSSProperties> = {
  // flex: '0 0 320px' — фиксированная колонка; minHeight: 0 — как у videoContainer,
  // иначе список внутри не ограничен высотой ряда и не скроллится.
  panel: {
    flex: '0 0 320px',
    width: 320,
    minHeight: 0,
    display: 'flex',
    flexDirection: 'column',
    background: '#111827',
    borderLeft: '1px solid #374151',
    color: 'white',
  },
  header: { padding: '10px 12px', borderBottom: '1px solid #374151', fontWeight: 600, fontSize: 14 },
  list: { flex: 1, minHeight: 0, overflowY: 'auto', padding: 12, display: 'flex', flexDirection: 'column', gap: 8 },
  empty: { margin: 'auto', color: '#6b7280', fontSize: 13 },
  bubble: { maxWidth: '85%', padding: '6px 10px', borderRadius: 10, fontSize: 13, lineHeight: 1.4 },
  meta: { display: 'flex', alignItems: 'center', gap: 6, marginBottom: 2, fontSize: 11 },
  dot: { width: 8, height: 8, borderRadius: '50%', flex: '0 0 auto' },
  author: { fontWeight: 600 },
  time: { marginLeft: 'auto', opacity: 0.8 },
  text: { whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' },
  typingRow: { display: 'flex', alignItems: 'center', gap: 8, padding: '0 12px 8px', fontSize: 12, color: '#9ca3af' },
  typingDots: { display: 'inline-flex', alignItems: 'center', height: 12 },
  composer: { display: 'flex', flexDirection: 'column', gap: 6, padding: 10, borderTop: '1px solid #374151' },
  hint: { fontSize: 11, color: '#f59e0b' },
  textarea: {
    width: '100%',
    boxSizing: 'border-box',
    resize: 'none',
    padding: '8px 10px',
    borderRadius: 8,
    border: '1px solid #374151',
    background: '#1f2937',
    color: 'white',
    font: '13px system-ui, sans-serif',
    outline: 'none',
  },
  sendBtn: {
    background: '#2563eb',
    color: 'white',
    border: 'none',
    padding: '8px 12px',
    borderRadius: 8,
    fontWeight: 600,
    alignSelf: 'flex-end',
  },
};
