const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { test } = require('node:test');
const { runInNewContext } = require('node:vm');

function clock() {
  const elements = { hour: {}, min: {}, sec: {} };
  const callbacks = new Map();
  let timestamp = 0;
  let sequence = 0;
  const context = {
    Date: { now: () => timestamp },
    document: { getElementById: identifier => elements[identifier] },
    setInterval: callback => { callbacks.set(++sequence, callback); return sequence; },
    clearInterval: identifier => callbacks.delete(identifier)
  };
  runInNewContext(readFileSync(join(__dirname, '../assets/javascripts/time_logger.js'), 'utf8'), context);
  return {
    context, elements, callbacks,
    advance: milliseconds => { timestamp += milliseconds; callbacks.forEach(callback => callback()); },
    display: () => [elements.hour, elements.min, elements.sec].map(element => element.textContent).join(':')
  };
}

test('delayed ticks use elapsed wall time, not interval count', () => {
  const timer = clock();
  timer.context.start_timer(58, 59, 0);
  assert.equal(timer.display(), '00:59:58');
  timer.advance(65000);
  assert.equal(timer.display(), '01:01:03');
});

test('pause stops ticking; resume uses server-provided elapsed seconds', () => {
  const timer = clock();
  timer.context.start_timer(10, 0, 0);
  timer.advance(2000);
  timer.context.pause_timer();
  timer.advance(300000);
  assert.equal(timer.display(), '00:00:12');
  timer.context.start_timer(12, 0, 0);
  timer.advance(3000);
  assert.equal(timer.display(), '00:00:15');
  assert.equal(timer.callbacks.size, 1);
});

test('replacing timer markup resynchronizes without duplicate intervals', () => {
  const timer = clock();
  timer.context.start_timer(0, 0, 0);
  timer.advance(3000);
  timer.context.start_timer(20, 0, 1);
  assert.equal(timer.display(), '01:00:20');
  assert.equal(timer.callbacks.size, 1);
  delete timer.elements.sec;
  assert.doesNotThrow(() => timer.advance(1000));
});