'use client';

/**
 * Viewer-страница: подключается к LiveKit Room по коду,
 * отображает screen-share видео клиента + voice chat.
 */

import { useEffect, useMemo, useRef, useState } from 'react';
import { useRouter } from 'next/navigation';
import {
  LiveKitRoom,
  VideoTrack,
  RoomAudioRenderer,
  useRemoteParticipants,
  useConnectionState,
  useLocalParticipant,
  useRoomContext,
} from '@livekit/components-react';
import type { DisconnectReason, RemoteTrack, RemoteTrackPublication, TrackPublication } from 'livekit-client';
import '@livekit/components-styles';
import { apiFetch } from '../../../lib/api';
import { AnnotationOverlay } from './AnnotationOverlay';
import { colorForIdentity } from '../../../lib/anno';

/**
 * Идентичность агента в рамках вкладки браузера. Persist через sessionStorage,
 * иначе после F5 регенерируется новый ID → backend видит "другой агент",
 * который пытается заклаймить чужой код → 409. С sessionStorage refresh
 * работает нормально: тот же agentId → тот же claim.
 *
 * TODO: заменить на реальную авторизацию (JWT из SSO / OAuth).
 */
function getOrCreateAgentId(): string {
  if (typeof window === 'undefined') return 'agent-ssr'; // SSR fallback, никогда не долетит до backend
  const KEY = 'cobrowse.agentId';
  const existing = sessionStorage.getItem(KEY);
  if (existing) return existing;
  const fresh = `agent-${Math.random().toString(36).slice(2, 8)}`;
  sessionStorage.setItem(KEY, fresh);
  return fresh;
}

type JoinResponse = {
  token: string;
  livekitUrl: string;
  roomName: string;
  customerId: string;
};

export default function SessionPage({ params }: { params: { code: string } }) {
  const router = useRouter();
  const [token, setToken] = useState<string>();
  const [serverUrl, setServerUrl] = useState<string>();
  const [roomName, setRoomName] = useState<string>();
  const [error, setError] = useState<string>();

  // Dedup guard против React StrictMode double-mount в dev-режиме. Без него
  // useEffect фаерится дважды, /agent/join зовётся дважды. Даже с идемпотентным
  // backend'ом это лишний round-trip и потенциальные гонки setState. Сохраняем,
  // для какого code уже фетчили — чтобы навигация на другую сессию (смена
  // params.code) корректно перезапускала запрос.
  const fetchedForCodeRef = useRef<string | null>(null);

  useEffect(() => {
    if (fetchedForCodeRef.current === params.code) return;
    fetchedForCodeRef.current = params.code;

    (async () => {
      try {
        const data = await apiFetch<JoinResponse>('/agent/join', {
          method: 'POST',
          body: JSON.stringify({ code: params.code, agentId: getOrCreateAgentId() }),
        });
        setToken(data.token);
        setServerUrl(data.livekitUrl);
        setRoomName(data.roomName);
      } catch (e: unknown) {
        setError(e instanceof Error ? e.message : String(e));
      }
    })();
  }, [params.code]);

  // Co-viewing: агент может только ПОКИНУТЬ сессию, не завершая её для других.
  // Просто уходим на главную — LiveKitRoom при размонтировании сам делает
  // room.disconnect(), клиент и остальные агенты продолжают работу.
  // Комнату закрывает клиент (iOS → /session/end) или TTL / empty_timeout.
  const handleLeave = () => {
    router.push('/');
  };

  if (error) {
    return (
      <div style={styles.center}>
        <h2>Не удалось подключиться</h2>
        <p style={{ color: '#dc2626' }}>{error}</p>
        <button style={styles.btn} onClick={() => router.push('/')}>На главную</button>
      </div>
    );
  }

  if (!token || !serverUrl) {
    return <div style={styles.center}>Подключение…</div>;
  }

  // Однократно логируем то, что backend прислал — чтобы можно было увидеть
  // livekitUrl и roomName в консоли, если участник не подгружается.
  console.log('[viewer] connecting to LiveKit', { serverUrl, roomName });

  return (
    <LiveKitRoom
      token={token}
      serverUrl={serverUrl}
      connect={true}
      // audio/video=false: НЕ запрашиваем медиа-permissions при коннекте.
      // Причины:
      //   * Chrome блокирует getUserMedia на insecure origin (http://<LAN-IP>);
      //     при audio=true это ронит всю сессию в onError с NotAllowedError.
      //   * Даже на secure origin — раньше времени просить permission ухудшает
      //     UX. Пусть агент подключится, посмотрит экран, а мик включит
      //     кнопкой, когда действительно надо говорить.
      audio={false}
      video={false}
      data-lk-theme="default"
      style={{ height: '100vh' }}
      onConnected={() => console.log('[viewer] LiveKitRoom onConnected')}
      onDisconnected={(reason?: DisconnectReason) =>
        console.warn('[viewer] LiveKitRoom onDisconnected, reason:', reason)
      }
      onError={(err: Error) => {
        console.error('[viewer] LiveKitRoom onError:', err);
        // Media permission errors — не фатал: сессия жива, просто без мика.
        // MicToggle сам покажет статус юзеру.
        if (err.name === 'NotAllowedError' || /permission/i.test(err.message)) {
          return;
        }
        setError(`LiveKit: ${err.message}`);
      }}
    >
      <SessionView code={params.code} roomName={roomName} serverUrl={serverUrl} onLeave={handleLeave} />
      <RoomAudioRenderer />
    </LiveKitRoom>
  );
}

function SessionView({
  code,
  roomName,
  serverUrl,
  onLeave,
}: {
  code: string;
  roomName?: string;
  serverUrl?: string;
  onLeave: () => void;
}) {
  const remoteParticipants = useRemoteParticipants();
  const connectionState = useConnectionState();

  // Контейнер видео — точка отсчёта для контент-бокса overlay-аннотаций.
  const videoBoxRef = useRef<HTMLDivElement>(null);

  // Отдельный лог на смену connection state — легко видно в консоли, где
  // именно застряли: connecting / connected / reconnecting / disconnected.
  useEffect(() => {
    console.log('[viewer] connection state:', connectionState);
  }, [connectionState]);

  // Собираем плоский список ВСЕХ video publications от remote-участников,
  // независимо от source. Причина: iOS SDK версии X может паблишить screen
  // с source .unknown или .camera, и жёсткий фильтр `useTracks([ScreenShare])`
  // такой трек молча пропустит. Берём первый video track, что есть — для
  // техподдержки это ровно то, что нужно (один клиент публикует один экран).
  const videoPublications = useMemo(() => {
    const out: Array<{
      participantIdentity: string;
      publication: RemoteTrackPublication;
    }> = [];
    for (const p of remoteParticipants) {
      for (const pub of p.videoTrackPublications.values()) {
        out.push({ participantIdentity: p.identity, publication: pub });
      }
    }
    return out;
  }, [remoteParticipants]);

  // Диагностический лог: раз в обновление печатаем каждого участника и его треки.
  // Убрать / скрыть за флагом после того, как всё точно поедет.
  useEffect(() => {
    if (remoteParticipants.length === 0) {
      console.log('[viewer] no remote participants yet');
      return;
    }
    for (const p of remoteParticipants) {
      const tracks = [...p.trackPublications.values()].map(describePublication);
      console.log(`[viewer] participant ${p.identity}, ${tracks.length} track(s):`, tracks);
    }
  }, [remoteParticipants]);

  // Ищем первый УЖЕ subscribed трек — только он реально что-то нарисует.
  // Если track опубликован, но isSubscribed=false, autoSubscribe где-то сломался
  // (проверить permissions в токене агента: canSubscribe должно быть true).
  const primaryVideo = videoPublications.find((v) => v.publication.isSubscribed && v.publication.track);

  const trackRef = primaryVideo
    ? {
        participant: remoteParticipants.find((p) => p.identity === primaryVideo.participantIdentity)!,
        publication: primaryVideo.publication,
        source: primaryVideo.publication.source,
      }
    : null;

  // WebRTC-статистика по video-track'у. Пуллим раз в секунду напрямую из
  // RTCPeerConnection'а (LiveKit прокидывает наружу через getRTCStatsReport).
  const videoStats = useVideoStats(primaryVideo?.publication);

  // ICE-состояние обоих PC (publisher/subscriber). Показывает где именно
  // застряло: signaling → PC create → gathering → checking → connected.
  // Ключевой признак "could not establish pc connection" — иметь ICE в
  // checking/failed и никогда не выйти в connected.
  const iceState = usePeerConnectionState();

  // Классификация участников по name (проставляется backend'ом в токене:
  // клиент = 'Customer', агент = 'Agent'). Клиент — тот, кто шарит экран.
  // Остальные агенты в комнате — коллеги-операторы (co-viewing).
  const { localParticipant } = useLocalParticipant();
  const customerPresent = remoteParticipants.some((p) => p.name === 'Customer');
  // Ростер агентов: локальный (мы) + удалённые агенты. Дедуп по identity на
  // случай, если local почему-то отразился и в remote-списке.
  const agentRoster = useMemo(() => {
    const remoteAgents = remoteParticipants.filter((p) => p.name === 'Agent');
    const seen = new Set<string>();
    const list: Array<{ identity: string; isLocal: boolean }> = [];
    if (localParticipant) {
      list.push({ identity: localParticipant.identity, isLocal: true });
      seen.add(localParticipant.identity);
    }
    for (const p of remoteAgents) {
      if (seen.has(p.identity)) continue;
      seen.add(p.identity);
      list.push({ identity: p.identity, isLocal: false });
    }
    return list;
  }, [remoteParticipants, localParticipant]);

  return (
    <div style={styles.viewer}>
      <InsecureContextBanner />
      <header style={styles.header}>
        <div style={{ display: 'flex', alignItems: 'center' }}>
          <strong>Сессия {code.slice(0, 3)}-{code.slice(3)}</strong>
          <span style={styles.liveBadge}>● LIVE</span>
        </div>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          <AgentRoster roster={agentRoster} />
          <MicToggle />
          <button style={styles.endBtn} onClick={onLeave} title="Выйти из сессии (для остальных она продолжится)">
            Покинуть
          </button>
        </div>
      </header>

      <div style={styles.videoContainer} ref={videoBoxRef}>
        {/* Локальный override поверх @livekit/components-styles.
            Default .lk-participant-media-video ставит object-fit:cover
            (обрезает по контейнеру). Overrid'ы для source=screen_share есть,
            но срабатывают, только если у track'а именно этот source; мы же
            принимаем любой video, поэтому подстраховываемся !important'ом.
            width/height 100% (а не auto) — важно: с auto video берёт
            intrinsic-размеры (portrait iPhone screen = высокий), из-за чего
            родительский flex-контейнер тянется по content'у и вываливается
            за viewport. С 100% + object-fit:contain video сжимается внутри
            бокса и правильно letterbox'ится. */}
        <style>{`
          .cobrowse-video {
            width: 100% !important;
            height: 100% !important;
            object-fit: contain !important;
            background: transparent !important;
          }
        `}</style>

        {trackRef ? (
          <VideoTrack trackRef={trackRef} className="cobrowse-video" />
        ) : (
          <WaitingPlaceholder
            customerPresent={customerPresent}
            videoPublications={videoPublications}
          />
        )}

        {/* Debug HUD — виден всегда, потому что POC. */}
        <DebugHUD
          connectionState={connectionState}
          roomName={roomName}
          serverUrl={serverUrl}
          participantCount={remoteParticipants.length}
          videoPublications={videoPublications}
          showingTrack={trackRef !== null}
          videoStats={videoStats}
          iceState={iceState}
        />

        {/* Операторские аннотации: SVG-слой поверх контент-бокса видео (ANNO-3).
            Ввод/тулбар — ANNO-4. */}
        <AnnotationOverlay containerRef={videoBoxRef} />
      </div>
    </div>
  );
}

function WaitingPlaceholder({
  customerPresent,
  videoPublications,
}: {
  customerPresent: boolean;
  videoPublications: Array<{ participantIdentity: string; publication: RemoteTrackPublication }>;
}) {
  // Разные плейсхолдеры для разных стадий — понятнее, где мы застряли.
  // Ориентируемся именно на присутствие КЛИЕНТА, а не на общее число
  // участников: другие агенты (co-viewing) не должны выглядеть как "клиент".
  if (!customerPresent) {
    return <div style={styles.waiting}>Клиент ещё не подключился к сессии…</div>;
  }
  if (videoPublications.length === 0) {
    return <div style={styles.waiting}>Клиент подключён, ждём публикации экрана…</div>;
  }
  // Треки есть, но ни один не subscribed — редкий кейс, чаще всего проблема
  // с permissions на токене агента (canSubscribe) или с codec-mismatch.
  return (
    <div style={styles.waiting}>
      Видео опубликовано, но не удалось подписаться.
      <br />
      <small style={{ color: '#6b7280' }}>
        Проверьте permissions агента и совместимость кодеков.
      </small>
    </div>
  );
}

// MARK: — Agent roster

/**
 * Ростер и счётчик агентов в сессии (co-viewing). Показывает, кто из
 * операторов сейчас смотрит один и тот же экран. Данные — из LiveKit
 * presence (local + remote-участники с name='Agent'), backend не опрашиваем.
 * Локальный агент помечен «вы».
 */
function AgentRoster({ roster }: { roster: Array<{ identity: string; isLocal: boolean }> }) {
  const [open, setOpen] = useState(false);
  const count = roster.length;

  return (
    <div style={{ position: 'relative' }}>
      <button
        onClick={() => setOpen((v) => !v)}
        title="Агенты, подключённые к сессии"
        style={{
          background: '#374151',
          color: 'white',
          border: 'none',
          padding: '8px 12px',
          borderRadius: 6,
          cursor: 'pointer',
          fontWeight: 600,
          fontSize: 13,
        }}
      >
        👥 Агентов: {count}
      </button>
      {open && (
        <div style={styles.rosterPopover}>
          {roster.map((a) => (
            <div key={a.identity} style={styles.rosterItem}>
              {/* Цвет метки = цвет аннотаций оператора (colorForIdentity, FNV) —
                  та же палитра, что на iOS: легенда «кто каким цветом рисует». */}
              <span style={{ ...styles.rosterDot, background: colorForIdentity(a.identity) }} />
              <span style={{ fontFamily: 'ui-monospace, monospace' }}>{a.identity}</span>
              {a.isLocal && <span style={styles.rosterYou}>вы</span>}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// MARK: — Microphone toggle

/**
 * Кнопка включения/выключения микрофона агента.
 *
 * Отдельный клик по кнопке — единственный момент, когда мы запрашиваем
 * getUserMedia. Это (а) даёт юзеру контроль, (б) не роняет коннект при
 * denied-permission, (в) обходит проблему автозапроса на insecure origin.
 */
function MicToggle() {
  const { localParticipant, isMicrophoneEnabled } = useLocalParticipant();
  const [pending, setPending] = useState(false);
  const [micError, setMicError] = useState<string | null>(null);

  const toggle = async () => {
    setPending(true);
    setMicError(null);
    try {
      await localParticipant.setMicrophoneEnabled(!isMicrophoneEnabled);
    } catch (e: unknown) {
      const err = e instanceof Error ? e : new Error(String(e));
      // Типовые кейсы, дружелюбно расшифровываем:
      //   NotAllowedError — юзер отказал / браузер блокирует (insecure origin).
      //   NotFoundError   — нет входного устройства.
      let hint = err.message;
      if (err.name === 'NotAllowedError') {
        hint = window.isSecureContext
          ? 'Микрофон отклонён. Проверьте permission в настройках сайта.'
          : 'Небезопасный origin (HTTP на LAN-IP). Chrome не даст мик без HTTPS/localhost.';
      } else if (err.name === 'NotFoundError') {
        hint = 'Микрофон не найден.';
      }
      setMicError(hint);
      console.error('[viewer] setMicrophoneEnabled failed:', err);
    } finally {
      setPending(false);
    }
  };

  const bg = micError ? '#dc2626' : isMicrophoneEnabled ? '#059669' : '#374151';
  const label = pending ? '…' : isMicrophoneEnabled ? '🎤 вкл' : '🎤 выкл';
  const tooltip = micError ?? (isMicrophoneEnabled ? 'Мик включён' : 'Нажмите чтобы включить мик');

  return (
    <button
      onClick={toggle}
      disabled={pending}
      title={tooltip}
      style={{
        background: bg,
        color: 'white',
        border: 'none',
        padding: '8px 12px',
        borderRadius: 6,
        cursor: pending ? 'wait' : 'pointer',
        fontWeight: 600,
        fontSize: 13,
      }}
    >
      {label}
    </button>
  );
}

// MARK: — Insecure context banner

/**
 * Предупреждение, если браузер считает origin небезопасным. На таких страницах
 * getUserMedia не работает вообще — микрофон не включить, ни при каких permission.
 * Единственный способ — HTTPS или запуск на localhost/127.0.0.1.
 */
function InsecureContextBanner() {
  if (typeof window === 'undefined') return null;
  if (window.isSecureContext) return null;

  return (
    <div
      style={{
        background: '#f59e0b',
        color: '#111',
        padding: '8px 20px',
        fontSize: 13,
        fontWeight: 600,
        textAlign: 'center',
      }}
    >
      ⚠ Insecure origin ({location.origin}). Микрофон работать не будет — Chrome требует HTTPS
      или localhost для getUserMedia. Видео можно смотреть без ограничений.
    </div>
  );
}

function DebugHUD({
  connectionState,
  roomName,
  serverUrl,
  participantCount,
  videoPublications,
  showingTrack,
  videoStats,
  iceState,
}: {
  connectionState: string;
  roomName?: string;
  serverUrl?: string;
  participantCount: number;
  videoPublications: Array<{ participantIdentity: string; publication: RemoteTrackPublication }>;
  showingTrack: boolean;
  videoStats: VideoStats;
  iceState: PeerConnectionSnapshot;
}) {
  const lines = [
    `LK conn:     ${connectionState}`,
    `room:        ${roomName ?? '?'}`,
    `livekit url: ${serverUrl ?? '?'}`,
    `participants: ${participantCount}`,
    `video pubs:  ${videoPublications.length}`,
    ...videoPublications.map((v) => {
      const p = v.publication;
      return `  · ${v.participantIdentity}: source=${p.source} subscribed=${p.isSubscribed} muted=${p.isMuted}`;
    }),
    `rendering:   ${showingTrack ? 'yes' : 'no'}`,
    '',
    '── ICE / PC ──',
    `pub  ice: ${iceState.publisherIce ?? '?'}  pc: ${iceState.publisherConn ?? '?'}`,
    `sub  ice: ${iceState.subscriberIce ?? '?'}  pc: ${iceState.subscriberConn ?? '?'}`,
    `selected: ${iceState.selectedAddress ?? '?'}`,
    '',
    '── video stream ──',
    `codec:       ${videoStats.codec ?? '?'}`,
    `resolution:  ${videoStats.resolution ?? '?'}`,
    `fps:         ${videoStats.fps ?? '?'}`,
    `bitrate:     ${formatBitrate(videoStats.bitrateBps)}`,
    `total:       ${formatBytes(videoStats.totalBytes)}`,
    `RTT:         ${videoStats.rttMs !== undefined ? `${videoStats.rttMs.toFixed(0)} ms` : '?'}`,
    `pkt loss:    ${videoStats.packetsLost ?? 0} / ${videoStats.packetsReceived ?? 0}`,
  ];

  return (
    <div style={styles.debugHud}>
      {lines.map((l, i) => (
        <div key={i}>{l || ' '}</div>
      ))}
    </div>
  );
}

// MARK: — Peer connection state

type PeerConnectionSnapshot = {
  publisherIce?: RTCIceConnectionState;
  publisherConn?: RTCPeerConnectionState;
  subscriberIce?: RTCIceConnectionState;
  subscriberConn?: RTCPeerConnectionState;
  /** Адрес выбранного ICE-кандидата ("host:port"), если связь установлена. */
  selectedAddress?: string;
};

/**
 * Возвращает состояние ICE и PC у publisher/subscriber peer connection'ов
 * и адрес выбранной ICE-пары. Ключевое для диагностики "could not establish
 * pc connection" — по состоянию видно, где именно застряло:
 *   - ice=new → PC ещё не создан
 *   - ice=checking, pc=connecting → идёт connectivity check
 *   - ice=failed → ни одна пара кандидатов не сработала
 *   - ice=connected + pc=connected → всё ок
 *
 * `useRoomContext()` даёт живой Room; `room.engine.pcManager` — internal,
 * но стабильно работающее API. Если LiveKit его перепрячут в апгрейде —
 * поле молча станет undefined, HUD покажет ?.
 */
function usePeerConnectionState(): PeerConnectionSnapshot {
  const room = useRoomContext();
  const [snap, setSnap] = useState<PeerConnectionSnapshot>({});

  useEffect(() => {
    if (!room) return;
    let cancelled = false;

    async function tick() {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const pm = (room as any).engine?.pcManager;
      if (!pm) {
        if (!cancelled) setSnap({});
        return;
      }
      const pub = pm.publisher;
      const sub = pm.subscriber;

      // Выбранный адрес: у publisher или subscriber — берём то, что установлено.
      // getConnectedAddress() резолвит host:port из candidate-pair.
      let selectedAddress: string | undefined;
      try {
        selectedAddress = await (pub?.getConnectedAddress?.() ?? sub?.getConnectedAddress?.());
      } catch {
        selectedAddress = undefined;
      }

      if (cancelled) return;
      setSnap({
        publisherIce: pub?.getICEConnectionState?.(),
        publisherConn: pub?.getConnectionState?.(),
        subscriberIce: sub?.getICEConnectionState?.(),
        subscriberConn: sub?.getConnectionState?.(),
        selectedAddress,
      });
    }

    tick();
    const interval = setInterval(tick, 500);
    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [room]);

  return snap;
}

// MARK: — Video stats hook

type VideoStats = {
  /** e.g. "H264", "VP8". */
  codec?: string;
  /** "1280x720" */
  resolution?: string;
  fps?: number;
  /** Мгновенный битрейт, bits/s. */
  bitrateBps: number;
  /** Кумулятивно с момента подписки. */
  totalBytes: number;
  /** Round-trip time, миллисекунды. */
  rttMs?: number;
  packetsReceived?: number;
  packetsLost?: number;
};

const DEFAULT_VIDEO_STATS: VideoStats = { bitrateBps: 0, totalBytes: 0 };

/**
 * Пуллит RTCStatsReport с track'а раз в секунду и парсит инкремент байт →
 * мгновенный битрейт, плюс codec / resolution / fps / RTT / потери.
 *
 * RTT берём в порядке приоритета:
 *   1. candidate-pair.currentRoundTripTime (ICE-уровень, свежее всех)
 *   2. remote-inbound-rtp.roundTripTime (RTCP receiver report)
 * Обычно есть либо одно, либо другое.
 */
function useVideoStats(publication: RemoteTrackPublication | undefined): VideoStats {
  const [stats, setStats] = useState<VideoStats>(DEFAULT_VIDEO_STATS);
  const prevRef = useRef<{ bytesReceived: number; timestamp: number } | null>(null);

  useEffect(() => {
    const track = publication?.track as RemoteTrack | undefined;
    if (!track) {
      setStats(DEFAULT_VIDEO_STATS);
      prevRef.current = null;
      return;
    }

    let cancelled = false;

    async function poll() {
      let report: RTCStatsReport | undefined;
      try {
        report = await track!.getRTCStatsReport();
      } catch {
        return;
      }
      if (cancelled || !report) return;

      // Собираем нужные stat-объекты одним проходом.
      let inbound: RTCInboundRtpStreamStats | undefined;
      let remoteInbound: (RTCRtpStreamStats & { roundTripTime?: number }) | undefined;
      let candidatePair: (RTCIceCandidatePairStats & { currentRoundTripTime?: number }) | undefined;
      let codecId: string | undefined;

      report.forEach((s: RTCStats) => {
        if (s.type === 'inbound-rtp' && (s as RTCInboundRtpStreamStats).kind === 'video') {
          inbound = s as RTCInboundRtpStreamStats;
          codecId = (s as RTCInboundRtpStreamStats & { codecId?: string }).codecId;
        } else if (s.type === 'remote-inbound-rtp' && (s as RTCRtpStreamStats).kind === 'video') {
          remoteInbound = s as RTCRtpStreamStats & { roundTripTime?: number };
        } else if (
          s.type === 'candidate-pair' &&
          (s as RTCIceCandidatePairStats).state === 'succeeded' &&
          (s as RTCIceCandidatePairStats & { nominated?: boolean }).nominated
        ) {
          candidatePair = s as RTCIceCandidatePairStats & { currentRoundTripTime?: number };
        }
      });

      if (!inbound) return;

      // Codec: mimeType в отдельной stat, ссылаемся через codecId.
      let codec: string | undefined;
      if (codecId) {
        const codecStat = report.get(codecId) as (RTCStats & { mimeType?: string }) | undefined;
        if (codecStat?.mimeType) {
          codec = codecStat.mimeType.replace(/^video\//i, '').toUpperCase();
        }
      }

      const inb = inbound as RTCInboundRtpStreamStats & {
        bytesReceived?: number;
        framesPerSecond?: number;
        frameWidth?: number;
        frameHeight?: number;
        packetsReceived?: number;
        packetsLost?: number;
      };
      const bytesReceived = inb.bytesReceived ?? 0;
      const now = performance.now();

      let bitrateBps = 0;
      if (prevRef.current) {
        const deltaBytes = bytesReceived - prevRef.current.bytesReceived;
        const deltaSec = (now - prevRef.current.timestamp) / 1000;
        if (deltaSec > 0 && deltaBytes >= 0) {
          bitrateBps = (deltaBytes * 8) / deltaSec;
        }
      }
      prevRef.current = { bytesReceived, timestamp: now };

      const rttSec =
        candidatePair?.currentRoundTripTime ?? remoteInbound?.roundTripTime ?? undefined;
      const rttMs = rttSec !== undefined ? rttSec * 1000 : undefined;

      setStats({
        codec,
        resolution:
          inb.frameWidth && inb.frameHeight ? `${inb.frameWidth}x${inb.frameHeight}` : undefined,
        fps: inb.framesPerSecond !== undefined ? Math.round(inb.framesPerSecond) : undefined,
        bitrateBps,
        totalBytes: bytesReceived,
        rttMs,
        packetsReceived: inb.packetsReceived,
        packetsLost: inb.packetsLost,
      });
    }

    // Первый опрос сразу, дальше — раз в секунду.
    poll();
    const interval = setInterval(poll, 1000);

    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [publication?.track]);

  return stats;
}

function formatBitrate(bps: number): string {
  if (bps < 1_000) return `${bps.toFixed(0)} bps`;
  if (bps < 1_000_000) return `${(bps / 1_000).toFixed(0)} kbps`;
  return `${(bps / 1_000_000).toFixed(2)} Mbps`;
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(2)} MB`;
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

/** Компактный дамп публикации для консоли — удобно раскрывать в DevTools. */
function describePublication(pub: TrackPublication) {
  return {
    trackSid: pub.trackSid,
    trackName: pub.trackName,
    kind: pub.kind,
    source: pub.source,
    isMuted: pub.isMuted,
    isSubscribed: (pub as RemoteTrackPublication).isSubscribed ?? 'n/a',
    hasTrack: !!pub.track,
    dimensions: pub.dimensions
      ? `${pub.dimensions.width}x${pub.dimensions.height}`
      : 'n/a',
  };
}

const styles: Record<string, React.CSSProperties> = {
  center: { display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', height: '100vh', gap: 16, fontFamily: 'system-ui' },
  btn: { background: '#2563eb', color: 'white', border: 'none', padding: '8px 16px', borderRadius: 8, cursor: 'pointer' },
  viewer: { display: 'flex', flexDirection: 'column', height: '100vh', background: '#000', color: 'white', fontFamily: 'system-ui' },
  header: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '12px 20px', background: '#1f2937' },
  liveBadge: { marginLeft: 12, color: '#f87171', fontSize: 12, fontWeight: 700 },
  endBtn: { background: '#dc2626', color: 'white', border: 'none', padding: '8px 16px', borderRadius: 6, cursor: 'pointer', fontWeight: 600 },
  rosterPopover: {
    position: 'absolute',
    top: 'calc(100% + 6px)',
    right: 0,
    zIndex: 10,
    minWidth: 200,
    background: '#111827',
    border: '1px solid #374151',
    borderRadius: 8,
    padding: 8,
    boxShadow: '0 8px 24px rgba(0,0,0,0.4)',
  },
  rosterItem: { display: 'flex', alignItems: 'center', gap: 8, padding: '6px 8px', fontSize: 13 },
  rosterDot: { width: 8, height: 8, borderRadius: '50%', background: '#22c55e', flex: '0 0 auto' },
  rosterYou: { marginLeft: 'auto', fontSize: 11, color: '#93c5fd', fontWeight: 600 },
  // minHeight: 0 — обязательно для flex-item в column-родителе. Без него
  // default min-height: auto = intrinsic content size, и если video внутри
  // хочет быть высоким (portrait iPhone), контейнер разрастается за пределы
  // flex-share, выталкивая всё за viewport → появляется скролл. С min-height:0
  // flex-share (calculated from parent height − siblings) корректно ограничивает.
  videoContainer: { flex: 1, minHeight: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', position: 'relative' },
  waiting: { color: '#9ca3af', fontSize: 18, textAlign: 'center', lineHeight: 1.5 },
  debugHud: {
    position: 'absolute',
    left: 12,
    bottom: 12,
    padding: '8px 12px',
    background: 'rgba(0,0,0,0.7)',
    color: '#9ca3af',
    fontFamily: 'ui-monospace, SFMono-Regular, monospace',
    fontSize: 11,
    lineHeight: 1.5,
    borderRadius: 6,
    pointerEvents: 'none',
    whiteSpace: 'pre',
  },
};
