/**
 * Just-in-time steering strings appended to specific tool results.
 *
 * These encode the core operating principle of this MCP: the model can change
 * the Studio world, but it cannot *perceive* how that world feels, looks in
 * motion, responds to input, or sounds. For anything it can't read back as a
 * fact, it should INSTRUMENT (debug prints, on-screen readouts, visual markers,
 * attribute mirroring) and hand the test to the human — rather than looping on
 * play-tests and screenshots trying to judge correctness it can't observe.
 *
 * We keep these here (not inline in the tool descriptions) on purpose:
 *   - The description is always-on context, paid for on every turn.
 *   - A nudge is on-demand: it only shows up in the result when the tool fires,
 *     which is the moment the reminder is most actionable and least wasteful.
 *
 * Wording is deliberately short. The goal is a reliable behavioral nudge, not
 * a manual.
 */

/** For play_solo / get_playtest_output — the "testing tools are a smoke check" rule. */
export const INSTRUMENT_OVER_PLAYTEST =
  'Smoke check only. Use the play test to confirm the game boots and to catch ' +
  'errors/tracebacks — not to judge whether behavior is correct. For behavior, ' +
  'timing, or feel: add event-keyed debug prints or an on-screen readout, then ' +
  'hand the test to the user with a short test card (do X → watch for Y → paste ' +
  'Z back) and wait. Do not loop play-tests trying to perceive feel from output.';

/** For run_live_lua — bias toward reading back facts, not probing for feel. */
export const RUN_LIVE_LUA_NUDGE =
  'Best used to read back FACTS (return values, live state, assertions) or to ' +
  'drive the live world. If the question is about feel, motion, or visuals, ' +
  'instrument it for the user instead of probing repeatedly — you cannot ' +
  'perceive those from return values.';

/** For capture_screenshot / render_object_view / render_gui — a frame isn't motion. */
export const STILL_FRAME_NUDGE =
  'A still frame cannot show motion, timing, input response, or audio. For any ' +
  'of those, instrument and hand the test to the user — do not try to infer ' +
  'them from an image.';
