/**
 * Тесты протокола аннотаций (ANNO-0). Прогон: `npx tsx lib/anno.test.ts`.
 *
 * Покрывает: round-trip кодека, letterbox-координаты, паритет FNV-хэша по
 * эталонным векторам (гарантирует совпадение цветов со Swift), reducer и
 * мульти-юзер семантику. Фреймворк не нужен — node:assert.
 */

import assert from 'node:assert/strict';
import {
  ANNO_VERSION,
  type AnnoMsg,
  encode,
  decode,
  contentRect,
  toNormalized,
  fromNormalized,
  fnv1a32,
  colorForIdentity,
  PALETTE,
  newState,
  apply,
  removeAuthor,
  expirePointers,
  snapshot,
  isReliable,
  IdGen,
  pointerOpacity,
  POINTER_HOLD_MS,
  POINTER_TTL_MS,
  quantize,
  simplifyPath,
  encodedSize,
  MAX_PACKET_BYTES,
  MAX_PATH_POINTS,
  ANNO_TOPIC,
} from './anno.ts';

let passed = 0;
function test(name: string, fn: () => void) {
  fn();
  passed++;
  console.log(`  ✓ ${name}`);
}

// ── Кодек ────────────────────────────────────────────────────────────────────

test('codec round-trip сохраняет сообщение', () => {
  const msg: AnnoMsg = {
    v: ANNO_VERSION,
    op: 'add',
    author: 'agent-ab12cd',
    id: 'agent-ab12cd:1',
    ts: 1720000000000,
    kind: 'path',
    color: '#ff375f',
    w: 0.006,
    pts: [
      [0.1, 0.2],
      [0.3, 0.4],
    ],
  };
  const back = decode(encode(msg));
  assert.deepEqual(back, msg);
});

test('decode отвергает битый JSON и чужую версию', () => {
  assert.equal(decode(new TextEncoder().encode('{not json')), null);
  const wrongVer = new TextEncoder().encode(JSON.stringify({ v: 999, op: 'add', author: 'x', ts: 1 }));
  assert.equal(decode(wrongVer), null);
  const noAuthor = new TextEncoder().encode(JSON.stringify({ v: ANNO_VERSION, op: 'add', ts: 1 }));
  assert.equal(decode(noAuthor), null);
});

// ── Координаты (letterbox) ───────────────────────────────────────────────────

test('contentRect леттербоксит landscape-видео в portrait-элементе', () => {
  // Элемент 400x800 (портрет), видео 16:9 (1280x720, landscape) → полосы сверху/снизу.
  const r = contentRect({ left: 0, top: 0, width: 400, height: 800 }, 1280, 720);
  assert.equal(r.w, 400); // ширина заполнена
  assert.equal(r.h, 225); // 400 * 720/1280
  assert.equal(r.x, 0);
  assert.equal(r.y, (800 - 225) / 2); // отцентрировано по вертикали
});

test('toNormalized/fromNormalized — обратимость и центр', () => {
  const r = contentRect({ left: 0, top: 0, width: 400, height: 800 }, 720, 1280); // портрет-видео
  // центр контента
  const cx = r.x + r.w / 2;
  const cy = r.y + r.h / 2;
  const n = toNormalized(cx, cy, r)!;
  assert.ok(Math.abs(n[0] - 0.5) < 1e-9 && Math.abs(n[1] - 0.5) < 1e-9);
  const back = fromNormalized(n[0], n[1], r);
  assert.ok(Math.abs(back.x - cx) < 1e-9 && Math.abs(back.y - cy) < 1e-9);
});

test('toNormalized возвращает null вне контент-бокса (letterbox-полоса)', () => {
  const r = contentRect({ left: 0, top: 0, width: 400, height: 800 }, 1280, 720);
  // точка в верхней чёрной полосе (y=10, контент начинается ниже)
  assert.equal(toNormalized(200, 10, r), null);
});

// ── Цвета: эталонные векторы FNV-1a (лочат паритет со Swift) ──────────────────

test('fnv1a32 совпадает с эталонными векторами', () => {
  assert.equal(fnv1a32(''), 2166136261); // 0x811c9dc5
  assert.equal(fnv1a32('a'), 3826002220); // 0xe40c292c
  assert.equal(fnv1a32('foobar'), 3214735720); // 0xbf9cf968
});

test('colorForIdentity детерминирован и из палитры', () => {
  const c1 = colorForIdentity('agent-ab12cd');
  const c2 = colorForIdentity('agent-ab12cd');
  assert.equal(c1, c2);
  assert.ok(PALETTE.includes(c1));
});

// ── Reducer: базовый жизненный цикл ──────────────────────────────────────────

const now = 1720000000000;
const mk = (op: AnnoMsg['op'], author: string, extra: Partial<AnnoMsg> = {}): AnnoMsg => ({
  v: ANNO_VERSION,
  op,
  author,
  ts: now,
  ...extra,
});

test('add → append (path) → end накапливает точки', () => {
  const s = newState();
  apply(s, mk('add', 'a', { id: 'a:1', kind: 'path', pts: [[0, 0]] }));
  apply(s, mk('append', 'a', { id: 'a:1', pts: [[0.1, 0.1]] }));
  apply(s, mk('append', 'a', { id: 'a:1', pts: [[0.2, 0.2]] }));
  apply(s, mk('end', 'a', { id: 'a:1' }));
  assert.deepEqual(s.items.get('a:1')!.pts, [
    [0, 0],
    [0.1, 0.1],
    [0.2, 0.2],
  ]);
});

test('append к чужому id игнорируется', () => {
  const s = newState();
  apply(s, mk('add', 'a', { id: 'a:1', kind: 'path', pts: [[0, 0]] }));
  apply(s, mk('append', 'b', { id: 'a:1', pts: [[9, 9]] })); // b дополняет чужое
  assert.deepEqual(s.items.get('a:1')!.pts, [[0, 0]]);
});

test('remove снимает только свою аннотацию', () => {
  const s = newState();
  apply(s, mk('add', 'a', { id: 'a:1', kind: 'arrow', from: [0, 0], to: [1, 1] }));
  apply(s, mk('remove', 'b', { id: 'a:1' })); // чужой remove — no-op
  assert.ok(s.items.has('a:1'));
  apply(s, mk('remove', 'a', { id: 'a:1' }));
  assert.ok(!s.items.has('a:1'));
});

// ── Права: только операторы пишут ────────────────────────────────────────────

test('isAgent-гейт отсекает клиента', () => {
  const s = newState();
  const isAgent = (author: string) => author !== 'Customer';
  apply(s, mk('add', 'Customer', { id: 'Customer:1', kind: 'path', pts: [[0, 0]] }), isAgent);
  assert.equal(s.items.size, 0);
  apply(s, mk('add', 'agent-x', { id: 'agent-x:1', kind: 'path', pts: [[0, 0]] }), isAgent);
  assert.equal(s.items.size, 1);
});

// ── Мульти-юзер: конкурентность и clear scope ────────────────────────────────

test('две одновременные аннотации разных авторов не конфликтуют', () => {
  const s = newState();
  apply(s, mk('add', 'a', { id: 'a:1', kind: 'path', pts: [[0, 0]] }));
  apply(s, mk('add', 'b', { id: 'b:1', kind: 'path', pts: [[1, 1]] }));
  assert.equal(s.items.size, 2);
});

test('clear own снимает только свои; clear all — всё', () => {
  const s = newState();
  apply(s, mk('add', 'a', { id: 'a:1', kind: 'path', pts: [[0, 0]] }));
  apply(s, mk('add', 'b', { id: 'b:1', kind: 'path', pts: [[1, 1]] }));
  apply(s, mk('pointer', 'a', { at: [0.5, 0.5] }));
  apply(s, mk('clear', 'a', { scope: 'own' }));
  assert.ok(!s.items.has('a:1') && s.items.has('b:1'));
  assert.ok(!s.pointers.has('a'));
  apply(s, mk('clear', 'b', { scope: 'all' }));
  assert.equal(s.items.size, 0);
});

// ── Указки: set / expire ─────────────────────────────────────────────────────

test('pointer ставится и протухает по ttl', () => {
  const s = newState();
  apply(s, mk('pointer', 'a', { at: [0.2, 0.3] }));
  assert.ok(s.pointers.has('a'));
  expirePointers(s, now + 500); // в пределах ttl 1000
  assert.ok(s.pointers.has('a'));
  expirePointers(s, now + 2000); // за ttl
  assert.ok(!s.pointers.has('a'));
});

// ── Ресинк и уход автора ─────────────────────────────────────────────────────

test('snapshot → sync-state восстанавливает состояние у нового клиента', () => {
  const src = newState();
  apply(src, mk('add', 'a', { id: 'a:1', kind: 'shape', shape: 'rect', from: [0, 0], to: [0.5, 0.5] }));
  apply(src, mk('add', 'b', { id: 'b:1', kind: 'text', at: [0.1, 0.1], text: 'hi' }));
  const items = snapshot(src);

  const dst = newState();
  apply(dst, mk('sync-state', 'a', { items }));
  assert.equal(dst.items.size, 2);
  assert.deepEqual(dst.items.get('a:1'), src.items.get('a:1'));
});

test('3 оператора: раздельные наборы, свои цвета, уход снимает только своё', () => {
  const s = newState();
  const ops = ['agent-a', 'agent-b', 'agent-c'];
  // каждый рисует по 2 аннотации своим цветом
  for (const op of ops) {
    apply(s, mk('add', op, { id: `${op}:1`, kind: 'path', color: colorForIdentity(op), pts: [[0, 0]] }));
    apply(s, mk('add', op, { id: `${op}:2`, kind: 'arrow', color: colorForIdentity(op), from: [0, 0], to: [1, 1] }));
  }
  assert.equal(s.items.size, 6);
  // цвета не перемешаны — у каждой аннотации цвет своего автора
  for (const a of s.items.values()) {
    assert.equal(a.color, colorForIdentity(a.author));
  }
  // ушёл agent-b → снимаются только его две
  removeAuthor(s, 'agent-b');
  assert.equal(s.items.size, 4);
  assert.ok(![...s.items.values()].some((a) => a.author === 'agent-b'));
  assert.ok([...s.items.values()].some((a) => a.author === 'agent-a'));
  assert.ok([...s.items.values()].some((a) => a.author === 'agent-c'));
});

test('повторный sync-state не создаёт дубликатов (F5 оператора)', () => {
  const src = newState();
  apply(src, mk('add', 'a', { id: 'a:1', kind: 'path', pts: [[0, 0]] }));
  apply(src, mk('add', 'b', { id: 'b:1', kind: 'arrow', from: [0, 0], to: [1, 1] }));
  const items = snapshot(src);

  const dst = newState();
  apply(dst, mk('sync-state', 'client', { items }));
  apply(dst, mk('sync-state', 'client', { items })); // повторный ресинк
  assert.equal(dst.items.size, 2);
});

test('снапшот для sync-state не содержит эфемерных указок', () => {
  const s = newState();
  apply(s, mk('add', 'a', { id: 'a:1', kind: 'path', pts: [[0, 0]] }));
  apply(s, mk('pointer', 'a', { at: [0.5, 0.5] }));
  const items = snapshot(s);
  assert.equal(items.length, 1);
  assert.equal(items[0].kind, 'path');
});

test('removeAuthor чистит аннотации ушедшего оператора', () => {
  const s = newState();
  apply(s, mk('add', 'a', { id: 'a:1', kind: 'path', pts: [[0, 0]] }));
  apply(s, mk('add', 'b', { id: 'b:1', kind: 'path', pts: [[1, 1]] }));
  apply(s, mk('pointer', 'a', { at: [0.5, 0.5] }));
  removeAuthor(s, 'a');
  assert.ok(!s.items.has('a:1') && s.items.has('b:1') && !s.pointers.has('a'));
});

// ── Надёжность и id ──────────────────────────────────────────────────────────

test('isReliable: pointer/append lossy, остальное reliable', () => {
  assert.equal(isReliable('pointer'), false);
  assert.equal(isReliable('append'), false);
  assert.equal(isReliable('add'), true);
  assert.equal(isReliable('end'), true);
  assert.equal(isReliable('clear'), true);
});

test('IdGen выдаёт стабильные author-scoped id', () => {
  const g = new IdGen('agent-x');
  assert.equal(g.next(), 'agent-x:1');
  assert.equal(g.next(), 'agent-x:2');
});

test('pointerOpacity: hold → линейный спад → 0', () => {
  assert.equal(pointerOpacity(0), 1);
  assert.equal(pointerOpacity(POINTER_HOLD_MS), 1);
  const mid = (POINTER_HOLD_MS + POINTER_TTL_MS) / 2;
  assert.ok(Math.abs(pointerOpacity(mid) - 0.5) < 1e-9);
  assert.equal(pointerOpacity(POINTER_TTL_MS), 0);
  assert.equal(pointerOpacity(POINTER_TTL_MS + 100), 0);
});

// ── ANNO-7: устойчивость к потерям и размеры пакетов ─────────────────────────

test('AC4: потеря lossy-append не искажает финальную геометрию', () => {
  // Оператор ведёт штрих из 6 точек; в сеть уходят add + append'ы + end.
  const full: [number, number][] = [
    [0.1, 0.1],
    [0.2, 0.15],
    [0.3, 0.25],
    [0.4, 0.2],
    [0.5, 0.3],
    [0.6, 0.35],
  ];

  const receiver = newState();
  apply(receiver, mk('add', 'a', { id: 'a:1', kind: 'path', pts: [full[0]] }));
  // Часть append'ов «потерялась» — доходит только один из середины.
  apply(receiver, mk('append', 'a', { id: 'a:1', pts: [full[2]] }));
  // Финальный end (reliable) несёт полную геометрию.
  apply(receiver, mk('end', 'a', { id: 'a:1', pts: full }));

  assert.deepEqual(receiver.items.get('a:1')!.pts, full);
});

test('simplifyPath сохраняет концы и сокращает лишние точки', () => {
  // Почти прямая линия из 50 точек → должна ужаться до пары концов.
  const pts: [number, number][] = [];
  for (let i = 0; i < 50; i++) pts.push([i / 49, 0.5]);
  const out = simplifyPath(pts);
  assert.deepEqual(out[0], quantize(pts[0]));
  assert.deepEqual(out[out.length - 1], quantize(pts[pts.length - 1]));
  assert.ok(out.length < pts.length);
});

test('simplifyPath не превышает жёсткий кап точек', () => {
  // Пила: RDP почти ничего не выбросит, сработает децимация.
  const pts: [number, number][] = [];
  for (let i = 0; i < 3000; i++) pts.push([i / 2999, i % 2 === 0 ? 0.2 : 0.8]);
  const out = simplifyPath(pts);
  assert.ok(out.length <= MAX_PATH_POINTS, `points=${out.length}`);
});

test('AC2: длинный штрих в end влезает в лимит пакета', () => {
  const pts: [number, number][] = [];
  for (let i = 0; i < 5000; i++) {
    pts.push([Math.random(), Math.random()]);
  }
  const msg = mk('end', 'agent-abcdef', { id: 'agent-abcdef:1', pts: simplifyPath(pts) });
  const size = encodedSize(msg);
  assert.ok(size < MAX_PACKET_BYTES, `size=${size}`);
});

test('quantize округляет до 4 знаков', () => {
  assert.deepEqual(quantize([0.123456789, 0.987654321]), [0.1235, 0.9877]);
});

test('топик протокола стабилен', () => {
  assert.equal(ANNO_TOPIC, 'cobrowse.anno');
});

console.log(`\n${passed} tests passed.`);
