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
  expireClicks,
  clickProgress,
  CLICK_TTL_MS,
  MAX_CHAT_LEN,
  clampChatText,
  CLIENT_PSEUDO_AUTHOR,
  type ChatItem,
} from './anno.ts';
import {
  chatFromMsg,
  chatHistoryFromMsg,
  makeChatMsg,
  isChatOp,
  typingFromMsg,
  makeTypingMsg,
  TypingTracker,
} from './chat.ts';

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

// ── Клик указкой ──────────────────────────────────────────────────────────────

test('click ставится и истекает по TTL', () => {
  const s = newState();
  apply(s, mk('click', 'a', { at: [0.3, 0.4] }));
  assert.equal(s.clicks.size, 1);
  expireClicks(s, now + CLICK_TTL_MS / 2);
  assert.equal(s.clicks.size, 1);
  expireClicks(s, now + CLICK_TTL_MS + 50);
  assert.equal(s.clicks.size, 0);
});

test('несколько кликов подряд сосуществуют (ключ по ts)', () => {
  const s = newState();
  apply(s, { v: ANNO_VERSION, op: 'click', author: 'a', ts: now, at: [0.1, 0.1] });
  apply(s, { v: ANNO_VERSION, op: 'click', author: 'a', ts: now + 100, at: [0.2, 0.2] });
  assert.equal(s.clicks.size, 2);
});

test('clear own и removeAuthor убирают клики автора', () => {
  const s = newState();
  apply(s, mk('click', 'a', { at: [0.1, 0.1] }));
  apply(s, { v: ANNO_VERSION, op: 'click', author: 'b', ts: now + 1, at: [0.2, 0.2] });
  apply(s, mk('clear', 'a', { scope: 'own' }));
  assert.equal(s.clicks.size, 1);
  removeAuthor(s, 'b');
  assert.equal(s.clicks.size, 0);
});

test('clickProgress идёт 0→1 и зажимается', () => {
  assert.equal(clickProgress(0), 0);
  assert.ok(Math.abs(clickProgress(CLICK_TTL_MS / 2) - 0.5) < 1e-9);
  assert.equal(clickProgress(CLICK_TTL_MS), 1);
  assert.equal(clickProgress(CLICK_TTL_MS * 3), 1);
});

test('click — reliable (разовое событие-акцент)', () => {
  assert.equal(isReliable('click'), true);
});

// ── Чат поддержки (op chat) ───────────────────────────────────────────────────

test('chat: round-trip кодека и reliable', () => {
  const msg = mk('chat', 'agent-a', { id: 'agent-a:1', text: 'привет' });
  assert.deepEqual(decode(encode(msg)), msg);
  assert.equal(isReliable('chat'), true);
});

test('chat не трогает состояние аннотаций', () => {
  const s = newState();
  apply(s, mk('add', 'a', { id: 'a:1', kind: 'path', pts: [[0.1, 0.1]] }));
  apply(s, mk('chat', 'a', { id: 'a:2', text: 'не аннотация' }));
  assert.equal(s.items.size, 1);
  assert.equal(s.items.has('a:2'), false);
  assert.equal(s.pointers.size, 0);
  assert.equal(s.clicks.size, 0);
});

test('clampChatText: trim + лимит', () => {
  assert.equal(clampChatText('  hi \n'), 'hi');
  assert.equal(clampChatText('   '), '');
  assert.equal(clampChatText('a'.repeat(MAX_CHAT_LEN + 5)).length, MAX_CHAT_LEN);
});

test('chatFromMsg отвергает пустой/пробельный/отсутствующий text и чужой op', () => {
  assert.equal(chatFromMsg(mk('chat', 'a', { id: 'a:1', text: '' }), 'a'), null);
  assert.equal(chatFromMsg(mk('chat', 'a', { id: 'a:1', text: '  \n ' }), 'a'), null);
  assert.equal(chatFromMsg(mk('chat', 'a', { id: 'a:1' }), 'a'), null);
  assert.equal(chatFromMsg(mk('add', 'a', { id: 'a:1', kind: 'text', text: 'x' }), 'a'), null);
});

test('chatFromMsg: автор из identity отправителя, ключ дедупа author|id', () => {
  const msg = mk('chat', 'spoofed', { id: 'client:7', text: '  ок  ' });
  const cm = chatFromMsg(msg, 'customer-real')!;
  assert.equal(cm.author, 'customer-real');
  assert.equal(cm.key, 'customer-real|client:7');
  assert.equal(cm.text, 'ок');
  assert.equal(cm.ts, msg.ts);
  // Без identity от транспорта — fallback на payload.author; без id — на ts.
  const fb = chatFromMsg(mk('chat', 'agent-b', { text: 'x' }))!;
  assert.equal(fb.author, 'agent-b');
  assert.equal(fb.key, `agent-b|${fb.ts}`);
});

test('makeChatMsg: null на пустом, иначе конверт v/op/id/text', () => {
  assert.equal(makeChatMsg('agent-a', 'agent-a:1', '   '), null);
  const msg = makeChatMsg('agent-a', 'agent-a:1', ' привет ', 123)!;
  assert.deepEqual(msg, { v: ANNO_VERSION, op: 'chat', author: 'agent-a', ts: 123, id: 'agent-a:1', text: 'привет' });
});

// ── «Печатает» (op typing) ────────────────────────────────────────────────────

test('typing: round-trip, reliable, не трогает аннотации, isChatOp', () => {
  const msg = mk('typing', 'agent-a', { typing: true });
  assert.deepEqual(decode(encode(msg)), msg);
  assert.equal(isReliable('typing'), true);
  const s = newState();
  apply(s, msg);
  assert.equal(s.items.size + s.pointers.size + s.clicks.size, 0);
  assert.equal(isChatOp('typing'), true);
  assert.equal(isChatOp('chat'), true);
  assert.equal(isChatOp('add'), false);
});

test('typingFromMsg: автор из identity, флаг только при typing === true', () => {
  const on = typingFromMsg(mk('typing', 'spoofed', { typing: true }), 'customer-1')!;
  assert.deepEqual(on, { author: 'customer-1', typing: true, ts: now });
  const off = typingFromMsg(mk('typing', 'agent-b', { typing: false }))!;
  assert.equal(off.author, 'agent-b');
  assert.equal(off.typing, false);
  assert.equal(typingFromMsg(mk('typing', 'a', {}), 'a')!.typing, false);
  assert.equal(typingFromMsg(mk('chat', 'a', { id: 'a:1', text: 'x' }), 'a'), null);
});

test('TypingTracker: heartbeat не чаще интервала, стоп один раз, reset', () => {
  const t = new TypingTracker(2000);
  assert.equal(t.onDraftChange(true, 0), true); // первый символ — сразу
  assert.equal(t.onDraftChange(true, 500), null); // внутри интервала — тишина
  assert.equal(t.onDraftChange(true, 2000), true); // heartbeat
  assert.equal(t.onDraftChange(false, 2100), false); // черновик опустел — стоп
  assert.equal(t.onDraftChange(false, 2200), null); // повторно не шлём
  assert.equal(t.onDraftChange(true, 2300), true); // снова печатает
  t.reset(); // сообщение отправлено
  assert.equal(t.onDraftChange(false, 2400), null); // стоп не нужен
  assert.equal(t.onDraftChange(true, 2500), true);
});

test('makeTypingMsg: конверт v/op/typing', () => {
  assert.deepEqual(makeTypingMsg('agent-a', false, 5), { v: ANNO_VERSION, op: 'typing', author: 'agent-a', ts: 5, typing: false });
});

// ── История чата (op chat-sync) ───────────────────────────────────────────────

test('chat-sync: round-trip, reliable, isChatOp, не трогает аннотации', () => {
  const msg = mk('chat-sync', CLIENT_PSEUDO_AUTHOR, {
    history: [{ id: 'client:1', author: CLIENT_PSEUDO_AUTHOR, text: 'привет', ts: now }],
  });
  assert.deepEqual(decode(encode(msg)), msg);
  assert.equal(isReliable('chat-sync'), true);
  assert.equal(isChatOp('chat-sync'), true);
  const s = newState();
  apply(s, msg);
  assert.equal(s.items.size, 0);
});

test('chatHistoryFromMsg: псевдо-автор телефона → identity отправителя, ключи как у живых', () => {
  const msg = mk('chat-sync', CLIENT_PSEUDO_AUTHOR, {
    history: [
      { id: 'agent-a:1', author: 'agent-a', text: 'Здравствуйте', ts: 1 },
      { id: 'client:1', author: CLIENT_PSEUDO_AUTHOR, text: '  Привет  ', ts: 2 },
      { id: 'client:2', author: CLIENT_PSEUDO_AUTHOR, text: '   ', ts: 3 }, // пустой — пропускаем
      { id: 42, author: 'agent-a', text: 'x', ts: 4 } as unknown as ChatItem, // битый — пропускаем
    ],
  });
  const out = chatHistoryFromMsg(msg, 'customer-1');
  assert.deepEqual(out, [
    { key: 'agent-a|agent-a:1', author: 'agent-a', text: 'Здравствуйте', ts: 1 },
    { key: 'customer-1|client:1', author: 'customer-1', text: 'Привет', ts: 2 },
  ]);
  // Ключ совпадает с ключом живого сообщения от того же телефона → дедуп сработает.
  const live = chatFromMsg(mk('chat', CLIENT_PSEUDO_AUTHOR, { id: 'client:1', text: 'Привет' }), 'customer-1')!;
  assert.equal(live.key, out[1].key);
  // Без identity отправителя псевдо-автор остаётся как есть; ts без числа — из конверта.
  const fb = chatHistoryFromMsg(mk('chat-sync', CLIENT_PSEUDO_AUTHOR, {
    history: [{ id: 'client:9', author: CLIENT_PSEUDO_AUTHOR, text: 'x' } as unknown as ChatItem],
  }));
  assert.deepEqual(fb, [{ key: 'client|client:9', author: 'client', text: 'x', ts: now }]);
  assert.deepEqual(chatHistoryFromMsg(mk('chat', 'a', { id: 'a:1', text: 'x' }), 'a'), []);
  assert.deepEqual(chatHistoryFromMsg(mk('chat-sync', CLIENT_PSEUDO_AUTHOR, {}), 'a'), []);
});

console.log(`\n${passed} tests passed.`);
