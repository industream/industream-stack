const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const code = fs.readFileSync(path.join(__dirname, '../../scripts/generate/monitoring/cards.js'), 'utf8');

function render(series, config = { defaults: {}, overrides: [] }) {
  const helpers = {};
  new Function('context', 'monitoringFieldConfig', code)({
    handlebars: { registerHelper: (name, fn) => { helpers[name] = fn; } },
    grafana: { theme: { visualization: { getColorByName: (name) => ({ red: '#f00', green: '#0f0', orange: '#fa0' })[name] || name }, colors: {
      text: { primary: '#eee', secondary: '#aaa' },
      border: { weak: '#333' }, background: { secondary: '#222' },
    } } },
    panelData: { series },
  }, config);
  return helpers.monitoringValues();
}

const field = (values, extra = {}) => ({ type: 'number', name: 'Value', values, config: {}, ...extra });

test('zero survives trailing nulls; formatting and mapped status color come from Grafana', () => {
  const values = render([{ fields: [field([1, 0, null, NaN], {
    display: (v) => { assert.equal(v, 0); return { text: 'Disconnected', color: '#f00' }; },
  })] }]);
  assert.equal(values[0].value, 0);
  assert.equal(values[0].text, 'Disconnected');
  assert.equal(values[0].color, '#f00');
});

test('missing data remains neutral, including all-null numeric fields', () => {
  assert.deepEqual(render([]), []);
  const values = render([{ fields: [field([null, NaN, Infinity, undefined], {
    display: () => { throw new Error('Missing data must not map to a healthy zero'); },
  })] }]);
  assert.equal(values[0].text, 'No data');
  assert.equal(values[0].color, '#aaa');
  assert.equal(values[0].meter, false);
});

test('every endpoint and query frame is kept separate, without summing values', () => {
  const endpoints = Array.from({ length: 50 }, (_, i) => ({ fields: [
    { type: 'time', name: 'Time', values: [1] },
    field([i], { labels: { endpoint: `opc.tcp://plc-${i}:4840` } }),
  ] }));
  const values = render(endpoints);
  assert.equal(values.length, 50);
  assert.equal(values[49].label, 'opc.tcp://plc-49:4840');
  assert.equal(values[49].value, 49);
});

test('units and resolved display names follow the field display processor', () => {
  const values = render([{ name: 'frame', fields: [field([1024], {
    state: { displayName: 'RAM · node-1' },
    display: () => ({ text: '1.00', suffix: 'KiB', color: '#123456' }),
  })] }]);
  assert.equal(values[0].label, 'RAM · node-1');
  assert.equal(values[0].text, '1.00 KiB');
});

test('gauge drawing clamps to the configured range without clamping the displayed value', () => {
  const values = render([{ fields: [field([120], { config: { min: 0, max: 100 } })] }]);
  assert.equal(values[0].percent, 100);
  assert.equal(values[0].text, '120');
  assert.equal(values[0].value, 120);
});

test('Business Text disabled field options are restored from the embedded panel configuration', () => {
  const config = { defaults: {
    min: 0, max: 100,
    color: { mode: 'thresholds' },
    thresholds: { steps: [{ value: null, color: 'green' }, { value: 1, color: 'orange' }] },
    mappings: [{ type: 'value', options: { 0: { text: 'Disconnected', color: 'red' } } }],
  }, overrides: [] };
  const values = render([{ fields: [field([0]), field([15]), field([null])] }], config);
  assert.equal(values[0].text, 'Disconnected');
  assert.equal(values[0].color, '#f00');
  assert.equal(values[1].color, '#fa0');
  assert.equal(values[1].meter, true);
  assert.equal(values[2].text, 'No data');
  assert.equal(values[2].color, '#aaa');
});

test('named overrides can change a mapping without affecting other series', () => {
  const values = render([{ fields: [field([0], { name: 'one' }), field([0], { name: 'two' })] }], {
    defaults: {}, overrides: [{ matcher: { id: 'byName', options: 'two' }, properties: [
      { id: 'mappings', value: [{ type: 'value', options: { 0: { text: 'Stopped', color: 'orange' } } }] },
    ] }],
  });
  assert.equal(values[0].text, '0');
  assert.equal(values[1].text, 'Stopped');
});
