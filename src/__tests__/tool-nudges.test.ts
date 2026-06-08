import { applyNudge, toolsByName } from '../tools/registry';
import {
  INSTRUMENT_OVER_PLAYTEST,
  RUN_LIVE_LUA_NUDGE,
  STILL_FRAME_NUDGE,
} from '../tools/nudges';

describe('applyNudge', () => {
  test('is a no-op when there is no nudge', () => {
    const result = { content: [{ type: 'text', text: 'body' }] };
    expect(applyNudge(result, undefined)).toBe(result);
  });

  test('appends the nudge as a trailing text block on MCP-shaped results', () => {
    const result = { content: [{ type: 'text', text: 'body' }] };
    const out = applyNudge(result, 'be careful') as any;

    // Original is not mutated.
    expect(result.content).toHaveLength(1);
    // New result has the nudge appended last.
    expect(out.content).toHaveLength(2);
    expect(out.content[0]).toEqual({ type: 'text', text: 'body' });
    expect(out.content[1]).toEqual({ type: 'text', text: 'be careful' });
  });

  test('preserves sibling result fields (e.g. image blocks, isError)', () => {
    const result = {
      isError: false,
      content: [
        { type: 'text', text: 'meta' },
        { type: 'image', data: 'abc', mimeType: 'image/png' },
      ],
    };
    const out = applyNudge(result, 'hint') as any;

    expect(out.isError).toBe(false);
    expect(out.content).toHaveLength(3);
    expect(out.content[2]).toEqual({ type: 'text', text: 'hint' });
    // Image block survives unchanged.
    expect(out.content[1]).toEqual({ type: 'image', data: 'abc', mimeType: 'image/png' });
  });

  test('returns non-MCP-shaped results untouched even with a nudge', () => {
    const plain = { foo: 'bar' };
    expect(applyNudge(plain, 'hint')).toBe(plain);
    expect(applyNudge('just-a-string', 'hint')).toBe('just-a-string');
    expect(applyNudge(undefined, 'hint')).toBeUndefined();
  });
});

describe('tool nudge wiring', () => {
  const expected: Record<string, string> = {
    play_solo: INSTRUMENT_OVER_PLAYTEST,
    get_playtest_output: INSTRUMENT_OVER_PLAYTEST,
    run_live_lua: RUN_LIVE_LUA_NUDGE,
    capture_screenshot: STILL_FRAME_NUDGE,
    render_object_view: STILL_FRAME_NUDGE,
    render_gui: STILL_FRAME_NUDGE,
  };

  test.each(Object.entries(expected))('%s carries the expected nudge', (name, nudge) => {
    expect(toolsByName[name].nudge).toBe(nudge);
  });

  test('non-instrumentation tools do not carry a nudge', () => {
    // A nudge on every tool would defeat the point (and waste tokens). Spot-check
    // that read/mutation tools stay quiet.
    expect(toolsByName['get_instance_properties'].nudge).toBeUndefined();
    expect(toolsByName['set_property'].nudge).toBeUndefined();
    expect(toolsByName['edit_script'].nudge).toBeUndefined();
  });
});
