'use client';

/**
 * Главный экран агента.
 * - Ввод 6-значного кода для подключения к новой сессии
 * - Список активных сессий (auto-refresh каждые 5 сек)
 */

import { useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { apiFetch } from '../lib/api';

type Session = {
  roomName: string;
  code: string;
  customerId: string;
  status: 'waiting' | 'active' | 'ended';
  startedAt: number;
  agentJoinedAt?: number;
};

export default function AgentDashboard() {
  const router = useRouter();
  const [code, setCode] = useState('');
  const [sessions, setSessions] = useState<Session[]>([]);
  const [error, setError] = useState<string | null>(null);

  // Auto-refresh списка сессий
  useEffect(() => {
    const load = async () => {
      try {
        const data = await apiFetch<{ sessions: Session[] }>('/session/list');
        setSessions(data.sessions || []);
      } catch {
        // silently ignore — следующий interval попробует ещё раз
      }
    };
    load();
    const id = setInterval(load, 5000);
    return () => clearInterval(id);
  }, []);

  const handleJoin = (rawCode: string) => {
    const normalized = rawCode.replace(/[^0-9]/g, '');
    if (normalized.length !== 6) {
      setError('Код должен содержать 6 цифр');
      return;
    }
    router.push(`/session/${normalized}`);
  };

  return (
    <main style={styles.container}>
      <h1 style={styles.title}>Cobrowse Agent</h1>

      <section style={styles.card}>
        <h2 style={styles.cardTitle}>Подключиться по коду</h2>
        <div style={styles.codeRow}>
          <input
            type="text"
            inputMode="numeric"
            placeholder="000-000"
            value={code}
            onChange={(e) => setCode(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && handleJoin(code)}
            style={styles.codeInput}
            autoFocus
            maxLength={7}
          />
          <button style={styles.primaryBtn} onClick={() => handleJoin(code)}>
            Подключиться
          </button>
        </div>
        {error && <p style={styles.error}>{error}</p>}
      </section>

      <section style={styles.card}>
        <h2 style={styles.cardTitle}>Ожидающие сессии ({sessions.filter(s => s.status === 'waiting').length})</h2>
        {sessions.length === 0 ? (
          <p style={styles.muted}>Нет активных сессий</p>
        ) : (
          <ul style={styles.sessionList}>
            {sessions.map((s) => (
              <li key={s.roomName} style={styles.sessionItem}>
                <div>
                  <div style={styles.sessionCode}>{s.code}</div>
                  <div style={styles.muted}>
                    {s.customerId} · {formatAge(s.startedAt)}
                  </div>
                </div>
                <div>
                  <span style={statusBadge(s.status)}>{s.status}</span>
                  {s.status === 'waiting' && (
                    <button
                      style={{ ...styles.primaryBtn, marginLeft: 12 }}
                      onClick={() => handleJoin(s.code.replace('-', ''))}
                    >
                      Войти
                    </button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>
    </main>
  );
}

function formatAge(ts: number): string {
  const sec = Math.floor((Date.now() - ts) / 1000);
  if (sec < 60) return `${sec}с назад`;
  return `${Math.floor(sec / 60)}мин назад`;
}

function statusBadge(status: Session['status']): React.CSSProperties {
  const colors = {
    waiting: { bg: '#fef3c7', fg: '#92400e' },
    active: { bg: '#dcfce7', fg: '#166534' },
    ended: { bg: '#e5e7eb', fg: '#374151' },
  }[status];
  return {
    background: colors.bg,
    color: colors.fg,
    padding: '4px 10px',
    borderRadius: 12,
    fontSize: 12,
    fontWeight: 600,
    textTransform: 'uppercase',
  };
}

const styles: Record<string, React.CSSProperties> = {
  container: { maxWidth: 800, margin: '40px auto', padding: '0 20px', fontFamily: 'system-ui, sans-serif' },
  title: { fontSize: 28, fontWeight: 700, marginBottom: 32 },
  card: { background: '#fff', border: '1px solid #e5e7eb', borderRadius: 12, padding: 24, marginBottom: 16 },
  cardTitle: { fontSize: 16, fontWeight: 600, marginBottom: 16, color: '#374151' },
  codeRow: { display: 'flex', gap: 12 },
  codeInput: { flex: 1, padding: '12px 16px', fontSize: 24, fontFamily: 'monospace', letterSpacing: 4, border: '1px solid #d1d5db', borderRadius: 8 },
  primaryBtn: { background: '#2563eb', color: 'white', border: 'none', padding: '0 24px', borderRadius: 8, fontWeight: 600, cursor: 'pointer' },
  error: { color: '#dc2626', marginTop: 8, fontSize: 14 },
  muted: { color: '#6b7280', fontSize: 14 },
  sessionList: { listStyle: 'none', padding: 0, margin: 0 },
  sessionItem: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '12px 0', borderTop: '1px solid #f3f4f6' },
  sessionCode: { fontFamily: 'monospace', fontSize: 18, fontWeight: 600 },
};
