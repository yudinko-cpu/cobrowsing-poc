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
} from '@livekit/components-react';
import type { DisconnectReason, RemoteTrackPublication, TrackPublication } from 'livekit-client';
import '@livekit/components-styles';
import { apiFetch } from '../../../lib/api';

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

  const handleEnd = async () => {
    if (roomName) {
      try {
        await apiFetch('/session/end', {
          method: 'POST',
          body: JSON.stringify({ roomName }),
        });
      } catch {
        // ignore — всё равно уходим на главную
      }
    }
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
      audio={true}    // публикуем мик агента
      video={false}   // не публикуем видео с камеры агента
      data-lk-theme="default"
      style={{ height: '100vh' }}
      onConnected={() => console.log('[viewer] LiveKitRoom onConnected')}
      onDisconnected={(reason?: DisconnectReason) =>
        console.warn('[viewer] LiveKitRoom onDisconnected, reason:', reason)
      }
      onError={(err: Error) => {
        console.error('[viewer] LiveKitRoom onError:', err);
        setError(`LiveKit: ${err.message}`);
      }}
    >
      <SessionView code={params.code} roomName={roomName} serverUrl={serverUrl} onEnd={handleEnd} />
      <RoomAudioRenderer />
    </LiveKitRoom>
  );
}

function SessionView({
  code,
  roomName,
  serverUrl,
  onEnd,
}: {
  code: string;
  roomName?: string;
  serverUrl?: string;
  onEnd: () => void;
}) {
  const remoteParticipants = useRemoteParticipants();
  const connectionState = useConnectionState();

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

  return (
    <div style={styles.viewer}>
      <header style={styles.header}>
        <div>
          <strong>Сессия {code.slice(0, 3)}-{code.slice(3)}</strong>
          <span style={styles.liveBadge}>● LIVE</span>
        </div>
        <button style={styles.endBtn} onClick={onEnd}>Завершить</button>
      </header>

      <div style={styles.videoContainer}>
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
            participantCount={remoteParticipants.length}
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
        />
      </div>

      {/* TODO P1: оверлей для аннотаций, лазерная указка */}
    </div>
  );
}

function WaitingPlaceholder({
  participantCount,
  videoPublications,
}: {
  participantCount: number;
  videoPublications: Array<{ participantIdentity: string; publication: RemoteTrackPublication }>;
}) {
  // Разные плейсхолдеры для разных стадий — понятнее, где мы застряли.
  if (participantCount === 0) {
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

function DebugHUD({
  connectionState,
  roomName,
  serverUrl,
  participantCount,
  videoPublications,
  showingTrack,
}: {
  connectionState: string;
  roomName?: string;
  serverUrl?: string;
  participantCount: number;
  videoPublications: Array<{ participantIdentity: string; publication: RemoteTrackPublication }>;
  showingTrack: boolean;
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
  ];

  return (
    <div style={styles.debugHud}>
      {lines.map((l, i) => (
        <div key={i}>{l}</div>
      ))}
    </div>
  );
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
