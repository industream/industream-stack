// Presentation only: select each series' last non-null value, then let Grafana
// apply its units. Business Text disables Grafana's color/mapping/min/max field
// options, so the generator embeds that presentation configuration explicitly.
// PromQL owns
// rates, totals and ratios. Keep every endpoint/worker separate.
const theme = context.grafana.theme.colors;
const colorOf = (name) => name === 'text' ? theme.text.primary :
  context.grafana.theme.visualization.getColorByName(name);
context.handlebars.registerHelper('monitoringTheme', () =>
  `--monitoring-text:${theme.text.primary};--monitoring-muted:${theme.text.secondary};` +
  `--monitoring-border:${theme.border.weak};--monitoring-bg:${theme.background.secondary};`);

context.handlebars.registerHelper('monitoringValues', () => {
  const cards = [];
  for (const frame of context.panelData.series) {
    for (const field of frame.fields) {
      if (field.type !== 'number') continue;
      const config = { ...field.config, ...monitoringFieldConfig.defaults };
      for (const override of monitoringFieldConfig.overrides || []) {
        const { id, options } = override.matcher;
        const name = field.state?.displayName || field.name;
        const matches = id === 'byName' ? options === name :
          id === 'byType' ? options === field.type :
          id === 'byFrameRefID' ? options === frame.refId :
          id === 'byRegexp' ? new RegExp(options).test(name) : false;
        if (matches) for (const property of override.properties) config[property.id] = property.value;
      }
      let value = null;
      for (let i = field.values.length - 1; i >= 0; i--) {
        const candidate = field.values[i];
        if (typeof candidate === 'number' && Number.isFinite(candidate)) {
          value = candidate;
          break;
        }
      }
      const display = value === null ? null : field.display?.(value);
      const mapping = value === null ? null : (config.mappings || [])
        .find((m) => Object.hasOwn(m.options, String(value)))?.options[String(value)];
      const text = value === null ? 'No data' : mapping?.text ?? (display
        ? [display.prefix, display.text, display.suffix].filter(Boolean).map((p) => p.trim()).join(' ')
        : String(value));
      let color = display?.color || theme.text.secondary;
      if (value !== null && config.color?.mode === 'thresholds') {
        for (const step of config.thresholds?.steps || []) {
          if (step.value === null || value >= step.value) color = colorOf(step.color);
        }
      }
      if (mapping?.color) color = colorOf(mapping.color);
      const label = field.state?.displayName || field.config.displayNameFromDS ||
        frame.name || field.labels?.endpoint || field.labels?.instance || field.name;
      const min = config.min;
      const max = config.max;
      const meter = value !== null && Number.isFinite(min) && Number.isFinite(max) && max > min;
      cards.push({
        label, text, color, meter, min, max, value,
        // Drawing scale only, like the native gauge; the displayed value is never clamped.
        percent: meter ? Math.max(0, Math.min(100, (value - min) / (max - min) * 100)) : 0,
      });
    }
  }
  return cards;
});
