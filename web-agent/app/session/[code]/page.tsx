'use client';

/**
 * Viewer-страница: подключается к LiveKit Room по коду,
 * отображает screen-share видео клиента + voice chat.
 */

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import {
  LiveKitRoom,
  VideoTrack,
  useTracks,
  RoomAudioRenderer,
} from '@livekit/components-react';
import { Track } from 'livekit-client';
import '@livekit/components-styles';
import { apiFetch } from '../../../lib/api';

const AGENT_ID = `agent-${Math.random().toString(36).slice(2, 8)}`; // TODO: реальная авторизация

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

  useEffect(() => {
    (async () => {
      try {
        const data = await apiFetch<JoinResponse>('/agent/join', {
          method: 'POST',
          body: JSON.stringify({ code: params.code, agentId: AGENT_ID }),
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

  return (
    <LiveKitRoom
      token={token}
      serverUrl={serverUrl}
      connect={true}
      audio={true}    // публикуем мик агента
      video={false}   // не публикуем видео с камеры агента
      data-lk-theme="default"
      style={{ height: '100vh' }}
    >
      <SessionView code={params.code} onEnd={handleEnd} />
      <RoomAudioRenderer />
    </LiveKitRoom>
  );
}

function SessionView({ code, onEnd }: { code: string; onEnd: () => void }) {
  const screenTracks = useTracks([Track.Source.ScreenShare]);
  const clientScreen = screenTracks[0]; // первый (и единственный) экран клиента

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
        {clientScreen ? (
          <VideoTrack
            trackRef={clientScreen}
            style={{ width: '100%', height: '100%', objectFit: 'contain' }}
          />
        ) : (
          <div style={styles.waiting}>
            Ждём, пока клиент начнёт делиться экраном…
          </div>
        )}
      </div>

      {/* TODO P1: оверлей для аннотаций, лазерная указка */}
    </div>
  );
}

const styles: Record<string, React.CSSProperties> = {
  center: { display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', height: '100vh', gap: 16, fontFamily: 'system-ui' },
  btn: { background: '#2563eb', color: 'white', border: 'none', padding: '8px 16px', borderRadius: 8, cursor: 'pointer' },
  viewer: { display: 'flex', flexDirection: 'column', height: '100vh', background: '#000', color: 'white', fontFamily: 'system-ui' },
  header: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '12px 20px', background: '#1f2937' },
  liveBadge: { marginLeft: 12, color: '#f87171', fontSize: 12, fontWeight: 700 },
  endBtn: { background: '#dc2626', color: 'white', border: 'none', padding: '8px 16px', borderRadius: 6, cursor: 'pointer', fontWeight: 600 },
  videoContainer: { flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', position: 'relative' },
  waiting: { color: '#9ca3af', fontSize: 18 },
};
