'use client';

/**
 * ChatPanel — мессенджер оператора с клиентом (правая колонка страницы сессии).
 *
 * Едет тем же data-топиком и конвертом, что аннотации (`op: 'chat'`, см.
 * lib/chat.ts). Второй независимый слушатель RoomEvent.DataReceived рядом с
 * AnnotationOverlay: Room — TypedEmitter, каждый `on` получает все события,
 * `off(fn)` снимает только свой. AnnotationOverlay на `chat` делает ранний
 * выход (до гейта прав — клиент вправе слать chat), сюда доходит всё остальное.
 *
 * Состояние — компонентное: теряется на unmount/F5. Так и задумано: истории
 * нет, всё живёт в рамках одной сессии, в sync-state чат не входит.
 *
 * Свои сообщения применяем оптимистично: LiveKit не эхоит data отправителю.
 */

import { useEffect, useMemo, useRef, useState, type CSSProperties, type KeyboardEvent } from 'react';
import { RoomEvent, ConnectionState, type RemoteParticipant, type DataPacket_Kind } from 'livekit-client';
import { useConnectionState, useLocalParticipant, useRoomContext } from '@livekit/components-react';
import { ANNO_TOPIC, MAX_CHAT_LEN, IdGen, colorForIdentity, decode, encode, isReliable } from '../../../lib/anno';
import { chatFromMsg, makeChatMsg, type ChatMessage } from '../../../lib/chat';

type Entry = ChatMessage & { isMine: boolean; isCustomer: boolean };

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
  // Ключи принятых сообщений: reliable-канал может доставить повтор. В ref,
  // чтобы пережить StrictMode-перемонтирование слушателя.
  const seenRef = useRef(new Set<string>());
  const listRef = useRef<HTMLDivElement>(null);

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
      if (!msg || msg.op !== 'chat') return;
      // author = аутентифицированная identity отправителя (анти-спуфинг).
      const cm = chatFromMsg(msg, participant?.identity);
      if (!cm || seenRef.current.has(cm.key)) return;
      seenRef.current.add(cm.key);
      // name проставляет backend в JWT: 'Customer' — клиент, 'Agent' — коллега-оператор.
      setMessages((m) => [...m, { ...cm, isMine: false, isCustomer: participant?.name === 'Customer' }]);
    };
    room.on(RoomEvent.DataReceived, onData);
    return () => {
      room.off(RoomEvent.DataReceived, onData);
    };
  }, [room]);

  // Автоскролл к последнему сообщению.
  useEffect(() => {
    const el = listRef.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages]);

  // ── Отправка ────────────────────────────────────────────────────────────────
  const canSend = connectionState === ConnectionState.Connected;
  const hasDraft = draft.trim().length > 0;

  const send = () => {
    const lp = room?.localParticipant;
    if (!lp || !canSend) return;
    const msg = makeChatMsg(myId, idGen.next(), draft);
    if (!msg) return;
    setMessages((m) => [
      ...m,
      { key: `${myId}|${msg.id}`, author: myId, text: msg.text ?? '', ts: msg.ts, isMine: true, isCustomer: false },
    ]);
    setDraft('');
    // Ошибку не глушим: молчаливый сбой неотличим от «сообщения не доходят».
    void lp
      .publishData(encode(msg), { reliable: isReliable('chat'), topic: ANNO_TOPIC })
      .catch((e: unknown) => console.error('[chat] publishData отклонён', { id: msg.id, error: e }));
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
      <div style={styles.header}>Чат с клиентом</div>

      <div ref={listRef} style={styles.list}>
        {messages.length === 0 ? (
          <div style={styles.empty}>Сообщений пока нет</div>
        ) : (
          messages.map((m) => <Bubble key={m.key} entry={m} />)
        )}
      </div>

      <div style={styles.composer}>
        {!canSend && <div style={styles.hint}>Нет соединения с комнатой</div>}
        <textarea
          rows={2}
          maxLength={MAX_CHAT_LEN}
          placeholder="Сообщение клиенту…"
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
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
